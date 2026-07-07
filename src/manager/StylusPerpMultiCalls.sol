// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../interfaces/IVault.sol";
import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Explicit-sender forwarded entrypoints on the Stylus engine. The manager is
///         the engine's `trustedForwarder` and passes the real `user`/`liquidator`/
///         `caller` as the first argument (the Stylus-feasible stand-in for ERC2771).
interface IStylusPerpEngine {
    function tradeFor(
        address user,
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes calldata unverifiedReport
    )
        external
        returns (uint256);
    function closeAndWithdrawFor(
        address user,
        uint256 maxSlippage,
        uint256 maxLiqFee,
        address frontendAddress,
        bytes calldata unverifiedReport
    )
        external;
    function addLiquidityFor(
        address user,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes calldata unverifiedReport
    )
        external;
    function removeLiquidityFor(
        address user,
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        uint256 maxFeeValue,
        bytes calldata unverifiedReport
    )
        external;
    function liquidateFor(
        address liquidator,
        address user,
        uint256 liquidatedPositionSize,
        bytes calldata unverifiedReport
    )
        external;
    function batchLiquidateFor(
        address liquidator,
        address[] calldata users,
        uint256[] calldata liquidatedPositionSizes,
        bytes calldata unverifiedReport
    )
        external;
    function realizePnLFor(address user, bytes calldata unverifiedReport) external returns (uint256, bool);

    // Public view getters (read paths for modify-liquidity / take-profit bundlers).
    function getLpLiquidityBalance(address user) external view returns (uint256, uint256);
    function getPrice() external view returns (uint256);
    function calcPnL(address user, uint256 price) external view returns (uint256, bool);
    // PerpStorage 8-field tuple: (vault, oracle, minimumTradeSize, minimumLiquidityMovement,
    // feeFrontend, feeLP, insuranceFundCap, tickerAssetCurrency).
    function ReadParameters()
        external
        view
        returns (address, address, uint256, uint256, uint256, uint256, uint256, bytes32);
}

