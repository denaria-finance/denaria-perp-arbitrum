// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./internalPerpLogic.sol";
import "../util/MatrixMath.sol";
import "../util/UtilMath.sol";
import "../manager/FeeManager.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpLiquidity is InternalPerpLogic {
    using Math for uint256;
    using SignedMath for int256;

    event LiquidityMoved(
        address indexed user, uint256 liquidityStable, uint256 liquidityAsset, uint256 fee, bool added
    );

    ///@dev Drops the directional curve accumulators. The accumulators and the
    ///     (lastCurveUpdate, lastTradeDirection, lastValidatedPrice) triple are ONE consistent
    ///     tuple: whoever clears the first must refresh the second, which is why only
    ///     `_syncCurveMemory` and the significance check below ever write them.
    function _clearCurveMemory() internal {
        delete dy0;
        delete dx0;
    }

    ///@dev Clears curve memory only for an LP movement large enough to matter: either leg
    ///     exceeding one sixty-fourth of its OWN pre-operation pool leg clears BOTH accumulators.
    ///     Straight leg pairing, strict comparison, and OR — one oversized leg is enough. A zero
    ///     or dust movement preserves the memory, which is the point: an unrelated dust deposit
    ///     must not reprice a curve window that is still open.
    function _clearCurveMemoryIfSignificant(uint256 stableAmount, uint256 assetAmount) private {
        if (stableAmount > globalLiquidityStable / 64 || assetAmount > globalLiquidityAsset / 64) {
            _clearCurveMemory();
        }
    }

    ///@dev Adds liquidity to the pool, acting as a liquidity provider.
    ///@dev Since margin ratio of LP when adding liquidity is always 0 we require that the user has at least 10% of his total debts as collateral.
    ///@param liquidityStable Amount of stable liquidity to add into the pool
    ///@param liquidityAsset Amount of asset liquidity to add into the pool, in vAsset.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity deposit
    ///@param unverifiedReport Chainlink price report.
    function addLiquidity(
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        public
        nonReentrant
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        address sender = _msgSender();
        uint256 spotPrice = getPrice();

        uint256 liquidityValue = liquidityStable + (liquidityAsset * spotPrice) / oracleDecimals;
        require(liquidityValue >= minimumLiquidityMovement, "L1"); // Error on add liquidity, under minimum movement

        // Compute fees
        uint256 fee = FeeManager.computeLiquidityDepositFee(
            liquidityStable,
            liquidityAsset,
            globalLiquidityStable,
            globalLiquidityAsset,
            spotPrice,
            oracleDecimals,
            liquidityMaxFee,
            liquidityMinFee,
            liquidityFeeK,
            decimals.liquidityFeeDecimals
        );

        if (globalLiquidityAsset == 0 && globalLiquidityStable == 0) {
            fee = 0;
        }

        uint256 feeValue = (liquidityValue * fee) / decimals.liquidityFeeDecimals;

        require(feeValue <= maxFeeValue || maxFeeValue == 0, "L2");

        // Measured against the PRE-deposit pool, so it must precede `_addLiquidity`. The amounts
        // are the gross user-requested ones, before the liquidity fee is deducted.
        _clearCurveMemoryIfSignificant(liquidityStable, liquidityAsset);

        _addLiquidity(liquidityStable, liquidityAsset, feeValue, spotPrice);

        LiquidityPosition storage position = liquidityPosition[sender];
        VirtualTraderPosition storage tpos = userVirtualTraderPosition[sender];

        uint256 collateral = getCollateral(sender);
        (uint256 pnl, bool pnlSign) = calcPnL(sender, spotPrice);
        require(pnl < collateral || pnlSign, "C1"); //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.

        require(
            position.debtStable + tpos.debtStable + (position.debtAsset + tpos.debtAsset) * spotPrice / oracleDecimals
                <= collateral * maxLpLeverage,
            "L3"
        ); //To deposit liquidity you must have collateral backing it, max leverage 10x
    }

    ///@dev Internal function to make the operations necessary for the addition of liquidity.
    ///@param liquidityStable Amount of stable liquidity to add into the pool
    ///@param liquidityAsset Amount of asset liquidity to add into the pool, in vAsset.
    ///@param feeValue Stable value of the fee associated to the liquidity deposit.
    ///@param spotPrice Oracle price of the asset.
    function _addLiquidity(
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 feeValue,
        uint256 spotPrice
    )
        private
    {
        address sender = _msgSender();
        VirtualTraderPosition storage position = userVirtualTraderPosition[sender];

        // Compute new funding rate and update it
        (uint256 newFundingRate, bool newFundingRateSign) = computeFundingRate(getPrice(), lastOperationTimestamp);
        (uint256 localFundingRate, bool localFundingRateSign) =
            UtilMath.signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);

        // Compute funding fee
        (uint256 localFundingFee, bool localFundingFeeSign) =
            _computeFundingFee(sender, localFundingRate, localFundingRateSign);
        (position.fundingFee, position.fundingFeeSign) =
            UtilMath.signedSum(position.fundingFee, position.fundingFeeSign, localFundingFee, localFundingFeeSign);

        // Settle global funding on the pre-deposit liquidity denominator, before this
        // deposit's fee and balance dilute it.
        _updateFG(spotPrice, lastOperationTimestamp);

        LiquidityPosition storage liquidityPos = liquidityPosition[sender];
        liquidityPos.debtStable += liquidityStable;
        liquidityPos.debtAsset += liquidityAsset;

        // Deduct fees from deposited liquidity
        if (liquidityStable >= feeValue) {
            unchecked {
                liquidityStable -= feeValue;
            }
        } else {
            unchecked {
                liquidityPos.debtStable += feeValue - liquidityStable;
                liquidityStable = 0;
            }
        }

        // Compute fee distribution between stable and asset LPs
        _distributeLiquidityFee(feeValue, spotPrice);

        // Remove old liquidity to re-add it
        (uint256 oldLpStableBalance, uint256 oldLpAssetBalance) = getLpLiquidityBalance(sender);
        unchecked {
            liquidityStable += oldLpStableBalance;
            liquidityAsset += oldLpAssetBalance;
        }

        // Rebase the global liquidity by the incumbent LP balance only when the pool is non-empty.
        if (globalLiquidityAsset != 0 || globalLiquidityStable != 0) {
            globalLiquidityStable -= oldLpStableBalance;
            globalLiquidityAsset -= oldLpAssetBalance;
        }

        unchecked {
            globalLiquidityStable += liquidityStable;
            globalLiquidityAsset += liquidityAsset;
        }

        // Snapshot the LP into the current accounting epoch: captures the RAW forward matrix M(t0) and
        // funding row G from the epoch (on an empty pool the epoch matrix is still the identity * scale,
        // reproducing the old bootstrap), the new initial balances, and the epoch id / activeLpCount.
        _updateSnapshots(sender, liquidityStable, liquidityAsset);

        emit LiquidityMoved(sender, liquidityStable, liquidityAsset, feeValue, true);
    }

    ///@dev Removes liquidity from the pool, adding it back to the liquidity provider's balance.
    ///@param liquidityStableToRemove Amount of stable liquidity to remove from the pool
    ///@param liquidityAssetToRemove Amount of asset liquidity to remove from the pool, in vAsset.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity removal
    ///@param unverifiedReport Chainlink price report.
    function removeLiquidity(
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        external
        nonReentrant
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = getPrice();

        require(
            liquidityStableToRemove + (liquidityAssetToRemove * spotPrice) / oracleDecimals >= minimumLiquidityMovement,
            "L4"
        ); // Error: Removal below min size

        address sender = _msgSender();
        _removeLiquidity(liquidityStableToRemove, liquidityAssetToRemove, sender, spotPrice, maxFeeValue);

        (uint256 pnl, bool pnlSign) = calcPnL(sender, spotPrice);
        require(pnl < getCollateral(sender) || pnlSign, "C1"); //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.
    }

    ///@dev Internal function to make the operations necessary for the removal of liquidity.
    ///@param liquidityStableToRemove Amount of stable liquidity to remove from the pool
    ///@param liquidityAssetToRemove Amount of asset liquidity to remove from the pool, in vAsset.
    ///@param user User to remove the liquidity for.
    ///@param spotPrice Price of the asset at the moment of liquidity removal.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity removal
    function _removeLiquidity(
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        address user,
        uint256 spotPrice,
        uint256 maxFeeValue
    )
        internal
    {
        // Get LP balances & price
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);

        // Ensure enough liquidity is available
        require(lpStableBalance >= liquidityStableToRemove && lpAssetBalance >= liquidityAssetToRemove, "L5"); // Error: Not enough liquidity

        // Measured against the PRE-removal pool: the global legs are decremented further down.
        // Living in the internal function means voluntary removal, the partial-liquidation LP pull
        // and the close-path LP drain all get the conditional behaviour.
        _clearCurveMemoryIfSignificant(liquidityStableToRemove, liquidityAssetToRemove);

        _updateFG(spotPrice, lastOperationTimestamp); // Update funding rate

        // Compute & apply funding fee
        (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);
        VirtualTraderPosition storage position = userVirtualTraderPosition[user];
        (position.fundingFee, position.fundingFeeSign) =
            UtilMath.signedSum(position.fundingFee, position.fundingFeeSign, localFundingFee, localFundingFeeSign);

        // Snapshot new values into the current accounting epoch (captures M(t0)/G, initials, epoch id).
        _updateSnapshots(user, lpStableBalance - liquidityStableToRemove, lpAssetBalance - liquidityAssetToRemove);
        LiquidityPosition storage liqPosition = liquidityPosition[user];

        // Compute removal fee
        uint256 fee = FeeManager.computeLiquidityRemovalFee(
            liquidityStableToRemove,
            liquidityAssetToRemove,
            globalLiquidityStable,
            globalLiquidityAsset,
            spotPrice,
            oracleDecimals,
            liquidityMaxFee,
            liquidityMinFee,
            liquidityFeeK,
            decimals.liquidityFeeDecimals
        );

        // Compute fee split
        uint256 feeValue = ((liquidityStableToRemove + (liquidityAssetToRemove * spotPrice) / oracleDecimals) * fee)
            / decimals.liquidityFeeDecimals;
        require(maxFeeValue >= feeValue || maxFeeValue == 0, "L6");

        // Ensure global liquidity is sufficient
        assert(globalLiquidityStable >= liquidityStableToRemove && globalLiquidityAsset >= liquidityAssetToRemove);

        unchecked {
            globalLiquidityStable -= liquidityStableToRemove;
            globalLiquidityAsset -= liquidityAssetToRemove;
        }

        _distributeLiquidityFee(feeValue, spotPrice);

        // Deduct fee from removed liquidity
        if (liquidityStableToRemove >= feeValue) {
            unchecked {
                liquidityStableToRemove -= feeValue;
            }
        } else {
            unchecked {
                position.debtStable += feeValue - liquidityStableToRemove;
                liquidityStableToRemove = 0;
            }
        }

        // Update LP balances
        unchecked {
            //first remove LP debt, then give back stable and assets.

            (liquidityStableToRemove, liqPosition.debtStable) =
                UtilMath.reduceValue(liquidityStableToRemove, liqPosition.debtStable);
            (liquidityAssetToRemove, liqPosition.debtAsset) =
                UtilMath.reduceValue(liquidityAssetToRemove, liqPosition.debtAsset);

            position.balanceStable += liquidityStableToRemove;
            position.balanceAsset += liquidityAssetToRemove;

            if (liquidityAssetToRemove > 0) {
                if (totalTraderExposureSign) {
                    totalTraderExposure += liquidityAssetToRemove;
                } else {
                    totalTraderExposureSign = totalTraderExposure < liquidityAssetToRemove;
                    totalTraderExposure = UtilMath.diffAbs(totalTraderExposure, liquidityAssetToRemove);
                }
            }
        }

        emit LiquidityMoved(user, liquidityStableToRemove, liquidityAssetToRemove, feeValue, false);
    }

    ///@dev Distributes stable-denominated removal fees to the remaining LPs, including one-sided pools.
    function _distributeLiquidityFee(uint256 feeValue, uint256 spotPrice) internal {
        uint256 totalLiquidityValue = globalLiquidityStable + (globalLiquidityAsset * spotPrice) / oracleDecimals;

        if (feeValue > 0 && totalLiquidityValue > 0) {
            unchecked {
                uint256 feeStable = (feeValue * globalLiquidityStable) / totalLiquidityValue;

                // Each allocation divides by its own leg, so it is computed only when that leg
                // is nonzero; an empty leg contributes no matrix update.
                int256 aX;
                int256 aY;

                if (globalLiquidityStable != 0) {
                    aX = SafeCast.toInt256(
                        feeStable * SafeCast.toUint256(decimals.liquidityMDecimals) / globalLiquidityStable
                    );
                }
                if (globalLiquidityAsset != 0) {
                    aY = SafeCast.toInt256(
                        (feeValue - feeStable) * SafeCast.toUint256(decimals.liquidityMDecimals) / globalLiquidityAsset
                    );
                }

                _applyLiquidityMatrixUpdate(aX, aY, 2);
                globalLiquidityStable += feeValue;
            }
        }
    }
}
