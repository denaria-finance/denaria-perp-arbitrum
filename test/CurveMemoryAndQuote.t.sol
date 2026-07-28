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
}
