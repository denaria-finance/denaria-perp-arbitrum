// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPair } from "../src/PerpPair.sol";
import { PerpPairTest } from "./PerpPair.t.sol";
import { UtilMath } from "../src/util/UtilMath.sol";

/// @dev PerpPair subclass exposing the curve accumulators (internal, with no getter behind the
///      declared interface) and a seeder for the oversized-short state. Everything under test runs
///      through the real public entrypoints; only observation and setup are added.
contract CurveMemoryHarness is PerpPair {
    constructor(
        address o,
        address v,
        address m,
        uint256 mmr,
        bytes32 t,
        uint32 ff,
        uint32 fl,
        address fp,
        uint256 tf,
        uint256 ftf,
        uint256 ema
    )
        PerpPair(o, v, m, mmr, t, ff, fl, fp, tf, ftf, ema)
    { }

    function exposedDx0() external view returns (uint256) {
        return dx0;
    }

    function exposedDy0() external view returns (uint256) {
        return dy0;
    }

    function exposedHasActiveCurveMemory(bool direction, uint256 price) external view returns (bool) {
        return _hasActiveCurveMemory(direction, price);
    }

    /// @dev Seeds a net short larger than the pool's asset side — the state a real pool reaches when
    ///      other traders drain the asset leg after the short is opened. Reproducing it by trading
    ///      is possible but couples the fixture to the curve parameters; seeding keeps it stable.
    function seedOversizedNetShort(
        address user,
        uint256 debtAsset,
        uint256 balanceStable,
        uint256 poolStable,
        uint256 poolAsset
    )
        external
    {
        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        pos.debtAsset = debtAsset;
        pos.balanceStable = balanceStable;
        globalLiquidityStable = poolStable;
        globalLiquidityAsset = poolAsset;
        // Exposure as the opening short left it: magnitude with the short (negative) sign.
        totalTraderExposure = debtAsset;
        totalTraderExposureSign = false;
    }
}

