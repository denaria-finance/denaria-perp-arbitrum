// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import "../src/token/USDCe.sol";
import "../src/util/UtilMath.sol";
import "../src/test_support/TestPriceProvider.sol";
import "../src/manager/multiCallManager.sol";
import "../src/interfaces/IPerpPair.sol";
import "../src/manager/callBatcher.sol";
import "./helpers/PerpPairTestDeploymentHelper.sol";

contract PerpPairBatchLiquidationHelperTest is Test, PerpPairTestDeploymentHelper {
    uint256 constant MAX_UINT = type(uint256).max;

    Vault public vault;
    PerpPair public perpPair;
    LostAndFound public lostAndFound;
    PerpMultiCalls public multiCallManager;
    TestPriceProvider public oracle;
    CallBatcher public batcher;

    // params (mirrored from your main test)
    uint256 public MMRDecimals = 1e6;
    uint256 public MMR = 38 * MMRDecimals / 1000;
    uint32 public feeFractionDecimals = 1e6;
    uint32 public feeFrontend = 5 * feeFractionDecimals / 100;
    address public frontendAddress = makeAddr("frontend");
    uint32 public feeLP = 5 * feeFractionDecimals / 10;
    address public feeProtocolAddr = makeAddr("denaria");
    uint256 public tradingFeeDecimals = 1e18;
    uint256 public tradingFee = 1 * tradingFeeDecimals / 1000;
    uint256 public flatTradingFee = 1e17;
    uint256 public oracleDecimals = 1e8;
    uint256 public ratioDecimals = 1e8;
    uint256 public maxUserLiquidityFee = 1e30;

    string public tokenName = "USDCe";
    string public tokenSymbol = "USDC.e";
    string public tokenCurrency = "USD";

    address public MasterMinter = makeAddr("Megamind");
    address public Pauser = makeAddr("Megamind");
    address public Blacklister = makeAddr("Megamind");
    address public Owner = makeAddr("Megamind");

    bytes public fakeReport;

    address[] public stableCoins;
    uint256[] public depositThresholds;
    uint256[] public withdrowalThresholds;
    uint256[] public stableDecimals;

    function setUp() public {
        uint256 numStableCoins = 2;
        FiatTokenV2 stablecoin;

        uint8[2] memory tokenDecs = [6, 18];
        for (uint256 i; i < numStableCoins; i++) {
            stablecoin = new FiatTokenV2();
            stablecoin.initialize(
                tokenName, tokenSymbol, tokenCurrency, tokenDecs[i], MasterMinter, Pauser, Blacklister, Owner
            );
            vm.prank(MasterMinter);
            stablecoin.configureMinter(MasterMinter, 1e30);

            stableCoins.push(address(stablecoin));
            depositThresholds.push(1 * ratioDecimals);
            withdrowalThresholds.push(1 * ratioDecimals);
        }
        stableDecimals.push(1e6);
        stableDecimals.push(1e18);

        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(
            address(multiCallManager),
            address(oracle),
            100,
            stableCoins,
            depositThresholds,
            withdrowalThresholds,
            stableDecimals
        );

        perpPair = _deployPerpPairForTest(
            address(oracle),
            address(vault),
            address(multiCallManager),
            MMR,
            "", // tickerAsset
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );

        multiCallManager.initializeAddresses(address(perpPair), address(vault));
        lostAndFound = new LostAndFound();
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        _restoreTestEraParameters(
            perpPair, address(oracle), feeFrontend, feeProtocolAddr, MMR, tradingFee, flatTradingFee, feeLP
        );

        batcher = new CallBatcher();

        // --- basic collateral setup for a few users ---
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address liquidator = makeAddr("liquidator");

        // approve vault
        vm.prank(alice);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(alice);
        coinB.approve(address(vault), MAX_UINT);
        vm.prank(bob);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(bob);
        coinB.approve(address(vault), MAX_UINT);
        vm.prank(charlie);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(charlie);
        coinB.approve(address(vault), MAX_UINT);
        vm.prank(liquidator);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(liquidator);
        coinB.approve(address(vault), MAX_UINT);

        // mint and deposit some collateral
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = liquidator;

        uint256[] memory amounts = new uint256[](4);

        // coinA (6 decimals)
        amounts[0] = 10_000_000 * 1e6;
        amounts[1] = 10_000_000 * 1e6;
        amounts[2] = 10_000_000 * 1e6;
        amounts[3] = 10_000_000 * 1e6;
        mint(stableCoins[0], users, amounts);

        // coinB (18 decimals)
        amounts[0] = 10_000_000 * 1e18;
        amounts[1] = 10_000_000 * 1e18;
        amounts[2] = 10_000_000 * 1e18;
        amounts[3] = 10_000_000 * 1e18;
        mint(stableCoins[1], users, amounts);

        // deposit collateral into vault (simple equal deposits)
        amounts = new uint256[](2);
        amounts[0] = 1_000_000 * 1e6;
        amounts[1] = 1_000_000 * 1e18;

        vm.prank(alice);
        vault.addCollateral(amounts);
    }

    /// @dev simple sanity test: batchLiquidate two long traders, their MR improves and the liquidator gets a position
    function testBatchLiquidateTwoLongTraders() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        skip(400);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        // Alice provides liquidity
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);
        vm.prank(charlie);
        vault.addCollateral(amounts);

        skip(400);
        // Both open the same long trade
        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        vm.prank(charlie);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        // Price goes down → they become liquidatable
        uint256 newPrice = 100;
        oracle.setPrice(newPrice * oracleDecimals);

        skip(4_000_000);
        uint256 marginBeforeBob = UtilMath.calcMR(
            bob,
            newPrice * oracleDecimals,
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        uint256 marginBeforeCharlie = UtilMath.calcMR(
            charlie,
            newPrice * oracleDecimals,
            address(perpPair),
            perpPair.getCollateral(charlie),
            perpPair.lastOperationTimestamp()
        );

        skip(400);
        // Prepare batch call
        address liquidator = makeAddr("liquidator");

        (, uint256 bobAssetBalance,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        (, uint256 charlieAssetBalance,,,,,,) = perpPair.userVirtualTraderPosition(charlie);

        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = charlie;

        uint256[] memory sizes = new uint256[](2);
        sizes[0] = bobAssetBalance;
        sizes[1] = charlieAssetBalance;

        skip(400);
        amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 10_000_000 * 1e18;
        vm.prank(liquidator);
        vault.addCollateral(amounts);

        // Call your helper
        vm.prank(liquidator);
        multiCallManager.batchLiquidate(users, sizes, fakeReport);

        skip(400);
        // Margin ratios should improve after liquidation
        uint256 marginAfterBob = UtilMath.calcMR(
            bob,
            newPrice * oracleDecimals,
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        uint256 marginAfterCharlie = UtilMath.calcMR(
            charlie,
            newPrice * oracleDecimals,
            address(perpPair),
            perpPair.getCollateral(charlie),
            perpPair.lastOperationTimestamp()
        );

        assertTrue(marginAfterBob > marginBeforeBob, "Bob MR did not improve after batch liquidation");
        assertTrue(marginAfterCharlie > marginBeforeCharlie, "Charlie MR did not improve after batch liquidation");

        // Liquidator should have received some position
        (uint256 liqStableBal, uint256 liqAssetBal, uint256 liqStableDebt, uint256 liqAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(liquidator);

        assertTrue(
            liqStableBal > 0 || liqAssetBal > 0 || liqStableDebt > 0 || liqAssetDebt > 0,
            "Liquidator did not receive any position in batchLiquidate"
        );

        uint256[] memory batchMR = batcher.batchCalcMR(users, 100e8, address(perpPair));
        CallBatcher.VirtualTraderPosition[] memory pos =
            batcher.batchUserVirtualTraderPosition(users, address(perpPair));
        CallBatcher.LiquidityPosition[] memory lp = batcher.batchLiquidityPosition(users, address(perpPair));

        console.log(batchMR[0], batchMR[1]);
    }

    // ========= support functions (copied style from your main test) =========

    function mint(address stableCoin, address[] memory addresses, uint256[] memory amounts) internal {
        require(addresses.length == amounts.length, "different length of addresses and amounts");
        for (uint256 i = 0; i < addresses.length; i++) {
            _mint(stableCoin, addresses[i], amounts[i]);
        }
    }

    function _mint(address stableCoin, address user, uint256 amount) internal {
        vm.prank(MasterMinter);
        FiatTokenV2(stableCoin).mint(user, amount);
    }
}
