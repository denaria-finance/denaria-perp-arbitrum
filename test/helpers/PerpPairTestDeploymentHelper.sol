// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPair } from "../../src/PerpPair.sol";
import { UtilMath } from "../../src/util/UtilMath.sol";
import { Vm } from "forge-std/Vm.sol";

abstract contract PerpPairTestDeploymentHelper {
    Vm private constant FIXTURE_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Restores the pre-mainnet-parameters ("test-era") protocol parameters the legacy
    ///      suites were calibrated against. The deploy-prep commits hardcoded mainnet values
    ///      into PerpStorage; the four restored here are the drifted ones that have setters:
    ///        insuranceFundCap 500e18 -> 1e8, maxLpLeverage 15 -> 10,
    ///        fundingC 10e5 -> 1e4, minimumTradeSize 48e18 -> 1e18.
    ///      Parameters without setters (curve A/B, autoCloseFee, minimumLiquidityMovement)
    ///      keep their live values and the tests derive their expectations from them instead.
    ///      The deploying test contract holds MOD_ROLE (granted in the PerpPair constructor),
    ///      so both setters are callable directly; the 10s paramTimeLock is crossed with warp.
    function _restoreTestEraParameters(
        PerpPair pair,
        address oracle_,
        uint32 feeFrontend_,
        address feeProtocolAddr_,
        uint256 mmr_,
        uint256 tradingFee_,
        uint256 flatTradingFee_,
        uint32 feeLP_
    )
        internal
    {
        // Not timelocked: restore insuranceFundCap and maxLpLeverage; everything else this
        // setter touches keeps its live value (liquidationDiscount stays 7500 on purpose —
        // tests read it from ReadFees()).
        pair.setUnguardedParameters(
            oracle_,
            feeFrontend_,
            feeProtocolAddr_,
            1e8, // insuranceFundCap: test-era value
            15, // maxLeverage: live value
            7500, // liquidationDiscount: live value
            10, // maxLpLeverage: test-era value
            10 // slipLiquidationTh: live value
        );
        // Timelocked: restore fundingC and minimumTradeSize; pass the suite's constructor
        // values and the live PerpStorage values through for the rest.
        UtilMath.ClampParameters memory clamp = UtilMath.ClampParameters(0, 1e18, 0);
        pair.prepareTimeLockedParameters(
            mmr_,
            tradingFee_,
            flatTradingFee_,
            feeLP_,
            0, // liquidityMinFee: live value
            5 * 1e10 / 100, // liquidityMaxFee: live value
            1e10, // liquidityFeeK: live value
            1e4, // fundingC: test-era value
            clamp,
            10, // paramTimeLock: live value
            1e18 // minimumTradeSize: test-era value
        );
        FIXTURE_VM.warp(block.timestamp + 10);
        pair.setTimeLockedParameters(
            mmr_, tradingFee_, flatTradingFee_, feeLP_, 0, 5 * 1e10 / 100, 1e10, 1e4, clamp, 10, 1e18
        );
    }

    function _deployPerpPairForTest(
        address oracle_,
        address vault_,
        address multiCallManager_,
        uint256 mmr_,
        bytes32 tickerAssetCurrency_,
        uint32 feeFrontend_,
        uint32 feeLP_,
        address feeProtocolAddr_,
        uint256 tradingFee_,
        uint256 flatTradingFee_,
        uint256 emaParam_
    )
        internal
        virtual
        returns (PerpPair)
    {
        return new PerpPair(
            oracle_,
            vault_,
            multiCallManager_,
            mmr_,
            tickerAssetCurrency_,
            feeFrontend_,
            feeLP_,
            feeProtocolAddr_,
            tradingFee_,
            flatTradingFee_,
            emaParam_
        );
    }
}