/// @title Stylus production-topology meta-call layer.
/// @notice Adaptation of `PerpMultiCalls` for the Stylus engine. Identical to the
///         Solidity manager EXCEPT that engine calls go to the explicit-sender `*For`
///         entrypoints (typed, no ERC2771 calldata suffix) while vault calls keep the
///         ERC2771 suffix (the vault is unchanged Solidity). The manager must be
///         registered as the engine's `trustedForwarder` (`engine.setTrustedForwarder`).
///         The relayer/EIP712 meta-tx machinery is identical to the Solidity manager
///         (engine-agnostic overhead), so the production-topology gas delta is the
///         engine call alone.
/// @dev Full bundler surface: close, add-liquidity, open-trade, batch-liquidate, and
///      (since the engine now exposes getLpLiquidityBalance/getPrice/calcPnL/ReadParameters
///      as public views) modify-liquidity and take-profit-remove-collateral.
contract StylusPerpMultiCalls is Initializable, EIP712, AccessControl, ReentrancyGuardTransient {
    using ECDSA for bytes32;

    address public perpPair;
    address public vault;

    bytes32 public immutable ADD_COLLATERAL_OPEN_TRADE_TYPEHASH = keccak256(
        "relayerAddCollateralOpenTrade(address from,uint256[] collateral,uint256 tradeSize,bool direction,uint256 minTradeReturn,uint256 initialGuess,address frontendAddress,uint8 leverage,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH = keccak256(
        "relayerAddCollateralAddLiquidity(address from,uint256[] collateral,uint256 liquidityStable,uint256 liquidityAsset,uint256 maxFeeValue,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH = keccak256(
        "relayerCloseAndRemoveAllCollateral(address from,uint256 maxSlippage,uint256 maxLiquidityFee,address frontendAddress,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable MODIFY_POSITION_TYPEHASH = keccak256(
        "relayerModifyLiquidityPosition(address from,uint256 newStable,uint256 newAsset,uint256 maxFeeValue,bytes unverifiedReport,uint256 deadline,uint256 nonce)"
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

    bytes32 public constant MOD_ROLE = keccak256("MOD_ROLE");

    mapping(address => uint256) public nonces;

    constructor() EIP712("StylusPerpMultiCalls", "1") {
        // Grant the deployer DEFAULT_ADMIN_ROLE so MOD_ROLE remains administrable
        // (transferable to a multisig / revocable) after deployment. Without an admin,
        // OpenZeppelin AccessControl would leave MOD_ROLE permanently frozen to the
        // deployer (its admin role, DEFAULT_ADMIN_ROLE, would be held by nobody).
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MOD_ROLE, msg.sender);
    }

    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    function initializeAddresses(address _perpPair, address _vault) public initializer onlyRole(MOD_ROLE) {
        perpPair = _perpPair;
        vault = _vault;
    }

    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    // --- close + remove all collateral -------------------------------------------------

    function closeAndRemoveAllCollateral(
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        external
    {
        _closeAndRemoveAllCollateral(msg.sender, maxSlippage, maxLiquidityFee, frontendAddress, unverifiedReport);
    }

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
        _closeAndRemoveAllCollateral(from, maxSlippage, maxLiquidityFee, frontendAddress, unverifiedReport);
    }

    function _closeAndRemoveAllCollateral(
        address sender,
        uint256 maxSlippage,
        uint256 maxLiquidityFee,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        private
    {
        // Engine: explicit-sender forwarded call (manager == trustedForwarder).
        IStylusPerpEngine(perpPair)
            .closeAndWithdrawFor(sender, maxSlippage, maxLiquidityFee, frontendAddress, unverifiedReport);
        // Vault: unchanged Solidity — ERC2771 sender suffix.
        _callContract(
            vault, abi.encodeWithSelector(IVault(vault).removeAllCollateral.selector, unverifiedReport), sender
        );
    }

    // --- add collateral + add liquidity ------------------------------------------------

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
        _permitCollateral(msg.sender, collateral, deadline, v, r, s);
        _addCollateralAddLiquidity(
            msg.sender, collateral, liquidityStable, liquidityAsset, maxFeeValue, unverifiedReport
        );
    }

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
        nonReentrant
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
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;
        _permitCollateral(from, collateral, permitDeadline, v, r, s);
        _addCollateralAddLiquidity(from, collateral, liquidityStable, liquidityAsset, maxFeeValue, unverifiedReport);
    }

    function _addCollateralAddLiquidity(
        address sender,
        uint256[] memory collateral,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        private
    {
        _callContract(vault, abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral), sender);
        IStylusPerpEngine(perpPair)
            .addLiquidityFor(sender, liquidityStable, liquidityAsset, maxFeeValue, unverifiedReport);
    }

    // --- add collateral + open trade (the headline production-topology path) -----------

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
        _permitCollateral(msg.sender, collateral, deadline, v, r, s);
        _callContract(vault, abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral), msg.sender);
        IStylusPerpEngine(perpPair)
            .tradeFor(
                msg.sender,
                direction,
                tradeSize,
                minTradeReturn,
                initialGuess,
                frontendAddress,
                leverage,
                unverifiedReport
            );
    }

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
        nonReentrant
    {
        // EIP712 structHash encodes exactly the fields declared in the typehash string
        // (the permit arrays are NOT signed: the user's permit sigs self-verify and the
        // collateral amounts are bound via keccak256(collateral), so a relayer cannot
        // tamper). The original Solidity manager over-encoded permitDeadline/v/r/s —
        // fields absent from its own typehash string (an internal EIP712 inconsistency);
        // not reproduced (cross-contract sig reuse is impossible anyway — distinct domain).
        bytes32 structHash = keccak256(
            abi.encode(
                ADD_COLLATERAL_OPEN_TRADE_TYPEHASH,
                from,
                keccak256(abi.encodePacked(collateral)),
                tradeData,
                keccak256(unverifiedReport),
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;
        _permitCollateral(from, collateral, permitDeadline, v, r, s);
        _callContract(vault, abi.encodeWithSelector(IVault(vault).addCollateral.selector, collateral), from);
        IStylusPerpEngine(perpPair)
            .tradeFor(
                from,
                tradeData.direction,
                tradeData.tradeSize,
                tradeData.minTradeReturn,
                tradeData.initialGuess,
                tradeData.frontendAddress,
                tradeData.leverage,
                unverifiedReport
            );
    }

    // --- batch liquidate ---------------------------------------------------------------

    function batchLiquidate(
        address[] calldata users,
        uint256[] calldata liquidatedPositionSizes,
        bytes calldata unverifiedReport
    )
        external
    {
        require(users.length == liquidatedPositionSizes.length, "length mismatch");
        // One engine call for the whole batch: the engine verifies the report and reads the
        // oracle price once, then loops the liquidations in-WASM (see batchLiquidateFor).
        IStylusPerpEngine(perpPair).batchLiquidateFor(msg.sender, users, liquidatedPositionSizes, unverifiedReport);
    }

    // --- modify liquidity position -----------------------------------------------------

    function modifyLiquidityPosition(
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        external
    {
        _modifyLiquidityPosition(msg.sender, newStable, newAsset, maxFeeValue, unverifiedReport);
    }

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
        nonReentrant
    {
        bytes32 structHash = keccak256(
            abi.encode(
                MODIFY_POSITION_TYPEHASH,
                from,
                newStable,
                newAsset,
                maxFeeValue,
                keccak256(unverifiedReport),
                deadline,
                nonce
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;
        _modifyLiquidityPosition(from, newStable, newAsset, maxFeeValue, unverifiedReport);
    }

    function _modifyLiquidityPosition(
        address sender,
        uint256 newStable,
        uint256 newAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        private
    {
        (uint256 oldStable, uint256 oldAsset) = IStylusPerpEngine(perpPair).getLpLiquidityBalance(sender);

        // ReadParameters() returns the 8-field PerpStorage tuple; [3] is
        // minimumLiquidityMovement — the liquidity threshold. (The original Solidity
        // manager bound a 6-field IPerpPair.ReadParameters and read [2], which against
        // the real 8-field engine decodes to minimumTradeSize — a latent decode bug.
        // Fixed here: read minimumLiquidityMovement directly, matching `liquidityTh`'s
        // intent.)
        (,,, uint256 liquidityTh,,,,) = IStylusPerpEngine(perpPair).ReadParameters();
        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = IStylusPerpEngine(perpPair).getPrice();
        uint256 oracleDecimals = 1e8;

        // The original gated execution on `dataForPerpPair.length != 0`; with typed
        // forwarded calls (no encoded calldata) an explicit flag is the equivalent guard.
        bool executed;
        if (oldStable >= newStable && oldAsset >= newAsset) {
            IStylusPerpEngine(perpPair)
                .removeLiquidityFor(sender, oldStable - newStable, oldAsset - newAsset, maxFeeValue, unverifiedReport);
            executed = true;
        } else if (oldStable < newStable && oldAsset < newAsset) {
            IStylusPerpEngine(perpPair)
                .addLiquidityFor(sender, newStable - oldStable, newAsset - oldAsset, maxFeeValue, unverifiedReport);
            executed = true;
        } else if (oldStable < newStable && oldAsset >= newAsset) {
            if ((oldAsset - newAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                IStylusPerpEngine(perpPair)
                    .removeLiquidityFor(sender, 0, oldAsset - newAsset, maxFeeValue, unverifiedReport);
                executed = true;
            }
            if (newStable - oldStable >= liquidityTh) {
                IStylusPerpEngine(perpPair)
                    .addLiquidityFor(sender, newStable - oldStable, 0, maxFeeValue, unverifiedReport);
                executed = true;
            }
        } else if (oldStable >= newStable && oldAsset < newAsset) {
            if ((oldStable - newStable) >= liquidityTh) {
                IStylusPerpEngine(perpPair)
                    .removeLiquidityFor(sender, oldStable - newStable, 0, maxFeeValue, unverifiedReport);
                executed = true;
            }
            if ((newAsset - oldAsset) * spotPrice / oracleDecimals >= liquidityTh) {
                IStylusPerpEngine(perpPair)
                    .addLiquidityFor(sender, 0, newAsset - oldAsset, maxFeeValue, unverifiedReport);
                executed = true;
            }
        }
        require(executed, "No call was executed");
    }

    // --- take profit + remove collateral -----------------------------------------------

    function takeProfitRemoveCollateral(bytes memory unverifiedReport) external {
        _takeProfitRemoveCollateral(msg.sender, unverifiedReport);
    }

    function relayerTakeProfitRemoveCollateral(
        address from,
        bytes memory unverifiedReport,
        uint256 deadline,
        uint256 nonce,
        bytes calldata sig
    )
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(
            abi.encode(TAKE_PROFIT_REMOVE_COLLATERAL_TYPEHASH, from, keccak256(unverifiedReport), deadline, nonce)
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(signer == from && nonce == nonces[from] && block.timestamp <= deadline, "Invalid/Expired Signature");
        nonces[from] += 1;
        _takeProfitRemoveCollateral(from, unverifiedReport);
    }

    function _takeProfitRemoveCollateral(address sender, bytes memory unverifiedReport) private {
        IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = SafeCast.toUint256(IOracleMiddleware(IVault(vault).oracle()).getPrice());

        (uint256 pnl, bool pnlSign) = IStylusPerpEngine(perpPair).calcPnL(sender, spotPrice);
        require(pnlSign, "Pnl must be positive");

        // Engine: realizePnL via the forwarded entrypoint (manager == trustedForwarder).
        IStylusPerpEngine(perpPair).realizePnLFor(sender, unverifiedReport);
        // Vault: unchanged Solidity — ERC2771 sender suffix.
        _callContract(
            vault, abi.encodeWithSelector(IVault(vault).removeCollateral.selector, pnl, unverifiedReport), sender
        );
    }

    // --- helpers -----------------------------------------------------------------------

    function _permitCollateral(
        address owner,
        uint256[] memory collateral,
        uint256[] memory deadline,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s
    )
        private
    {
        address stablecoinAddress;
        for (uint256 i; i < collateral.length; i++) {
            if (collateral[i] != 0) {
                (stablecoinAddress,,,) = IVault(vault).stableCoins(i);
                IERC20Permit(stablecoinAddress).permit(owner, vault, collateral[i], deadline[i], v[i], r[i], s[i]);
            }
        }
    }

    /// @dev ERC2771 forwarding for the (still-Solidity) vault: appends `originalSender`.
    function _callContract(address contractAddress, bytes memory callData, address originalSender) private {
        bytes memory forwardedData = abi.encodePacked(callData, originalSender);
        (bool success, bytes memory returndata) = contractAddress.call(forwardedData);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            } else {
                revert("Call to contract failed");
            }
        }
    }
}
