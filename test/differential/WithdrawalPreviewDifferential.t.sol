// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Withdrawal-preview differential generator
/// @notice The withdrawal preview is implemented TWICE — once in the Rust engine that ships, once in
///         the Solidity reference — and the two are written to mirror each other. Each side has its
///         own tests, but only this lane proves they agree. It drives the REAL Solidity `PerpPair`
///         through a grid of seeded states, records the inputs and the `withdrawalCheckData` verdict
///         into a JSON fixture, and the Rust engine replays it under `stub_boundary` (perp-engine
///         test `withdrawal_preview_differential`) asserting bit-exact equality.
///
///         State is SEEDED rather than traded into. The preview must be pinned over states a trade
///         sequence cannot reach — a dust asset leg below the 1e13 cutoff, a net short at the pool
///         boundary, an open curve window whose accumulator exceeds the leg it is netted against —
///         and `minimumTradeSize` alone rules most of those out.
///
///         Two invariants the fixture must hold, or the comparison is invalid: the curve parameters
///         stay at A=1e8, B=1e7, curveDecimals=1e8, and tradingFeeDecimals stays 1e18. The engine
///         HARDCODES all four on this path while the reference reads them from storage, so varying
///         them would manufacture a divergence that cannot occur in production (neither repo has a
///         setter for them).
contract MockOracleW {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000;
    }
}

contract MockVaultW {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
}

contract PerpWithdrawalRef is PerpPair {
    constructor(
        address o,
        address v,
        address f
    )
        PerpPair(
            o, v, address(1), (40 * 1e6) / 1000, bytes32("BENCH"), uint32(300_000), uint32(500_000), f, 0, 12e16, 9e7
        )
    { }

    struct Seed {
        uint256 poolStable;
        uint256 poolAsset;
        uint256 balanceStable;
        uint256 balanceAsset;
        uint256 debtStable;
        uint256 debtAsset;
        uint256 fundingFee;
        bool fundingFeeSign;
        uint256 lpInitialStable;
        uint256 lpInitialAsset;
        uint256 lpDebtStable;
        uint256 lpDebtAsset;
        uint256 dx0;
        uint256 dy0;
        uint256 lastCurveUpdate;
        bool lastTradeDirection;
        uint256 lastValidatedPrice;
    }

    function seedCase(address user, Seed memory s) external {
        globalLiquidityStable = s.poolStable;
        globalLiquidityAsset = s.poolAsset;

        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        pos.balanceStable = s.balanceStable;
        pos.balanceAsset = s.balanceAsset;
        pos.debtStable = s.debtStable;
        pos.debtAsset = s.debtAsset;
        pos.fundingFee = s.fundingFee;
        pos.fundingFeeSign = s.fundingFeeSign;

        // Scaled-identity snapshot and epoch matrix, so LP recovery returns the seeded balances
        // exactly and the fixture pins the PREVIEW rather than the matrix machinery.
        int256 scale = decimals.liquidityMDecimals;
        LiquidityEpoch storage epoch = liquidityEpochs[currentLiquidityEpoch];
        epoch.liquidityM = [[scale, int256(0)], [int256(0), scale]];
        LiquidityPosition storage lp = liquidityPosition[user];
        if (s.lpInitialStable != 0 || s.lpInitialAsset != 0) {
            lp.snapshotM = [[scale, int256(0)], [int256(0), scale]];
            epoch.activeLpCount = 1;
        }
        lp.initialStableBalance = s.lpInitialStable;
        lp.initialAssetBalance = s.lpInitialAsset;
        lp.debtStable = s.lpDebtStable;
        lp.debtAsset = s.lpDebtAsset;
        liquidityPositionEpoch[user] = currentLiquidityEpoch;

        dx0 = s.dx0;
        dy0 = s.dy0;
        curveParameters.lastCurveUpdate = s.lastCurveUpdate;
        curveParameters.lastTradeDirection = s.lastTradeDirection;
        curveParameters.lastValidatedPrice = s.lastValidatedPrice;
    }

    function clearCase(address user) external {
        delete userVirtualTraderPosition[user];
        delete liquidityPosition[user];
    }
}

