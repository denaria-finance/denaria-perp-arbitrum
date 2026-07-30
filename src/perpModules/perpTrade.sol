// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpLiquidity.sol";
import "../util/UtilMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

abstract contract PerpTrade is PerpLiquidity {
    using Math for uint256;
    using SignedMath for int256;

    event ClosedPosition(address indexed user, uint256 pnl, bool pnlSign);

    event ExecutedTrade(
        address indexed user,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        uint256 leverage
    );

    ///@dev Is the curve window still open for this direction at this price? All four conditions
    ///     must hold. The timestamp bound is non-strict on the active side, so a trade landing
    ///     exactly on the interval boundary still reuses the window.
    ///@dev The fourth condition guards the base-frame reconstruction below. Now that the 1/64 rule
    ///     lets the accumulators survive an LP removal that shrinks the pool, a pool leg can fall
    ///     under the accumulator it must be netted against; `globalLiquidityStable - dy0` would
    ///     then underflow. Note the pairing is the opposite of the naive one — a LONG nets against
    ///     the STABLE leg, a SHORT against the ASSET leg.
    function _hasActiveCurveMemory(bool direction, uint256 price) internal view returns (bool) {
        return block.timestamp <= curveParameters.lastCurveUpdate + curveParameters.curveUpdateInterval
            && curveParameters.lastTradeDirection == direction && curveParameters.lastValidatedPrice == price
            && (direction ? globalLiquidityStable > dy0 : globalLiquidityAsset > dx0);
    }

    ///@notice The curve accumulators, but only while the window is genuinely open for `direction`
    ///        at `price`; otherwise zero. A withdrawal preview has to quote against the same base
    ///        pool frame a real close would see, and reading `dx0`/`dy0` raw would apply a stale
    ///        window's accumulators to a fresh quote.
    ///@dev Exposed on the reference model so the differential harness can compare a preview against
    ///     the engine's internal equivalent; the engine does not need a selector for it, since only
    ///     its own consolidated read consumes it.
    function readCurveMemory(uint256 direction, uint256 price) external view returns (uint256 dx, uint256 dy) {
        return _readCurveMemory(direction != 0, price);
    }

    function _readCurveMemory(bool direction, uint256 price) internal view returns (uint256 dx, uint256 dy) {
        if (_hasActiveCurveMemory(direction, price)) return (dx0, dy0);
    }

    ///@notice The Vault's whole collateral-withdrawal safety read in one call: the FEE-INCLUSIVE
    ///        exit PnL and whether the position stays margin-safe with `hypotheticalCollateral`.
    ///@dev The old check valued the position at its mark and ignored what leaving actually costs —
    ///     the trade exit fee, the LP removal fee, and the slippage of the closing curve. A position
    ///     could therefore pass the check and still be unable to exit without going into bad debt.
    ///@dev Computed here rather than in the Vault so the whole verdict comes from ONE snapshot: two
    ///     separate reads could disagree, and each additional read costs a cross-contract call.
    function withdrawalCheckData(
        address user,
        uint256 price,
        uint256 hypotheticalCollateral
    )
        external
        view
        returns (uint256 pnl, bool pnlSign, bool marginSafe)
    {
        uint256 positionValue;
        uint256 exitFee;
        (pnl, pnlSign, positionValue, exitFee) = _withdrawalExitPreview(user, price);

        (uint256 totalEquity, bool totalEquitySign) = UtilMath.signedSum(hypotheticalCollateral, true, pnl, pnlSign);
        if (!totalEquitySign && totalEquity != 0) return (pnl, pnlSign, false);
        uint256 calculatedMMR =
            positionValue == 0 ? decimals.MMRDecimals : totalEquity * decimals.MMRDecimals / positionValue;

        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        LiquidityPosition storage lp = liquidityPosition[user];
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);
        uint256 debtStable = pos.debtStable > pos.balanceStable ? pos.debtStable - pos.balanceStable : 0;
        uint256 debtAsset = pos.debtAsset > pos.balanceAsset ? pos.debtAsset - pos.balanceAsset : 0;
        if (lpStableBalance + lpAssetBalance != 0) {
            // The exit fee is money the LP will not have once it leaves, so the leverage cap has to
            // be applied to what actually remains.
            uint256 feeAdjustedCollateral = hypotheticalCollateral > exitFee ? hypotheticalCollateral - exitFee : 0;
            if (
                feeAdjustedCollateral * maxLpLeverage
                    < debtStable + lp.debtStable + (debtAsset + lp.debtAsset) * price / oracleDecimals
            ) {
                calculatedMMR = 0;
            }
        }
        marginSafe = calculatedMMR >= MMR;
    }

    ///@dev Aggregates the trader and LP legs, folds in funding as of the last `updateFG` plus the
    ///     LP removal fee, then prices the exit through the closing curve.
    ///@dev `Vault.removeCollateral` calls `updateFG` immediately before this read, so on that path
    ///     the funding is current to the block; a direct caller sees the last settled rate.
    function _withdrawalExitPreview(
        address user,
        uint256 price
    )
        private
        view
        returns (uint256 pnl, bool pnlSign, uint256 positionValue, uint256 exitFee)
    {
        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        LiquidityPosition storage lp = liquidityPosition[user];
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);

        (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);
        (uint256 fundingFee, bool fundingFeeSign) =
            UtilMath.signedSum(pos.fundingFee, pos.fundingFeeSign, localFundingFee, localFundingFeeSign);

        // The removal fee is charged like a funding debit, so it lands on the same side of the fold.
        uint256 lpRemovalFee = _lpRemovalFee(price, lpStableBalance, lpAssetBalance);
        if (lpRemovalFee != 0) {
            (fundingFee, fundingFeeSign) = UtilMath.signedSum(fundingFee, fundingFeeSign, lpRemovalFee, true);
        }

        (pnl, pnlSign, positionValue, exitFee) = _feeInclusivePnl(
            pos.balanceStable + lpStableBalance,
            pos.balanceAsset + lpAssetBalance,
            pos.debtStable + lp.debtStable,
            pos.debtAsset + lp.debtAsset,
            fundingFee,
            fundingFeeSign,
            price
        );
        exitFee += lpRemovalFee;
    }

    ///@dev What unwinding this LP position would cost in removal fees, at the current pool.
    function _lpRemovalFee(
        uint256 price,
        uint256 lpStableBalance,
        uint256 lpAssetBalance
    )
        private
        view
        returns (uint256 feeValue)
    {
        if ((lpStableBalance | lpAssetBalance) == 0) return 0;
        uint256 fee = FeeManager.computeLiquidityRemovalFee(
            lpStableBalance,
            lpAssetBalance,
            globalLiquidityStable,
            globalLiquidityAsset,
            price,
            oracleDecimals,
            liquidityMaxFee,
            liquidityMinFee,
            liquidityFeeK,
            decimals.liquidityFeeDecimals
        );
        feeValue = (lpStableBalance + lpAssetBalance * price / oracleDecimals) * fee / decimals.liquidityFeeDecimals;
    }

    ///@dev PnL that already carries the cost of closing. The asset leg is priced through the curve
    ///     the exit would actually trade on, net of the trading fee.
    function _feeInclusivePnl(
        uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,
        uint256 price
    )
        private
        view
        returns (uint256 pnl, bool pnlSign, uint256 positionValue, uint256 closeFee)
    {
        (uint256 diffStable, bool diffStableSign) = UtilMath.signedSum(balanceStable, true, debtStable, false);
        (diffStable, diffStableSign) = UtilMath.signedSum(diffStable, diffStableSign, fundingFee, !fundingFeeSign);
        (uint256 diffAsset, bool diffAssetSign) = UtilMath.signedSum(balanceAsset, true, debtAsset, false);
        positionValue = diffAsset * price / oracleDecimals;

        uint256 stableTradeValue;
        // Dust cutoff: below this the exit is not worth pricing, and charging the FLAT trading fee
        // on a dust leg would invent a cost far larger than the leg itself.
        if (diffAsset > 1e13 * oracleDecimals / price) {
            if (diffAssetSign) {
                (stableTradeValue, closeFee) = _longCloseValue(diffAsset, price);
            } else {
                (stableTradeValue, closeFee) = _shortCloseCost(diffAsset, price);
            }
        }

        (pnl, pnlSign) = UtilMath.signedSum(diffStable, diffStableSign, stableTradeValue, diffAssetSign);
    }

    ///@dev Selling a net-long asset leg: a SHORT trade, quoted against the short window's base pool
    ///     frame so the preview sees the same curve a real close would.
    function _longCloseValue(
        uint256 assetSize,
        uint256 price
    )
        private
        view
        returns (uint256 netReturn, uint256 closeFee)
    {
        uint256 stableLiquidity = globalLiquidityStable;
        uint256 assetLiquidity = globalLiquidityAsset;
        (uint256 curveDx, uint256 curveDy) = _readCurveMemory(false, price);
        uint256 grossReturn = _computeIncrementalShortReturn(
            assetSize,
            curveDx,
            price,
            oracleDecimals,
            stableLiquidity + curveDy,
            stableLiquidity + curveDy,
            assetLiquidity - curveDx,
            curveParameters.shortCurveParameterA,
            curveParameters.shortCurveParameterB,
            1e8
        );
        closeFee = grossReturn * tradingFee / decimals.tradingFeeDecimals + flatTradingFee;
        if (closeFee < grossReturn) return (grossReturn - closeFee, closeFee);
        return (0, grossReturn);
    }

    ///@dev Buying back a net-short asset leg: a LONG trade. Same two-term ceil gross-up the close
    ///     path uses, so the preview cannot quote an exit cheaper than the one it would get.
    function _shortCloseCost(uint256 assetSize, uint256 price) private view returns (uint256 cost, uint256 closeFee) {
        uint256 stableLiquidity = globalLiquidityStable;
        uint256 assetLiquidity = globalLiquidityAsset;
        // The quote short-circuits to a plain spot value when the buy-back would empty the asset leg
        // or leave a sub-unit pool; on those branches the answer bears no relation to dy0, and since
        // a long window's dy0 exceeds the spot value of its dx0 by the slippage premium, `- curveDy`
        // would underflow. This is the close path's own guard in the same positive form: outside it
        // there is no window to unwind against, so the leg is priced at spot with no memory.
        uint256 curveDx;
        uint256 curveDy;
        if (assetSize < assetLiquidity && (assetLiquidity - assetSize) * price / oracleDecimals >= 1e18) {
            (curveDx, curveDy) = _readCurveMemory(true, price);
        }
        uint256 rawAmountIn = _computeExecutableAmountInLong(
            assetSize + curveDx,
            price,
            oracleDecimals,
            stableLiquidity,
            stableLiquidity - curveDy,
            assetLiquidity + curveDx,
            curveParameters.longCurveParameterA,
            curveParameters.longCurveParameterB,
            1e8
        );
        // The guard makes this saturation unreachable; it must NOT stand alone — saturating without
        // the guard would understate the buy-back and let an oversized short withdraw.
        uint256 exactAmountIn = rawAmountIn > curveDy ? rawAmountIn - curveDy : 0;
        uint256 feeDenominator = decimals.tradingFeeDecimals - tradingFee;
        cost = Math.mulDiv(exactAmountIn, decimals.tradingFeeDecimals, feeDenominator, Math.Rounding.Ceil)
            + Math.mulDiv(flatTradingFee, decimals.tradingFeeDecimals, feeDenominator, Math.Rounding.Ceil);
        closeFee = cost > exactAmountIn ? cost - exactAmountIn : 0;
    }

    ///@dev Opens a fresh curve window unless the current one is still active for this direction
    ///     and price. The accumulators and the (update, direction, price) triple are only ever
    ///     written together, here — the LP paths deliberately no longer touch the triple.
    function _syncCurveMemory(bool direction, uint256 price) private {
        if (!_hasActiveCurveMemory(direction, price)) {
            curveParameters.lastCurveUpdate = block.timestamp;
            curveParameters.lastTradeDirection = direction;
            curveParameters.lastValidatedPrice = price;
            _clearCurveMemory();
        }
    }

    //Function for trading asset, direction is true=long, false=short. Size is in vStable for long and vAsset for short. Initial guess is for newton method, if we compute it from frontend
    ///@dev Main trading function. Opens a trade position from the frontend. Exchange virtual stable and assets minting additional virtual tokens for the user if necessary.
    ///@dev The separate trade positions are logged using the event being emitted in this function.
    ///@param direction Direction of the trade, true for long, false for short.
    ///@param size Size of the trade expressed in the currency to be input in the trade, vStable for long and vAsset for short.
    ///@param minTradeReturn Minimum trade return allowed for the trade by the user.
    ///@param initialGuess Initial guess for the newton method used in the curve functions to compute the trade return.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this trade. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param leverage Leverage chosen for the trade by the user. Used solely for keeping track of the trades in the events.
    ///@param unverifiedReport Chainlink price report.
    ///@return tradeReturn Currency being returned from the trade.
    function trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes memory unverifiedReport
    )
        external
        nonReentrant
        returns (uint256)
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        require(leverage <= maxLeverage, "T0");

        address user = _msgSender();
        uint256 spotPrice = getPrice();

        require(direction ? size >= minimumTradeSize : (size * spotPrice) / oracleDecimals >= minimumTradeSize, "T2");

        uint256 tradeReturn = _trade(direction, size, minTradeReturn, initialGuess, frontendAddress, user, spotPrice);

        require(
            UtilMath.calcMR(user, spotPrice, address(this), getCollateral(user), lastOperationTimestamp) > MMR, "T1"
        );

        emit ExecutedTrade(user, direction, size, tradeReturn, spotPrice, leverage);

        return tradeReturn;
    }

    ///@dev Internal trade function that handles all of the necessary operations for moving virtual assets during a trade.
    ///@param direction Direction of the trade, true for long, false for short.
    ///@param size Size of the trade expressed in the currency to be input in the trade, vStable for long and vAsset for short.
    ///@param minTradeReturn Minimum trade return allowed for the trade by the user.
    ///@param initialGuess Initial guess for the newton method used in the curve functions to compute the trade return.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this trade. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param user user which performs the trade.
    ///@param spotPrice oracle price.
    ///@return tradeReturn Currency being returned from the trade.
    function _trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        address user,
        uint256 spotPrice
    )
        internal
        returns (uint256)
    {
        uint256 stableLiq = globalLiquidityStable;
        uint256 assetLiq = globalLiquidityAsset;
        uint256 tradingFeeAmount;
        uint256 tradeReturn;
        uint256 shortTotalTradeReturn;

        uint256 _oracleDecimals = oracleDecimals;
        uint256 _feeFrontend = feeFrontend;
        uint256 _lastOperationTimestamp = lastOperationTimestamp;

        uint256 zeroSlippageReturn = direction ? size * _oracleDecimals / spotPrice : size * spotPrice / _oracleDecimals;

        _syncCurveMemory(direction, spotPrice);

        // Compute trade return and validate slippage
        if (direction) {
            if (assetLiq <= zeroSlippageReturn) {
                initialGuess = 0;
            } else if (initialGuess > assetLiq || initialGuess < (assetLiq - zeroSlippageReturn)) {
                initialGuess = assetLiq - zeroSlippageReturn;
            }

            tradingFeeAmount = (size * tradingFee) / decimals.tradingFeeDecimals + flatTradingFee;
            if (size > tradingFeeAmount) {
                // Only run the trade if the size is bigger than the fee. We know that we don't treat the case where the frontEnd fee is 0, but it's a minor edge case that does not affect the protocol function
                uint256 frontendFeePart = (tradingFeeAmount * _feeFrontend) / decimals.feeFractionsDecimals;
                if (frontendAddress == address(0)) {
                    tradeReturn = _computeLongReturn(
                        size - (tradingFeeAmount - frontendFeePart) + dy0,
                        spotPrice,
                        _oracleDecimals,
                        initialGuess,
                        stableLiq - dy0,
                        assetLiq + dx0,
                        curveParameters.longCurveParameterA,
                        curveParameters.longCurveParameterB,
                        1e8
                    ) - dx0;
                    dy0 += size - (tradingFeeAmount - frontendFeePart);
                } else {
                    tradeReturn = _computeLongReturn(
                        size - tradingFeeAmount + dy0,
                        spotPrice,
                        _oracleDecimals,
                        initialGuess,
                        stableLiq - dy0,
                        assetLiq + dx0,
                        curveParameters.longCurveParameterA,
                        curveParameters.longCurveParameterB,
                        1e8
                    ) - dx0;
                    dy0 += size - tradingFeeAmount;
                }
                // Every executed trade feeds the slippage EMA — including a second trade in the
                // same block. The former same-block skip let an attacker split a move across one
                // block to leave the liquidation benchmark stale.
                avgSlippageL = UtilMath.calcEMA(
                    (size - tradingFeeAmount) * _oracleDecimals / tradeReturn,
                    spotPrice,
                    _oracleDecimals,
                    avgSlippageL,
                    emaParam
                );
                dx0 += tradeReturn;
            } else {
                //If the trade is so small that it cannot cover its own fees then don't trade at all and only take fee.
                tradeReturn = 0;
                tradingFeeAmount = size;
            }

            require(tradeReturn >= minTradeReturn && tradeReturn <= zeroSlippageReturn, "T4");
        } else {
            if (stableLiq <= zeroSlippageReturn) {
                initialGuess = 0;
            } else if (initialGuess > stableLiq || initialGuess < (stableLiq - zeroSlippageReturn)) {
                initialGuess = stableLiq - (size * spotPrice) / _oracleDecimals;
            }

            // Priced as a SLICE against the window's base pool state, so splitting a short across
            // several transactions in one window cannot beat trading it whole. The helper nets the
            // already-consumed `dx0` internally, which is why the trailing `- dy0` is gone.
            shortTotalTradeReturn = _computeIncrementalShortReturn(
                size,
                dx0,
                spotPrice,
                _oracleDecimals,
                initialGuess + dy0,
                stableLiq + dy0,
                assetLiq - dx0,
                curveParameters.shortCurveParameterA,
                curveParameters.shortCurveParameterB,
                1e8
            );
            // Unconditional for the same reason as the long leg: same-block trades must not skip
            // the EMA.
            avgSlippageS = UtilMath.calcEMA(
                shortTotalTradeReturn * _oracleDecimals / size, spotPrice, _oracleDecimals, avgSlippageS, emaParam
            );
            dx0 += size;

            tradingFeeAmount = (shortTotalTradeReturn * tradingFee) / decimals.tradingFeeDecimals + flatTradingFee;
            if (tradingFeeAmount < shortTotalTradeReturn) {
                tradeReturn = shortTotalTradeReturn - tradingFeeAmount;
            } else {
                tradingFeeAmount = shortTotalTradeReturn;
                tradeReturn = 0;
            }

            if (frontendAddress == address(0)) {
                tradeReturn += (tradingFeeAmount * _feeFrontend) / decimals.feeFractionsDecimals;
            }

            require(tradeReturn >= minTradeReturn && tradeReturn <= zeroSlippageReturn, "T4");
        }

        require(direction ? tradeReturn < assetLiq : tradeReturn < stableLiq, "T5");

        _updateFG(spotPrice, _lastOperationTimestamp); // Update Funding Rate and G vector

        unchecked {
            VirtualTraderPosition storage userPosition = userVirtualTraderPosition[user];

            (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);

            // Update cumulative funding fee for trader and make new snapshots
            (userPosition.fundingFee, userPosition.fundingFeeSign) = UtilMath.signedSum(
                userPosition.fundingFee, userPosition.fundingFeeSign, localFundingFee, localFundingFeeSign
            );

            // Store new snapshots
            userPosition.initialFundingRate = fundingRate;
            userPosition.initialFundingRateSign = fundingRateSign;
            // Re-baseline the LP funding snapshot against the user's own epoch (no-op for a pure trader).
            _refreshLpFundingSnapshot(user);

            if (direction) {
                (totalTraderExposure, totalTraderExposureSign) =
                    UtilMath.signedSum(totalTraderExposure, totalTraderExposureSign, tradeReturn, true);
                userPosition.balanceAsset += tradeReturn;
                if (size <= userPosition.balanceStable) {
                    userPosition.balanceStable -= size;
                } else {
                    userPosition.debtStable += size - userPosition.balanceStable;
                    userPosition.balanceStable = 0;
                }
            } else {
                (totalTraderExposure, totalTraderExposureSign) =
                    UtilMath.signedSum(totalTraderExposure, totalTraderExposureSign, size, false);
                userPosition.balanceStable += tradeReturn;
                if (size <= userPosition.balanceAsset) {
                    userPosition.balanceAsset -= size;
                } else {
                    userPosition.debtAsset += size - userPosition.balanceAsset;
                    userPosition.balanceAsset = 0;
                }
            }
        }

        int256 aY;
        int256 aX;

        uint256 feeFracDec = decimals.feeFractionsDecimals;
        int256 liqMDec = decimals.liquidityMDecimals;
        uint256 liqMDecU = SafeCast.toUint256(liqMDec);

        uint256 feeLPShare = (tradingFeeAmount * feeLP) / feeFracDec;

        if (direction) {
            unchecked {
                uint256 adjSize = size - tradingFeeAmount * (feeFracDec - feeLP) / feeFracDec;
                if (frontendAddress == address(0)) {
                    adjSize += (tradingFeeAmount * _feeFrontend) / feeFracDec;
                }

                aY = SafeCast.toInt256(adjSize * liqMDecU / assetLiq);
                aX = SafeCast.toInt256(tradeReturn * liqMDecU / assetLiq);

                _applyLiquidityMatrixUpdate(aX, aY, 0);

                globalLiquidityStable += adjSize;
                globalLiquidityAsset -= tradeReturn;
            }
        } else {
            unchecked {
                uint256 netReturn = shortTotalTradeReturn - feeLPShare;
                // Record the NET pool outflow, not the gross return: dy0 must be exactly the sum
                // of the `globalLiquidityStable` decrements over the window, so that
                // `stableLiq + dy0` reconstructs the window-start pool bit-exactly.
                dy0 += netReturn;

                aX = SafeCast.toInt256(size * liqMDecU / stableLiq);
                aY = SafeCast.toInt256(netReturn * liqMDecU / stableLiq);

                _applyLiquidityMatrixUpdate(aX, aY, 1);

                globalLiquidityStable -= netReturn;
                globalLiquidityAsset += size;
            }
        }
        unchecked {
            _assignProtocolFeeFillingInsurance(
                (tradingFeeAmount * (feeFracDec - feeLP - _feeFrontend)) / feeFracDec, feeProtocolAddr
            );
            if (frontendAddress != address(0)) {
                userVirtualTraderPosition[frontendAddress].balanceStable += (tradingFeeAmount * _feeFrontend)
                    / feeFracDec;
            }
        }

        require(globalLiquidityStable >= 1e18 && globalLiquidityAsset * spotPrice / oracleDecimals >= 1e18, "T3");

        return tradeReturn;
    }

    ///@dev Function to assing the a fee to protocolAddr passed as input only if the insuranceFund is full, otherwise it fills it first.
    ///@param fee The fee to be assigned.
    ///@param protocolAddr Address that holds the fees.
    function _assignProtocolFeeFillingInsurance(uint256 fee, address protocolAddr) internal {
        if (insuranceFundSign) {
            uint256 current = insuranceFund;
            // If under cap, fill insurance fund first
            if (current < insuranceFundCap) {
                uint256 capLeft = insuranceFundCap - current;
                if (fee <= capLeft) {
                    // Fully absorb fee
                    insuranceFund = current + fee;
                    return;
                }
                // Partially fill and forward remainder
                insuranceFund = insuranceFundCap;
                userVirtualTraderPosition[protocolAddr].balanceStable += fee - capLeft;
                return;
            }
            // Already at cap: forward entire fee
            userVirtualTraderPosition[protocolAddr].balanceStable += fee;
            return;
        }

        // insuranceFundSign == false: signed addition mode
        uint256 signedCapacity = insuranceFundCap + insuranceFund;
        if (fee <= signedCapacity) {
            // Fits within signed capacity
            (insuranceFund, insuranceFundSign) = UtilMath.signedSum(insuranceFund, insuranceFundSign, fee, true);
            return;
        }

        // Exceeds cap: fill to cap and forward remainder
        userVirtualTraderPosition[protocolAddr].balanceStable += fee - signedCapacity;
        insuranceFund = insuranceFundCap;
        insuranceFundSign = true;
    }

    ///@dev Closes the virtual position of the user and adds (or subtracts) the pnl to the user's collateral in the vault.
    ///@param maxSlippage Maximum slippage allowed for the trade by the user.
    ///@param maxLiqFee Maximum liquidity fee allowd for the liquidity removal by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param unverifiedReport Chainlink price report.
    function closeAndWithdraw(
        uint256 maxSlippage,
        uint256 maxLiqFee,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        public
        nonReentrant
    {
        address user = _msgSender();
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        _closeAndWithdraw(maxSlippage, maxLiqFee, frontendAddress, user, true);
    }

    ///@dev Implemented by PerpAutoClose: clears a user's auto-close config and emits
    /// ToggledAutoClose. Declared here so the position-reset path can invoke it.
    function _disableAutoClose(address user, uint256 mode) internal virtual;

    //Function to be called when exiting the system. It repays all debts (if possible) and returns final pnl
    ///@dev Internal function that handles the closing of a position.
    ///@param maxSlippage Maximum slippage allowed for the trade by the user.
    ///@param maxLiqFee Maximum liquidity fee allowd for the liquidity removal by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param user User owning the position to close
    function _closeAndWithdraw(
        uint256 maxSlippage,
        uint256 maxLiqFee,
        address frontendAddress,
        address user,
        bool isSelfClose
    )
        internal
    {
        uint256 price = getPrice();
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);
        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        LiquidityPosition storage lpPos = liquidityPosition[user];

        // Close liquidity positions if needed. An LP whose visible balances and debts have all
        // decayed to zero can still hold an active snapshot carrying unsettled funding, so the
        // removal path runs for it too and settles that funding before the state is dropped.
        if (
            (lpStableBalance | lpAssetBalance | lpPos.debtAsset | lpPos.debtStable) != 0
                || _hasActiveLiquiditySnapshot(lpPos)
        ) {
            _removeLiquidity(lpStableBalance, lpAssetBalance, user, price, maxLiqFee);
            uint256 assetDebtLP = lpPos.debtAsset;
            pos.debtAsset += assetDebtLP;
            pos.debtStable += lpPos.debtStable;
            if (assetDebtLP > 0) {
                if (!totalTraderExposureSign) {
                    totalTraderExposure += assetDebtLP;
                } else {
                    totalTraderExposureSign = totalTraderExposure > assetDebtLP;
                    totalTraderExposure = UtilMath.diffAbs(totalTraderExposure, assetDebtLP);
                }
            }
        }
        delete liquidityPosition[user];

        if (UtilMath.diffAbs(pos.balanceAsset, pos.debtAsset) * price / oracleDecimals < 1e10) {
            pos.balanceAsset = pos.debtAsset;
        } else {
            // Repay asset debt
            if (pos.balanceAsset > pos.debtAsset) {
                unchecked {
                    pos.balanceAsset -= pos.debtAsset;
                }
                pos.debtAsset = 0;
                uint256 minTradeReturn = pos.balanceAsset * price / oracleDecimals * (1e5 - maxSlippage) / 1e5;
                uint256 inputSize = pos.balanceAsset;
                uint256 tradeReturn =
                    _trade(false, inputSize, minTradeReturn, globalLiquidityStable, frontendAddress, user, price);
                emit ExecutedTrade(user, false, inputSize, tradeReturn, price, 0);
            } else {
                unchecked {
                    pos.debtAsset -= pos.balanceAsset;
                }
                pos.balanceAsset = 0;
            }

            // Repay stable debt and fully close position

            if (pos.debtAsset > 0) {
                // Stays outside both guards: the curve window may roll even when no buy-back runs.
                _syncCurveMemory(true, price);
                // The guards read the RAW asset leg while the quote reads the memory-adjusted one;
                // the two `+ dx0` terms cancel, so this is the callee's own oversized-output test
                // written in positive form. When either guard fails there is no quote, no trade, no
                // event and NO C0 check: the position is deleted carrying its residual debt.
                if (pos.debtAsset < globalLiquidityAsset) {
                    unchecked {
                        if ((globalLiquidityAsset - pos.debtAsset) * price / oracleDecimals >= 1e18) {
                            uint256 exactAmountIn = _computeExecutableAmountInLong(
                                pos.debtAsset + dx0,
                                price,
                                oracleDecimals,
                                globalLiquidityStable,
                                globalLiquidityStable - dy0,
                                globalLiquidityAsset + dx0,
                                curveParameters.longCurveParameterA,
                                curveParameters.longCurveParameterB,
                                1e8
                            ) - dy0;
                            // One unconditional two-term ceil. With a real frontend the fraction is
                            // the whole ratio and the frontend rebate drops out; with none, the
                            // forward trade rebates that share so the gross-up must not charge it.
                            uint256 feeChargedFraction = frontendAddress == address(0)
                                ? decimals.feeFractionsDecimals - feeFrontend
                                : decimals.feeFractionsDecimals;
                            uint256 feeDenominator = decimals.tradingFeeDecimals * decimals.feeFractionsDecimals
                                - tradingFee * feeChargedFraction;
                            uint256 inputNeeded = Math.mulDiv(
                                exactAmountIn,
                                decimals.tradingFeeDecimals * decimals.feeFractionsDecimals,
                                feeDenominator,
                                Math.Rounding.Ceil
                            )
                            + Math.mulDiv(
                                flatTradingFee * feeChargedFraction,
                                decimals.tradingFeeDecimals,
                                feeDenominator,
                                Math.Rounding.Ceil
                            );
                            uint256 tradeReturn = _trade(
                                true,
                                inputNeeded,
                                inputNeeded * oracleDecimals / price * (1e5 - maxSlippage) / 1e5,
                                globalLiquidityAsset,
                                frontendAddress,
                                user,
                                price
                            );
                            emit ExecutedTrade(user, true, inputNeeded, tradeReturn, price, 0);

                            // Flat dust bound. It was briefly pool-relative because the ANALYTIC
                            // inverse left a residual that grew with pool depth; the executable
                            // quote bisects to a tolerance expressed in exactly these units, so the
                            // residual is bounded by the quote instead. Residuals under the bound
                            // are still priced into the user's PnL by calcPnL, so the bound only
                            // caps the per-close dust drift of totalTraderExposure.
                            require(
                                UtilMath.diffAbs(pos.balanceAsset, pos.debtAsset) * price / oracleDecimals < 1e10, "C0"
                            );
                        }
                    }
                }
            }
        }

        // Calculate PnL
        (uint256 pnl, bool pnlSign) = calcPnL(user, price);

        if (isSelfClose && !pnlSign) {
            require(pnl < getCollateral(user), "C1"); //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.
        }

        // Give back whatever net short survives the close — the skip path and the dust-snap branch
        // both leave one. Without this it stays in global exposure forever, corrupting the funding
        // rate and pool-skew accounting. It must read the post-buy-back position, so it sits after
        // the bad-debt check and before the delete.
        if (pos.debtAsset > pos.balanceAsset) {
            unchecked {
                (totalTraderExposure, totalTraderExposureSign) = UtilMath.signedSum(
                    totalTraderExposure, totalTraderExposureSign, pos.debtAsset - pos.balanceAsset, true
                );
            }
        }

        // Reset position
        delete userVirtualTraderPosition[user];
        _disableAutoClose(user, 0);

        // Update collateral
        if (getCollateral(user) < pnl && !pnlSign) {
            (insuranceFund, insuranceFundSign) =
                UtilMath.signedSum(insuranceFund, insuranceFundSign, pnl - getCollateral(user), false);
        }
        IVault(vault).addPnlToCollateral(user, pnl, pnlSign);

        emit ClosedPosition(user, pnl, pnlSign);
    }
}
