// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Liquidation stateful differential generator (review finding F-04, scenario 4)
/// @notice Drives the REAL Solidity `PerpPair` public `liquidate` path through a full
///         bad-debt SHORT liquidation (which also exercises short CLOSE, the case deferred
///         from scenario 3) and a full bad-debt LONG liquidation. Each op's pre-state
///         (the liquidatable position + the liquidator's funding) is set via a harness
///         setter and RECORDED in the fixture, so the Rust/Stylus `PerpEngine` replays the
///         identical setup + `liquidateFor` under `stub_boundary` (perp-engine test
///         `liquidation_differential`) and asserts bit-exact. Env mirrors the Stylus stub:
///         oracle 3000e8, vault collateral 1000e18 (the MMR-gate collateral).
contract MockOracleLq {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000;
    }
}

contract MockVaultLq {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
    function addPnlToCollateral(address, uint256, bool) external { }
    function removeAllCollateralForUser(address) external { }
}

contract PerpLiquidationRef is PerpPair {
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

    function setVtp(address u, uint256 balS, uint256 balA, uint256 debtS, uint256 debtA) external {
        VirtualTraderPosition storage p = userVirtualTraderPosition[u];
        p.balanceStable = balS;
        p.balanceAsset = balA;
        p.debtStable = debtS;
        p.debtAsset = debtA;
    }

    function getInsurance() external view returns (uint256, bool) {
        return (insuranceFund, insuranceFundSign);
    }
}

