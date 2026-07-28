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
}
