// SPDX-License-Identifier: MIT-OR-APACHE-2.0
pragma solidity ^0.8.23;

interface ICurveMathAdapter {
    function computeLongReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParamA,
        uint256 longCurveParamB,
        uint256 curveParameterDecimals
    )
        external
        view
        returns (uint256);

    function computeShortReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParamA,
        uint256 shortCurveParamB,
        uint256 curveParameterDecimals
    )
        external
        view
        returns (uint256);

    function computeExactAmountInLong(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParamA,
        uint256 longCurveParamB,
        uint256 curveParameterDecimals
    )
        external
        view
        returns (uint256);

    function computeExactAmountInShort(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParamA,
        uint256 shortCurveParamB,
        uint256 curveParameterDecimals
    )
        external
        view
        returns (uint256);
}