contract WithdrawalPreviewDifferentialTest is Test {
    string constant FIXTURE_PATH = "/test/fixtures/withdrawal_preview_differential.json";
    uint256 constant PRICE = 300_000_000_000;
    uint256 constant BLOCK_TS = 1_700_000_000;

    PerpWithdrawalRef internal ref;
    address internal user = address(0xBEEF);

    function test_generate() external {
        vm.warp(BLOCK_TS);
        ref = new PerpWithdrawalRef(address(new MockOracleW()), address(new MockVaultW()), address(this));

        string memory cases;
        cases = _case(cases, "trader-long", _base(), 1000e18);

        PerpWithdrawalRef.Seed memory s = _base();
        s.balanceAsset = 100e18;
        cases = _case(cases, "trader-long-asset-leg", s, 1000e18);

        s = _base();
        s.debtAsset = 100e18;
        s.balanceStable = 10_000_000e18;
        cases = _case(cases, "trader-short", s, 1000e18);

        s = _base();
        s.balanceAsset = 100e18;
        s.lastTradeDirection = false;
        s.dx0 = 500e18;
        s.dy0 = 1_500_000e18;
        cases = _case(cases, "long-leg-open-short-window", s, 1000e18);

        s = _base();
        s.debtAsset = 100e18;
        s.balanceStable = 10_000_000e18;
        s.lastTradeDirection = true;
        s.dx0 = 500e18;
        s.dy0 = 1_500_000e18;
        cases = _case(cases, "short-leg-open-long-window", s, 1000e18);

        // The guard case: a net short on a stable-heavy pool under an open long window, where the
        // quote takes its spot short circuit and the raw `- dy0` would go negative.
        s = _base();
        s.poolStable = 1_000_000e18;
        s.poolAsset = 1e18;
        s.debtAsset = 1e18;
        s.balanceStable = 100_000e18;
        s.lastTradeDirection = true;
        s.dy0 = 500_000e18;
        cases = _case(cases, "short-at-pool-boundary-thin-asset", s, 1000e18);

        // Dust: one wei either side of the 1e13 * oracleDecimals / price cutoff, on the short leg.
        uint256 cutoff = 1e13 * 1e8 / PRICE;
        s = _base();
        s.debtAsset = cutoff;
        s.balanceStable = 1000e18;
        cases = _case(cases, "dust-short-at-cutoff", s, 1e18);
        s.debtAsset = cutoff + 1;
        cases = _case(cases, "dust-short-over-cutoff", s, 1e18);

        // LP-only, and mixed trader + LP: the legs are summed BEFORE pricing, so a mixed position is
        // quoted as ONE close and takes more slippage than pricing the legs apart would.
        s = _base();
        s.lpInitialStable = 1_000_000e18;
        s.lpInitialAsset = 100e18;
        s.lpDebtStable = 500_000e18;
        cases = _case(cases, "lp-only", s, 1_000_000e18);

        s = _base();
        s.balanceAsset = 50e18;
        s.lpInitialStable = 1_000_000e18;
        s.lpInitialAsset = 100e18;
        cases = _case(cases, "mixed-trader-and-lp", s, 1_000_000e18);

        // Funding on both signs.
        s = _base();
        s.balanceAsset = 100e18;
        s.fundingFee = 5e18;
        s.fundingFeeSign = true;
        cases = _case(cases, "funding-payable", s, 1000e18);
        s.fundingFeeSign = false;
        cases = _case(cases, "funding-receivable", s, 1000e18);

        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), string.concat('{"cases":[', cases, "]}"));
    }

    function _base() internal pure returns (PerpWithdrawalRef.Seed memory s) {
        s.poolStable = 18_000_000e18;
        s.poolAsset = 6000e18;
        s.lastCurveUpdate = BLOCK_TS;
        s.lastValidatedPrice = PRICE;
    }

    function _case(
        string memory acc,
        string memory label,
        PerpWithdrawalRef.Seed memory s,
        uint256 hypotheticalCollateral
    )
        internal
        returns (string memory)
    {
        ref.clearCase(user);
        ref.seedCase(user, s);
        (uint256 pnl, bool pnlSign, bool marginSafe) = ref.withdrawalCheckData(user, PRICE, hypotheticalCollateral);

        string memory head = string.concat(
            '{"label":"',
            label,
            '","price":"',
            vm.toString(PRICE),
            '","blockTs":"',
            vm.toString(BLOCK_TS),
            '","hypotheticalCollateral":"',
            vm.toString(hypotheticalCollateral),
            '","poolStable":"',
            vm.toString(s.poolStable),
            '","poolAsset":"',
            vm.toString(s.poolAsset),
            '","balanceStable":"',
            vm.toString(s.balanceStable),
            '","balanceAsset":"',
            vm.toString(s.balanceAsset),
            '","debtStable":"',
            vm.toString(s.debtStable),
            '","debtAsset":"',
            vm.toString(s.debtAsset),
            '"'
        );
        string memory mid = string.concat(
            ',"fundingFee":"',
            vm.toString(s.fundingFee),
            '","fundingFeeSign":',
            s.fundingFeeSign ? "true" : "false",
            ',"lpInitialStable":"',
            vm.toString(s.lpInitialStable),
            '","lpInitialAsset":"',
            vm.toString(s.lpInitialAsset),
            '","lpDebtStable":"',
            vm.toString(s.lpDebtStable),
            '","lpDebtAsset":"',
            vm.toString(s.lpDebtAsset),
            '","dx0":"',
            vm.toString(s.dx0),
            '","dy0":"',
            vm.toString(s.dy0),
            '"'
        );
        string memory tail = string.concat(
            ',"lastCurveUpdate":"',
            vm.toString(s.lastCurveUpdate),
            '","lastTradeDirection":',
            s.lastTradeDirection ? "true" : "false",
            ',"lastValidatedPrice":"',
            vm.toString(s.lastValidatedPrice),
            '","pnl":"',
            vm.toString(pnl),
            '","pnlSign":',
            pnlSign ? "true" : "false",
            ',"marginSafe":',
            marginSafe ? "true" : "false",
            "}"
        );
        string memory entry = string.concat(head, mid, tail);
        return bytes(acc).length == 0 ? entry : string.concat(acc, ",", entry);
    }
}
