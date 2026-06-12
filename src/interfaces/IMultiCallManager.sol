// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

library PerpMultiCalls {
    struct TradeData {
        uint256 tradeSize;
        bool direction;
        uint256 minTradeReturn;
        uint256 initialGuess;
        address frontendAddress;
        uint8 leverage;
    }
}

interface IMultiCallManager {
    error AccessControlBadConfirmation();
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureLength(uint256 length);
    error ECDSAInvalidSignatureS(bytes32 s);
    error InvalidInitialization();
    error InvalidShortString();
    error NotInitializing();
    error ReentrancyGuardReentrantCall();
    error StringTooLong(string str);

    event EIP712DomainChanged();
    event Initialized(uint64 version);
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH() external view returns (bytes32);
    function ADD_COLLATERAL_OPEN_TRADE_TYPEHASH() external view returns (bytes32);
    function CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MODIFY_POSITION_TYPEHASH() external view returns (bytes32);
    function MOD_ROLE() external view returns (bytes32);
    function addCollateralAddLiquidity(
        uint256[] memory collateral,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport,
        uint256[] memory deadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s
    )
        external;
    function addCollateralOpenTrade(
        uint256[] memory collateral,
        uint256 tradeSize,
        bool direction,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes memory unverifiedReport,
        uint256[] memory deadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s
    )
        external;
    function closeAndRemoveAllCollateral(
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        external;
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    function getNonce(address user) external view returns (uint256);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hashTypedData(bytes32 structHash) external view returns (bytes32);
    function initializeAddresses(address _perpPair, address _vault) external;
    function modifyLiquidityPosition(
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        external;
    function nonces(address) external view returns (uint256);
    function perpPair() external view returns (address);
    function relayerAddCollateralAddLiquidity(
        address from,
        uint256[] memory collateral,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport,
        uint256[] memory permitDeadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s,
        uint256 deadline,
        uint256 nonce,
        bytes memory sig
    )
        external;
    function relayerAddCollateralOpenTrade(
        address from,
        uint256[] memory collateral,
        PerpMultiCalls.TradeData memory tradeData,
        bytes memory unverifiedReport,
        uint256[] memory permitDeadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s,
        uint256 deadline,
        uint256 nonce,
        bytes memory sig
    )
        external;
    function relayerCloseAndRemoveAllCollateral(
        address from,
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes memory sig
    )
        external;
    function relayerModifyLiquidityPosition(
        address from,
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes memory sig
    )
        external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function revokeRole(bytes32 role, address account) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function vault() external view returns (address);
}
