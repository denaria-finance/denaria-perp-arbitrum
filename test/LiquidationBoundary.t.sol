// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPairTest } from "./PerpPair.t.sol";
import { UtilMath } from "../src/util/UtilMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Boundary tests for the two liquidation margin bands. `calcMR` floors, so a ratio landing
///      exactly on a threshold must be read as the healthier side of it: an account at MMR is not
///      liquidatable at all, and one at MMR/2 is liquidatable only up to half. The setup places an
///      account at a chosen FLOORED ratio, so each test pins one side of a boundary.
contract LiquidationBoundaryTest is PerpPairTest {
    /// @dev Opens a pure short and trims collateral until `calcMR` floors to `targetMarginRatio`.
    ///      `equityBump` adds wei of true equity on top of the exact threshold, so a caller can put
    ///      the account marginally ABOVE a band while the floored ratio still reads as sitting on it.
    function _setupShortAtMarginBoundary(
        uint256 targetMarginRatio,
        uint256 equityBump
    )
        private
        returns (address user, uint256 assetDebt, uint256 positionValue, uint256 equity)
    {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address lp = makeAddr("alice");
        vm.prank(lp);
        perpPair.addLiquidity(10_000_000 * 1e18, 100_000 * 1e18, maxUserLiquidityFee, fakeReport);

        user = makeAddr("bob");
        uint256 initialGuess = perpPair.globalLiquidityStable();
        vm.prank(user);
        perpPair.trade(false, 10 * 1e18, 100 * 1e5, initialGuess, frontendAddress, 1, fakeReport);

        (
            uint256 stableBalance,
            uint256 assetBalance,
            uint256 stableDebt,
            uint256 currentAssetDebt,
            uint256 fundingFee,
            bool fundingFeeSign,,
        ) = perpPair.userVirtualTraderPosition(user);
        assetDebt = currentAssetDebt;
        assertEq(assetBalance, 0, "boundary setup must be a pure short");

        positionValue = assetDebt * price / oracleDecimals;
        equity = Math.mulDiv(targetMarginRatio, positionValue, MMRDecimals, Math.Rounding.Ceil) + equityBump;

        (uint256 pnl, bool pnlSign) = UtilMath._calcPnL(
            stableBalance,
            assetBalance,
            stableDebt,
            assetDebt,
            fundingFee,
            fundingFeeSign,
            price,
            oracleDecimals,
            address(perpPair),
            true
        );
        uint256 targetCollateral;
        if (pnlSign) {
            assertGe(equity, pnl, "positive pnl exceeds target equity");
            targetCollateral = equity - pnl;
        } else {
            targetCollateral = equity + pnl;
        }

        uint256 currentCollateral = perpPair.getCollateral(user);
        assertGe(currentCollateral, targetCollateral, "insufficient setup collateral");
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(user, currentCollateral - targetCollateral, false);

        uint256 marginRatio = UtilMath.calcMR(
            user, price, address(perpPair), perpPair.getCollateral(user), perpPair.lastOperationTimestamp()
        );
        assertEq(marginRatio, targetMarginRatio, "unexpected floored margin ratio");
    }

    ///@dev An account sitting exactly at MMR/2 belongs to the SOFT band: at most half of it can be
    ///     taken. Under the old inclusive comparison it fell into the hard band and was fully
    ///     liquidatable.
    function testExactHalfMmrAllowsOnlyPartialLiquidation() public {
        (address user, uint256 assetDebt, uint256 positionValue, uint256 equity) =
            _setupShortAtMarginBoundary(MMR / 2, 0);
        assertEq(equity * MMRDecimals, (MMR / 2) * positionValue, "setup must sit exactly at MMR/2");

        vm.expectRevert(bytes("LQ1"));
        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt * 3 / 4, fakeReport);

        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt / 2, fakeReport);
        (,,, uint256 remainingAssetDebt,,,,) = perpPair.userVirtualTraderPosition(user);
        assertEq(remainingAssetDebt, assetDebt / 2, "half liquidation must remain available");
    }

    ///@dev One wei of equity BELOW the half boundary is the hard band, so the whole position can be
    ///     taken. This pins the other side of the same threshold.
    function testJustBelowHalfMmrAllowsFullLiquidation() public {
        (address user, uint256 assetDebt,,) = _setupShortAtMarginBoundary(MMR / 2 - 1, 0);

        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt, fakeReport);
        (,,, uint256 remainingAssetDebt,,,,) = perpPair.userVirtualTraderPosition(user);
        assertEq(remainingAssetDebt, 0, "hard band must allow a full liquidation");
    }

    ///@dev True equity one wei ABOVE MMR still floors to MMR, and an account at MMR is healthy:
    ///     no fraction may be liquidated. The old code accepted it as a partial liquidation.
    function testMarginFlooringToMmrCannotBeLiquidated() public {
        (address user, uint256 assetDebt, uint256 positionValue, uint256 equity) = _setupShortAtMarginBoundary(MMR, 1);
        assertGt(equity * MMRDecimals, MMR * positionValue, "true margin must be above MMR");
        assertLt(equity * MMRDecimals, (MMR + 1) * positionValue, "floored margin must remain MMR");

        vm.expectRevert(bytes("LQ1"));
        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt * 2 / 5, fakeReport);
    }

    ///@dev Exactly at MMR — with no equity bump — is also healthy, so the rejection is a property of
    ///     the band and not of the extra wei used by the flooring test above.
    function testExactMmrCannotBeLiquidated() public {
        (address user, uint256 assetDebt,,) = _setupShortAtMarginBoundary(MMR, 0);

        vm.expectRevert(bytes("LQ1"));
        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt * 2 / 5, fakeReport);
    }

    ///@dev One below MMR is the soft band: half is accepted, more than half is not.
    function testJustBelowMmrAllowsOnlyPartialLiquidation() public {
        (address user, uint256 assetDebt,,) = _setupShortAtMarginBoundary(MMR - 1, 0);

        vm.expectRevert(bytes("LQ1"));
        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt * 3 / 4, fakeReport);

        vm.prank(makeAddr("charlie"));
        perpPair.liquidate(user, assetDebt / 2, fakeReport);
        (,,, uint256 remainingAssetDebt,,,,) = perpPair.userVirtualTraderPosition(user);
        assertEq(remainingAssetDebt, assetDebt / 2, "soft band must accept a half liquidation");
    }
}