contract LiquidationDifferentialTest is Test {
    string internal constant FIXTURE_PATH = "/test/fixtures/liquidation_differential.json";

    PerpLiquidationRef ref;

    uint256 internal constant MAX_SLIP = 50_000;
    uint256 internal constant MAX_LIQ_FEE = 1e18;
    uint256 internal constant LOSS_TH = 1;

    struct Setup {
        uint256 uBalS;
        uint256 uBalA;
        uint256 uDebtS;
        uint256 uDebtA;
        uint256 lqBalS;
        uint256 lqBalA;
    }

    function test_generate() external {
        ref = new PerpLiquidationRef(address(new MockOracleLq()), address(new MockVaultLq()), address(this));
        ref.seedReserves(18_000_000e18, 6000e18);

        // op0: full bad-debt SHORT (user owes 10e18 asset, MR=0). Liquidator pre-funded with
        // the asset it must hand over. Also exercises short close.
        string memory ops = liqOp(address(0x51), address(0x52), 10e18, 1000, Setup(0, 0, 0, 10e18, 0, 10e18));
        // op1: full bad-debt LONG (user holds 10e18 asset but owes 35000e18 stable → underwater,
        // MR=0). Liquidator pre-funded with stable to pay for the asset it receives.
        ops = string.concat(
            ops, ",", liqOp(address(0x61), address(0x62), 10e18, 4600, Setup(0, 10e18, 35_000e18, 0, 100_000e18, 0))
        );
        // op2: auto-close on a LOSS threshold. A slightly-underwater long (1e18 asset,
        // 3500e18 stable debt → curve-close loss ~500e18 < collateral) with lossTh=1; a
        // keeper triggers autoCloseUserPosition and collects the autoCloseFee. (Long close
        // is C0-clean.)
        ops = string.concat(ops, ",", autoCloseOp(address(0x71), address(0x72), 8200));
        // op3: PARTIAL liquidation — the fraction/discount branch the full bad-debt ops above do
        // not reach. A long in the partial MR band: balanceAsset 10e18, debtStable 30100e18,
        // collateral 1000e18 → MR ~30000 (MMR=40000, MMR/2=20000, so MMR/2 < MR <= MMR ⇒
        // partial-only). liquidatedPositionSize 4e18 → fraction 0.4 (<= 0.5), so
        // `_liquidatePosition` runs WITHOUT the full close+sweep (fraction != 1) and the user
        // keeps a residual position. Liquidator pre-funded with stable (long liquidation pays it).
        ops = string.concat(
            ops, ",", liqOp(address(0x81), address(0x82), 4e18, 10_000, Setup(0, 10e18, 30_100e18, 0, 100_000e18, 0))
        );

        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), string.concat('{"ops":[', ops, "]}"));
    }

    function liqOp(
        address user,
        address liquidator,
        uint256 size,
        uint256 ts,
        Setup memory s
    )
        internal
        returns (string memory)
    {
        vm.warp(ts);
        ref.setVtp(user, s.uBalS, s.uBalA, s.uDebtS, s.uDebtA);
        ref.setVtp(liquidator, s.lqBalS, s.lqBalA, 0, 0);
        vm.prank(liquidator);
        ref.liquidate(user, size, "");

        string memory head = string.concat(
            '{"kind":"liquidate","user":"',
            vm.toString(user),
            '","liquidator":"',
            vm.toString(liquidator),
            '","size":"',
            vm.toString(size),
            '","blockTs":"',
            vm.toString(ts),
            '"'
        );
        string memory setup = string.concat(
            ',"uBalS":"',
            vm.toString(s.uBalS),
            '","uBalA":"',
            vm.toString(s.uBalA),
            '","uDebtS":"',
            vm.toString(s.uDebtS),
            '","uDebtA":"',
            vm.toString(s.uDebtA),
            '","lqBalS":"',
            vm.toString(s.lqBalS),
            '","lqBalA":"',
            vm.toString(s.lqBalA),
            '"'
        );
        return string.concat(head, setup, stateJson(user, liquidator), "}");
    }

    function autoCloseOp(address user, address keeper, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        ref.setVtp(user, 0, 1e18, 3500e18, 0); // underwater long → loss
        vm.prank(user);
        ref.enableAutoClose(0, LOSS_TH, MAX_SLIP, MAX_LIQ_FEE);
        vm.prank(keeper);
        ref.autoCloseUserPosition(user, address(0), "");

        string memory head = string.concat(
            '{"kind":"autoclose","user":"',
            vm.toString(user),
            '","liquidator":"',
            vm.toString(keeper),
            '","size":"0","blockTs":"',
            vm.toString(ts),
            '"'
        );
        // record the setup so the Rust side writes the identical pre-state + enableAutoClose args
        string memory setup = string.concat(
            ',"uBalS":"0","uBalA":"',
            vm.toString(uint256(1e18)),
            '","uDebtS":"',
            vm.toString(uint256(3500e18)),
            '","uDebtA":"0","lqBalS":"0","lqBalA":"0","lossTh":"',
            vm.toString(LOSS_TH),
            '","maxSlip":"',
            vm.toString(MAX_SLIP),
            '","maxLiqFee":"',
            vm.toString(MAX_LIQ_FEE),
            '"'
        );
        return string.concat(head, setup, stateJson(user, keeper), "}");
    }

    function stateJson(address user, address liquidator) internal view returns (string memory) {
        (uint256 ins, bool insSign) = ref.getInsurance();
        string memory glob = string.concat(
            ',"gStable":"',
            vm.toString(ref.globalLiquidityStable()),
            '","gAsset":"',
            vm.toString(ref.globalLiquidityAsset()),
            '","exposure":"',
            vm.toString(ref.totalTraderExposure()),
            '","exposureSign":',
            ref.totalTraderExposureSign() ? "true" : "false",
            ',"insurance":"',
            vm.toString(ins),
            '","insuranceSign":',
            insSign ? "true" : "false"
        );
        return string.concat(glob, posJson("u", user), posJson("lq", liquidator));
    }

    function posJson(string memory pfx, address u) internal view returns (string memory) {
        (uint256 balS, uint256 balA, uint256 debtS, uint256 debtA,,,,) = ref.userVirtualTraderPosition(u);
        return string.concat(
            ',"',
            pfx,
            "BalS_post",
            '":"',
            vm.toString(balS),
            '","',
            pfx,
            "BalA_post",
            '":"',
            vm.toString(balA),
            '","',
            pfx,
            "DebtS_post",
            '":"',
            vm.toString(debtS),
            '","',
            pfx,
            "DebtA_post",
            '":"',
            vm.toString(debtA),
            '"'
        );
    }
}
