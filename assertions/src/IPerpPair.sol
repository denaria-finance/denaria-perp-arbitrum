// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IPerpPair {

    function addLiquidity(
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    ) external;
    function calcPnL(address user, uint256 price) external view returns (uint256, bool);
    function closeAndWithdraw(
        uint256 maxSlippage,
        uint256 maxLiqFee,
        address frontendAddress,
        bytes memory unverifiedReport
    ) external;
    function enableAutoClose(uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) external;
    function getCollateral(address user) external view returns (uint256);
    function getPrice() external view returns (uint256);
    function liquidate(address user, uint256 liquidatedPositionSize, bytes memory unverifiedReport) external;
    function trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes memory unverifiedReport
    ) external returns (uint256);
    function realizePnL(bytes calldata unverifiedReport) external;
    function removeLiquidity(
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    ) external;
}
