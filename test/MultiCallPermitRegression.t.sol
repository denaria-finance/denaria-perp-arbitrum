// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { PerpPairTest } from "./MultiCallTest.t.sol";
import { PerpMultiCalls } from "../src/manager/multiCallManager.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { ShortPermitToken } from "./helpers/ShortPermitToken.sol";

/// @title Permit-wrapper regressions
/// @notice The bundlers take one permit signature per registered stablecoin. Two shapes broke them:
///         a stablecoin the user is not depositing (amount 0) still had its permit submitted, and a
///         permit already landed by anyone else — permits are public, so anyone can front-run one —
///         reverted the whole bundle on nonce reuse. The wrapper must skip a zero amount, skip the
///         permit when the allowance already covers the amount, and otherwise verify the allowance
///         the permit was meant to establish.
contract MultiCallPermitRegressionTest is PerpPairTest {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct PermitContext {
        address user;
        uint256 userPk;
        uint256[] collateral;
        uint256[] deadlines;
        uint8[] v;
        bytes32[] r;
        bytes32[] s;
    }

    struct RelaySignature {
        uint256 deadline;
        uint256 nonce;
        bytes signature;
    }

    function _signPermit(
        address token,
        PermitContext memory context,
        uint256 value,
        uint256 deadline
    )
        private
        returns (uint8 sigV, bytes32 sigR, bytes32 sigS)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, context.user, address(vault), value, IERC20Permit(token).nonces(context.user), deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(context.userPk, digest);
    }

    /// @dev A user depositing only stablecoin #1: slot #0 carries amount 0 and an unsigned permit,
    ///      which must never be submitted.
    function _prepareSparseUser(string memory label) private returns (PermitContext memory context) {
        (context.user, context.userPk) = makeAddrAndKey(label);

        context.collateral = new uint256[](2);
        context.collateral[1] = 1000 * 1e18;
        _mint(stableCoins[1], context.user, context.collateral[1]);

        context.deadlines = new uint256[](2);
        context.deadlines[1] = block.timestamp + 1000;
        context.v = new uint8[](2);
        context.r = new bytes32[](2);
        context.s = new bytes32[](2);
        (context.v[1], context.r[1], context.s[1]) =
            _signPermit(stableCoins[1], context, context.collateral[1], context.deadlines[1]);
    }

    function _frontRunActivePermit(PermitContext memory context) private {
        vm.prank(makeAddr("permit-front-runner"));
        IERC20Permit(stableCoins[1])
            .permit(
                context.user,
                address(vault),
                context.collateral[1],
                context.deadlines[1],
                context.v[1],
                context.r[1],
                context.s[1]
            );

        assertEq(IERC20(stableCoins[1]).allowance(context.user, address(vault)), context.collateral[1]);
        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 1);
    }

    function _signRelayerLpEntry(
        PermitContext memory context,
        uint256 liquidityStable,
        uint256 liquidityAsset
    )
        private
        returns (RelaySignature memory relay)
    {
        relay.deadline = block.timestamp + 1000;
        relay.nonce = multiCallManager.getNonce(context.user);
        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH(),
                context.user,
                keccak256(abi.encodePacked(context.collateral)),
                liquidityStable,
                liquidityAsset,
                maxUserLiquidityFee,
                keccak256(fakeReport),
                keccak256(abi.encodePacked(context.deadlines)),
                keccak256(abi.encodePacked(context.v)),
                keccak256(abi.encodePacked(context.r)),
                keccak256(abi.encodePacked(context.s)),
                relay.deadline,
                relay.nonce
            )
        );
        bytes32 digest = multiCallManager.hashTypedData(request);
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(context.userPk, digest);
        relay.signature = abi.encodePacked(sigR, sigS, sigV);
    }

    function _signRelayerTradeEntry(
        PermitContext memory context,
        PerpMultiCalls.TradeData memory tradeData
    )
        private
        returns (RelaySignature memory relay)
    {
        relay.deadline = block.timestamp + 1000;
        relay.nonce = multiCallManager.getNonce(context.user);
        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.ADD_COLLATERAL_OPEN_TRADE_TYPEHASH(),
                context.user,
                keccak256(abi.encodePacked(context.collateral)),
                tradeData,
                keccak256(fakeReport),
                keccak256(abi.encodePacked(context.deadlines)),
                keccak256(abi.encodePacked(context.v)),
                keccak256(abi.encodePacked(context.r)),
                keccak256(abi.encodePacked(context.s)),
                relay.deadline,
                relay.nonce
            )
        );
        bytes32 digest = multiCallManager.hashTypedData(request);
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(context.userPk, digest);
        relay.signature = abi.encodePacked(sigR, sigS, sigV);
    }

    function _seedTradeLiquidity(uint256 price) private returns (uint256 liquidityAsset) {
        uint256 liquidityStable = 10_000 * 1e18;
        liquidityAsset = liquidityStable * oracleDecimals / price;
        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);
    }

    function testDirectLpEntrySkipsZeroPermitAndToleratesFrontRun() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        PermitContext memory context = _prepareSparseUser("direct-lp-user");
        _frontRunActivePermit(context);

        uint256 liquidityStable = 500 * 1e18;
        uint256 liquidityAsset = liquidityStable * oracleDecimals / price;
        vm.prank(context.user);
        multiCallManager.addCollateralAddLiquidity(
            context.collateral,
            liquidityStable,
            liquidityAsset,
            maxUserLiquidityFee,
            fakeReport,
            context.deadlines,
            context.v,
            context.r,
            context.s
        );

        (uint256 actualStable, uint256 actualAsset) = perpPair.getLpLiquidityBalance(context.user);
        assertEq(actualStable, liquidityStable);
        assertEq(actualAsset, liquidityAsset);
        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 1, "wrapper replayed permit");
    }

    function testRelayedLpEntrySkipsZeroPermitAndToleratesFrontRun() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        PermitContext memory context = _prepareSparseUser("relayed-lp-user");

        uint256 liquidityStable = 500 * 1e18;
        uint256 liquidityAsset = liquidityStable * oracleDecimals / price;
        RelaySignature memory relay = _signRelayerLpEntry(context, liquidityStable, liquidityAsset);
        _frontRunActivePermit(context);

        multiCallManager.relayerAddCollateralAddLiquidity(
            context.user,
            context.collateral,
            liquidityStable,
            liquidityAsset,
            maxUserLiquidityFee,
            fakeReport,
            context.deadlines,
            context.v,
            context.r,
            context.s,
            relay.deadline,
            relay.nonce,
            relay.signature
        );

        (uint256 actualStable, uint256 actualAsset) = perpPair.getLpLiquidityBalance(context.user);
        assertEq(actualStable, liquidityStable);
        assertEq(actualAsset, liquidityAsset);
        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 1, "wrapper replayed permit");
    }

    function testDirectTradeEntryToleratesFrontRunPermit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        uint256 initialGuess = _seedTradeLiquidity(price);
        PermitContext memory context = _prepareSparseUser("direct-trade-user");
        _frontRunActivePermit(context);

        uint256 tradeSize = 500 * 1e18;
        vm.prank(context.user);
        multiCallManager.addCollateralOpenTrade(
            context.collateral,
            tradeSize,
            true,
            0,
            initialGuess,
            frontendAddress,
            1,
            fakeReport,
            context.deadlines,
            context.v,
            context.r,
            context.s
        );

        (,, uint256 stableDebt,,,,,) = perpPair.userVirtualTraderPosition(context.user);
        assertEq(stableDebt, tradeSize);
        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 1, "wrapper replayed permit");
    }

    function testRelayedTradeEntryToleratesFrontRunPermit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        uint256 initialGuess = _seedTradeLiquidity(price);
        PermitContext memory context = _prepareSparseUser("relayed-trade-user");

        PerpMultiCalls.TradeData memory tradeData =
            PerpMultiCalls.TradeData(500 * 1e18, true, 0, initialGuess, frontendAddress, 1);
        RelaySignature memory relay = _signRelayerTradeEntry(context, tradeData);
        _frontRunActivePermit(context);

        multiCallManager.relayerAddCollateralOpenTrade(
            context.user,
            context.collateral,
            tradeData,
            fakeReport,
            context.deadlines,
            context.v,
            context.r,
            context.s,
            relay.deadline,
            relay.nonce,
            relay.signature
        );

        (,, uint256 stableDebt,,,,,) = perpPair.userVirtualTraderPosition(context.user);
        assertEq(stableDebt, tradeData.tradeSize);
        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 1, "wrapper replayed permit");
    }

    /// @dev A pre-existing allowance (not from this bundle's permit) is equally sufficient: the
    ///      wrapper must consume neither the signature nor the nonce.
    function testPreExistingAllowanceBypassesPermit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);
        PermitContext memory context = _prepareSparseUser("pre-approved-user");

        vm.prank(context.user);
        IERC20(stableCoins[1]).approve(address(vault), type(uint256).max);

        uint256 liquidityStable = 500 * 1e18;
        uint256 liquidityAsset = liquidityStable * oracleDecimals / price;
        vm.prank(context.user);
        multiCallManager.addCollateralAddLiquidity(
            context.collateral,
            liquidityStable,
            liquidityAsset,
            maxUserLiquidityFee,
            fakeReport,
            context.deadlines,
            context.v,
            context.r,
            context.s
        );

        assertEq(IERC20Permit(stableCoins[1]).nonces(context.user), 0, "permit consumed despite allowance");
    }

    /// @dev A permit that lands but establishes less allowance than requested must revert the
    ///      bundle up front, before any collateral is pulled.
    function testInsufficientPostPermitAllowanceReverts() public {
        address user = makeAddr("short-permit-user");
        ShortPermitToken shortToken = new ShortPermitToken();
        uint256 amount = 1000e18;
        shortToken.mint(user, amount);

        address[] memory coins = new address[](1);
        coins[0] = address(shortToken);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1000 * 1e8;
        uint256[] memory scales = new uint256[](1);
        scales[0] = 1e18;

        PerpMultiCalls shortManager = new PerpMultiCalls();
        Vault shortVault = new Vault(address(shortManager), 100, coins, thresholds, thresholds, scales);
        shortManager.initializeAddresses(address(perpPair), address(shortVault));
        shortVault.initializeParameters(address(perpPair), address(new LostAndFound()));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory shortDeadlines = new uint256[](1);
        shortDeadlines[0] = block.timestamp + 1000;

        // The bundle must stop at the allowance check: no transfer may be attempted at all.
        vm.expectCall(address(shortToken), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.prank(user);
        vm.expectRevert(bytes("Insufficient allowance"));
        shortManager.addCollateralAddLiquidity(
            amounts,
            0,
            0,
            maxUserLiquidityFee,
            fakeReport,
            shortDeadlines,
            new uint8[](1),
            new bytes32[](1),
            new bytes32[](1)
        );
    }
}
