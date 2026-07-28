// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPairTest } from "./PerpPair.t.sol";
import { FeeManager } from "../src/manager/FeeManager.sol";
import { UtilMath } from "../src/util/UtilMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Liquidity fees are stable-denominated and credited to whoever is still in the pool. When one
///      leg of the pool is empty the fee used to be dropped entirely, silently confiscating it from
///      the remaining LPs; it must instead be routed through the leg that still exists. The three
///      entry points that reach `_distributeLiquidityFee` — deposit, voluntary removal and the forced
///      removal inside a liquidation — are each covered here.
contract OneSidedLiquidityFeeTest is PerpPairTest {
    /// @dev Stable value of the fee that removing (`stableToRemove`, `assetToRemove`) charges against
    ///      the pool as it stands right now.
    function _liquidityRemovalFeeValue(
        uint256 stableToRemove,
        uint256 assetToRemove,
        uint256 price
    )
        internal
        view
        returns (uint256)
    {
        (,,, uint256 minFee, uint256 maxFee, uint256 feeK,,,,,) = perpPair.ReadFees();
        uint256 fee = FeeManager.computeLiquidityRemovalFee(
            stableToRemove,
            assetToRemove,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            price,
            oracleDecimals,
            maxFee,
            minFee,
            feeK,
            liquidityFeeDecimals
        );

        return (stableToRemove + assetToRemove * price / oracleDecimals) * fee / liquidityFeeDecimals;
    }

    /// @dev The matrix credit is applied in Q80 fixed point, so a claim can trail the exact fee by a
    ///      rounding step proportional to the credited amount.
    function _distributionDust(uint256 creditedValue) internal pure returns (uint256) {
        return Math.mulDiv(creditedValue, 1, uint256(1) << 80, Math.Rounding.Ceil) + 1;
    }

    ///@dev Asset-only exit from a pool whose remaining leg is stable: the fee must land on the stable
    ///     LP. Pre-fix the zero asset leg suppressed the whole distribution.
    function testAssetSideRemovalFeeCreditsRemainingStableLp() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address assetLp = makeAddr("alice");
        address stableLp = makeAddr("bob");

        vm.prank(assetLp);
        perpPair.addLiquidity(0, 10 * 1e18, maxUserLiquidityFee, fakeReport);
        vm.prank(stableLp);
        perpPair.addLiquidity(2000 * 1e18, 0, maxUserLiquidityFee, fakeReport);

        (uint256 stableClaimBefore,) = perpPair.getLpLiquidityBalance(stableLp);
        uint256 stableBefore = perpPair.globalLiquidityStable();
        uint256 assetBefore = perpPair.globalLiquidityAsset();
        uint256 feeValue = _liquidityRemovalFeeValue(0, assetBefore, price);
        assertGt(feeValue, 0, "setup must charge a removal fee");

        vm.prank(assetLp);
        perpPair.removeLiquidity(0, assetBefore, maxUserLiquidityFee, fakeReport);

        (uint256 stableClaimAfter, uint256 assetClaimAfter) = perpPair.getLpLiquidityBalance(stableLp);
        (,, uint256 exitingLpStableDebt,,,,,) = perpPair.userVirtualTraderPosition(assetLp);

        assertEq(perpPair.globalLiquidityAsset(), 0, "asset side should be fully removed");
        assertEq(perpPair.globalLiquidityStable(), stableBefore + feeValue, "fee must remain in the pool");
        assertApproxEqAbs(stableClaimAfter, stableClaimBefore + feeValue, 1, "remaining LP must receive the fee");
        assertEq(assetClaimAfter, 0, "stable-only LP should stay asset-free");
        assertEq(exitingLpStableDebt, feeValue, "exiting LP must pay the routed fee");
    }

    ///@dev The mirror case: a stable-only exit leaves an asset-only pool, and the stable-denominated
    ///     fee must be credited through the asset leg rather than dropped.
    function testStableSideRemovalFeeCreditsRemainingAssetLp() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address stableLp = makeAddr("alice");
        address assetLp = makeAddr("bob");

        vm.prank(stableLp);
        perpPair.addLiquidity(2000 * 1e18, 0, maxUserLiquidityFee, fakeReport);
        vm.prank(assetLp);
        perpPair.addLiquidity(0, 10 * 1e18, maxUserLiquidityFee, fakeReport);

        (, uint256 assetClaimBefore) = perpPair.getLpLiquidityBalance(assetLp);
        uint256 stableBefore = perpPair.globalLiquidityStable();
        uint256 feeValue = _liquidityRemovalFeeValue(stableBefore, 0, price);
        assertGt(feeValue, 0, "setup must charge a removal fee");

        vm.prank(stableLp);
        perpPair.removeLiquidity(stableBefore, 0, maxUserLiquidityFee, fakeReport);

        (uint256 stableClaimAfter, uint256 assetClaimAfter) = perpPair.getLpLiquidityBalance(assetLp);

        assertEq(perpPair.globalLiquidityStable(), feeValue, "fee must recreate the stable claim side");
        assertApproxEqAbs(stableClaimAfter, feeValue, _distributionDust(feeValue), "asset LP must receive the fee");
        assertEq(assetClaimAfter, assetClaimBefore, "asset claim must remain unchanged");
    }

    ///@dev Deposits reach the same helper, but they can never carry a fee into the one-sided branch:
    ///     the deposit fee is computed against the PRE-deposit pool and `computeLiquidityDepositFee`
    ///     waives it outright when either leg is empty, while distribution also runs before the
    ///     deposit is folded into the globals. This pins that reachability argument, so the one-sided
    ///     branch stays a removal-path concern only.
    function testDepositIntoAOneSidedPoolCarriesNoFeeToDistribute() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address incumbent = makeAddr("alice");
        address joiner = makeAddr("bob");

        vm.prank(incumbent);
        perpPair.addLiquidity(2000 * 1e18, 0, maxUserLiquidityFee, fakeReport);
        assertEq(perpPair.globalLiquidityAsset(), 0, "pool must be stable-only");

        (uint256 claimBefore,) = perpPair.getLpLiquidityBalance(incumbent);
        uint256 stableBefore = perpPair.globalLiquidityStable();

        // Asset-only deposit: at distribution time the pool is still the stable-only pre-deposit one,
        // which is exactly the shape the removal paths reach with a live fee.
        uint256 depositAsset = 10 * 1e18;
        vm.prank(joiner);
        perpPair.addLiquidity(0, depositAsset, maxUserLiquidityFee, fakeReport);

        assertEq(perpPair.globalLiquidityStable(), stableBefore, "one-sided deposit must charge no fee");
        (uint256 claimAfter,) = perpPair.getLpLiquidityBalance(incumbent);
        assertApproxEqAbs(claimAfter, claimBefore, 1, "incumbent claim must be untouched by a waived fee");
    }

    ///@dev The forced removal inside a full LP liquidation reaches the same helper. When the victim
    ///     owns the entire asset leg, unwinding it empties that leg, and the fee must still reach the
    ///     stable-only LP that stays behind.
    function testFullLpLiquidationCreditsForcedRemovalFee() public {
        vm.warp(7 days + 2);

        uint256 startPrice = 100 * oracleDecimals;
        uint256 liquidationPrice = 150 * oracleDecimals;
        oracle.setPrice(startPrice);

        address scarceAssetLp = makeAddr("alice");
        address stableOnlyLp = makeAddr("bob");
        address trader = makeAddr("charlie");
        address liquidator = makeAddr("david");

        vm.prank(stableOnlyLp);
        perpPair.addLiquidity(100_000_000 * 1e18, 0, maxUserLiquidityFee, fakeReport);

        vm.prank(scarceAssetLp);
        perpPair.addLiquidity(10_000_000 * 1e18, 1_000_000 * 1e18, maxUserLiquidityFee, fakeReport);
        vm.prank(scarceAssetLp);
        vault.removeCollateral(8_000_000 * 1e18, fakeReport);

        uint256 initialGuess = perpPair.globalLiquidityAsset();
        vm.prank(trader);
        perpPair.trade(true, 30_000_000 * 1e18, 0, initialGuess, address(0), 1, fakeReport);

        oracle.setPrice(liquidationPrice);

        uint256 marginRatio = UtilMath.calcMR(
            scarceAssetLp,
            liquidationPrice,
            address(perpPair),
            perpPair.getCollateral(scarceAssetLp),
            perpPair.lastOperationTimestamp()
        );
        assertLt(marginRatio, MMR / 2, "setup must permit full liquidation");

        (uint256 lpStable, uint256 lpAsset) = perpPair.getLpLiquidityBalance(scarceAssetLp);
        assertEq(lpAsset, perpPair.globalLiquidityAsset(), "victim must own the remaining asset side");

        (, uint256 balanceAsset,, uint256 debtAsset,,,,) = perpPair.userVirtualTraderPosition(scarceAssetLp);
        (,,, uint256 lpDebtAsset) = perpPair.liquidityPosition(scarceAssetLp);
        uint256 fullExposure = UtilMath.diffAbs(lpAsset + balanceAsset, debtAsset + lpDebtAsset);
        uint256 feeValue = _liquidityRemovalFeeValue(lpStable, lpAsset, liquidationPrice);
        (uint256 stableClaimBefore,) = perpPair.getLpLiquidityBalance(stableOnlyLp);

        assertGt(fullExposure, 0, "victim must have liquidatable exposure");
        assertGt(feeValue, 0, "forced unwind must charge a removal fee");

        vm.prank(liquidator);
        perpPair.liquidate(scarceAssetLp, fullExposure, fakeReport);

        (uint256 stableClaimAfter,) = perpPair.getLpLiquidityBalance(stableOnlyLp);
        assertEq(perpPair.globalLiquidityAsset(), 0, "forced unwind should remove the asset side");
        assertApproxEqAbs(
            stableClaimAfter,
            stableClaimBefore + feeValue,
            _distributionDust(stableClaimBefore + feeValue),
            "remaining stable LP must receive the forced-removal fee"
        );
    }
}
