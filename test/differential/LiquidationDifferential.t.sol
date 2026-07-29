// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Liquidation stateful differential generator
/// @notice Drives the REAL Solidity `PerpPair` public `liquidate` path through a full
///         bad-debt SHORT liquidation (which also exercises short CLOSE) and a full bad-debt LONG liquidation. Each op's pre-state
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
    /// Stateful collateral, defaulting to the stub constant 1000e18 for every untouched account:
    /// auto-close eligibility is decided from the collateral delta the close actually produced, so
    /// a no-op vault would make every auto-close op revert A1. Writes mirror the real
    /// `Vault.addPnlToCollateral` (losses clamp at zero) exactly like the engine's stub_boundary
    /// arm; the ops use distinct users, so every recorded engine value still sees 1000e18.
    mapping(address => uint256) internal collateral;
    mapping(address => bool) internal touched;

    function userCollateral(address user) external view returns (uint256) {
        return touched[user] ? collateral[user] : 1000e18;
    }

    function addPnlToCollateral(address user, uint256 pnl, bool pnlSign) external {
        uint256 current = touched[user] ? collateral[user] : 1000e18;
        touched[user] = true;
        if (pnlSign) {
            collateral[user] = current + pnl;
        } else {
            collateral[user] = current >= pnl ? current - pnl : 0;
        }
    }

    function removeAllCollateralForUser(address user) external {
        touched[user] = true;
        collateral[user] = 0;
    }
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

    /// Seed the slippage benchmarks: the punitive-pricing gate compares the liquidation's own
    /// slippage against `slipLiquidationTh * avgSlippage`, so with the EMAs at zero every
    /// liquidation collapses to the spot fallback and the curve pricing path stays untested.
    function seedAvgSlippages(uint256 l, uint256 s) external {
        avgSlippageL = l;
        avgSlippageS = s;
    }

    function getAvgSlippages() external view returns (uint256, uint256) {
        return (avgSlippageL, avgSlippageS);
    }

    /// The margin ratio exactly as `liquidate` computes it: funding settled for this block
    /// first, then calcMR on the refreshed timestamp. updateFG is idempotent per block, so
    /// calling this before `liquidate` does not change the op's outcome.
    function liquidationMarginRatio(address u) external returns (uint256) {
        uint256 spotPrice = getPrice();
        _updateFG(spotPrice, lastOperationTimestamp);
        return UtilMath.calcMR(u, spotPrice, address(this), getCollateral(u), lastOperationTimestamp);
    }

    /// Scaled-identity LP seed (the WithdrawalPreviewDifferential trick): with both matrices
    /// at identity, LP recovery returns the seeded balances exactly, so the op pins the
    /// LIQUIDATION's LP-pull branch rather than the matrix machinery.
    function seedLp(address u, uint256 initS, uint256 initA, uint256 lpDebtS, uint256 lpDebtA) external {
        int256 scale = decimals.liquidityMDecimals;
        LiquidityEpoch storage epoch = liquidityEpochs[currentLiquidityEpoch];
        epoch.liquidityM = [[scale, int256(0)], [int256(0), scale]];
        epoch.activeLpCount = 1;
        LiquidityPosition storage lp = liquidityPosition[u];
        lp.snapshotM = [[scale, int256(0)], [int256(0), scale]];
        lp.initialStableBalance = initS;
        lp.initialAssetBalance = initA;
        lp.debtStable = lpDebtS;
        lp.debtAsset = lpDebtA;
        liquidityPositionEpoch[u] = currentLiquidityEpoch;
    }

    function getLpState(address u) external view returns (uint256 s, uint256 a, uint256 ds, uint256 da) {
        (s, a) = getLpLiquidityBalance(u);
        LiquidityPosition storage lp = liquidityPosition[u];
        return (s, a, lp.debtStable, lp.debtAsset);
    }

    function getG() external view returns (int256, int256) {
        return
            (liquidityEpochs[currentLiquidityEpoch].matrixRowG[0], liquidityEpochs[currentLiquidityEpoch].matrixRowG[1]);
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
        // op4: fraction EXACTLY at the soft-band half cap. Same soft-band long as op3, size 5e18
        // → fraction = 500_000 = liquidationDecimals/2 exactly: the band require admits it via
        // `<=`; a one-sided regression to `<` makes the replay revert LQ1 here.
        ops = string.concat(
            ops,
            ",",
            liqOpSeeded(
                Party(address(0x91), address(0x92)),
                5e18,
                26_200,
                Setup(0, 10e18, 30_100e18, 0, 100_000e18, 0),
                Seeded(0, 0, 20_000, 39_999)
            )
        );
        // op5: margin ratio just UNDER MMR/2, with a fraction (0.6) only the hard band admits.
        // Pins the band placement at threshold adjacency: a cross-language MR divergence of a
        // few units flips the band and the replay reverts LQ1. Unit-level MR parity is pinned
        // by the replay's direct assert on the recorded `mr` (the discount formula plateaus
        // over ~2.67 MR units, so outcome asserts alone cannot see a ±1-unit divergence).
        ops = string.concat(
            ops,
            ",",
            liqOpSeeded(
                Party(address(0x93), address(0x94)),
                6e18,
                29_800,
                Setup(0, 10e18, 3_040_012e16, 0, 100_000e18, 0),
                Seeded(0, 0, 19_900, 19_999)
            )
        );
        // op6: full NON-bad-debt LONG liquidation through the CURVE dyPrime. Loss 600e18 <
        // collateral 1000e18 (no bad-debt spot fallback) and avgSlippageS seeded high, so
        // `slip > slipLiquidationTh * avgSlippageS` is false and the punitive pricing takes
        // the curve branch — unreachable while the lane's EMAs were all zero.
        ops = string.concat(
            ops,
            ",",
            liqOpSeeded(
                Party(address(0x95), address(0x96)),
                10e18,
                33_400,
                Setup(0, 10e18, 30_600e18, 0, 100_000e18, 0),
                Seeded(0, 1e8, 1, 19_999)
            )
        );
        // op7: full NON-bad-debt SHORT liquidation: the buy-back dyPrime is priced by the
        // EXECUTABLE QUOTE (computeExecutableAmountInLong) and, with the bad-debt and slippage
        // overrides both false, that quote survives into the transfer accounting — the quote
        // machinery inside a liquidation for the first time in any differential. The liquidator
        // hands over the asset.
        ops = string.concat(
            ops,
            ",",
            liqOpSeeded(
                Party(address(0x97), address(0x98)),
                10e18,
                37_000,
                Setup(29_400e18, 0, 0, 10e18, 0, 10e18),
                Seeded(1e8, 0, 1, 19_999)
            )
        );

        // op8: liquidation of a user HOLDING LP liquidity — the LP-pull branch (LP legs in the
        // fraction denominator, the required-asset-removal override, the nested fee-bearing
        // _removeLiquidity) never ran in any differential. The LP is asset-HEDGED (borrowed
        // asset), the only shape where the override BINDS: the fraction-proportional pull
        // cannot cover LP debt + the liquidated size over the trader leg, so the pull is
        // topped up. Partial fraction (0.75) → no close sweep, the residual stays visible.
        ops = string.concat(
            ops,
            ",",
            lpLiqOp(
                Party(address(0x99), address(0x9A)),
                15e17, // size 1.5e18: fraction = 1.5e18/|5+1-4|e18 = 750_000 (hard band only)
                40_600,
                Setup(0, 1e18, 9910e18, 0, 100_000e18, 0),
                LpSeed(3000e18, 5e18, 0, 4e18),
                Seeded(0, 0, 1, 19_999)
            )
        );

        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), string.concat('{"ops":[', ops, "]}"));
    }

    struct LpSeed {
        uint256 lpS;
        uint256 lpA;
        uint256 lpDebtS;
        uint256 lpDebtA;
    }

    struct Party {
        address user;
        address liquidator;
    }

    struct Seeded {
        uint256 emaL;
        uint256 emaS;
        uint256 mrLo;
        uint256 mrHi;
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
        return liqOpSeeded(Party(user, liquidator), size, ts, s, Seeded(0, 0, 0, type(uint256).max));
    }

    function lpLiqOp(
        Party memory p,
        uint256 size,
        uint256 ts,
        Setup memory s,
        LpSeed memory lp,
        Seeded memory sd
    )
        internal
        returns (string memory)
    {
        ref.seedLp(p.user, lp.lpS, lp.lpA, lp.lpDebtS, lp.lpDebtA);
        string memory core = liqOpSeeded(p, size, ts, s, sd);
        (uint256 ls, uint256 la, uint256 lds, uint256 lda) = ref.getLpState(p.user);
        // Strip the closing brace, splice the LP seed + LP post-state, re-close.
        bytes memory b = bytes(core);
        b[b.length - 1] = " ";
        return string.concat(
            string(b),
            ',"lpS":"',
            vm.toString(lp.lpS),
            '","lpA":"',
            vm.toString(lp.lpA),
            '","lpDebtS":"',
            vm.toString(lp.lpDebtS),
            '","lpDebtA":"',
            vm.toString(lp.lpDebtA),
            '","lpS_post":"',
            vm.toString(ls),
            '","lpA_post":"',
            vm.toString(la),
            '","lpDebtS_post":"',
            vm.toString(lds),
            '","lpDebtA_post":"',
            vm.toString(lda),
            '"}'
        );
    }

    function liqOpSeeded(
        Party memory p,
        uint256 size,
        uint256 ts,
        Setup memory s,
        Seeded memory sd
    )
        internal
        returns (string memory)
    {
        vm.warp(ts);
        ref.setVtp(p.user, s.uBalS, s.uBalA, s.uDebtS, s.uDebtA);
        ref.setVtp(p.liquidator, s.lqBalS, s.lqBalA, 0, 0);
        // Every op seeds the EMAs (zero for the legacy ops): from this package on, close sweeps
        // WRITE the EMAs, so without explicit seeding each op's pricing would depend on the
        // sweep history of the ops before it.
        ref.seedAvgSlippages(sd.emaL, sd.emaS);
        // Funding-settled margin ratio, exactly as `liquidate` computes it (idempotent within
        // the block). The window pins the seed in its intended band; regen fails loudly on drift.
        uint256 mr = ref.liquidationMarginRatio(p.user);
        require(mr >= sd.mrLo && mr <= sd.mrHi, string.concat("band seed drift: mr=", vm.toString(mr)));
        vm.prank(p.liquidator);
        ref.liquidate(p.user, size, "");

        string memory head = string.concat(
            '{"kind":"liquidate","user":"',
            vm.toString(p.user),
            '","liquidator":"',
            vm.toString(p.liquidator),
            '","size":"',
            vm.toString(size),
            '","blockTs":"',
            vm.toString(ts),
            '","emaL":"',
            vm.toString(sd.emaL),
            '","emaS":"',
            vm.toString(sd.emaS),
            '","mr":"',
            vm.toString(mr),
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
        return string.concat(head, setup, stateJson(p.user, p.liquidator), "}");
    }

    function autoCloseOp(address user, address keeper, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        ref.setVtp(user, 0, 1e18, 3500e18, 0); // underwater long → loss
        // Same explicit-EMA-seeding invariant as every liquidate op: without it this op would
        // inherit whatever the preceding op's close sweep wrote, and the replay (which seeds
        // the recorded values) would diverge if the sequence is ever reordered.
        ref.seedAvgSlippages(0, 0);
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
            '","emaL":"0","emaS":"0"'
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
        (uint256 avgL, uint256 avgS) = ref.getAvgSlippages();
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
            insSign ? "true" : "false",
            // Post-op EMAs: pins the close-sweep EMA writes (and the auto-close restore)
            // cross-language — liquidation pricing reads these and nothing else recorded them.
            ',"avgL_post":"',
            vm.toString(avgL),
            '","avgS_post":"',
            vm.toString(avgS),
            '"'
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
