// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { CurveMath } from "../util/CurveMath.sol";

contract CurveMathSolidityHarness {
    function computeLongReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeLongReturn(
            size,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
    }

    function computeShortReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeShortReturn(
            size,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );
    }

    function computeExactAmountInLong(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeExactAmountInLong(
            outputSize,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
    }

    function computeExactAmountInShort(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeExactAmountInShort(
            outputSize,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );
    }
}
