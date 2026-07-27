// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { FiatTokenV2 } from "../src/token/USDCe.sol";
import { TestPriceProvider } from "../src/test_support/TestPriceProvider.sol";
import { PerpMultiCalls } from "../src/manager/multiCallManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Vault claim-preservation regressions
/// @notice Two accounting states the vault must not destroy:
///         (1) a positive balance credited without a deposit (realized fees or PnL) has no
///             stablecoin mix yet — blending a later deposit against an all-zero mix would drop
///             the pre-existing claim, so the vault mix is seeded first;
///         (2) a withdrawal that drains the vault's current backing but not the user's full claim
///             must keep the residual `userCollateral` and its ratios, otherwise the unbacked part
///             of the claim is silently confiscated instead of surviving until a refill.
contract VaultSingleStableRegressionTest is Test {
    uint256 internal constant RATIO_DECIMALS = 1e8;
    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 internal constant MMR_DECIMALS = 1e6;

    address internal masterMinter = makeAddr("masterMinter");
    address internal pauser = makeAddr("pauser");
    address internal blacklister = makeAddr("blacklister");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");

    FiatTokenV2 internal stableCoin;
    TestPriceProvider internal oracle;
    PerpMultiCalls internal multiCallManager;
    Vault internal vault;
    PerpPair internal perpPair;
    LostAndFound internal lostAndFound;

    bytes internal fakeReport;

    function setUp() public {
        stableCoin = new FiatTokenV2();
        stableCoin.initialize("USDCe", "USDC.e", "USD", 18, masterMinter, pauser, blacklister, owner);
        vm.prank(masterMinter);
        stableCoin.configureMinter(masterMinter, type(uint256).max);

        address[] memory stableCoins = new address[](1);
        stableCoins[0] = address(stableCoin);

        uint256[] memory depositThresholds = new uint256[](1);
        depositThresholds[0] = 1000 * RATIO_DECIMALS;

        uint256[] memory withdrawalThresholds = new uint256[](1);
        withdrawalThresholds[0] = 1000 * RATIO_DECIMALS;

        uint256[] memory stableDecimals = new uint256[](1);
        stableDecimals[0] = 1e18;

        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(
            address(multiCallManager), 100, stableCoins, depositThresholds, withdrawalThresholds, stableDecimals
        );
        perpPair = new PerpPair(
            address(oracle),
            address(vault),
            address(multiCallManager),
            38 * MMR_DECIMALS / 1000,
            bytes32(0),
            uint32(5e4),
            uint32(5e5),
            protocolFeeRecipient,
            1e15,
            1e17,
            ORACLE_DECIMALS * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));

        lostAndFound = new LostAndFound();
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        oracle.setPrice(100 * ORACLE_DECIMALS);
    }

    function testDepositPreservesExistingZeroRatioFeeClaim() public {
        _deposit(alice, 1000e18);

        uint256 feeClaim = 10e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(feeRecipient, feeClaim, true);

        assertEq(vault.userCollateral(feeRecipient), feeClaim);
        assertEq(vault.userCollateralRatio(feeRecipient, ERC20(address(stableCoin))), 0);

        uint256 freshDeposit = 1e18;
        _deposit(feeRecipient, freshDeposit);

        assertEq(vault.userCollateral(feeRecipient), feeClaim + freshDeposit);
        assertEq(vault.userCollateralRatio(feeRecipient, ERC20(address(stableCoin))), RATIO_DECIMALS);

        uint256 balanceBefore = stableCoin.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.removeAllCollateral(fakeReport);

        assertEq(stableCoin.balanceOf(feeRecipient) - balanceBefore, feeClaim + freshDeposit);
        assertEq(vault.userCollateral(feeRecipient), 0);
    }

    function testExactVaultDrainPreservesUnderbackedResidualClaim() public {
        uint256 backing = 1000e18;
        _deposit(alice, backing);

        uint256 userClaim = 1100e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(feeRecipient, userClaim, true);

        vm.expectRevert(bytes("RC3"));
        vm.prank(feeRecipient);
        vault.removeAllCollateral(fakeReport);

        uint256 balanceBefore = stableCoin.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.removeCollateral(backing, fakeReport);

        assertEq(stableCoin.balanceOf(feeRecipient) - balanceBefore, backing);
        assertEq(stableCoin.balanceOf(address(vault)), 0);
        assertEq(vault.totalCollateral(), 0);
        assertEq(vault.userCollateral(feeRecipient), userClaim - backing);
        assertEq(vault.userCollateralRatio(feeRecipient, ERC20(address(stableCoin))), RATIO_DECIMALS);
    }

    /// @dev The residual claim must be payable once backing returns: a refill after the drain
    ///      lets the user withdraw exactly what was preserved above.
    function testPreservedResidualClaimIsPayableAfterRefill() public {
        uint256 backing = 1000e18;
        _deposit(alice, backing);

        uint256 userClaim = 1100e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(feeRecipient, userClaim, true);

        vm.prank(feeRecipient);
        vault.removeCollateral(backing, fakeReport);

        uint256 residual = userClaim - backing;
        _deposit(alice, residual);

        uint256 balanceBefore = stableCoin.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.removeAllCollateral(fakeReport);

        assertEq(stableCoin.balanceOf(feeRecipient) - balanceBefore, residual);
        assertEq(vault.userCollateral(feeRecipient), 0);
    }

    /// @dev A full drain that also exhausts the user's own claim still clears their ratios.
    function testFullDrainOfOwnClaimClearsRatios() public {
        uint256 deposited = 1000e18;
        _deposit(alice, deposited);

        vm.prank(alice);
        vault.removeCollateral(deposited, fakeReport);

        assertEq(vault.userCollateral(alice), 0);
        assertEq(vault.userCollateralRatio(alice, ERC20(address(stableCoin))), 0);
        assertEq(vault.totalCollateral(), 0);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(masterMinter);
        stableCoin.mint(user, amount);

        vm.prank(user);
        stableCoin.approve(address(vault), type(uint256).max);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(user);
        vault.addCollateral(amounts);
    }
}