contract CurveMemoryAndQuoteTest is PerpPairTest {
    function _deployPerpPairForTest(
        address oracle_,
        address vault_,
        address multiCallManager_,
        uint256 mmr_,
        bytes32 tickerAssetCurrency_,
        uint32 feeFrontend_,
        uint32 feeLP_,
        address feeProtocolAddr_,
        uint256 tradingFee_,
        uint256 flatTradingFee_,
        uint256 emaParam_
    )
        internal
        override
        returns (PerpPair)
    {
        return new CurveMemoryHarness(
            oracle_,
            vault_,
            multiCallManager_,
            mmr_,
            tickerAssetCurrency_,
            feeFrontend_,
            feeLP_,
            feeProtocolAddr_,
            tradingFee_,
            flatTradingFee_,
            emaParam_
        );
    }

    function _h() internal view returns (CurveMemoryHarness) {
        return CurveMemoryHarness(address(perpPair));
    }

    function _balanceStable(address user) internal view returns (uint256 bal) {
        (bal,,,,,,,) = perpPair.userVirtualTraderPosition(user);
    }

    function _seedPool() internal returns (address lp) {
        oracle.setPrice(100 * oracleDecimals);
        lp = makeAddr("alice");
        vm.prank(lp);
        perpPair.addLiquidity(100_000 * 1e18, 1000 * 1e18, maxUserLiquidityFee, fakeReport);
    }

    /// @dev Re-denominates a trader's collateral into the 18-decimal stable, so the margin check
    ///      after the trade has room. Mirrors the funding the other trade-path tests do.
    function _fundTrader(address user) internal {
        vm.prank(user);
        vault.removeAllCollateral(fakeReport);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100_000 * 1e18;
        vm.prank(user);
        vault.addCollateral(amounts);
    }

    ///@dev A net short at or beyond the pool's asset side cannot be bought back, so the close skips
    ///     the buy-back entirely — and must still hand the trader's exposure back. Before the fix
    ///     that exposure stayed in the global figure forever, permanently skewing the funding rate.
    function testOversizedShortClosesAndReturnsExposure() public {
        oracle.setPrice(100 * oracleDecimals);
        address bob = makeAddr("bob");

        uint256 debtAsset = 200 * 1e18;
        _h().seedOversizedNetShort(bob, debtAsset, 30_000 * 1e18, 100_000 * 1e18, 100 * 1e18);
        assertGe(debtAsset, perpPair.globalLiquidityAsset(), "fixture must sit on the skip path");

        (uint256 exposureBefore, bool exposureSignBefore) = (0, false);
        (,,,,,,,,,,,,,, exposureBefore, exposureSignBefore) = perpPair.ReadParameters();
        assertEq(exposureBefore, debtAsset, "seeded exposure");
        assertFalse(exposureSignBefore, "seeded exposure is short");

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e30, frontendAddress, fakeReport);

        (uint256 balStable, uint256 balAsset, uint256 debtStable, uint256 debtAssetAfter,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertEq(balStable | balAsset | debtStable | debtAssetAfter, 0, "position not cleared");

        (uint256 exposureAfter,) = (0, false);
        (,,,,,,,,,,,,,, exposureAfter,) = perpPair.ReadParameters();
        assertEq(exposureAfter, 0, "the skipped close leaked the trader's net short into exposure");
    }

    ///@dev Valuing a short larger than the pool no longer reverts. The old guard was a hard revert
    ///     inside a VIEW path, so it bricked margin ratio and liquidation eligibility too.
    function testOversizedShortValuationDoesNotRevert() public {
        oracle.setPrice(100 * oracleDecimals);
        address bob = makeAddr("bob");
        _h().seedOversizedNetShort(bob, 200 * 1e18, 30_000 * 1e18, 100_000 * 1e18, 100 * 1e18);

        // The point is that this RETURNS at all: the old guard reverted here.
        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(bob, 100 * oracleDecimals);
        // Valued at spot, 30_000 stable held against 200 asset owed at 100 leaves ~10_000 of profit.
        assertTrue(pnlSign, "oversized short should still be in profit here");
        assertApproxEqRel(pnl, 10_000 * 1e18, 1e15, "oversized short must be valued at spot, not reverted");

        // The reads layered on top must work too — this is what the old revert bricked.
        uint256 mr = UtilMath.calcMR(
            bob, 100 * oracleDecimals, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        assertGt(mr, 0, "margin ratio must be computable for an oversized short");
    }

    ///@dev A dust LP movement — under one sixty-fourth of its own pool leg — must NOT reset the
    ///     curve window. Resetting on dust let anyone reprice an open window with a trivial deposit.
    function testDustLiquidityMoveKeepsCurveMemory() public {
        _seedPool();
        address bob = makeAddr("bob");
        _fundTrader(bob);

        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 10 * 1e18, 1, guess, frontendAddress, 1, fakeReport);
        uint256 dx0Before = _h().exposedDx0();
        uint256 dy0Before = _h().exposedDy0();
        assertGt(dx0Before, 0, "short must have opened a curve window");

        // Stable leg is 100_000e18-ish, so one sixty-fourth is ~1_562e18. Deposit far below it.
        address joiner = makeAddr("david");
        vm.prank(joiner);
        perpPair.addLiquidity(1 * 1e18, 0, maxUserLiquidityFee, fakeReport);

        assertEq(_h().exposedDx0(), dx0Before, "dust add reset dx0");
        assertEq(_h().exposedDy0(), dy0Before, "dust add reset dy0");
    }

    ///@dev The mirror case: a movement above the threshold does clear, so the rule is a threshold
    ///     and not a blanket "never reset".
    function testSignificantLiquidityMoveClearsCurveMemory() public {
        _seedPool();
        address bob = makeAddr("bob");
        _fundTrader(bob);

        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 10 * 1e18, 1, guess, frontendAddress, 1, fakeReport);
        assertGt(_h().exposedDx0(), 0, "short must have opened a curve window");

        address joiner = makeAddr("david");
        uint256 overThreshold = perpPair.globalLiquidityStable() / 64 + 1e18;
        vm.prank(joiner);
        perpPair.addLiquidity(overThreshold, 0, maxUserLiquidityFee, fakeReport);

        assertEq(_h().exposedDx0(), 0, "significant add must clear dx0");
        assertEq(_h().exposedDy0(), 0, "significant add must clear dy0");
    }

    ///@dev Splitting a short across two transactions inside one curve window must not beat trading
    ///     it whole. Before incremental pricing each slice was priced from the window's base state
    ///     as if it were the first, so a split captured strictly better fills.
    function testShortSplitDoesNotBeatAggregateTrade() public {
        uint256 whole;
        uint256 split;

        uint256 snap = vm.snapshotState();
        {
            _seedPool();
            address bob = makeAddr("bob");
            _fundTrader(bob);
            uint256 before = _balanceStable(bob);
            uint256 guess = perpPair.globalLiquidityStable();
            vm.prank(bob);
            perpPair.trade(false, 20 * 1e18, 1, guess, frontendAddress, 1, fakeReport);
            whole = _balanceStable(bob) - before;
        }
        vm.revertToState(snap);
        {
            _seedPool();
            address bob = makeAddr("bob");
            _fundTrader(bob);
            uint256 before = _balanceStable(bob);
            uint256 guess1 = perpPair.globalLiquidityStable();
            vm.prank(bob);
            perpPair.trade(false, 10 * 1e18, 1, guess1, frontendAddress, 1, fakeReport);
            uint256 guess2 = perpPair.globalLiquidityStable();
            vm.prank(bob);
            perpPair.trade(false, 10 * 1e18, 1, guess2, frontendAddress, 1, fakeReport);
            split = _balanceStable(bob) - before;
        }

        assertLe(split, whole, "splitting a short inside one window must not pay better than trading it whole");
    }

    ///@dev The LOSS side of the boundary. A net short that leaves less than one stable unit of asset
    ///     in the pool is valued at SPOT, not on the curve whose price asymptotes there: the marked
    ///     loss stays a handful of stable below the trader's collateral instead of exploding past it,
    ///     so the position is neither fake bad debt nor fake liquidatable, and it still closes.
    function testNearBoundaryShortAtLossIsMarkedAtSpot() public {
        uint256 price = 100 * oracleDecimals;
        address lp = _seedPool();
        address bob = makeAddr("bob");

        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 200 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);

        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 10 * 1e18, 1, guess, frontendAddress, 1, fakeReport);

        (, uint256 balanceAsset,, uint256 debtAsset,,,,) = perpPair.userVirtualTraderPosition(bob);
        uint256 netShort = debtAsset - balanceAsset;

        uint256 residual = 1e15;
        uint256 assetToRemove = perpPair.globalLiquidityAsset() - netShort - residual;
        vm.prank(lp);
        perpPair.removeLiquidity(0, assetToRemove, maxUserLiquidityFee, fakeReport);

        (uint256 markedLoss, bool pnlSign) = perpPair.calcPnL(bob, price);

        assertFalse(pnlSign, "short must be at a loss after fees and opening slippage");
        assertEq(
            markedLoss + _balanceStable(bob),
            netShort * price / oracleDecimals,
            "near-boundary short was not valued at spot"
        );
        assertLt(markedLoss, perpPair.getCollateral(bob), "near-boundary short was overmarked into bad debt");
        assertGt(
            UtilMath.calcMR(
                bob, price, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
            ),
            perpPair.MMR(),
            "overmark made a solvent short look liquidatable"
        );

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);
        (uint256 bs, uint256 ba, uint256 ds, uint256 da,,,,) = perpPair.userVirtualTraderPosition(bob);
        assertEq(bs | ba | ds | da, 0, "position not cleared");
    }

    ///@dev A solvent short beyond the pool's asset side must keep EVERY exit, not just the close:
    ///     the margin ratio has to clear MMR, `realizePnL` has to settle the spot-valued profit into
    ///     collateral, and the Vault's withdrawal check has to price the exit without reverting.
    function testOversizedHealthyShortKeepsEveryExitPath() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        address bob = makeAddr("bob");

        uint256 debtAsset = 200 * 1e18;
        _h().seedOversizedNetShort(bob, debtAsset, 30_000 * 1e18, 100_000 * 1e18, 100 * 1e18);
        assertGt(debtAsset, perpPair.globalLiquidityAsset(), "fixture must sit beyond the pool's asset side");

        assertGt(
            UtilMath.calcMR(
                bob, price, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
            ),
            perpPair.MMR(),
            "oversized short valued at spot is solvent and must not read as liquidatable"
        );

        uint256 collateralBefore = perpPair.getCollateral(bob);
        vm.prank(bob);
        (uint256 realized, bool realizedSign) = perpPair.realizePnL(fakeReport);
        assertTrue(realizedSign, "spot-valued oversized short is in profit here");
        assertEq(perpPair.getCollateral(bob), collateralBefore + realized, "realized profit did not reach collateral");

        vm.prank(bob);
        vault.removeCollateral(100, fakeReport);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);
        (uint256 bs2, uint256 ba2, uint256 ds2, uint256 da2,,,,) = perpPair.userVirtualTraderPosition(bob);
        assertEq(bs2 | ba2 | ds2 | da2, 0, "position not cleared");
    }

    ///@dev DEBT-ONLY LP CLOSE. An LP that has withdrawn every visible balance can still owe LP
    ///     debt, with its snapshot already dropped, so the close path drains "nothing" out of the
    ///     pool on its way to settling that debt. That zero-sized drain must neither move the pool
    ///     globals nor reset an open curve window — the 1/64 significance rule is what makes it a
    ///     no-op instead of a free window reset — and the debt itself must still be charged.
    function testDebtOnlyLpCloseKeepsPoolAndCurveMemory() public {
        oracle.setPrice(100 * oracleDecimals);
        address backstopLp = makeAddr("alice");
        address sacrificeLp = makeAddr("bob");
        address shortMaker = makeAddr("charlie");
        address primer = makeAddr("david");

        vm.prank(backstopLp);
        perpPair.addLiquidity(1_000_000 * 1e18, 10_000 * 1e18, maxUserLiquidityFee, fakeReport);
        vm.prank(sacrificeLp);
        perpPair.addLiquidity(200_000 * 1e18, 0, maxUserLiquidityFee, fakeReport);

        // A short marks the stable-only LP down, so what it can withdraw is worth less than the
        // stable it deposited: the shortfall is exactly the LP debt that survives the exit.
        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(shortMaker);
        perpPair.trade(false, 1000 * 1e18, 0, guess, frontendAddress, 1, fakeReport);

        (uint256 lpStable, uint256 lpAsset) = perpPair.getLpLiquidityBalance(sacrificeLp);
        vm.prank(sacrificeLp);
        perpPair.removeLiquidity(lpStable, lpAsset, maxUserLiquidityFee, fakeReport);

        // Sell the asset leg the exit handed back, so the trader side is flat too and the close
        // has no buy-back of its own to run.
        (, uint256 assetBalance,,,,,,) = perpPair.userVirtualTraderPosition(sacrificeLp);
        guess = perpPair.globalLiquidityStable();
        vm.prank(sacrificeLp);
        perpPair.trade(false, assetBalance, 0, guess, frontendAddress, 1, fakeReport);

        (lpStable, lpAsset) = perpPair.getLpLiquidityBalance(sacrificeLp);
        (,, uint256 lpDebtStable, uint256 lpDebtAsset) = perpPair.liquidityPosition(sacrificeLp);
        uint256 balanceStable;
        uint256 debtAsset;
        (balanceStable, assetBalance,, debtAsset,,,,) = perpPair.userVirtualTraderPosition(sacrificeLp);
        assertEq(lpStable | lpAsset | lpDebtAsset | assetBalance | debtAsset, 0, "fixture is not debt-only");
        assertGt(lpDebtStable, 0, "fixture left no LP debt to settle");
        assertLt(balanceStable, lpDebtStable, "fixture must close at a loss for the debt charge to be visible");
        uint256 expectedLoss = lpDebtStable - balanceStable;

        // Arm a long curve window that the close must leave alone.
        guess = perpPair.globalLiquidityAsset();
        vm.prank(primer);
        perpPair.trade(true, 120_000 * 1e18, 0, guess, frontendAddress, 1, fakeReport);

        uint256 dxBefore = _h().exposedDx0();
        uint256 dyBefore = _h().exposedDy0();
        uint256 stableBefore = perpPair.globalLiquidityStable();
        uint256 assetBefore = perpPair.globalLiquidityAsset();
        uint256 collateralBefore = vault.userCollateral(sacrificeLp);
        assertGt(dxBefore, 0, "primer did not arm dx0");
        assertGt(dyBefore, 0, "primer did not arm dy0");

        skip(1);
        vm.prank(sacrificeLp);
        perpPair.closeAndWithdraw(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);

        assertEq(perpPair.globalLiquidityStable(), stableBefore, "debt-only close moved stable liquidity");
        assertEq(perpPair.globalLiquidityAsset(), assetBefore, "debt-only close moved asset liquidity");
        assertEq(_h().exposedDx0(), dxBefore, "debt-only close reset dx0");
        assertEq(_h().exposedDy0(), dyBefore, "debt-only close reset dy0");

        // The no-op drain must not become a free pass: the LP debt is still settled against
        // collateral, and no debt-only remnant is left behind.
        (,, uint256 lpDebtStableAfter, uint256 lpDebtAssetAfter) = perpPair.liquidityPosition(sacrificeLp);
        uint256 debtStableAfter;
        (balanceStable, assetBalance, debtStableAfter, debtAsset,,,,) = perpPair.userVirtualTraderPosition(sacrificeLp);
        assertEq(
            lpDebtStableAfter | lpDebtAssetAfter | balanceStable | assetBalance | debtStableAfter | debtAsset,
            0,
            "debt-only close left position state behind"
        );
        uint256 collateralAfter = vault.userCollateral(sacrificeLp);
        assertLt(collateralAfter, collateralBefore, "debt-only close forgave the surviving LP debt");
        assertEq(
            collateralBefore - collateralAfter, expectedLoss, "debt-only close did not charge the surviving LP debt"
        );
    }
}
