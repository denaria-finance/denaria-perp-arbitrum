// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPairTest } from "./PerpPair.t.sol";

/// @dev The withdrawal gate used to value a position at its MARK and ignore what leaving actually
///      costs — the trade exit fee, the LP removal fee, and the slippage of the closing curve. A
///      position could therefore pass the check and still be unable to exit without going into bad
///      debt. These tests pin the difference directly: each one shows the mark-valued read still
///      reporting a healthy margin while the fee-inclusive read refuses.
contract WithdrawalSafetyTest is PerpPairTest {
    uint256 internal constant PRICE = 100 * 1e8;

    function _fundTrader(address user) internal {
        vm.prank(user);
        vault.removeAllCollateral(fakeReport);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100_000 * 1e18;
        vm.prank(user);
        vault.addCollateral(amounts);
    }

    /// @dev The mark-valued verdict the OLD gate would have reached, read straight from the engine's
    ///      unchanged `marginCheckData`. Having both surfaces lets each test show the two disagree.
    function _markValuedSafe(address user, uint256 hypotheticalCollateral) internal view returns (bool) {
        (uint256 markMR,,,,,,,,,, uint256 mmr) = perpPair.marginCheckData(user, PRICE, hypotheticalCollateral);
        return markMR >= mmr;
    }

    ///@dev An LP whose removal fee is large relative to what it would keep must not be allowed to
    ///     withdraw down to a level that cannot absorb that fee. This is the core of the fix.
    function testWithdrawalRefusedWhenTheRemovalFeeWouldSinkTheLp() public {
        oracle.setPrice(PRICE);

        address stableOnlyLp = makeAddr("bob");
        vm.prank(stableOnlyLp);
        perpPair.addLiquidity(100_000_000 * 1e18, 0, maxUserLiquidityFee, fakeReport);

        address lp = makeAddr("alice");
        vm.prank(lp);
        perpPair.addLiquidity(10_000_000 * 1e18, 1_000_000 * 1e18, maxUserLiquidityFee, fakeReport);

        uint256 amount = 8_000_000 * 1e18;
        uint256 hypothetical = vault.userCollateral(lp) - amount;

        assertTrue(_markValuedSafe(lp, hypothetical), "mark-valued gate would have allowed this withdrawal");
        (,, bool marginSafe) = perpPair.withdrawalCheckData(lp, PRICE, hypothetical);
        assertFalse(marginSafe, "fee-inclusive gate must refuse it");

        vm.expectRevert(bytes("RC4"));
        vm.prank(lp);
        vault.removeCollateral(amount, fakeReport);
    }

    ///@dev With nothing open, the two gates must agree and the withdrawal must go through — the
    ///     fee-inclusive preview must not invent a cost for an empty position.
    function testWithdrawalWithNoPositionIsUnaffected() public {
        oracle.setPrice(PRICE);
        address user = makeAddr("bob");
        uint256 before = vault.userCollateral(user);
        assertGt(before, 0, "fixture must start with collateral");

        (uint256 pnl,, bool marginSafe) = perpPair.withdrawalCheckData(user, PRICE, before / 2);
        assertEq(pnl, 0, "an empty position has no exit cost");
        assertTrue(marginSafe, "an empty position is always safe to withdraw against");

        vm.prank(user);
        vault.removeCollateral(before / 2, fakeReport);
        assertEq(vault.userCollateral(user), before - before / 2, "withdrawal did not go through");
    }

    ///@dev A dust asset leg must not be charged the FLAT trading fee: below the cutoff the exit is
    ///     not priced at all, because a flat fee on dust would invent a cost larger than the leg.
    function testDustPositionIsNotChargedAnExitFee() public {
        oracle.setPrice(PRICE);
        address user = makeAddr("bob");
        _fundTrader(user);

        // Seed a stable-only position: no asset leg at all, so the cutoff branch is what decides.
        uint256 collateral = vault.userCollateral(user);
        (uint256 pnl,, bool marginSafe) = perpPair.withdrawalCheckData(user, PRICE, collateral);
        assertEq(pnl, 0, "no asset leg means no close value and no flat fee");
        assertTrue(marginSafe, "a position with no asset leg stays withdrawable");
    }

    ///@dev A trader carrying a real short pays the buy-back cost in the preview, so the gate is
    ///     strictly more conservative than the mark-valued one at the same state.
    function testShortPaysItsBuyBackCostInThePreview() public {
        oracle.setPrice(PRICE);
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(100_000 * 1e18, 1000 * 1e18, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        _fundTrader(bob);
        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 10 * 1e18, 1, guess, frontendAddress, 1, fakeReport);

        uint256 collateral = vault.userCollateral(bob);
        (uint256 feeInclusivePnl, bool feeInclusiveSign,) = perpPair.withdrawalCheckData(bob, PRICE, collateral);
        (uint256 markPnl, bool markSign) = perpPair.calcPnL(bob, PRICE);

        // Both are losses here; the fee-inclusive one must be the LARGER loss, never smaller.
        assertFalse(feeInclusiveSign, "short should preview as a loss");
        if (!markSign) {
            assertGe(feeInclusivePnl, markPnl, "the preview must not quote a cheaper exit than the mark");
        }
    }

    ///@dev The gate is a threshold, not a blanket refusal: one unit of collateral either side of the
    ///     boundary must land on opposite verdicts.
    function testWithdrawalBoundaryIsOneUnitWide() public {
        oracle.setPrice(PRICE);
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(100_000 * 1e18, 1000 * 1e18, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        _fundTrader(bob);
        uint256 guess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 10 * 1e18, 1, guess, frontendAddress, 1, fakeReport);

        // Bisect the hypothetical collateral for the exact flip point.
        uint256 low;
        uint256 high = vault.userCollateral(bob);
        (,, bool safeAtTop) = perpPair.withdrawalCheckData(bob, PRICE, high);
        assertTrue(safeAtTop, "full collateral must be safe");
        (,, bool safeAtZero) = perpPair.withdrawalCheckData(bob, PRICE, low);
        assertFalse(safeAtZero, "zero collateral must not be safe");

        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            (,, bool safe) = perpPair.withdrawalCheckData(bob, PRICE, mid);
            if (safe) high = mid;
            else low = mid;
        }
        (,, bool justBelow) = perpPair.withdrawalCheckData(bob, PRICE, low);
        (,, bool atBoundary) = perpPair.withdrawalCheckData(bob, PRICE, high);
        assertFalse(justBelow, "one unit below the boundary must be refused");
        assertTrue(atBoundary, "the boundary itself must be accepted");
    }

    /// @dev The least collateral the fee-inclusive gate still calls safe, found by bisection so the
    ///      cases below never hardcode a magnitude: the verdict is monotone in the collateral, the
    ///      whole position value being fixed at the point of the search.
    function _minSafeCollateral(address user) internal view returns (uint256) {
        uint256 low;
        uint256 high = vault.userCollateral(user);
        (,, bool safeAtTop) = perpPair.withdrawalCheckData(user, PRICE, high);
        assertTrue(safeAtTop, "full collateral must be safe");
        (,, bool safeAtZero) = perpPair.withdrawalCheckData(user, PRICE, low);
        assertFalse(safeAtZero, "zero collateral must not be safe");
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            (,, bool safe) = perpPair.withdrawalCheckData(user, PRICE, mid);
            if (safe) high = mid;
            else low = mid;
        }
        return high;
    }

    /// @dev The curve window is a shared resource: whoever traded last leaves it open for their own
    ///      direction, and the next quote in that direction is priced as a CONTINUATION of it. A
    ///      short's buy-back therefore costs more while a third party's long window is still open,
    ///      and the withdrawal gate has to charge the trader that price — the one the close would
    ///      actually pay — rather than the mark. This runs the whole decision through
    ///      `Vault.removeCollateral`, so it pins the preview as the value the Vault acts on, not
    ///      just a read that happens to agree with it.
    function testShortWithdrawalRefusedWhileAThirdPartyLongWindowIsArmed() public {
        oracle.setPrice(PRICE);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(100_000 * 1e18, 1000 * 1e18, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        _fundTrader(bob);
        uint256 shortGuess = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 100 * 1e18, 1, shortGuess, frontendAddress, 1, fakeReport);

        // A third party arms the LONG window. Bob's buy-back now has to unwind it first.
        address charlie = makeAddr("charlie");
        _fundTrader(charlie);
        uint256 longGuess = perpPair.globalLiquidityAsset();
        vm.prank(charlie);
        perpPair.trade(true, 20_000 * 1e18, 1, longGuess, frontendAddress, 1, fakeReport);

        (uint256 armedDx, uint256 armedDy) = perpPair.readCurveMemory(1, PRICE);
        assertGt(armedDx, 0, "the long must have armed the curve window");
        assertGt(armedDy, 0, "the long must have armed the curve window");
        (,,,,,, bool lastDirection, uint256 lastValidatedPrice) = perpPair.curveParameters();
        assertTrue(lastDirection, "the open window must belong to the long side");
        assertEq(lastValidatedPrice, PRICE, "the window must be open at the price the gate reads");

        uint256 hypothetical = _minSafeCollateral(bob) - 1;
        uint256 amount = vault.userCollateral(bob) - hypothetical;

        assertTrue(_markValuedSafe(bob, hypothetical), "mark-valued gate would have allowed this withdrawal");
        (,, bool marginSafe) = perpPair.withdrawalCheckData(bob, PRICE, hypothetical);
        assertFalse(marginSafe, "the armed window makes the buy-back unaffordable at this collateral");

        vm.expectRevert(bytes("RC4"));
        vm.prank(bob);
        vault.removeCollateral(amount, fakeReport);

        // Same position, same pool, same price: only the window is gone. The identical withdrawal
        // now goes through, which is what shows the Vault acted on the window-aware quote and not
        // merely on some fee the pool state alone would have implied.
        (,,,,, uint256 curveUpdateInterval,,) = perpPair.curveParameters();
        vm.warp(block.timestamp + curveUpdateInterval + 1);
        (uint256 staleDx, uint256 staleDy) = perpPair.readCurveMemory(1, PRICE);
        assertEq(staleDx | staleDy, 0, "an expired window must not be readable");

        (,, bool safeOnceExpired) = perpPair.withdrawalCheckData(bob, PRICE, hypothetical);
        assertTrue(safeOnceExpired, "with no window to unwind the same withdrawal must be safe");
        vm.prank(bob);
        vault.removeCollateral(amount, fakeReport);
        assertEq(vault.userCollateral(bob), hypothetical, "withdrawal did not go through");
    }

    /// @dev The long side of the same reservation: closing a net-long leg SELLS it, so the gate must
    ///     hold back that sale's slippage and trading fee — here on top of a third party's open
    ///     short window, which the sale is priced as a continuation of. Typed revert, so the refusal
    ///     is the margin gate and not one of the other removeCollateral guards.
    function testLongWithdrawalRefusedWhileAThirdPartyShortWindowIsArmed() public {
        oracle.setPrice(PRICE);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(100_000 * 1e18, 1000 * 1e18, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        _fundTrader(bob);
        uint256 longGuess = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, 10_000 * 1e18, 1, longGuess, frontendAddress, 1, fakeReport);

        address charlie = makeAddr("charlie");
        _fundTrader(charlie);
        uint256 shortGuess = perpPair.globalLiquidityStable();
        vm.prank(charlie);
        perpPair.trade(false, 100 * 1e18, 1, shortGuess, frontendAddress, 1, fakeReport);

        (uint256 armedDx, uint256 armedDy) = perpPair.readCurveMemory(0, PRICE);
        assertGt(armedDx, 0, "the short must have armed the curve window");
        assertGt(armedDy, 0, "the short must have armed the curve window");

        uint256 hypothetical = _minSafeCollateral(bob) - 1;
        uint256 amount = vault.userCollateral(bob) - hypothetical;

        assertTrue(_markValuedSafe(bob, hypothetical), "mark-valued gate would have allowed this withdrawal");
        (,, bool marginSafe) = perpPair.withdrawalCheckData(bob, PRICE, hypothetical);
        assertFalse(marginSafe, "selling the long leg at this collateral must be refused");

        vm.expectRevert(bytes("RC4"));
        vm.prank(bob);
        vault.removeCollateral(amount, fakeReport);

        (,,,,, uint256 curveUpdateInterval,,) = perpPair.curveParameters();
        vm.warp(block.timestamp + curveUpdateInterval + 1);
        (,, bool safeOnceExpired) = perpPair.withdrawalCheckData(bob, PRICE, hypothetical);
        assertTrue(safeOnceExpired, "with no window to continue the same withdrawal must be safe");
        vm.prank(bob);
        vault.removeCollateral(amount, fakeReport);
        assertEq(vault.userCollateral(bob), hypothetical, "withdrawal did not go through");
    }
}
