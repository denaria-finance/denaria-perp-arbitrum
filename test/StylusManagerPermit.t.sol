// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { FiatTokenV2 } from "../src/token/USDCe.sol";
import { StylusPerpMultiCalls } from "../src/manager/StylusPerpMultiCalls.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShortPermitToken } from "./helpers/ShortPermitToken.sol";

/// @dev Records the forwarded engine call so the collateral leg can be exercised without the
///      Stylus engine, which Foundry cannot deploy or call.
contract EngineLiquidityRecorderMock {
    address public lastUser;
    uint256 public lastStable;
    uint256 public lastAsset;
    uint256 public calls;

    function addLiquidityFor(
        address user,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256,
        bytes calldata
    )
        external
    {
        lastUser = user;
        lastStable = liquidityStable;
        lastAsset = liquidityAsset;
        calls += 1;
    }
}

/// @title Permit-wrapper regressions on the deployed Stylus manager
/// @notice `StylusPerpMultiCalls` funnels all four entry points through one `_permitCollateral`
///         helper, so the permit hardening is verified here on the contract that is actually
///         deployed: a zero-amount stablecoin is never permitted, an allowance that already covers
///         the amount skips the permit (surviving a front-run that consumed the nonce), and a
///         permit leaving too small an allowance reverts before any transfer.
contract StylusManagerPermitTest is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant RATIO_DECIMALS = 1e8;

    address internal masterMinter = makeAddr("masterMinter");
    address internal pauser = makeAddr("pauser");
    address internal blacklister = makeAddr("blacklister");
    address internal owner = makeAddr("owner");

    FiatTokenV2 internal coin6;
    FiatTokenV2 internal coin18;
    Vault internal vault;
    LostAndFound internal lostAndFound;
    StylusPerpMultiCalls internal manager;
    EngineLiquidityRecorderMock internal engine;

    address internal user;
    uint256 internal userPk;

    uint256[] internal collateral;
    uint256[] internal deadlines;
    uint8[] internal v;
    bytes32[] internal r;
    bytes32[] internal s;

    function setUp() public {
        coin6 = _newToken(6);
        coin18 = _newToken(18);

        address[] memory coins = new address[](2);
        coins[0] = address(coin6);
        coins[1] = address(coin18);
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1000 * RATIO_DECIMALS;
        thresholds[1] = 1000 * RATIO_DECIMALS;
        uint256[] memory scales = new uint256[](2);
        scales[0] = 1e6;
        scales[1] = 1e18;

        manager = new StylusPerpMultiCalls();
        vault = new Vault(address(manager), 100, coins, thresholds, thresholds, scales);
        engine = new EngineLiquidityRecorderMock();
        manager.initializeAddresses(address(engine), address(vault));

        lostAndFound = new LostAndFound();
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));
        vault.initializeParameters(address(engine), address(lostAndFound));

        (user, userPk) = makeAddrAndKey("stylus-permit-user");

        // Sparse bundle: depositing only stablecoin #1, so slot #0 carries amount 0 and an
        // unsigned permit that must never be submitted.
        collateral = new uint256[](2);
        collateral[1] = 1000 * 1e18;
        vm.prank(masterMinter);
        coin18.mint(user, collateral[1]);

        deadlines = new uint256[](2);
        deadlines[1] = block.timestamp + 1000;
        v = new uint8[](2);
        r = new bytes32[](2);
        s = new bytes32[](2);
        (v[1], r[1], s[1]) = _signPermit(address(coin18), collateral[1], deadlines[1]);
    }

    function testZeroAmountStableIsNeverPermitted() public {
        // Slot #0 has no signature at all: any permit attempt on it would revert the bundle.
        // Pin the guard itself, not only the outcome — the zero slot must not even be touched.
        vm.expectCall(address(coin6), abi.encodeWithSelector(IERC20Permit.permit.selector), 0);
        vm.prank(user);
        manager.addCollateralAddLiquidity(collateral, 0, 0, 0, "", deadlines, v, r, s);

        assertEq(IERC20Permit(address(coin6)).nonces(user), 0, "zero-amount stable was permitted");
        assertEq(vault.userCollateral(user), collateral[1]);
    }

    function testFrontRunPermitDoesNotRevertBundle() public {
        vm.prank(makeAddr("permit-front-runner"));
        IERC20Permit(address(coin18)).permit(user, address(vault), collateral[1], deadlines[1], v[1], r[1], s[1]);
        assertEq(IERC20Permit(address(coin18)).nonces(user), 1);

        vm.prank(user);
        manager.addCollateralAddLiquidity(collateral, 500e18, 5e18, 0, "", deadlines, v, r, s);

        assertEq(IERC20Permit(address(coin18)).nonces(user), 1, "wrapper replayed permit");
        assertEq(vault.userCollateral(user), collateral[1]);
        assertEq(engine.calls(), 1);
        assertEq(engine.lastUser(), user);
        assertEq(engine.lastStable(), 500e18);
    }

    function testPreExistingAllowanceBypassesPermit() public {
        vm.prank(user);
        IERC20(address(coin18)).approve(address(vault), type(uint256).max);

        vm.prank(user);
        manager.addCollateralAddLiquidity(collateral, 0, 0, 0, "", deadlines, v, r, s);

        assertEq(IERC20Permit(address(coin18)).nonces(user), 0, "permit consumed despite allowance");
        assertEq(vault.userCollateral(user), collateral[1]);
    }

    /// @dev A permit that lands but establishes less allowance than requested must revert the
    ///      bundle up front, before any collateral is pulled.
    function testInsufficientPostPermitAllowanceReverts() public {
        ShortPermitToken shortToken = new ShortPermitToken();
        uint256 amount = 1000e18;
        shortToken.mint(user, amount);

        address[] memory coins = new address[](1);
        coins[0] = address(shortToken);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1000 * RATIO_DECIMALS;
        uint256[] memory scales = new uint256[](1);
        scales[0] = 1e18;

        StylusPerpMultiCalls shortManager = new StylusPerpMultiCalls();
        Vault shortVault = new Vault(address(shortManager), 100, coins, thresholds, thresholds, scales);
        shortManager.initializeAddresses(address(engine), address(shortVault));
        shortVault.initializeParameters(address(engine), address(lostAndFound));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory shortDeadlines = new uint256[](1);
        shortDeadlines[0] = block.timestamp + 1000;

        // The bundle must stop at the allowance check: no transfer may be attempted at all.
        vm.expectCall(address(shortToken), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.prank(user);
        vm.expectRevert(bytes("Insufficient allowance"));
        shortManager.addCollateralAddLiquidity(
            amounts, 0, 0, 0, "", shortDeadlines, new uint8[](1), new bytes32[](1), new bytes32[](1)
        );
    }

    function _newToken(uint8 tokenDecimals) private returns (FiatTokenV2 token) {
        token = new FiatTokenV2();
        token.initialize("USDCe", "USDC.e", "USD", tokenDecimals, masterMinter, pauser, blacklister, owner);
        token.initializeV2("USDCe");
        vm.prank(masterMinter);
        token.configureMinter(masterMinter, type(uint256).max);
    }

    function _signPermit(
        address token,
        uint256 value,
        uint256 deadline
    )
        private
        view
        returns (uint8 sigV, bytes32 sigR, bytes32 sigS)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, user, address(vault), value, IERC20Permit(token).nonces(user), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(userPk, digest);
    }

    // --- relayer meta-call authorisation ---------------------------------------------------
    //
    // The relayer entry points let ANY caller submit an action on a user's behalf against an
    // EIP-712 signature. That makes signature binding and nonce consumption the security boundary
    // of the whole manager, and none of it was exercised: the deployed contract had no test that a
    // signature cannot be replayed, cannot be produced by a third party, and expires.

    /// @dev Builds the digest exactly as `relayerAddCollateralAddLiquidity` does and signs it with
    ///      `signerPk`. Note which fields are bound: the permit arrays are NOT part of this
    ///      typehash (its sibling `relayerAddCollateralOpenTrade` does bind them).
    function _signAddLiquidityMetaCall(
        uint256 signerPk,
        address from,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 deadline,
        uint256 nonce
    )
        private
        view
        returns (bytes memory sig)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                manager.ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH(),
                from,
                keccak256(abi.encodePacked(collateral)),
                liquidityStable,
                liquidityAsset,
                uint256(0), // maxFeeValue
                keccak256(bytes("")), // unverifiedReport
                deadline,
                nonce
            )
        );
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(signerPk, manager.hashTypedData(structHash));
        return abi.encodePacked(sr, ss, sv);
    }

    function _submitMetaCall(uint256 deadline, uint256 nonce, bytes memory sig) private {
        vm.prank(makeAddr("relayer"));
        manager.relayerAddCollateralAddLiquidity(
            user, collateral, 500e18, 5e18, 0, "", deadlines, v, r, s, deadline, nonce, sig
        );
    }

    /// @dev The happy path, and the nonce it must burn. Anyone may submit it — the signature, not
    ///      the caller, is the authorisation.
    function testRelayerMetaCallExecutesAndBurnsTheNonce() public {
        uint256 deadline = block.timestamp + 1000;
        assertEq(manager.getNonce(user), 0, "fresh signer");

        _submitMetaCall(deadline, 0, _signAddLiquidityMetaCall(userPk, user, 500e18, 5e18, deadline, 0));

        assertEq(manager.getNonce(user), 1, "nonce must advance");
        assertEq(vault.userCollateral(user), collateral[1], "collateral leg ran");
        assertEq(engine.calls(), 1, "engine leg ran");
        assertEq(engine.lastUser(), user, "engine acted for the SIGNER, not the relayer");
        assertEq(engine.lastStable(), 500e18);
    }

    /// @dev THE property: a captured signature cannot be replayed. The nonce is bound into the
    ///      digest and consumed on use, so the second submission of the identical payload fails.
    function testRelayerMetaCallCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1000;
        bytes memory sig = _signAddLiquidityMetaCall(userPk, user, 500e18, 5e18, deadline, 0);
        _submitMetaCall(deadline, 0, sig);

        vm.expectRevert(bytes("Invalid/Expired Signature"));
        _submitMetaCall(deadline, 0, sig);
        assertEq(engine.calls(), 1, "the replay must not reach the engine");
    }

    /// @dev A signature from any other key cannot move a user's funds, however well-formed.
    function testRelayerMetaCallRejectsAForeignSigner() public {
        (, uint256 attackerPk) = makeAddrAndKey("meta-call-attacker");
        uint256 deadline = block.timestamp + 1000;
        // Sign BEFORE arming expectRevert: the signing helper makes an external `hashTypedData`
        // call, which would otherwise be the call expectRevert latches onto.
        bytes memory forged = _signAddLiquidityMetaCall(attackerPk, user, 500e18, 5e18, deadline, 0);

        vm.expectRevert(bytes("Invalid/Expired Signature"));
        _submitMetaCall(deadline, 0, forged);
        assertEq(manager.getNonce(user), 0, "a rejected signature must not burn the nonce");
        assertEq(engine.calls(), 0);
    }

    /// @dev Expiry and nonce ordering are both enforced, so a signature cannot be held indefinitely
    ///      and cannot be submitted out of sequence.
    function testRelayerMetaCallRejectsExpiryAndWrongNonce() public {
        uint256 deadline = block.timestamp + 1000;

        bytes memory futureNonce = _signAddLiquidityMetaCall(userPk, user, 500e18, 5e18, deadline, 7);
        vm.expectRevert(bytes("Invalid/Expired Signature"));
        _submitMetaCall(deadline, 7, futureNonce);

        bytes memory expiring = _signAddLiquidityMetaCall(userPk, user, 500e18, 5e18, deadline, 0);
        skip(1001); // one second past the signed deadline
        vm.expectRevert(bytes("Invalid/Expired Signature"));
        _submitMetaCall(deadline, 0, expiring);

        assertEq(manager.getNonce(user), 0, "neither rejection burned the nonce");
    }
}
