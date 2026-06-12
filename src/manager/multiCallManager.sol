// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../interfaces/IVault.sol";
import "../interfaces/IPerpPair.sol";
import "../util/UtilMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title A contract to provide bundled calls, so that these operations can be done atomically from the frontend.
 *     @notice All the functions are implemented in two ways: one that allows for direct call from an EOA, the other that allows the use of a relayer for gas sponsoring
 */
contract PerpMultiCalls is Initializable, EIP712, AccessControl, ReentrancyGuardTransient {
    using Math for uint256;
    using SignedMath for int256;
    using ECDSA for bytes32;

    ///@dev Address of the perpPair contract.
    address public perpPair;

    ///@dev Address of the vault contract.
    address public vault;

    ///@dev State of the contract. True after the addresses of perpPair and vault have been initialized.
    bool private initialized;

    ///@dev EIP712 typehashes for the relayer function calls, exposed to public so that they can be read from the caller.
    bytes32 public immutable MODIFY_POSITION_TYPEHASH = keccak256(
        "relayerModifyLiquidityPosition(address from,uint256 newStable,uint256 newAsset,uint256 maxFeeValue,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable ADD_COLLATERAL_OPEN_TRADE_TYPEHASH = keccak256(
        "relayerAddCollateralOpenTrade(address from,uint256[] collateral,uint256 tradeSize,bool direction,uint256 minTradeReturn,uint256 initialGuess,address frontendAddress,uint8 leverage,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH = keccak256(
        "relayerAddCollateralAddLiquidity(address from,uint256[] collateral,uint256 liquidityStable,uint256 liquidityAsset,uint256 maxFeeValue,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH = keccak256(
        "relayerCloseAndRemoveAllCollateral(address from,uint256 maxSlippage,uint256 maxLiquidityFee,address frontendAddress,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable TAKE_PROFIT_REMOVE_COLLATERAL_TYPEHASH = keccak256(
        "relayerTakeProfitRemoveCollateral(address from,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );

    struct TradeData {
        uint256 tradeSize;
        bool direction;
        uint256 minTradeReturn;
        uint256 initialGuess;
        address frontendAddress;
        uint8 leverage;
    }

    /// @dev Role for mods, that can update parameters.
    bytes32 public constant MOD_ROLE = keccak256("MOD_ROLE");

    /// @dev nonces of users to prevent replay attacks
    mapping(address => uint256) public nonces;

    constructor() EIP712("PerpMultiCalls", "1") {
        _grantRole(MOD_ROLE, _msgSender());
    }

    ///@dev Exposes the nonces for the users.
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    ///@dev This multicall bundles the operations of closeAndWithdraw and removeCollateral.
    ///@param maxSlippage Maximum slippage allowed for the trads required in closeAndWithdraw by the user.
    ///@param maxLiquidityFee Maximum liquidity fee allowed for the liquidity removal in closeAndWithdraw by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation.
    ///@param unverifiedReport Chainlink price report.
    function closeAndRemoveAllCollateral(
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        external
    {
        bytes memory dataForCall;
        dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).closeAndWithdraw.selector,
            maxSlippage,
            maxLiquidityFee,
            frontendAddress,
            unverifiedReport
        );
        _callContract(perpPair, dataForCall, _msgSender());

        dataForCall = abi.encodeWithSelector(IVault(vault).removeAllCollateral.selector, unverifiedReport);
        _callContract(vault, dataForCall, _msgSender());
    }

    ///@dev This multicall bundles the operations of closeAndWithdraw and removeCollateral and is called through a relayer.
    ///@param from Original caller's address.
    ///@param maxSlippage Maximum slippage allowed for the trads required in closeAndWithdraw by the user.
    ///@param maxLiquidityFee Maximum liquidity fee allowed for the liquidity removal in closeAndWithdraw by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation.
    ///@param unverifiedReport Chainlink price report.
    ///@param deadline Deadline of the EIP712 signature.
    ///@param nonce nonce for the EIP712 signature.
    ///@param sig EIP712 signature.
    function relayerCloseAndRemoveAllCollateral(
        address from,
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes calldata sig
    )
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH,
                from,
                maxSlippage,
                maxLiquidityFee,
                frontendAddress,
                keccak256(unverifiedReport),
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;

        bytes memory dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).closeAndWithdraw.selector,
            maxSlippage,
            maxLiquidityFee,
            frontendAddress,
            unverifiedReport
        );
        _callContract(perpPair, dataForCall, from);
        dataForCall = abi.encodeWithSelector(IVault(vault).removeAllCollateral.selector, unverifiedReport);
        _callContract(vault, dataForCall, from);
    }

    ///@dev This multicall bundles the operations of addCollateral and addLiquidity.
    ///@param collateral Amount of collateral the user is depositing
    ///@param liquidityStable Amount of stable liquidity the user wants to deposit in the pool
    ///@param liquidityAsset Amount of asset liquidity the user wants to deposit in the pool
    ///@param unverifiedReport Chainlink report of the current price
    ///@param deadline Deadline of the signature for the stablecoin permit
    ///@param v Part of the permit signature
    ///@param r Part of the permit signature
    ///@param s Part of the permit signature
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
        external
    {
        address stablecoinAddress;
        for (uint256 i; i < collateral.length; i++) {
            (stablecoinAddress,,,) = IVault(vault).stableCoins(i);
            IERC20Permit(stablecoinAddress).permit(_msgSender(), vault, collateral[i], deadline[i], v[i], r[i], s[i]);
        }
        bytes memory dataForCall;
        dataForCall = abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral);
        _callContract(vault, dataForCall, _msgSender());

        dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).addLiquidity.selector, liquidityStable, liquidityAsset, maxFeeValue, unverifiedReport
        );
        _callContract(perpPair, dataForCall, _msgSender());
    }

    ///@dev This multicall bundles the operations of addCollateral and addLiquidity.
    ///@param from Original caller's address.
    ///@param collateral Amount of collateral the user is depositing
    ///@param liquidityStable Amount of stable liquidity the user wants to deposit in the pool
    ///@param liquidityAsset Amount of asset liquidity the user wants to deposit in the pool
    ///@param unverifiedReport Chainlink report of the current price
    ///@param permitDeadline Deadline of the signature for the stablecoin permit
    ///@param v Part of the permit signature
    ///@param r Part of the permit signature
    ///@param s Part of the permit signature
    ///@param deadline Deadline of the EIP712 signature.
    ///@param nonce nonce for the EIP712 signature.
    ///@param sig EIP712 signature.
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
        bytes calldata sig
    )
        external
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH,
                from,
                keccak256(abi.encodePacked(collateral)),
                liquidityStable,
                liquidityAsset,
                maxFeeValue,
                keccak256(unverifiedReport),
                keccak256(abi.encodePacked(permitDeadline)),
                keccak256(abi.encodePacked(v)),
                keccak256(abi.encodePacked(r)),
                keccak256(abi.encodePacked(s)),
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;

        address stablecoinAddress;
        for (uint256 i; i < collateral.length; i++) {
            (stablecoinAddress,,,) = IVault(vault).stableCoins(i);
            IERC20Permit(stablecoinAddress).permit(from, vault, collateral[i], permitDeadline[i], v[i], r[i], s[i]);
        }
        bytes memory dataForCall;
        dataForCall = abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral);
        _callContract(vault, dataForCall, from);

        dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).addLiquidity.selector, liquidityStable, liquidityAsset, maxFeeValue, unverifiedReport
        );
        _callContract(perpPair, dataForCall, from);
    }

    ///@dev This multicall bundles the operations of addCollateral and openTrade.
    ///@param collateral Amount of collateral the user is depositing
    ///@param tradeSize Size of the trade
    ///@param direction Direction of the trade, true for long, false for short
    ///@param minTradeReturn Minimum return accepted for the trade
    ///@param initialGuess Initial guess for the newton method
    ///@param frontendAddress Address that recieves the fees due to the frontend
    ///@param leverage Leverage of the trade. Used for logging.
    ///@param unverifiedReport Chainlink report of the current price
    ///@param deadline Deadline of the signature for the stablecoin permit
    ///@param v Part of the permit signature
    ///@param r Part of the permit signature
    ///@param s Part of the permit signature
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
        external
    {
        address stablecoinAddress;
        for (uint256 i; i < collateral.length; i++) {
            if (collateral[i] != 0) {
                (stablecoinAddress,,,) = IVault(vault).stableCoins(i);
                IERC20Permit(stablecoinAddress)
                    .permit(_msgSender(), vault, collateral[i], deadline[i], v[i], r[i], s[i]);
            }
        }
        bytes memory dataForCall;
        dataForCall = abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral);
        _callContract(vault, dataForCall, _msgSender());

        dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).trade.selector,
            direction,
            tradeSize,
            minTradeReturn,
            initialGuess,
            frontendAddress,
            leverage,
            unverifiedReport
        );
        _callContract(perpPair, dataForCall, _msgSender());
    }

    ///@dev Function to add collateral and open a liquidity position
    ///@param from Original caller's address.
    ///@param collateral Amount of collateral the user is depositing
    ///@param tradeData data for the openTrade call
    ///@param unverifiedReport Chainlink report of the current price
    ///@param permitDeadline Deadline of the signature for the stablecoin permit
    ///@param v Part of the permit signature
    ///@param r Part of the permit signature
    ///@param s Part of the permit signature
    ///@param deadline Deadline of the EIP712 signature.
    ///@param nonce nonce for the EIP712 signature.
    ///@param sig EIP712 signature.
    function relayerAddCollateralOpenTrade(
        address from,
        uint256[] memory collateral,
        TradeData memory tradeData,
        bytes memory unverifiedReport,
        uint256[] memory permitDeadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s,
        uint256 deadline,
        uint256 nonce,
        bytes calldata sig
    )
        external
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ADD_COLLATERAL_OPEN_TRADE_TYPEHASH,
                from,
                keccak256(abi.encodePacked(collateral)),
                tradeData,
                keccak256(unverifiedReport),
                keccak256(abi.encodePacked(permitDeadline)),
                keccak256(abi.encodePacked(v)),
                keccak256(abi.encodePacked(r)),
                keccak256(abi.encodePacked(s)),
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;

        address stablecoinAddress;
        for (uint256 i; i < collateral.length; i++) {
            if (collateral[i] != 0) {
                (stablecoinAddress,,,) = IVault(vault).stableCoins(i);
                IERC20Permit(stablecoinAddress).permit(from, vault, collateral[i], permitDeadline[i], v[i], r[i], s[i]);
            }
        }
        bytes memory dataForCall;
        dataForCall = abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral);
        _callContract(vault, dataForCall, from);

        dataForCall = abi.encodeWithSelector(
            IPerpPair(perpPair).trade.selector,
            tradeData.direction,
            tradeData.tradeSize,
            tradeData.minTradeReturn,
            tradeData.initialGuess,
            tradeData.frontendAddress,
            tradeData.leverage,
            unverifiedReport
        );
        _callContract(perpPair, dataForCall, from);
    }

    ///@dev Function to add collateral and open a liquidity position
    ///@param newStable Target value for the stable amount in the LP position
    ///@param newAsset Target value for the asset amount in the LP position
    ///@param maxFeeValue Maximum liquidity fee allowed for the liquidity removal in closeAndWithdraw by the user.
    ///@param unverifiedReport Chainlink report of the current price
    function modifyLiquidityPosition(
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        external
    {
        (uint256 oldStable, uint256 oldAsset) = IPerpPair(perpPair).getLpLiquidityBalance(_msgSender());

        (,, uint256 liquidityTh,,,) = IPerpPair(perpPair).ReadParameters();
        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = IPerpPair(perpPair).getPrice();
        uint256 oracleDecimals = 1e8; // oracle price scale for this market

        bytes memory dataForPerpPair;
        if (oldStable >= newStable && oldAsset >= newAsset) {
            dataForPerpPair = abi.encodeWithSelector(
                IPerpPair(perpPair).removeLiquidity.selector,
                oldStable - newStable,
                oldAsset - newAsset,
                maxFeeValue,
                unverifiedReport
            );
            _callContract(perpPair, dataForPerpPair, _msgSender());
        } else if (oldStable < newStable && oldAsset < newAsset) {
            dataForPerpPair = abi.encodeWithSelector(
                IPerpPair(perpPair).addLiquidity.selector,
                newStable - oldStable,
                newAsset - oldAsset,
                maxFeeValue,
                unverifiedReport
            );
            _callContract(perpPair, dataForPerpPair, _msgSender());
        } else if (oldStable < newStable && oldAsset >= newAsset) {
            if ((oldAsset - newAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).removeLiquidity.selector, 0, oldAsset - newAsset, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, _msgSender());
            }
            if (newStable - oldStable >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).addLiquidity.selector, newStable - oldStable, 0, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, _msgSender());
            }
        } else if (oldStable >= newStable && oldAsset < newAsset) {
            if ((oldStable - newStable) >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).removeLiquidity.selector,
                    oldStable - newStable,
                    0,
                    maxFeeValue,
                    unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, _msgSender());
            }
            if ((newAsset - oldAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).addLiquidity.selector, 0, newAsset - oldAsset, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, _msgSender());
            }
        }
        require(dataForPerpPair.length != 0, "No call was executed");
    }

    ///@dev Function to add collateral and open a liquidity position
    ///@param from Original caller's address.
    ///@param newStable Target value for the stable amount in the LP position
    ///@param newAsset Target value for the asset amount in the LP position
    ///@param maxFeeValue Maximum liquidity fee allowed for the liquidity removal in closeAndWithdraw by the user.
    ///@param unverifiedReport Chainlink report of the current price
    ///@param deadline Deadline of the EIP712 signature.
    ///@param nonce nonce for the EIP712 signature.
    ///@param sig EIP712 signature.
    function relayerModifyLiquidityPosition(
        address from,
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes calldata sig
    )
        external
    {
        bytes32 structHash = keccak256(
            abi.encode(
                MODIFY_POSITION_TYPEHASH,
                from,
                newStable,
                newAsset,
                maxFeeValue,
                keccak256(unverifiedReport), // dynamic → hash first
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;

        (uint256 oldStable, uint256 oldAsset) = IPerpPair(perpPair).getLpLiquidityBalance(from);

        (,, uint256 liquidityTh,,,) = IPerpPair(perpPair).ReadParameters();
        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = IPerpPair(perpPair).getPrice();
        uint256 oracleDecimals = 1e8; // oracle price scale for this market

        bytes memory dataForPerpPair;
        if (oldStable >= newStable && oldAsset >= newAsset) {
            dataForPerpPair = abi.encodeWithSelector(
                IPerpPair(perpPair).removeLiquidity.selector,
                oldStable - newStable,
                oldAsset - newAsset,
                maxFeeValue,
                unverifiedReport
            );
            _callContract(perpPair, dataForPerpPair, from);
        } else if (oldStable < newStable && oldAsset < newAsset) {
            dataForPerpPair = abi.encodeWithSelector(
                IPerpPair(perpPair).addLiquidity.selector,
                newStable - oldStable,
                newAsset - oldAsset,
                maxFeeValue,
                unverifiedReport
            );
            _callContract(perpPair, dataForPerpPair, from);
        } else if (oldStable < newStable && oldAsset >= newAsset) {
            if ((oldAsset - newAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).removeLiquidity.selector, 0, oldAsset - newAsset, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, from);
            }
            if (newStable - oldStable >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).addLiquidity.selector, newStable - oldStable, 0, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, from);
            }
        } else if (oldStable >= newStable && oldAsset < newAsset) {
            if ((oldStable - newStable) >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).removeLiquidity.selector,
                    oldStable - newStable,
                    0,
                    maxFeeValue,
                    unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, from);
            }
            if ((newAsset - oldAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                dataForPerpPair = abi.encodeWithSelector(
                    IPerpPair(perpPair).addLiquidity.selector, 0, newAsset - oldAsset, maxFeeValue, unverifiedReport
                );
                _callContract(perpPair, dataForPerpPair, from);
            }
        }
        require(dataForPerpPair.length != 0, "No call was executed");
    }

    function batchLiquidate(
        address[] calldata users,
        uint256[] calldata liquidatedPositionSizes,
        bytes calldata unverifiedReport
    )
        external
    {
        uint256 len = users.length;
        require(len == liquidatedPositionSizes.length, "length mismatch");

        for (uint256 i = 0; i < len;) {
            bytes memory dataForCall = abi.encodeWithSelector(
                IPerpPair(perpPair).liquidate.selector, users[i], liquidatedPositionSizes[i], unverifiedReport
            );

            _callContract(perpPair, dataForCall, _msgSender());

            unchecked {
                ++i;
            }
        }
    }

    function takeProfitRemoveCollateral(bytes memory unverifiedReport) external {
        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = SafeCast.toUint256(IOracleMiddleware(IVault(vault).oracle()).getPrice());

        (uint256 pnl, bool pnlSign) = IPerpPair(perpPair).calcPnL(_msgSender(), spotPrice);
        require(pnlSign, "Pnl must be positive");

        bytes memory dataForCall = abi.encodeWithSelector(IPerpPair(perpPair).realizePnL.selector, unverifiedReport);
        _callContract(perpPair, dataForCall, _msgSender());

        dataForCall = abi.encodeWithSelector(IVault(vault).removeCollateral.selector, pnl, unverifiedReport);
        _callContract(vault, dataForCall, _msgSender());
    }

    function relayerTakeProfitRemoveCollateral(
        address from,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes calldata sig
    )
        external
    {
        bytes32 structHash = keccak256(
            abi.encode(TAKE_PROFIT_REMOVE_COLLATERAL_TYPEHASH, from, keccak256(unverifiedReport), deadline, nonce)
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;

        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = SafeCast.toUint256(IOracleMiddleware(IVault(vault).oracle()).getPrice());

        (uint256 pnl, bool pnlSign) = IPerpPair(perpPair).calcPnL(from, spotPrice);
        require(pnlSign, "Pnl must be positive");

        bytes memory dataForCall = abi.encodeWithSelector(IPerpPair(perpPair).realizePnL.selector, unverifiedReport);
        _callContract(perpPair, dataForCall, from);

        dataForCall = abi.encodeWithSelector(IVault(vault).removeCollateral.selector, pnl, unverifiedReport);
        _callContract(vault, dataForCall, from);
    }

    ///@dev function to call contractAddress with callData coming from originalSender
    function _callContract(address contractAddress, bytes memory callData, address originalSender) private {
        // Append the original sender to the calldata
        bytes memory forwardedData = abi.encodePacked(callData, originalSender);

        (bool success, bytes memory returndata) = contractAddress.call(forwardedData);
        if (!success) {
            if (returndata.length > 0) {
                // Revert with the callee's exact revert data
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            } else {
                revert("Call to contract failed"); // no revert data available
            }
        }
    }

    ///@dev exposes EIP712 _hashTypedDataV4 to the caller.
    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    ///@dev initializes the multicall contract, assigning the addresses of the other two contracts.
    function initializeAddresses(address _perpPair, address _vault) public initializer onlyRole(MOD_ROLE) {
        perpPair = _perpPair;
        vault = _vault;
    }
}
