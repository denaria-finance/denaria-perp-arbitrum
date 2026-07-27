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

/// @title Vault claim accounting with a skewed multi-stablecoin mix
/// @notice The single-stablecoin regressions cannot distinguish the seeded mix from any other
///         value: with one coin every ratio collapses to `ratioDecimals`. These tests run a
///         two-coin vault with a deliberately skewed mix so the seeded and preserved ratios carry
///         real information — the claim must open at the vault's actual composition, and a drain
///         must preserve exactly that composition for the residual.
contract VaultMultiStableClaimTest is Test {
    uint256 internal constant RATIO_DECIMALS = 1e8;

    address internal masterMinter = makeAddr("masterMinter");
    address internal pauser = makeAddr("pauser");
    address internal blacklister = makeAddr("blacklister");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal claimant = makeAddr("claimant");
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");

    FiatTokenV2 internal coinA; // 18 decimals
    FiatTokenV2 internal coinB; // 18 decimals, second leg of the mix
    Vault internal vault;
    LostAndFound internal lostAndFound;
    TestPriceProvider internal oracle;
    PerpMultiCalls internal multiCallManager;
    PerpPair internal perpPair;

    bytes internal fakeReport;

    function setUp() public {
        coinA = _newToken();
        coinB = _newToken();

        address[] memory coins = new address[](2);
        coins[0] = address(coinA);
        coins[1] = address(coinB);
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1000 * RATIO_DECIMALS;
        thresholds[1] = 1000 * RATIO_DECIMALS;
        uint256[] memory scales = new uint256[](2);
        scales[0] = 1e18;
        scales[1] = 1e18;

        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(address(multiCallManager), 100, coins, thresholds, thresholds, scales);
        perpPair = new PerpPair(
            address(oracle),
            address(vault),
            address(multiCallManager),
            38 * 1e6 / 1000,
            bytes32(0),
            uint32(5e4),
            uint32(5e5),
            protocolFeeRecipient,
            1e15,
            1e17,
            1e8 * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));

        lostAndFound = new LostAndFound();
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        oracle.setPrice(100 * 1e8);

        // Skew the vault: 700 of coinA and 300 of coinB, i.e. a 70/30 mix.
        _deposit(alice, 700e18, 300e18);
        assertEq(vault.totalCollateralRatio(ERC20(address(coinA))), 70 * RATIO_DECIMALS / 100);
        assertEq(vault.totalCollateralRatio(ERC20(address(coinB))), 30 * RATIO_DECIMALS / 100);
    }

    /// @dev A claim credited without a deposit opens with the vault's mix, not with the mix of the
    ///      coin that happens to be deposited next. Seeding from anything else (or not at all)
    ///      leaves the ratio sum short of `ratioDecimals`, silently under-paying the claim.
    function testZeroRatioClaimOpensAtVaultMix() public {
        uint256 claim = 100e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(claimant, claim, true);

        assertEq(vault.userCollateralRatio(claimant, ERC20(address(coinA))), 0);
        assertEq(vault.userCollateralRatio(claimant, ERC20(address(coinB))), 0);

        // Deposit exclusively coinB on top of the claim.
        uint256 deposit = 10e18;
        _deposit(claimant, 0, deposit);

        uint256 ratioA = vault.userCollateralRatio(claimant, ERC20(address(coinA)));
        uint256 ratioB = vault.userCollateralRatio(claimant, ERC20(address(coinB)));

        // Expected: the claim opens at 70/30, then the coinB deposit is blended in.
        uint256 total = claim + deposit;
        assertEq(ratioA, (claim * 70 / 100) * RATIO_DECIMALS / total);
        assertEq(ratioB, (claim * 30 / 100 + deposit) * RATIO_DECIMALS / total);

        // The ratios must account for the whole balance, not just the deposit.
        assertApproxEqAbs(ratioA + ratioB, RATIO_DECIMALS, 2, "claim lost from the ratio mix");
        assertEq(vault.userCollateral(claimant), total);
    }

    /// @dev Without seeding, the ratios would describe only the fresh deposit, so the pre-existing
    ///      claim would be unwithdrawable. Prove the full balance is actually payable.
    function testSeededClaimIsFullyWithdrawable() public {
        uint256 claim = 100e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(claimant, claim, true);
        _deposit(claimant, 0, 10e18);

        uint256 deposit = 10e18;
        uint256 expected = claim + deposit;
        vm.prank(claimant);
        vault.removeAllCollateral(fakeReport);

        uint256 paid = coinA.balanceOf(claimant) + coinB.balanceOf(claimant);
        // Ratios are stored at 1e8 precision, so a payout loses at most one floor-division step
        // per coin. Without the seeding the shortfall would be the whole claim, not this dust.
        uint256 ratioDust = 2 * expected / RATIO_DECIMALS + 2;
        assertApproxEqAbs(paid, expected, ratioDust, "claim not fully paid");
        assertGt(paid, deposit * 2, "payout collapsed to the fresh deposit");
        assertEq(vault.userCollateral(claimant), 0);
    }

    /// @dev A drain that exhausts vault backing but not the claim must preserve the residual AND
    ///      the mix it was opened at — zeroing the ratios would strand the residual permanently.
    function testDrainPreservesResidualClaimAndItsMix() public {
        uint256 backing = 1000e18; // exactly what alice deposited
        uint256 claim = 1200e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(claimant, claim, true);

        vm.prank(claimant);
        vault.removeCollateral(backing, fakeReport);

        assertEq(vault.totalCollateral(), 0);
        assertEq(vault.userCollateral(claimant), claim - backing);
        // Preserved at the vault mix the claim was seeded from, not reset and not re-read from the
        // just-zeroed global ratios.
        assertEq(vault.userCollateralRatio(claimant, ERC20(address(coinA))), 70 * RATIO_DECIMALS / 100);
        assertEq(vault.userCollateralRatio(claimant, ERC20(address(coinB))), 30 * RATIO_DECIMALS / 100);
        assertEq(coinA.balanceOf(address(vault)), 0);
        assertEq(coinB.balanceOf(address(vault)), 0);
    }

    /// @dev The preserved residual is payable in the same proportions once backing returns.
    function testPreservedResidualPaidAtItsOwnMixAfterRefill() public {
        uint256 backing = 1000e18;
        uint256 claim = 1200e18;
        vm.prank(address(perpPair));
        vault.addPnlToCollateral(claimant, claim, true);

        vm.prank(claimant);
        vault.removeCollateral(backing, fakeReport);

        uint256 residual = claim - backing; // 200e18
        _deposit(alice, residual * 70 / 100, residual * 30 / 100);

        uint256 aBefore = coinA.balanceOf(claimant);
        uint256 bBefore = coinB.balanceOf(claimant);
        vm.prank(claimant);
        vault.removeAllCollateral(fakeReport);

        assertEq(coinA.balanceOf(claimant) - aBefore, residual * 70 / 100);
        assertEq(coinB.balanceOf(claimant) - bBefore, residual * 30 / 100);
        assertEq(vault.userCollateral(claimant), 0);
    }

    /// @dev Generalises the class: after any deposit the user's per-coin ratios must account for
    ///      the whole balance, pre-existing claim included (floor division costs at most one wei
    ///      per coin).
    function testFuzz_depositOnClaimKeepsRatiosComplete(uint96 claim, uint96 depositA, uint96 depositB) public {
        claim = uint96(bound(claim, 1e15, 1e24));
        depositA = uint96(bound(depositA, 0, 1e24));
        depositB = uint96(bound(depositB, 1e15, 1e24));

        vm.prank(address(perpPair));
        vault.addPnlToCollateral(claimant, claim, true);
        _deposit(claimant, depositA, depositB);

        uint256 ratioSum = vault.userCollateralRatio(claimant, ERC20(address(coinA)))
            + vault.userCollateralRatio(claimant, ERC20(address(coinB)));
        assertApproxEqAbs(ratioSum, RATIO_DECIMALS, 2, "ratios do not cover the whole balance");
        assertEq(vault.userCollateral(claimant), uint256(claim) + depositA + depositB);
    }

    function _newToken() private returns (FiatTokenV2 token) {
        token = new FiatTokenV2();
        token.initialize("USDCe", "USDC.e", "USD", 18, masterMinter, pauser, blacklister, owner);
        token.initializeV2("USDCe");
        vm.prank(masterMinter);
        token.configureMinter(masterMinter, type(uint256).max);
    }

    function _deposit(address user, uint256 amountA, uint256 amountB) private {
        if (amountA > 0) {
            vm.prank(masterMinter);
            coinA.mint(user, amountA);
        }
        if (amountB > 0) {
            vm.prank(masterMinter);
            coinB.mint(user, amountB);
        }
        vm.startPrank(user);
        coinA.approve(address(vault), type(uint256).max);
        coinB.approve(address(vault), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        vault.addCollateral(amounts);
        vm.stopPrank();
    }
}
