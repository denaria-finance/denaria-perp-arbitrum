// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Close + PnL stateful differential generator
/// @notice Drives the REAL Solidity `PerpPair` through open→close (long) and open→realizePnL
///         sequences, snapshotting full state after each op into a JSON fixture. The
///         Rust/Stylus `PerpEngine` replays it under `stub_boundary` (perp-engine test
///         `close_pnl_differential`) and asserts bit-exact. Env mirrors the Stylus stub:
///         oracle 3000e8, vault collateral 1000e18.
///
///         Short SELF-close (closeAndWithdraw on a short) is intentionally NOT exercised
///         here: on the real `PerpPair` it buys back `debtAsset + dx0` and reverts `C0`
///         unless the post-buyback residual lands within the dust bound
///         (max(1e10, globalLiquidityStable / 1e10)) — a real-engine property,
///         not a Stylus divergence. Short CLOSE is covered via the liquidation path
///         (which closes shorts through `liquidate`) and the C0
///         envelope harness (test/c0_envelope/).
contract MockOracleC {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000;
    }
}

contract MockVaultC {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
    // close/realizePnL forward (pnl, sign) here; a no-op keeps the boundary cost without
    // moving collateral (the engine's own accounting is what the differential compares).
    function addPnlToCollateral(address, uint256, bool) external { }
    function removeAllCollateral(bytes calldata) external { }
}

contract PerpClosePnlRef is PerpPair {
    constructor(
        address o,
        address v,
        address f
    )
        PerpPair(
            o, v, address(1), (40 * 1e6) / 1000, bytes32("BENCH"), uint32(300_000), uint32(500_000), f, 0, 12e16, 9e7
        )
    { }

    function seedReserves(uint256 s, uint256 a) external {
        globalLiquidityStable = s;
        globalLiquidityAsset = a;
    }

    function getG() external view returns (int256, int256) {
        return (matrixRowG[0], matrixRowG[1]);
    }

    function getInsurance() external view returns (uint256, bool) {
        return (insuranceFund, insuranceFundSign);
    }
}

contract ClosePnlDifferentialTest is Test {
    string internal constant FIXTURE_PATH = "/test/fixtures/close_pnl_differential.json";

    PerpClosePnlRef ref;
    address internal ua = address(0xA);
    address internal ub = address(0xB);
    address internal uc = address(0xC);
    address internal ud = address(0xD);

    uint256 internal constant MAX_SLIP = 50_000; // 50% tolerance (units of 1e5): no slippage revert
    uint256 internal constant MAX_LIQ_FEE = 1e18;

    function test_generate() external {
        ref = new PerpClosePnlRef(address(new MockOracleC()), address(new MockVaultC()), address(this));
        ref.seedReserves(18_000_000e18, 6000e18);

        string memory ops = tradeOp(ua, true, 1000e18, 1, 1000);
        ops = string.concat(ops, ",", closeOp(ua, 4600));
        ops = string.concat(ops, ",", tradeOp(ub, true, 500e18, 1, 8200));
        ops = string.concat(ops, ",", closeOp(ub, 11_800));
        ops = string.concat(ops, ",", tradeOp(uc, true, 800e18, 1, 15_400));
        ops = string.concat(ops, ",", realizeOp(uc, 19_000));
        // leverage>1 regression: `leverage` is an event/T0-only field in perpTrade.trade — it is
        // NOT passed to `_trade`, so a leverage=5 open must produce state IDENTICAL to leverage=1
        // (same size) and must pass T0 (leverage <= maxLeverage). This locks that the engine never
        // uses leverage in the trade math, and exercises the forwarded path at leverage>1.
        ops = string.concat(ops, ",", tradeOp(ud, true, 800e18, 5, 23_800));
        ops = string.concat(ops, ",", closeOp(ud, 28_600));

        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), string.concat('{"ops":[', ops, "]}"));
    }

    function tradeOp(address u, bool dir, uint256 size, uint8 lev, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        vm.prank(u);
        uint256 ret = ref.trade(dir, size, 0, 0, address(0), lev, "");
        string memory head = string.concat(
            '{"kind":"trade","user":"',
            vm.toString(u),
            '","blockTs":"',
            vm.toString(ts),
            '","direction":',
            dir ? "true" : "false",
            ',"size":"',
            vm.toString(size),
            '","leverage":',
            vm.toString(uint256(lev)),
            ',"ret":"',
            vm.toString(ret),
            '","retSign":true'
        );
        return string.concat(head, stateJson(u), "}");
    }

    function closeOp(address u, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        vm.prank(u);
        ref.closeAndWithdraw(MAX_SLIP, MAX_LIQ_FEE, address(0), "");
        string memory head = string.concat(
            '{"kind":"close","user":"', vm.toString(u), '","blockTs":"', vm.toString(ts), '","ret":"0","retSign":true'
        );
        return string.concat(head, stateJson(u), "}");
    }

    function realizeOp(address u, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        vm.prank(u);
        (uint256 pnl, bool sign) = ref.realizePnL("");
        string memory head = string.concat(
            '{"kind":"realizepnl","user":"',
            vm.toString(u),
            '","blockTs":"',
            vm.toString(ts),
            '","ret":"',
            vm.toString(pnl),
            '","retSign":',
            sign ? "true" : "false"
        );
        return string.concat(head, stateJson(u), "}");
    }

    function stateJson(address u) internal view returns (string memory) {
        (int256 g0, int256 g1) = ref.getG();
        (uint256 ins, bool insSign) = ref.getInsurance();
        (uint256 balS, uint256 balA, uint256 debtS, uint256 debtA, uint256 fee, bool feeSign,,) =
            ref.userVirtualTraderPosition(u);
        string memory glob = string.concat(
            ',"gStable":"',
            vm.toString(ref.globalLiquidityStable()),
            '","gAsset":"',
            vm.toString(ref.globalLiquidityAsset()),
            '","fundingRate":"',
            vm.toString(ref.fundingRate()),
            '","fundingRateSign":',
            ref.fundingRateSign() ? "true" : "false",
            ',"exposure":"',
            vm.toString(ref.totalTraderExposure()),
            '","exposureSign":',
            ref.totalTraderExposureSign() ? "true" : "false",
            ',"lastOpTs":"',
            vm.toString(ref.lastOperationTimestamp()),
            '","g0":"',
            vm.toString(g0),
            '","g1":"',
            vm.toString(g1),
            '","insurance":"',
            vm.toString(ins),
            '","insuranceSign":',
            insSign ? "true" : "false"
        );
        string memory usr = string.concat(
            ',"uBalStable":"',
            vm.toString(balS),
            '","uBalAsset":"',
            vm.toString(balA),
            '","uDebtStable":"',
            vm.toString(debtS),
            '","uDebtAsset":"',
            vm.toString(debtA),
            '","uFee":"',
            vm.toString(fee),
            '","uFeeSign":',
            feeSign ? "true" : "false"
        );
        return string.concat(glob, usr);
    }
}
