// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpConfig.sol";
import "../util/UtilMath.sol";
import "../util/MatrixMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";

abstract contract PerpFunding is PerpConfig {
    using Math for uint256;
    using SignedMath for int256;

    /// @dev Determinant (Q80) of an epoch's liquidity matrix; 0 for an uninitialized epoch.
    function _liquidityEpochDeterminant(uint256 epochId) internal view returns (int256) {
        LiquidityEpoch storage epoch = liquidityEpochs[epochId];
        if (epoch.liquidityM[0][0] == 0) return 0;

        return MatrixMath.sumMulDivSigned(
            epoch.liquidityM[0][0],
            epoch.liquidityM[1][1],
            -epoch.liquidityM[1][0],
            epoch.liquidityM[0][1],
            decimals.liquidityMDecimals
        );
    }

    /// @dev Reset an epoch to the Q80 identity matrix with a zeroed funding row (activeLpCount is left as-is).
    function _initializeLiquidityEpoch(uint256 epochId) internal {
        LiquidityEpoch storage epoch = liquidityEpochs[epochId];
        epoch.liquidityM = [[decimals.liquidityMDecimals, int256(0)], [int256(0), decimals.liquidityMDecimals]];
        delete epoch.matrixRowG;
    }

    /// @dev Advance oldestActiveLiquidityEpoch past any drained/uninitialized epoch below current, freeing storage.
    function _retireInactiveLiquidityEpochs() internal {
        while (oldestActiveLiquidityEpoch < currentLiquidityEpoch) {
            LiquidityEpoch storage epoch = liquidityEpochs[oldestActiveLiquidityEpoch];
            if (epoch.liquidityM[0][0] != 0 && epoch.activeLpCount != 0) return;
            if (epoch.liquidityM[0][0] != 0) delete liquidityEpochs[oldestActiveLiquidityEpoch];
            oldestActiveLiquidityEpoch += 1;
        }
    }

    /// @dev Roll a fresh epoch once the current matrix determinant has decayed past the threshold, so new
    /// snapshots key off a well-conditioned identity matrix. Reverts LECAP if the active window is full.
    function _rollLiquidityEpochIfNeeded() internal {
        int256 determinant = _liquidityEpochDeterminant(currentLiquidityEpoch);
        if (determinant > decimals.liquidityMDecimals / int256(LIQUIDITY_EPOCH_DET_DENOMINATOR)) return;

        uint256 previousEpoch = currentLiquidityEpoch;
        uint256 activeWindow = previousEpoch + 1 - oldestActiveLiquidityEpoch;
        if (liquidityEpochs[previousEpoch].activeLpCount == 0) activeWindow -= 1;
        if (!(activeWindow < MAX_ACTIVE_LIQUIDITY_EPOCHS)) revert("LECAP");

        currentLiquidityEpoch = previousEpoch + 1;
        _initializeLiquidityEpoch(currentLiquidityEpoch);
        _retireInactiveLiquidityEpochs();
    }

    /// @dev Whether an LP position holds a live snapshot (nonzero M and initial balance).
    function _hasActiveLiquiditySnapshot(LiquidityPosition storage position) internal view returns (bool) {
        return
            position.snapshotM[0][0] != 0 && (position.initialStableBalance != 0 || position.initialAssetBalance != 0);
    }

    /// @dev Re-baseline an LP's funding G snapshot against its own epoch's current G (M untouched).
    function _refreshLpFundingSnapshot(address user) internal {
        LiquidityPosition storage lp = liquidityPosition[user];
        if (!_hasActiveLiquiditySnapshot(lp)) return;
        lp.snapshotG = liquidityEpochs[liquidityPositionEpoch[user]].matrixRowG;
    }

    /// @dev Apply a trade/fee matrix update to every active epoch. updateKind: 0 = long, 1 = short, 2 = fee.
    function _applyLiquidityMatrixUpdate(int256 aX, int256 aY, uint8 updateKind) internal {
        int256 liqMDec = decimals.liquidityMDecimals;

        for (uint256 epochId = oldestActiveLiquidityEpoch; epochId <= currentLiquidityEpoch; epochId++) {
            LiquidityEpoch storage epoch = liquidityEpochs[epochId];
            if (epoch.liquidityM[0][0] == 0 || (epochId != currentLiquidityEpoch && epoch.activeLpCount == 0)) {
                continue;
            }

            if (updateKind == 0) {
                int256 m10 = epoch.liquidityM[1][0];
                int256 m11 = epoch.liquidityM[1][1];
                epoch.liquidityM[0][0] += aY * m10 / liqMDec;
                epoch.liquidityM[0][1] += aY * m11 / liqMDec;
                epoch.liquidityM[1][0] = m10 - UtilMath.divCeil(aX * m10, liqMDec);
                epoch.liquidityM[1][1] = m11 - UtilMath.divCeil(aX * m11, liqMDec);
            } else if (updateKind == 1) {
                int256 m00 = epoch.liquidityM[0][0];
                int256 m01 = epoch.liquidityM[0][1];
                epoch.liquidityM[1][0] += aX * m00 / liqMDec;
                epoch.liquidityM[1][1] += aX * m01 / liqMDec;
                epoch.liquidityM[0][0] = m00 - UtilMath.divCeil(aY * m00, liqMDec);
                epoch.liquidityM[0][1] = m01 - UtilMath.divCeil(aY * m01, liqMDec);
            } else {
                epoch.liquidityM[0][0] += (aY * epoch.liquidityM[1][0] + aX * epoch.liquidityM[0][0]) / liqMDec;
                epoch.liquidityM[0][1] += (aY * epoch.liquidityM[1][1] + aX * epoch.liquidityM[0][1]) / liqMDec;
            }
        }
    }

    ///@dev Returns the oracle price for the asset.
    ///@return price Oracle price of the asset.
    function getPrice() public view returns (uint256) {
        return SafeCast.toUint256((IOracleMiddleware(oracle).getPrice()));
    }

    //Compute the (funding rate * AvgPrice) for a time period.
    ///@dev Computes the increase (or decrease) of the funding rate since the last update. Note that we do not actually store the funding rate, but the funding rate * price.
    ///@dev Important: the timestamp that is being passed in input must be in the past. It is meant to be the timestamp of the last update of the funding rate.
    ///@dev The timestamp can be used to have a "projection" of the funding rate, passing a timestamp equal to (block.timestamp - projectionLength). This way the funding rate is computed for a time laps (projectionLength)
    ///@param price Oracle price of the vAsset.
    ///@param timestamp Timestamp of the last update of the funding rate. Computes the update using the time difference (now-timestamp)
    ///@return localFundingRate Increase of the funding rate.
    ///@return localFundingRateSign Sign of the increase of the funding rate. True for positive, false for negative.
    function computeFundingRate(uint256 price, uint256 timestamp) public view returns (uint256, bool) {
        // 0. Ensure timestamp not in future
        require(timestamp <= block.timestamp, "F1");

        // 1. Load and combine liquidity
        uint256 assetLiq = globalLiquidityAsset;
        uint256 stableLiq = globalLiquidityStable;
        if (assetLiq + stableLiq == 0) return (0, true);

        // 2. Pre-calc price over oracle decimals with 18 decimals
        uint256 priceO = price * 1e18 / oracleDecimals;

        // 3. Compute unclamped coefficient numerator
        uint256 raw = totalTraderExposure * priceO / 1e18 * decimals.fundingCDecimals * decimals.fundingRateDecimals;

        // 4. Compute denominator
        uint256 denomAsset = assetLiq * priceO / 1e18;
        uint256 denom = fundingC * (denomAsset + stableLiq);

        // 5. Compute signed coefficient
        uint256 coeff = raw / denom;
        bool coeffSign = totalTraderExposureSign;

        // 6. Time-weighted rate
        uint256 delta = block.timestamp - timestamp;
        uint256 newRate = coeff * delta / fundingInterval;

        // 7. Adjust by price and return
        return (priceO * newRate / 1e18, coeffSign);
    }

    ///@dev Computes the increase (or decrease) of the funding fee of an user since the last update.
    ///@param user User to compute the funding fee for.
    function computeFundingFee(address user) public view returns (uint256 localFundingFee, bool localFundingFeeSign) {
        return _computeFundingFee(user, fundingRate, fundingRateSign);
    }

    ///@dev Computes the increase (or decrease) of the funding fee of an user since the last update, given appropriate fundingRate and fundingRateSign.
    ///@param user User to compute the funding fee for.
    ///@param _fundingRate Funding rate for the computation of the fee.
    ///@param _fundingRateSign Funding rate sign for the computation of the fee.
    function _computeFundingFee(
        address user,
        uint256 _fundingRate,
        bool _fundingRateSign
    )
        public
        view
        returns (uint256 localFundingFee, bool localFundingFeeSign)
    {
        int256 invLMD = decimals.liquidityMDecimals;
        LiquidityPosition storage lp = liquidityPosition[user];
        VirtualTraderPosition storage vp = userVirtualTraderPosition[user];
        LiquidityEpoch storage lpEpoch = liquidityEpochs[liquidityPositionEpoch[user]];

        (uint256 deltaF, bool deltaFSign) =
            UtilMath.signedSum(_fundingRate, _fundingRateSign, fundingRate, !fundingRateSign);
        int256 b = SafeCast.toInt256(deltaF * decimals.liquidityGDecimals / decimals.fundingRateDecimals);
        if (!deltaFSign) {
            b = -b;
        }

        //Compute DeltaG against the LP's own epoch bases.
        int256 deltaG0 =
            lpEpoch.matrixRowG[0] - lp.snapshotG[0] + MatrixMath.mulDivSigned(b, lpEpoch.liquidityM[1][0], invLMD);
        int256 deltaG1 =
            lpEpoch.matrixRowG[1] - lp.snapshotG[1] + MatrixMath.mulDivSigned(b, lpEpoch.liquidityM[1][1], invLMD);

        // star = DeltaG * M^-1(t0) * v(t0), recovered via the adjugate from the RAW forward
        // snapshot M(t0). Only a live LP runs it (else star = 0); a real LP with a corrupted
        // (det <= 0) snapshot reverts MDET.
        int256 star = 0;
        if (lp.initialStableBalance != 0 || lp.initialAssetBalance != 0) {
            star = MatrixMath.recoverFundingStarFromSnapshot(
                deltaG0,
                deltaG1,
                lp.snapshotM,
                lp.initialStableBalance,
                lp.initialAssetBalance,
                invLMD,
                decimals.liquidityGDecimals
            );
        }

        //Reusing old variables
        (deltaF, deltaFSign) =
            UtilMath.signedSum(_fundingRate, _fundingRateSign, vp.initialFundingRate, !vp.initialFundingRateSign);

        // Compute `exposure`
        (uint256 exposure, bool exposureSign) =
            UtilMath.signedSum(vp.balanceAsset, true, vp.debtAsset + lp.debtAsset, false);

        unchecked {
            uint256 absStar = star >= 0 ? uint256(star) : uint256(-star);

            (localFundingFee, localFundingFeeSign) = UtilMath.signedSum(
                absStar, star >= 0, (exposure * deltaF) / decimals.fundingRateDecimals, deltaFSign == exposureSign
            );
        }
    }

    /// @notice Update funding rate and the G vector.
    /// @param price Oracle price for the asset.
    /// @param timestamp This timestamp will be passed to the funding rate computation function, it should be the LastOperationTimestamp.
    function _updateFG(uint256 price, uint256 timestamp) internal {
        // Idempotent within a block: once funding is settled and the timestamp stamped, a
        // second settlement in the same block would double-count. The stamp lives here (not
        // in the callers) so every subsequent reader sees the refreshed timestamp.
        if (lastOperationTimestamp == block.timestamp) return;

        int256 invLMD = decimals.liquidityMDecimals;
        //Compute Funding Rate
        (uint256 newFundingRate, bool newFundingRateSign) = computeFundingRate(price, timestamp);
        (fundingRate, fundingRateSign) =
            UtilMath.signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);

        //Compute B
        int256 b = SafeCast.toInt256(newFundingRate * decimals.liquidityGDecimals / decimals.fundingRateDecimals);
        if (!newFundingRateSign) {
            b = -b;
        }

        //Accrue G into every live LP accounting epoch — overflow-safe signed mulDiv (Q80 matrix scale).
        for (uint256 epochId = oldestActiveLiquidityEpoch; epochId <= currentLiquidityEpoch; epochId++) {
            LiquidityEpoch storage epoch = liquidityEpochs[epochId];
            if (epoch.liquidityM[0][0] == 0 || (epochId != currentLiquidityEpoch && epoch.activeLpCount == 0)) {
                continue;
            }

            epoch.matrixRowG[0] += MatrixMath.mulDivSigned(b, epoch.liquidityM[1][0], invLMD);
            epoch.matrixRowG[1] += MatrixMath.mulDivSigned(b, epoch.liquidityM[1][1], invLMD);
        }

        lastOperationTimestamp = block.timestamp;
    }

    /// @notice Update price, funding rate and the G vector from external action.
    ///@param unverifiedReport Chainlink report of the current price
    function updateFG(bytes memory unverifiedReport) external {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        _updateFG(getPrice(), lastOperationTimestamp);
    }
}
