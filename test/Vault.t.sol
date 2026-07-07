// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import { IPerpPair } from "../src/interfaces/IPerpPair.sol";
import { IOracleMiddleware } from "../src/CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import "../src/token/USDCe.sol";
import "../src/util/CurveMath.sol";
import "../src/util/MatrixMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/test_support/TestPriceProvider.sol";
import "../src/manager/multiCallManager.sol";
import "./helpers/PerpPairTestDeploymentHelper.sol";

contract VaultTest is Test, PerpPairTestDeploymentHelper {
    uint256 MAX_UINT = 2 ** 256 - 1;
    address[] public stableCoins;
    uint256[] public depositThresholds;
    uint256[] public withdrowalThresholds;
    uint256[] public stableDecimals;
    uint256 public numStableCoins = 2;
    Vault public vault;
    PerpPair public perpPair;
    LostAndFound public lostAndFound;
    PerpMultiCalls public multiCallManager;
    uint256 public MMRDecimals = 1e6;
    uint256 public MMR = 38 * MMRDecimals / 1000;
    bytes32 public tickerAsset;
    string public tickerCurrency;
    uint256 public tradingFeeDecimals = 1e18;
    uint32 public feeFractionDecimals = 1e6;
    uint32 public feeFrontend = 5 * feeFractionDecimals / 100;
    address public frontendAddress = makeAddr("frontend");
    uint32 public feeLP = 5 * feeFractionDecimals / 10;
    address public feeProtocolAddr = makeAddr("denaria");
    uint256 public tradingFee = 1 * tradingFeeDecimals / 1000;
    uint256 public flatTradingFee = 1e17;
    uint256 public clampFundRate;
    TestPriceProvider public oracle;
    uint256 public oracleDecimals = 1e8;
    uint256 public currencyDecimals = 1e18;
    string public tokenName = "USDCe";
    string public tokenSymbol = "USDC.e";
    string public tokenCurrency = "USD";
    uint256 public collateralDecimals = 10 ** 18;
    uint256 public ratioDecimals = 1e8;
    bytes public fakeReportData;
    uint256 public maxUserLiquidityFee = 1e30;

    address public MasterMinter = makeAddr("Megamind");
    address public Pauser = makeAddr("Megamind");
    address public Blacklister = makeAddr("Megamind");
    address public Owner = makeAddr("Megamind");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public donkey = makeAddr("donkey");
    address public eve = makeAddr("eve");
    address public farquaad = makeAddr("farquaad");
    uint256 startingStableAmount = 10_000_000;

    event DebugEvent(uint256);

    function setUp() public {
        FiatTokenV2 stablecoin;

        uint8[2] memory tokenDecimals = [6, 18];
        for (uint256 i; i < numStableCoins; i++) {
            stablecoin = new FiatTokenV2();
            stablecoin.initialize(
                tokenName, tokenSymbol, tokenCurrency, tokenDecimals[i], MasterMinter, Pauser, Blacklister, Owner
            );
            vm.prank(MasterMinter);
            stablecoin.configureMinter(MasterMinter, 1e30);
            stableCoins.push(address(stablecoin));
            depositThresholds.push(1 * ratioDecimals);
            withdrowalThresholds.push(1 * ratioDecimals / 10);
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
            tickerAsset,
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));

        lostAndFound = new LostAndFound();
        console.log(lostAndFound.hasRole(bytes32(0), address(this)));
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        _restoreTestEraParameters(
            perpPair, address(oracle), feeFrontend, feeProtocolAddr, MMR, tradingFee, flatTradingFee, feeLP
        );
        oracle.setPrice(100 * oracleDecimals);

        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

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
        vm.prank(donkey);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(donkey);
        coinB.approve(address(vault), MAX_UINT);
        vm.prank(eve);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(eve);
        coinB.approve(address(vault), MAX_UINT);
        vm.prank(farquaad);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(farquaad);
        coinB.approve(address(vault), MAX_UINT);

        address[] memory users = new address[](6);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = donkey;
        users[4] = eve;
        users[5] = farquaad;

        uint256[] memory amounts = new uint256[](6);
        amounts[0] = startingStableAmount * 1e6;
        amounts[1] = startingStableAmount * 1e6;
        amounts[2] = startingStableAmount * 1e6;
        amounts[3] = startingStableAmount * 1e6;
        amounts[4] = startingStableAmount * 1e6;
        amounts[5] = startingStableAmount * 1e6;
        mint(stableCoins[0], users, amounts);

        amounts[0] = startingStableAmount * 1e18;
        amounts[1] = startingStableAmount * 1e18;
        amounts[2] = startingStableAmount * 1e18;
        amounts[3] = startingStableAmount * 1e18;
        amounts[4] = startingStableAmount * 1e18;
        amounts[5] = startingStableAmount * 1e18;
        mint(stableCoins[1], users, amounts);
    }

    ///@dev Test minting support function
    function testMinting() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 * 1e6;

        mint(stableCoins[0], users, amounts);

        (ERC20 coin,,,) = vault.stableCoins(0);

        assertTrue(
            coin.totalSupply() == 1000 * 1e6 + startingStableAmount * 6 * 1e6
                && coin.balanceOf(alice) == 1000 * 1e6 + startingStableAmount * 1e6,
            "Mint error"
        );
    }

    ///@dev Tests the AddCollateral function. Two users deposit collateral in two stablecoins
    function testAddCollateral() public {
        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 6000 * 1e18;
        vm.startSnapshotGas("compute");
        vm.prank(alice);
        vault.addCollateral(amounts);
        uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        console.log("addCollateral: ", used);

        amounts[0] = 1000 * 1e6;
        amounts[1] = 4000 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);

        assertTrue(vault.totalCollateral() == 15_000 * collateralDecimals, "total collateral");
        assertTrue(
            vault.totalCollateralRatio(coinA) == 1 * ratioDecimals / 3
                && vault.totalCollateralRatio(coinB) == 2 * ratioDecimals / 3,
            "total ratios"
        );

        assertTrue(vault.userCollateral(alice) == 10_000 * collateralDecimals, "alice collateral in vault");
        assertTrue(
            vault.userCollateralRatio(alice, coinA) == 4 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinB) == 6 * ratioDecimals / 10,
            "alice ratios"
        );

        assertTrue(vault.userCollateral(bob) == 5000 * collateralDecimals, "bob collateral in vault");
        assertTrue(
            vault.userCollateralRatio(bob, coinA) == 2 * ratioDecimals / 10
                && vault.userCollateralRatio(bob, coinB) == 8 * ratioDecimals / 10,
            "bob ratios"
        );
    }

    ///@dev Tests removal of collateral where the inital ratio of stablecoins of the user is allowed.
    function testRemoveCollateralInitialRatio() public {
        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 6000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        amounts[0] = 2000 * 1e6;
        amounts[1] = 3000 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);

        vm.prank(alice);
        vault.removeCollateral(5000 * 1e18, fakeReportData);

        vm.prank(bob);
        vault.removeCollateral(5000 * 1e18, fakeReportData);

        assertTrue(vault.totalCollateral() == 5000 * collateralDecimals, "total collateral");
        assertTrue(
            inConfidenceInterval(vault.totalCollateralRatio(coinA), 2 * ratioDecimals / 5, 100_000)
                && inConfidenceInterval(vault.totalCollateralRatio(coinB), 3 * ratioDecimals / 5, 100_000),
            "total ratios"
        );
    }

    ///@dev Tests removal of collateral where the inital ratio of stablecoins of the user is not allowed and the vault ratio is used.
    function testRemoveCollateralVaultRatio() public {
        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 1000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        amounts[0] = 1000 * 1e6;
        amounts[1] = 4000 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);

        vm.prank(bob);
        vault.removeCollateral(4000 * 1e18, fakeReportData);

        assertTrue(vault.totalCollateral() == 6000 * collateralDecimals, "total collateral");
        assertTrue(
            inConfidenceInterval(vault.totalCollateralRatio(coinA), 1 * ratioDecimals / 2, 100_000)
                && inConfidenceInterval(vault.totalCollateralRatio(coinB), 1 * ratioDecimals / 2, 100_000),
            "total ratios"
        );
        assertTrue(
            inConfidenceInterval(vault.userCollateralRatio(bob, coinA), 0, 100_000)
                && inConfidenceInterval(vault.userCollateralRatio(bob, coinB), 1 * ratioDecimals, 100_000),
            "user ratios"
        );
    }

    ///@dev Tests remove collateral when called with more stable than available.
    function testRemoveCollateralMoreThanTotal() public {
        uint256[] memory amounts = new uint256[](numStableCoins);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 6000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        amounts[0] = 1000 * 1e6;
        amounts[1] = 4000 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);

        vm.expectRevert(bytes("RC1"));
        vm.prank(alice);
        vault.removeCollateral(16_000 * 1e18, fakeReportData);

        //vault._setTotalCollateral(2000 * 1e18);
        //vm.expectRevert(bytes("RC3"));
        //vm.prank(alice);
        //vault.removeCollateral(3000 * 1e18, fakeReportData);
    }

    //withdraw going under MMR
    ///@dev Test remove collateral safeguard that prevents from removing collateral resulting in liquidation.
    function testRemoveCollateralRevertMMR() public {
        oracle.setPrice(100 * oracleDecimals);

        uint256[] memory amounts = new uint256[](numStableCoins);
        amounts[0] = startingStableAmount * 1e6;
        amounts[1] = startingStableAmount * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);
        uint256 aliceLiquidityStable = 100_000 * 1e18;
        uint256 aliceLiquidityAsset = 1000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReportData);

        amounts[0] = 25 * 1e6;
        amounts[1] = 25 * 1e18;
        vm.prank(bob);
        vault.addCollateral(amounts);
        uint256 tradeSize = 1000 * 1e18;

        uint256 a = UtilMath.calcMR(
            bob, 100 * oracleDecimals, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        console.log(a);

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 0, aliceLiquidityAsset, frontendAddress, 1, fakeReportData);

        skip(20_000);

        a = UtilMath.calcMR(
            bob, 100 * oracleDecimals, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        console.log(a);

        vm.expectRevert();
        vm.prank(bob);
        vault.removeCollateral(1 * 1e18, fakeReportData);
    }

    //close & withdraw tests
    //positive pnl close and withdraw
    ///@dev Test close and withdraw in profit from the vault's prespective.
    function testCloseAndWithdrawProfit() public {
        oracle.setPrice(100 * oracleDecimals);

        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        uint256[] memory collat = new uint256[](numStableCoins);
        collat[0] = startingStableAmount * stableDecimals[0];
        collat[1] = startingStableAmount * stableDecimals[1];

        vm.prank(alice);
        vault.addCollateral(collat);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReportData);

        uint256 tradeSize = 1000 * 1e18;

        collat = new uint256[](2);
        collat[0] = 250 * stableDecimals[0];
        collat[1] = 250 * stableDecimals[1];

        vm.prank(bob);
        vault.addCollateral(collat);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 0, aliceLiquidityAsset, frontendAddress, 1, fakeReportData);

        oracle.setPrice(110 * oracleDecimals);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReportData);

        uint256 finalCollat = vault.userCollateral(bob);
        vm.prank(bob);
        vault.removeCollateral(finalCollat, fakeReportData);
        assertTrue(
            inConfidenceInterval(finalCollat, 500 * 1e18 + tradeSize * 1 / 10 - tradeSize * 2 / 1000, 100),
            "final profit"
        );
    }

    //negative pnl close and withdraw
    ///@dev Test close and withdraw in loss from the vault's prespective.
    function testCloseAndWithdrawLoss() public {
        oracle.setPrice(100 * oracleDecimals);

        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        uint256[] memory collat = new uint256[](numStableCoins);
        collat[0] = startingStableAmount * stableDecimals[0];
        collat[1] = startingStableAmount * stableDecimals[1];

        vm.prank(alice);
        vault.addCollateral(collat);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReportData);

        uint256 tradeSize = 1000 * 1e18;

        collat = new uint256[](2);
        collat[0] = 250 * stableDecimals[0];
        collat[1] = 250 * stableDecimals[1];

        vm.prank(bob);
        vault.addCollateral(collat);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 0, aliceLiquidityAsset, frontendAddress, 1, fakeReportData);

        oracle.setPrice(90 * oracleDecimals);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReportData);

        uint256 finalCollat = vault.userCollateral(bob);
        vm.prank(bob);
        vault.removeCollateral(finalCollat, fakeReportData);
        assertTrue(
            inConfidenceInterval(finalCollat, 500 * 1e18 - tradeSize * 1 / 10 - tradeSize * 2 / 1000, 100), "final loss"
        );
    }

    //one sided collateral
    ///@dev Test close and withdraw in profit with a user that deposited only one kind of collateral.
    function testCloseAndWithdrawProfitOneSided() public {
        oracle.setPrice(100 * oracleDecimals);

        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        uint256[] memory collat = new uint256[](numStableCoins);
        collat[0] = startingStableAmount * stableDecimals[0];

        vm.prank(alice);
        vault.addCollateral(collat);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReportData);

        uint256 tradeSize = 1000 * 1e18;

        collat = new uint256[](2);
        collat[0] = 250 * stableDecimals[0];
        collat[1] = 250 * stableDecimals[1];

        vm.prank(bob);
        vault.addCollateral(collat);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 0, aliceLiquidityAsset, frontendAddress, 1, fakeReportData);

        oracle.setPrice(110 * oracleDecimals);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReportData);

        uint256 finalCollat = vault.userCollateral(bob);
        vm.prank(bob);
        vault.removeCollateral(finalCollat, fakeReportData);
        assertTrue(
            inConfidenceInterval(finalCollat, 500 * 1e18 + tradeSize * 1 / 10 - tradeSize * 2 / 1000, 100),
            "final profit"
        );
    }

    //fee address close and withdraw
    ///@dev Test frontend fee withdrawal.
    function testCloseAndWithdrawProtocolFrontendFee() public {
        oracle.setPrice(100 * oracleDecimals);

        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        uint256[] memory collat = new uint256[](numStableCoins);
        collat[0] = startingStableAmount * stableDecimals[0];
        collat[1] = startingStableAmount * stableDecimals[1];

        vm.prank(alice);
        vault.addCollateral(collat);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReportData);

        uint256 tradeSize = 1000 * 1e18;

        collat = new uint256[](2);
        collat[0] = 2500 * stableDecimals[0];
        collat[1] = 2500 * stableDecimals[1];

        vm.startPrank(bob);
        vault.addCollateral(collat);
        perpPair.trade(true, tradeSize, 0, perpPair.globalLiquidityAsset(), frontendAddress, 1, fakeReportData);
        perpPair.trade(
            false, 2 * tradeSize / 100, 0, perpPair.globalLiquidityStable(), frontendAddress, 1, fakeReportData
        );
        perpPair.trade(true, 3 * tradeSize, 0, perpPair.globalLiquidityAsset(), frontendAddress, 1, fakeReportData);
        perpPair.trade(false, tradeSize / 100, 0, perpPair.globalLiquidityStable(), frontendAddress, 1, fakeReportData);
        vm.stopPrank();

        vm.prank(frontendAddress);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReportData);

        uint256 frontend = vault.userCollateral(frontendAddress);
        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        vm.prank(frontendAddress);
        vault.removeCollateral(frontend, fakeReportData);
        assertTrue(
            inConfidenceInterval(
                frontend,
                (tradeSize * 7 * tradingFee / tradingFeeDecimals + flatFee * 4) * feeFrontend / feeFractionDecimals,
                10_000
            ),
            "frontend profit"
        );

        vm.prank(feeProtocolAddr);
        perpPair.closeAndWithdraw(1e5, 1e10, feeProtocolAddr, fakeReportData);
        uint256 protocol = vault.userCollateral(feeProtocolAddr);
        vm.prank(feeProtocolAddr);
        vault.removeCollateral(protocol, fakeReportData);
        assertTrue(
            inConfidenceInterval(
                protocol,
                (tradeSize * 7 * tradingFee / tradingFeeDecimals + flatFee * 4)
                    * (feeFractionDecimals - feeLP - feeFrontend) / feeFractionDecimals,
                10_000
            ),
            "protocol profit"
        );
    }

    ///@dev Test adding a stable coin to the allowed list
    function testAddStablecoin() public {
        vm.prank(MasterMinter);
        vault.grantRole(vault.MOD_ROLE(), MasterMinter);
        vm.prank(MasterMinter);
        vault.prepareAddStableCoin(address(0), 0, 0, 0, 1);
        skip(604_801);
        vm.prank(MasterMinter);
        vault.addStableCoin(address(0), 0, 0, 0, 1);

        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 8000 * 1e6;
        amounts[1] = 12_000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        FiatTokenV2 stablecoin = new FiatTokenV2();
        stablecoin.initialize(tokenName, tokenSymbol, tokenCurrency, 18, MasterMinter, Pauser, Blacklister, Owner);
        vm.prank(MasterMinter);
        stablecoin.configureMinter(MasterMinter, 1e30);

        vm.prank(MasterMinter);
        vault.prepareAddStableCoin(address(stablecoin), 1000 * ratioDecimals, 1 * ratioDecimals / 3, 1e18, 0);
        skip(2);
        vm.prank(MasterMinter);
        vault.addStableCoin(address(stablecoin), 1000 * ratioDecimals, 1 * ratioDecimals / 3, 1e18, 0);
        vm.prank(bob);
        stablecoin.approve(address(vault), MAX_UINT);

        address[] memory users = new address[](1);
        uint256[] memory mintingAmount = new uint256[](1);
        users[0] = bob;
        mintingAmount[0] = 100_000_000 * 1e18;
        mint(address(stablecoin), users, mintingAmount);

        (ERC20 coinC,,,) = vault.stableCoins(2);

        uint256[] memory newAmounts = new uint256[](3);
        newAmounts[0] = 1000 * 1e6;
        newAmounts[1] = 3000 * 1e18;
        newAmounts[2] = 1000 * 1e18;
        vm.prank(bob);
        vault.addCollateral(newAmounts);

        assertTrue(vault.totalCollateral() == 25_000 * collateralDecimals, "total collateral");
        assertTrue(
            vault.totalCollateralRatio(coinA) == 36 * ratioDecimals / 100
                && vault.totalCollateralRatio(coinB) == 6 * ratioDecimals / 10
                && vault.totalCollateralRatio(coinC) == 4 * ratioDecimals / 100,
            "total ratios 1"
        );

        assertTrue(vault.userCollateral(alice) == 20_000 * collateralDecimals, "alice collateral in vault");
        assertTrue(
            vault.userCollateralRatio(alice, coinA) == 4 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinB) == 6 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinC) == 0,
            "alice ratios 1"
        );

        assertTrue(vault.userCollateral(bob) == 5000 * collateralDecimals, "bob collateral in vault");
        assertTrue(
            vault.userCollateralRatio(bob, coinA) == 2 * ratioDecimals / 10
                && vault.userCollateralRatio(bob, coinB) == 6 * ratioDecimals / 10
                && vault.userCollateralRatio(bob, coinC) == 2 * ratioDecimals / 10,
            "bob ratios 1"
        );

        vm.prank(bob);
        vault.removeCollateral(2500 * collateralDecimals, fakeReportData);

        assertTrue(vault.totalCollateral() == 22_500 * collateralDecimals, "total collateral after removal");
        assertTrue(
            vault.totalCollateralRatio(coinA) == 36 * ratioDecimals / 100
                && vault.totalCollateralRatio(coinB) == 6 * ratioDecimals / 10
                && vault.totalCollateralRatio(coinC) == 4 * ratioDecimals / 100,
            "total ratios 2"
        );

        assertTrue(
            vault.userCollateral(alice) == 20_000 * collateralDecimals, "alice collateral in vault after removal"
        );
        assertTrue(
            vault.userCollateralRatio(alice, coinA) == 4 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinB) == 6 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinC) == 0,
            "alice ratios 2"
        );

        assertTrue(vault.userCollateral(bob) == 2500 * collateralDecimals, "bob collateral in vault after removal");
        assertTrue(
            vault.userCollateralRatio(bob, coinA) == 4 * ratioDecimals / 100
                && vault.userCollateralRatio(bob, coinB) == 6 * ratioDecimals / 10
                && vault.userCollateralRatio(bob, coinC) == 36 * ratioDecimals / 100,
            "bob ratios 2"
        );
    }

    ///@dev Test withdrawing a stablecoin from a blacklisted account
    function testBlacklistedRemoval() public {
        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 6000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        vm.prank(Blacklister);
        FiatTokenV2(address(coinA)).blacklist(alice);

        vm.prank(alice);
        vault.removeCollateral(5000 * collateralDecimals, fakeReportData);

        assertTrue(vault.totalCollateral() == 5000 * collateralDecimals, "total collateral");
        assertTrue(
            vault.totalCollateralRatio(coinA) == 4 * ratioDecimals / 10
                && vault.totalCollateralRatio(coinB) == 6 * ratioDecimals / 10,
            "total ratios"
        );

        assertTrue(vault.userCollateral(alice) == 5000 * collateralDecimals, "alice collateral in vault");
        assertTrue(
            vault.userCollateralRatio(alice, coinA) == 4 * ratioDecimals / 10
                && vault.userCollateralRatio(alice, coinB) == 6 * ratioDecimals / 10,
            "alice ratios"
        );
        assertTrue(coinA.balanceOf(address(lostAndFound)) == 2000 * 1e6, "recovery balance");

        vm.prank(Blacklister);
        FiatTokenV2(address(coinA)).unBlacklist(alice);

        vm.prank(alice);
        lostAndFound.retrieveLostFunds(address(coinA), 500 * 1e6);

        assertTrue(coinA.balanceOf(address(lostAndFound)) == 1500 * 1e6, "recovery balance 2");

        vm.prank(alice);
        lostAndFound.retrieveLostFunds(address(coinA));

        assertTrue(coinA.balanceOf(address(lostAndFound)) == 0, "recovery balance 3");
    }

    function testZeroRatioRemoval() public {
        uint256[] memory amounts = new uint256[](numStableCoins);
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        amounts[0] = 400_000 * 1e6;
        amounts[1] = 600_000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        address newGuy = makeAddr("newGuy");

        vm.prank(address(perpPair));
        vault.addPnlToCollateral(newGuy, 1e16, true);

        console.log(coinA.balanceOf(newGuy), coinB.balanceOf(newGuy));
        console.log(vault.totalCollateral(), vault.userCollateral(newGuy));
        console.log(vault.userCollateralRatio(newGuy, coinA), vault.userCollateralRatio(newGuy, coinB));

        vm.prank(newGuy);
        vault.removeAllCollateral(fakeReportData);

        console.log(coinA.balanceOf(newGuy), coinB.balanceOf(newGuy));
        console.log(vault.totalCollateral(), vault.userCollateral(newGuy));
        console.log(vault.userCollateralRatio(newGuy, coinA), vault.userCollateralRatio(newGuy, coinB));

        vm.assertEq(coinA.balanceOf(newGuy) * 1e12 + coinB.balanceOf(newGuy), 1e16);
    }

    ///@dev Tests remove collateral when called with more stable than available.
    function testRemoveAllCollateral() public {
        uint256[] memory amounts = new uint256[](numStableCoins);

        amounts[0] = 4000 * 1e6;
        amounts[1] = 6000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        vm.prank(alice);
        vault.removeAllCollateral(fakeReportData);
    }

    ///@dev Test initializing multiple times the vault
    function testMultipleInitialize() public {
        vm.expectRevert("UNINIT1");
        vault.initializeParameters(address(1), address(1));
    }

    ///@dev Test adding to pnl from an unouthorized account (not perpPair)
    function testUnauthorizedAddToPnL() public {
        vm.expectRevert("OnlyPerp");
        vault.addPnlToCollateral(msg.sender, 100, true);
    }

    // ==========================================================================================
    // Seam-read dedup refactor — equivalence proofs.
    //   #2 updateSnapshot: guard the perpPair.lastOperationTimestamp() read behind the base
    //      time-window check (skip it when the snapshot cannot flip).
    //   #7 removeCollateral: read oracle.getPrice() once and reuse it for the PnL and MR checks.
    // The refactor must be behaviour-identical; the whole existing suite passing unchanged is the
    // primary regression proof. These add targeted checks on the exact changed decisions.
    // ==========================================================================================

    /// @dev Vault default ratioLockTime (the field is private; this mirrors the constructor value).
    uint256 private constant SEAM_RATIO_LOCK = 3600 * 24;

    /// @dev Balanced 50/50 deposit so ratios never move (no AC3) while still triggering updateSnapshot.
    function _seamDeposit(address u, uint256 units) internal {
        uint256[] memory a = new uint256[](numStableCoins);
        a[0] = units * 1e6; // coinA, 6 decimals
        a[1] = units * 1e18; // coinB, 18 decimals
        vm.prank(u);
        vault.addCollateral(a);
    }

    /// @dev The exact snapshot-flip predicate the pre-refactor updateSnapshot implemented.
    function _seamSpecFlip(uint256 nowTs, uint256 lastSnap, uint256 lastOpTs) internal pure returns (bool) {
        uint256 randomDelta = uint256(keccak256(abi.encodePacked(lastOpTs))) % (3600 * 2);
        return nowTs > lastSnap + SEAM_RATIO_LOCK + randomDelta;
    }

    /// @dev #2 differential: the guarded updateSnapshot must flip the snapshot on EXACTLY the same
    ///      timestamps as the original predicate, including the randomDelta-sensitive band just past
    ///      ratioLockTime where the guard does not short-circuit.
    function test_seam_updateSnapshotFlip_matchesSpec() public {
        vm.warp(5_000_000);
        _seamDeposit(alice, 1000); // establish an initial snapshot

        // Offsets from the current snapshot spanning: deep in-window, exactly at ratioLockTime,
        // one second past (randomDelta decides), and past the maximum randomDelta (must flip).
        uint256[5] memory offsets =
            [uint256(10), SEAM_RATIO_LOCK, SEAM_RATIO_LOCK + 1, SEAM_RATIO_LOCK + 7200, SEAM_RATIO_LOCK + 7201];

        for (uint256 i; i < offsets.length; i++) {
            uint256 snapBefore = vault.lastSnapshotTimestamp();
            uint256 lastOpTs = perpPair.lastOperationTimestamp(); // unchanged by addCollateral
            uint256 t = snapBefore + offsets[i];
            bool expectFlip = _seamSpecFlip(t, snapBefore, lastOpTs);

            vm.warp(t);
            _seamDeposit(alice, 1000);

            assertEq(vault.lastSnapshotTimestamp(), expectFlip ? t : snapBefore, "flip decision diverged from spec");
        }
    }

    /// @dev #2 gas win: in-window, the guard must skip the perpPair read entirely (0 calls).
    function test_seam_updateSnapshot_skipsEngineReadInWindow() public {
        vm.warp(5_000_000);
        _seamDeposit(alice, 1000); // flips: lastSnapshotTimestamp = 5_000_000

        vm.warp(5_000_000 + 100); // well within ratioLockTime
        vm.expectCall(address(perpPair), abi.encodeWithSelector(IPerpPair.lastOperationTimestamp.selector), 0);
        _seamDeposit(alice, 1000);
    }

    /// @dev #2 counterpart: out-of-window, the read still happens exactly once (behaviour preserved).
    function test_seam_updateSnapshot_readsEngineOutOfWindow() public {
        vm.warp(5_000_000);
        _seamDeposit(alice, 1000);

        vm.warp(5_000_000 + SEAM_RATIO_LOCK + 7201); // past ratioLockTime + max randomDelta
        vm.expectCall(address(perpPair), abi.encodeWithSelector(IPerpPair.lastOperationTimestamp.selector), 1);
        _seamDeposit(alice, 1000);
    }

    /// @dev #7: removeCollateral must read oracle.getPrice() one fewer time. Post-refactor it is read
    ///      twice total (once in perpPair.updateFG, once in the Vault reused for PnL + MR); pre-refactor
    ///      the Vault read it a second time in _checkMR (3 total). Outcome must be unchanged.
    function test_seam_removeCollateral_singleVaultOracleRead() public {
        uint256[] memory a = new uint256[](numStableCoins);
        a[0] = 4000 * 1e6;
        a[1] = 6000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(a);

        vm.expectCall(address(oracle), abi.encodeWithSelector(IOracleMiddleware.getPrice.selector), 2);
        vm.prank(alice);
        vault.removeCollateral(5000 * 1e18, fakeReportData);

        assertEq(vault.userCollateral(alice), 5000 * collateralDecimals, "alice collateral after removal");
        assertEq(vault.totalCollateral(), 5000 * collateralDecimals, "total collateral after removal");
    }

    //support functions
    //returns if value is inside confidence interval of target
    function inConfidenceInterval(uint256 value, uint256 target, uint256 tolerance) public pure returns (bool) {
        uint256 diff = UtilMath.diffAbs(value, target);
        return diff <= value / tolerance;
    }

    function mint(address stableCoin, address[] memory addresses, uint256[] memory amounts) public {
        assertTrue(addresses.length == amounts.length, "different length of addresses and amounts");
        for (uint256 i = 0; i < addresses.length; i++) {
            _mint(stableCoin, addresses[i], amounts[i]);
        }
    }

    function _mint(address stableCoin, address user, uint256 amount) public {
        vm.prank(MasterMinter);
        FiatTokenV2(stableCoin).mint(user, amount);
    }
}
