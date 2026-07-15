// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../util/UtilMath.sol";
import "../util/CurveMath.sol";
import "../interfaces/ICurveMathAdapter.sol";

/// @title PerpStorage
/// @notice Defines shared storage used across PerpPair modules like trading, liquidity, and funding
abstract contract PerpStorage {
    // --- Addresses & Flags (packed into slot 0) ---
    /// @dev Address of the vault contract
    address internal vault;
    /// @dev Sign of the insurance fund, if negative means there is too much bad debt and the protocol is losing money.
    bool internal insuranceFundSign = true;
    /// @dev Sign of the cumulative funding rate.
    bool public fundingRateSign;
    /// @dev Sign of the total trader exposure.
    bool public totalTraderExposureSign;
    /// @dev Address of the oracle contract
    address public oracle;
    /// @dev Address that collects protocol fees
    address internal feeProtocolAddr;
    /// @dev Maximum leverage allowed, only tied to what comes from the frontend in openTrade
    uint8 internal maxLeverage = 15;
    /// @dev Maximum leverage allowed for LPs
    uint8 public maxLpLeverage = 15;
    /// @dev Fraction of the liquidation discount to put inside the insurance fund.
    uint8 internal insFundFraction = 6;
    /// @dev
    uint8 internal slipLiquidationTh = 10;

    /// @dev Q80 fixed-point scale for the liquidity matrix M (2^80), replacing the old decimal 1e22.
    /// The adjugate snapshot recovery keys its fast path off `liquidityMDecimals <= 2^80`.
    int256 internal constant LIQUIDITY_M_Q80 = int256(1) << 80;

    /// @dev Roll a fresh LP accounting epoch once the current epoch's matrix determinant decays to
    /// `liquidityMDecimals / LIQUIDITY_EPOCH_DET_DENOMINATOR` (~1e-12 of full scale), so LP snapshots
    /// always recover against a well-conditioned matrix instead of an ill-conditioned global one.
    uint256 internal constant LIQUIDITY_EPOCH_DET_DENOMINATOR = 1e12;
    /// @dev Cap on the number of simultaneously-active LP accounting epochs.
    uint256 internal constant MAX_ACTIVE_LIQUIDITY_EPOCHS = 8;

    /// @dev This structs contains decimals for many quantities that require decimal representation. It is initialized in the constructor.
    /**
     * The used values are:
     * MMRDecimals = 1e6
     * liquidationDecimals = 1e6
     * feeFractionsDecimals = 1e6
     * liquidityFeeDecimals = 1e10
     * fundingRateDecimals = 1e18
     * fundingCDecimals = 1e5
     * liquidityMDecimals = 2^80
     */

    struct Decimals {
        uint256 MMRDecimals;
        uint256 liquidationDecimals;
        uint256 feeFractionsDecimals;
        uint256 liquidityFeeDecimals;
        uint256 fundingRateDecimals;
        uint256 fundingCDecimals;
        int256 liquidityMDecimals;
        uint256 tradingFeeDecimals;
        uint256 liquidityGDecimals;
    }

    ///@dev decimals used for the oracle price
    uint256 internal oracleDecimals = 1e8;

    // --- Margin Settings ---
    /// @dev Value for the maitanance margin ratio for the pool.
    uint256 public MMR = (40 * 1e6) / 1000;

    // --- Liquidation stuff ---
    /// @dev Discount applied to the purchase of the liquidated position during half liquidation. For full liquidation it's doubled. Comes with 6 decimals.
    uint256 internal liquidationDiscount = 7500;

    // --- Trading & Liquidity Minimums ---
    /// @dev Minimum allowed trade size.
    uint256 internal minimumTradeSize = 48 * 1e18;
    /// @dev Minimum allowed liquidity deposit.
    uint256 internal minimumLiquidityMovement = 1e18 / 100;

    // --- Trading Fees ---
    /// @dev Fee applied to trades. 1 is 100% fee, 0.01 is 1% fee. Has 18 decimals.
    uint256 internal tradingFee;
    /// @dev Flat portion of the fee to be applied to each trade.
    uint256 internal flatTradingFee = 12e16;
    /// @dev Fee fraction due to the frontend.
    uint256 internal feeFrontend = (30 * 1e6) / 100;
    /// @dev Fee fraction due to the LPs.
    uint256 internal feeLP = (50 * 1e6) / 100;
    /// @dev AutoClosing position fee, flat fee
    uint256 internal autoCloseFee = 2e17;

    // --- Insurance Fund ---
    /// @dev Insurance fund, stores a part of the fees instead of the protocol to cover bad debts.
    uint256 internal insuranceFund;
    /// @dev Insurance fund cap, if the insurance fund is full all protocol fees go to protocol.
    uint256 internal insuranceFundCap = 500 * 1e18;

    // --- Liquidity Pool ---
    /// @dev Total stable liquidity in the pool.
    uint256 public globalLiquidityStable;
    /// @dev Total asset liquidity in the pool.
    uint256 public globalLiquidityAsset;

    // --- Liquidity Fee Settings ---
    /// @dev Minimum fee paid for depositing liquidity, has 10 decimals.
    uint256 internal liquidityMinFee = 0;
    /// @dev Maximum fee paid for depositing liquidity, has 10 decimals.
    uint256 internal liquidityMaxFee = 5 * 1e10 / 100;
    /// @dev Parameter K used in the computation of the liquidity fee.
    uint256 internal liquidityFeeK = 1e10;

    // --- Liquidity Matrix (M) — per accounting epoch ---
    /// @dev Per-epoch LP accounting bases. Each epoch carries its own liquidity matrix M (tracking
    /// the liquidity changes trades cause), funding accumulator row G, and a refcount of the LP
    /// snapshots still pinned to it. Trades and funding updates touch every active epoch; an LP only
    /// ever recovers against the epoch its snapshot was taken in.
    struct LiquidityEpoch {
        int256[2][2] liquidityM;
        int256[2] matrixRowG;
        uint256 activeLpCount;
    }

    /// @dev Epoch new LP snapshots attach to.
    uint256 internal currentLiquidityEpoch;
    /// @dev Lowest epoch that may still need trade/funding updates.
    uint256 internal oldestActiveLiquidityEpoch;

    // --- Funding Rate ---
    /// @dev Parameter used in the computation of the funding rate. 5 decimals.
    uint256 internal fundingC = 10 * 1e5;
    /// @dev Reference time interval for the computation of the funding rate.
    uint256 internal fundingInterval = 3600 * 24;
    /// @dev Timestamp of the last operation that updated the funding rate.
    uint256 public lastOperationTimestamp;
    /// @dev Cumulative funding rate, not really meaningful by itself. 18 decimals.
    uint256 public fundingRate;

    // --- Trader Exposure ---
    /// @dev Total exposure of all traders. Used to compute the funding rate too.
    uint256 public totalTraderExposure;

    // --- Curve Parameters ---
    /// @dev Parameters used for the curve equations. The last four are used to ensure that splitting a trade into multiple smaller ones does not bring an advantage.
    struct CurveParameters {
        uint256 shortCurveParameterA;
        uint256 shortCurveParameterB;
        uint256 longCurveParameterA;
        uint256 longCurveParameterB;
        uint256 lastCurveUpdate;
        uint256 curveUpdateInterval;
        bool lastTradeDirection;
        uint256 lastValidatedPrice;
    }

    /// @dev Variation in total asset liquidity since the laste curve update, used to ensure that splitting a trade into multiple smaller ones does not bring an advantage.
    uint256 internal dx0;
    /// @dev Variation in total stable liquidity since the laste curve update, used to ensure that splitting a trade into multiple smaller ones does not bring an advantage.
    uint256 internal dy0;

    /// @dev average slippage long computed with Exponential Moving Average. Computation on utilMath.
    uint256 internal avgSlippageL;
    /// @dev average slippage short computed with Exponential Moving Average. Computation on utilMath.
    uint256 internal avgSlippageS;
    /// @dev param of the EMA
    uint256 internal emaParam = oracleDecimals * 9 / 10;

    // --- Roles ---
    /// @dev Role for mods, that can update parameters.
    bytes32 internal MOD_ROLE = keccak256("MOD_ROLE");

    // --- Miscellaneous ---
    /// @dev Hash of the parameters to set after time has elapsed
    bytes32 internal paramHash;
    /// @dev timeStamp after which the parameters will be able to be set
    uint256 internal paramLockedUntil;
    /// @dev parameter time lock duration
    uint256 internal paramTimeLock = 10;
    /// @dev Ticker of the asset relative to this pool.
    bytes32 internal tickerAssetCurrency;

    /// @dev Structure that holds decimals for various quantities.
    Decimals internal decimals;
    /// @dev Structure that holds the parameters used in the curve equations.
    CurveParameters public curveParameters;

    /// @dev Optional external CurveMath adapter. If unset, the contract uses the in-Solidity CurveMath library.
    address public curveMathAdapter;

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

    function _computeLongReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 _oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable_,
        uint256 globalLiquidityAsset_,
        uint256 longCurveParamA,
        uint256 longCurveParamB,
        uint256 curveParameterDecimals
    )
        internal
        view
        returns (uint256)
    {
        address adapter = curveMathAdapter;
        if (adapter == address(0)) {
            return CurveMath.computeLongReturn(
                size,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                longCurveParamA,
                longCurveParamB,
                curveParameterDecimals
            );
        }

        return ICurveMathAdapter(adapter)
            .computeLongReturn(
                size,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                longCurveParamA,
                longCurveParamB,
                curveParameterDecimals
            );
    }

    function _computeShortReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 _oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable_,
        uint256 globalLiquidityAsset_,
        uint256 shortCurveParamA,
        uint256 shortCurveParamB,
        uint256 curveParameterDecimals
    )
        internal
        view
        returns (uint256)
    {
        address adapter = curveMathAdapter;
        if (adapter == address(0)) {
            return CurveMath.computeShortReturn(
                size,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                shortCurveParamA,
                shortCurveParamB,
                curveParameterDecimals
            );
        }

        return ICurveMathAdapter(adapter)
            .computeShortReturn(
                size,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                shortCurveParamA,
                shortCurveParamB,
                curveParameterDecimals
            );
    }

    function _computeExactAmountInLong(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 _oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable_,
        uint256 globalLiquidityAsset_,
        uint256 longCurveParamA,
        uint256 longCurveParamB,
        uint256 curveParameterDecimals
    )
        internal
        view
        returns (uint256)
    {
        address adapter = curveMathAdapter;
        if (adapter == address(0)) {
            return CurveMath.computeExactAmountInLong(
                outputSize,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                longCurveParamA,
                longCurveParamB,
                curveParameterDecimals
            );
        }

        return ICurveMathAdapter(adapter)
            .computeExactAmountInLong(
                outputSize,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                longCurveParamA,
                longCurveParamB,
                curveParameterDecimals
            );
    }

    function _computeExactAmountInShort(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 _oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable_,
        uint256 globalLiquidityAsset_,
        uint256 shortCurveParamA,
        uint256 shortCurveParamB,
        uint256 curveParameterDecimals
    )
        internal
        view
        returns (uint256)
    {
        address adapter = curveMathAdapter;
        if (adapter == address(0)) {
            return CurveMath.computeExactAmountInShort(
                outputSize,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                shortCurveParamA,
                shortCurveParamB,
                curveParameterDecimals
            );
        }

        return ICurveMathAdapter(adapter)
            .computeExactAmountInShort(
                outputSize,
                spotPrice,
                _oracleDecimals,
                initialGuess,
                globalLiquidityStable_,
                globalLiquidityAsset_,
                shortCurveParamA,
                shortCurveParamB,
                curveParameterDecimals
            );
    }

    struct LiquidityPosition {
        uint256 initialStableBalance;
        uint256 initialAssetBalance;
        uint256 debtStable;
        uint256 debtAsset;
        int256[2][2] snapshotM;
        int256[2] snapshotG;
    }

    struct AutoCloseData {
        bool authorized;
        uint256 profitTh;
        uint256 lossTh;
        uint256 maxSlippage;
        uint256 maxLiqFee;
    }

    /// @dev Mapping of the user virtual positions.
    mapping(address => VirtualTraderPosition) public userVirtualTraderPosition;
    /// @dev Mapping of the liquidity positions of LPs.
    mapping(address => LiquidityPosition) public liquidityPosition;
    /// @dev LP accounting epoch associated with each user's current liquidity snapshot.
    mapping(address => uint256) internal liquidityPositionEpoch;
    /// @dev Epoch-local LP accounting bases (liquidity matrix M, funding row G, active-LP refcount).
    mapping(uint256 => LiquidityEpoch) internal liquidityEpochs;
    /// @dev Mapping of users who opted into automatic closure, also contains thresholds for the closure.
    mapping(address => AutoCloseData) public autoCloseUsersData;

    /// @notice Returns vault, oracle, fee/limit parameters, the insurance fund, the
    /// trade-curve coefficients and net trader exposure in one call. The trailing eight
    /// fields fold in the former ReadInsuranceFund / curve-A/B / totalTraderExposure reads.
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
        )
    {
        return (
            vault,
            oracle,
            minimumTradeSize,
            minimumLiquidityMovement,
            feeFrontend,
            feeLP,
            insuranceFundCap,
            tickerAssetCurrency,
            insuranceFund,
            insuranceFundSign,
            curveParameters.shortCurveParameterA,
            curveParameters.shortCurveParameterB,
            curveParameters.longCurveParameterA,
            curveParameters.longCurveParameterB,
            totalTraderExposure,
            totalTraderExposureSign
        );
    }

    /// @notice Returns funding-related parameters.
    function ReadFundingParameters() external view returns (uint256 fundingC_, uint256 fundingInterval_) {
        return (fundingC, fundingInterval);
    }

    function ReadInsuranceFund() external view returns (uint256 insFund_, bool insFundSign_) {
        return (insuranceFund, insuranceFundSign);
    }

    /// @notice Returns fee parameters plus the funding parameters, rate and sign. The
    /// trailing four fields fold in the former ReadFundingParameters / fundingRate /
    /// fundingRateSign reads.
    function ReadFees()
        external
        view
        returns (
            uint256 tradingFee_,
            uint256 flatTradingFee_,
            uint256 autoCloseFee_,
            uint256 liquidityMinFee_,
            uint256 liquidityMaxFee_,
            uint256 liquidityFeeK_,
            uint256 liquidationDiscount_,
            uint256 fundingC_,
            uint256 fundingInterval_,
            uint256 fundingRate_,
            bool fundingRateSign_
        )
    {
        return (
            tradingFee,
            flatTradingFee,
            autoCloseFee,
            liquidityMinFee,
            liquidityMaxFee,
            liquidityFeeK,
            liquidationDiscount,
            fundingC,
            fundingInterval,
            fundingRate,
            fundingRateSign
        );
    }
}
