// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../storage/PerpStorage.sol";
import "./perpFunding.sol";
import "../util/UtilMath.sol";
import "../util/MatrixMath.sol";
import "../interfaces/IVault.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

abstract contract InternalPerpLogic is PerpFunding, ReentrancyGuardTransient {
    using Math for uint256;
    using SignedMath for int256;

    event RealizedPnL(address indexed user, uint256 pnl, bool pnlSign);

    ///@dev Returns the collateral of a user.
    ///@param user Target user.
    ///@return collateral Collateral of the target user.
    function getCollateral(address user) public view returns (uint256) {
        return IVault(vault).userCollateral(user);
    }

    //returns the stable and asset balance of user.
    ///@dev Returns the liquidity balance of an LP user.
    ///@param user target user.
    ///@return lpStableBalance Stable liquidity of the LP.
    ///@return lpAssetBalance Asset liquidity of the LP.
    function getLpLiquidityBalance(address user) public view returns (uint256 lpStableBalance, uint256 lpAssetBalance) {
        LiquidityPosition storage position = liquidityPosition[user];

        // If user has no LP position, return (0,0)
        if (position.snapshotM[0][0] == 0) return (0, 0);
        // Recover against the LP's OWN accounting epoch matrix M(t); a retired/empty epoch yields (0,0).
        LiquidityEpoch storage epoch = liquidityEpochs[liquidityPositionEpoch[user]];
        if (epoch.liquidityM[0][0] == 0) return (0, 0);

        // Recover the balance from the RAW forward snapshot M(t0) via the adjugate (no stored
        // inverse): M(t) * adj(M(t0)) * v(t0) / det(M(t0)). Reverts MDET when det(M(t0)) <= 0.
        (int256 stableResult, int256 assetResult) = MatrixMath.recoverLpBalanceFromSnapshot(
            epoch.liquidityM,
            position.snapshotM,
            position.initialStableBalance,
            position.initialAssetBalance,
            decimals.liquidityMDecimals
        );

        // Clamp each leg to 0 if negative instead of wrapping on the uint256 cast: an
        // ill-conditioned M(t) can drive a leg negative, which would otherwise wrap
        // to a huge value and inflate the LP balance up to the pool cap.
        lpStableBalance = stableResult > 0 ? uint256(stableResult) : 0;
        lpAssetBalance = assetResult > 0 ? uint256(assetResult) : 0;

        // Cap at global liquidity.
        if (lpStableBalance > globalLiquidityStable) lpStableBalance = globalLiquidityStable;
        if (lpAssetBalance > globalLiquidityAsset) lpAssetBalance = globalLiquidityAsset;
    }

    /// @notice Return the liquidity accounting epoch used by an LP snapshot.
    /// @param user LP address to inspect.
    function getLpLiquidityEpoch(address user) external view returns (uint256) {
        return liquidityPositionEpoch[user];
    }

    /// @notice Update the snapshots in the position of the user for the funding rate (F), the matrix row G (G) and the initial shares.
    /// @param user Address of the user to update
    /// @param newInitialStableBalance New initial stable balance
    /// @param newInitialAssetBalance New initial asset balance
    function _updateSnapshots(address user, uint256 newInitialStableBalance, uint256 newInitialAssetBalance) internal {
        userVirtualTraderPosition[user].initialFundingRate = fundingRate;
        userVirtualTraderPosition[user].initialFundingRateSign = fundingRateSign;

        LiquidityPosition storage position = liquidityPosition[user];
        bool hadActiveSnapshot = _hasActiveLiquiditySnapshot(position);
        uint256 oldEpochId = liquidityPositionEpoch[user];

        // Full exit: drop the snapshot, release its epoch refcount, and retire drained epochs.
        if (newInitialStableBalance == 0 && newInitialAssetBalance == 0) {
            if (hadActiveSnapshot) {
                liquidityEpochs[oldEpochId].activeLpCount -= 1;
            }
            position.initialStableBalance = 0;
            position.initialAssetBalance = 0;
            delete position.snapshotM;
            delete position.snapshotG;
            delete liquidityPositionEpoch[user];
            _retireInactiveLiquidityEpochs();
            return;
        }

        // Roll BEFORE choosing the target epoch, then attach the snapshot to the current epoch.
        _rollLiquidityEpochIfNeeded();

        uint256 newEpochId = currentLiquidityEpoch;
        if (!hadActiveSnapshot) {
            liquidityEpochs[newEpochId].activeLpCount += 1;
        } else if (oldEpochId != newEpochId) {
            liquidityEpochs[oldEpochId].activeLpCount -= 1;
            liquidityEpochs[newEpochId].activeLpCount += 1;
        }

        position.snapshotG = liquidityEpochs[newEpochId].matrixRowG;
        position.snapshotM = liquidityEpochs[newEpochId].liquidityM;
        position.initialStableBalance = newInitialStableBalance;
        position.initialAssetBalance = newInitialAssetBalance;
        liquidityPositionEpoch[user] = newEpochId;

        _retireInactiveLiquidityEpochs();
    }

    /// @notice Crystallize the user's accrued funding fee into their position and migrate their LP
    /// snapshot to the current accounting epoch.
    function _settleFundingAndUpdateSnapshots(address user) internal {
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);

        (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);
        VirtualTraderPosition storage position = userVirtualTraderPosition[user];
        (position.fundingFee, position.fundingFeeSign) =
            UtilMath.signedSum(position.fundingFee, position.fundingFeeSign, localFundingFee, localFundingFeeSign);

        _updateSnapshots(user, lpStableBalance, lpAssetBalance);
    }

    /// @notice Force-refresh an LP snapshot into the current accounting epoch.
    function updateLpSnapshot(address user, bytes memory unverifiedReport) external {
        require(_hasActiveLiquiditySnapshot(liquidityPosition[user]), "LS0");
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        uint256 price = getPrice();

        // _updateFG stamps lastOperationTimestamp itself (idempotent within a block).
        _updateFG(price, lastOperationTimestamp);

        _settleFundingAndUpdateSnapshots(user);
    }

    ///@dev Computes the PnL for a user at a given oracle price.
    ///@param user target user.
    ///@param price Oracle price for the asset.
    function calcPnL(address user, uint256 price) public view returns (uint256, bool) {
        return _calcPnLInternal(user, price, false);
    }

    ///@dev Liquidation-only PnL. When the user is net-short by more than the pool can buy
    /// back (totalDebtAsset - totalBalanceAsset > globalLiquidityAsset), the position is
    /// valued at spot instead of on the curve, so an oversized short cannot make its own
    /// liquidation revert on insufficient pool liquidity. The close / realize / auto-close
    /// paths deliberately keep the curve valuation via calcPnL.
    function _calcPnLLiquidationSafe(address user, uint256 price) internal view returns (uint256, bool) {
        return _calcPnLInternal(user, price, true);
    }

    function _calcPnLInternal(
        address user,
        uint256 price,
        bool allowOversizedShortSpotFallback
    )
        private
        view
        returns (uint256, bool)
    {
        (uint256 stableLPBalance, uint256 assetLPBalance) = getLpLiquidityBalance(user);
        (uint256 newFundingRate, bool newFundingRateSign) = computeFundingRate(price, lastOperationTimestamp);
        (newFundingRate, newFundingRateSign) =
            UtilMath.signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);
        (uint256 localFundingFee, bool localFundingFeeSign) =
            _computeFundingFee(user, newFundingRate, newFundingRateSign);
        VirtualTraderPosition storage traderPosition = userVirtualTraderPosition[user];
        (localFundingFee, localFundingFeeSign) = UtilMath.signedSum(
            traderPosition.fundingFee, traderPosition.fundingFeeSign, localFundingFee, localFundingFeeSign
        );

        uint256 totalBalanceAsset = traderPosition.balanceAsset + assetLPBalance;
        uint256 totalDebtAsset = traderPosition.debtAsset + liquidityPosition[user].debtAsset;
        bool useSpotPrice = allowOversizedShortSpotFallback && totalDebtAsset > totalBalanceAsset
            && totalDebtAsset - totalBalanceAsset > globalLiquidityAsset;

        return UtilMath._calcPnL(
            traderPosition.balanceStable + stableLPBalance,
            traderPosition.balanceAsset + assetLPBalance,
            traderPosition.debtStable + liquidityPosition[user].debtStable,
            traderPosition.debtAsset + liquidityPosition[user].debtAsset,
            localFundingFee,
            localFundingFeeSign,
            price,
            oracleDecimals,
            address(this),
            useSpotPrice
        );
    }

    ///@dev Single-call margin data for the Vault's collateral-removal check: the margin ratio plus
    ///     the raw position/LP fields and maxLpLeverage/MMR its bad-debt override needs. Returns the
    ///     same values Vault._checkMR used to read one by one; the override stays in the Vault.
    ///@param user Target user.
    ///@param price Oracle price for the asset.
    ///@param collateral Hypothetical collateral covering the position after removal.
    function marginCheckData(
        address user,
        uint256 price,
        uint256 collateral
    )
        external
        view
        returns (
            uint256 marginRatio,
            uint256 balanceStable,
            uint256 balanceAsset,
            uint256 debtStable,
            uint256 debtAsset,
            uint256 lpDebtStable,
            uint256 lpDebtAsset,
            uint256 lpBalanceStable,
            uint256 lpBalanceAsset,
            uint256 maxLpLev,
            uint256 mmr
        )
    {
        marginRatio = UtilMath.calcMR(user, price, address(this), collateral, lastOperationTimestamp);
        VirtualTraderPosition storage vp = userVirtualTraderPosition[user];
        balanceStable = vp.balanceStable;
        balanceAsset = vp.balanceAsset;
        debtStable = vp.debtStable;
        debtAsset = vp.debtAsset;
        LiquidityPosition storage lp = liquidityPosition[user];
        lpDebtStable = lp.debtStable;
        lpDebtAsset = lp.debtAsset;
        (lpBalanceStable, lpBalanceAsset) = getLpLiquidityBalance(user);
        maxLpLev = maxLpLeverage;
        mmr = MMR;
    }

    ///@dev Moves the PnL of the user to the user's Collateral.
    function realizePnL(bytes memory unverifiedReport) external nonReentrant returns (uint256, bool) {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        address user = _msgSender();
        uint256 price = getPrice();
        // _updateFG stamps lastOperationTimestamp itself (idempotent within a block).
        _updateFG(price, lastOperationTimestamp);

        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];
        (uint256 pnl, bool pnlSign) = calcPnL(user, price);
        require(pnlSign || pnl < getCollateral(user), "R1");
        _settleFundingAndUpdateSnapshots(user);

        if (!pnlSign) {
            if (pnl < pos.debtStable) {
                pos.debtStable -= pnl;
            } else {
                pos.balanceStable += (pnl - pos.debtStable);
                pos.debtStable = 0;
            }
        } else {
            if (pnl < pos.balanceStable) {
                pos.balanceStable -= pnl;
            } else {
                pos.debtStable += (pnl - pos.balanceStable);
                pos.balanceStable = 0;
            }
        }
        IVault(vault).addPnlToCollateral(user, pnl, pnlSign);
        emit RealizedPnL(user, pnl, pnlSign);
        return (pnl, pnlSign);
    }
}
