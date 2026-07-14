// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../interfaces/IPerpPair.sol";
import "../interfaces/IVault.sol";
import "../util/UtilMath.sol";

/// @dev Correct 16-field binding of `ReadParameters()` (PerpStorage / Stylus engine).
/// `IPerpPair.ReadParameters` is stale and returns the old 6-field tuple. The batcher
/// reads only index [0] (vault) to resolve the Vault for collateral reads.
interface IPerpPairBatcherParameters {
    function ReadParameters()
        external
        view
        returns (
            address vault_,
            address oracle_,
            uint256 minimumTradeSize_,
            uint256 minimumLiquidityMovement_,
            uint256 feeFrontend_,
            uint256 feeLP_,
            uint256 insuranceFundCap_,
            bytes32 tickerAssetCurrency_,
            uint256 insuranceFund_,
            bool insuranceFundSign_,
            uint256 shortCurveParameterA_,
            uint256 shortCurveParameterB_,
            uint256 longCurveParameterA_,
            uint256 longCurveParameterB_,
            uint256 totalTraderExposure_,
            bool totalTraderExposureSign_
        );
}

contract CallBatcher {
    constructor() { }

    /*//////////////////////////////////////////////////////////////
                             calcMR batching
    //////////////////////////////////////////////////////////////*/

    function batchCalcMR(
        address[] calldata users,
        uint256 price,
        address perpPairAddress
    )
        external
        view
        returns (uint256[] memory mr)
    {
        IPerpPair perpInterface = IPerpPair(perpPairAddress);
        uint256 lastOperationTimestamp = perpInterface.lastOperationTimestamp();
        address vault = _vaultFor(perpPairAddress);
        uint256 len = users.length;
        mr = new uint256[](len);
        uint256 collateral;
        for (uint256 i = 0; i < len;) {
            collateral = IVault(vault).userCollateral(users[i]);
            mr[i] = UtilMath.calcMR(users[i], price, perpPairAddress, collateral, lastOperationTimestamp);
            unchecked {
                ++i;
            }
        }
    }

    struct VirtualTraderPosition {
        uint256 balanceStable;
        uint256 balanceAsset;
        uint256 debtStable;
        uint256 debtAsset;
        uint256 fundingFee;
        bool fundingFeeSign;
        uint256 initialFundingRate;
        bool initialFundingRateSign;
    }

    function batchUserVirtualTraderPosition(
        address[] calldata users,
        address perpPairAddress
    )
        external
        view
        returns (VirtualTraderPosition[] memory positions)
    {
        IPerpPair perpInterface = IPerpPair(perpPairAddress);
        uint256 len = users.length;
        positions = new VirtualTraderPosition[](len);

        for (uint256 i = 0; i < len;) {
            (
                uint256 balanceStable,
                uint256 balanceAsset,
                uint256 debtStable,
                uint256 debtAsset,
                uint256 fundingFee,
                bool fundingFeeSign,
                uint256 initialFundingRate,
                bool initialFundingRateSign
            ) = perpInterface.userVirtualTraderPosition(users[i]);

            positions[i] = VirtualTraderPosition({
                balanceStable: balanceStable,
                balanceAsset: balanceAsset,
                debtStable: debtStable,
                debtAsset: debtAsset,
                fundingFee: fundingFee,
                fundingFeeSign: fundingFeeSign,
                initialFundingRate: initialFundingRate,
                initialFundingRateSign: initialFundingRateSign
            });

            unchecked {
                ++i;
            }
        }
    }

    struct LiquidityPosition {
        uint256 initialStableShares;
        uint256 initialAssetShares;
        uint256 debtStable;
        uint256 debtAsset;
        uint256 balanceStable;
        uint256 balanceAsset;
    }

    function batchCollateral(
        address[] calldata users,
        uint256,
        address perpPairAddress
    )
        external
        view
        returns (uint256[] memory collaterals)
    {
        uint256 len = users.length;
        collaterals = new uint256[](len);
        if (len == 0) return collaterals;
        address vault = _vaultFor(perpPairAddress);
        for (uint256 i = 0; i < len;) {
            collaterals[i] = IVault(vault).userCollateral(users[i]);
            unchecked {
                ++i;
            }
        }
    }

    function batchLiquidityPosition(
        address[] calldata users,
        address perpPairAddress
    )
        external
        view
        returns (LiquidityPosition[] memory positions)
    {
        IPerpPair perpInterface = IPerpPair(perpPairAddress);
        uint256 len = users.length;
        positions = new LiquidityPosition[](len);

        for (uint256 i = 0; i < len;) {
            (uint256 initialStableShares, uint256 initialAssetShares, uint256 debtStable, uint256 debtAsset) =
                perpInterface.liquidityPosition(users[i]);

            (uint256 balanceStable, uint256 balanceAsset) = perpInterface.getLpLiquidityBalance(users[i]);

            positions[i] = LiquidityPosition({
                initialStableShares: initialStableShares,
                initialAssetShares: initialAssetShares,
                debtStable: debtStable,
                debtAsset: debtAsset,
                balanceStable: balanceStable,
                balanceAsset: balanceAsset
            });

            unchecked {
                ++i;
            }
        }
    }

    struct AutoCloseData {
        bool authorized;
        uint256 profitTh;
        uint256 lossTh;
        uint256 maxSlippage;
        uint256 maxLiqFee;
    }

    /// @notice Read the auto-close config of many users in one call, so a keeper can pick the
    ///         positions whose thresholds are met before submitting auto-closes.
    function batchAutoCloseData(
        address[] calldata users,
        address perpPairAddress
    )
        external
        view
        returns (AutoCloseData[] memory autoCloseData)
    {
        IPerpPair perpInterface = IPerpPair(perpPairAddress);
        uint256 len = users.length;
        autoCloseData = new AutoCloseData[](len);

        for (uint256 i = 0; i < len;) {
            (bool authorized, uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) =
                perpInterface.autoCloseUsersData(users[i]);

            autoCloseData[i] = AutoCloseData({
                authorized: authorized,
                profitTh: profitTh,
                lossTh: lossTh,
                maxSlippage: maxSlippage,
                maxLiqFee: maxLiqFee
            });

            unchecked {
                ++i;
            }
        }
    }

    function _vaultFor(address perpPairAddress) private view returns (address vault) {
        (vault,,,,,,,,,,,,,,,) = IPerpPairBatcherParameters(perpPairAddress).ReadParameters();
    }
}
