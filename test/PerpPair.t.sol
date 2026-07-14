// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import "../src/token/USDCe.sol";
import "../src/util/CurveMath.sol";
import "../src/util/MatrixMath.sol";
import "../src/util/UtilMath.sol";
import "../src/manager/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/test_support/TestPriceProvider.sol";
import "../src/manager/multiCallManager.sol";
import "./helpers/PerpPairTestDeploymentHelper.sol";

contract PerpPairTest is Test, PerpPairTestDeploymentHelper {
    uint256 MAX_UINT = 2 ** 256 - 1;
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
    uint256 public curveParameterDecimals = 1e8;
    TestPriceProvider public oracle;
    uint256 public oracleDecimals = 1e8;
    uint256 public currencyDecimals = 1e18;
    uint256 public ratioDecimals = 1e8;
    uint256 public liquidityFeeDecimals = 1e10;
    string public tokenName = "USDCe";
    string public tokenSymbol = "USDC.e";
    string public tokenCurrency = "USD";
    address public MasterMinter = makeAddr("Megamind");
    address public Pauser = makeAddr("Megamind");
    address public Blacklister = makeAddr("Megamind");
    address public Owner = makeAddr("Megamind");
    uint256 startingStableAmount = 10_000_000;
    bytes public fakeReport;
    uint256 public maxUserLiquidityFee = 1e30;

    address[] public stableCoins;
    uint256[] public depositThresholds;
    uint256[] public withdrowalThresholds;
    uint256[] public stableDecimals;

    event DebugEvent(uint256);
    event ToggledAutoClose(
        address indexed user, uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee
    );

    function setUp() public {
        uint256 numStableCoins = 2;
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
            withdrowalThresholds.push(1 * ratioDecimals);
        }
        stableDecimals.push(1e6);
        stableDecimals.push(1e18);
        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(
            address(multiCallManager), 100, stableCoins, depositThresholds, withdrowalThresholds, stableDecimals
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
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        _restoreTestEraParameters(
            perpPair, address(oracle), feeFrontend, feeProtocolAddr, MMR, tradingFee, flatTradingFee, feeLP
        );

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        address eve = makeAddr("eve");
        address farquaad = makeAddr("farquaad");

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
        vm.prank(david);
        coinA.approve(address(vault), MAX_UINT);
        vm.prank(david);
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
        users[3] = david;
        users[4] = eve;
        users[5] = farquaad;

        uint256[] memory amounts = new uint256[](6);
        amounts[0] = startingStableAmount * 1e6 * 2;
        amounts[1] = startingStableAmount * 1e6 * 2;
        amounts[2] = startingStableAmount * 1e6 * 2;
        amounts[3] = startingStableAmount * 1e6 * 2;
        amounts[4] = startingStableAmount * 1e6 * 2;
        amounts[5] = startingStableAmount * 1e6 * 2;
        mint(stableCoins[0], users, amounts);

        amounts[0] = startingStableAmount * 1e18 * 2;
        amounts[1] = startingStableAmount * 1e18 * 2;
        amounts[2] = startingStableAmount * 1e18 * 2;
        amounts[3] = startingStableAmount * 1e18 * 2;
        amounts[4] = startingStableAmount * 1e18 * 2;
        amounts[5] = startingStableAmount * 1e18 * 2;
        mint(stableCoins[1], users, amounts);

        amounts = new uint256[](2);
        amounts[0] = startingStableAmount * 1e6;
        amounts[1] = startingStableAmount * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);
        vm.prank(bob);
        vault.addCollateral(amounts);
        vm.prank(charlie);
        vault.addCollateral(amounts);
        vm.prank(david);
        vault.addCollateral(amounts);
        vm.prank(eve);
        vault.addCollateral(amounts);
        vm.prank(farquaad);
        vault.addCollateral(amounts);
    }

    //Tests on trading modes
    ///@dev test trading with trade, closeTrade.
    function testTradeEasyTrader() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        assertTrue(debtStable == tradeSize && debtAsset == 0, "debt");
        assertTrue(balanceStable == 0 && inConfidenceInterval(balanceAsset, tradeSize / 100, 100), "balance");
    }

    ///@dev test trading with trade.
    function testTradeProTrader() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        assertTrue(debtStable == tradeSize && debtAsset == 0, "debt");
        assertTrue(balanceStable == 0 && inConfidenceInterval(balanceAsset, tradeSize / 100, 100), "balance");
    }

    ///@dev tests safeguard that prevents from being liquidated after opening a trade due to slippage/fees
    function testTradeForbiddenByMMR() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        Vault(vault).removeCollateral(2 * 10_000_000 * 1e18, fakeReport);

        uint256 tradeSize = 1000 * 1e18;

        vm.expectRevert(bytes("T1"));
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
    }

    //test close&withdraw
    ///@dev tests the closeAndWithdraw function in a scenario where the trader went long and made profit.
    function testCloseAndWithdrawLongProfit() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        vm.prank(alice);
        vault.addCollateral(collateral);
        vm.prank(alice);
        perpPair.trade(false, tradeSize / 10, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        skip(1000);
        oracle.setPrice(110 * oracleDecimals);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReport);

        uint256 finalCollat = vault.userCollateral(bob);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertTrue(balanceStable == 0 && balanceAsset == 0 && debtStable == 0 && debtAsset == 0, "not closed");
        assertTrue(finalCollat > 1000 * 1e18 + 2 * startingStableAmount, "collateral did not go up");
    }

    ///@dev a zero-frontend close is allowed: the corrected gross-up no longer overshoots.
    function testCloseAndWithdrawAllowsZeroFrontend() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(1_000_000 * 1e18, 10_000 * 1e18, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;
        vm.prank(bob);
        vault.addCollateral(collateral);
        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, 1000 * 1e18, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, address(0), fakeReport);

        (, uint256 balanceAsset,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        assertEq(balanceAsset, 0, "zero-frontend close should clear the position");
    }

    ///@dev a zero-frontend SHORT close exercises the corrected buy-back gross-up: it closes
    /// cleanly and pays no frontend fee (the fee share is rebated into the trade).
    function testCloseAndWithdrawShortWithZeroFrontend() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        vm.prank(alice);
        vault.addCollateral(collateral);
        vm.prank(alice);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        uint256 liq = perpPair.globalLiquidityStable();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(false, tradeSize / 100, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        skip(1000);
        oracle.setPrice(90 * oracleDecimals);

        (uint256 frontendStableBefore,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, address(0), fakeReport);

        (uint256 balanceStable, uint256 balanceAsset2, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertTrue(balanceStable == 0 && balanceAsset2 == 0 && debtStable == 0 && debtAsset == 0, "not closed");
        (uint256 frontendStableAfter,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 zeroStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(address(0));
        assertTrue(frontendStableAfter == frontendStableBefore, "frontend fee paid");
        assertTrue(zeroStableBalance == 0, "zero frontend fee paid");
    }

    ///@dev tests the closeAndWithdraw function in a scenario where the trader went long and made profit.
    function testCloseAndWithdrawShortProfit() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        vm.prank(alice);
        vault.addCollateral(collateral);
        vm.prank(alice);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        uint256 liq = perpPair.globalLiquidityStable();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(false, tradeSize / 100, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        skip(1000);
        oracle.setPrice(90 * oracleDecimals);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReport);

        uint256 finalCollat = vault.userCollateral(bob);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertTrue(balanceStable == 0 && balanceAsset == 0 && debtStable == 0 && debtAsset == 0, "not closed");
        assertTrue(finalCollat > 1000 * 1e18 + 2 * startingStableAmount, "collateral did not go up");
    }

    function testCloseAndWithdrawPnLDust() public {
        uint256 priceWithDecimals = 6_843_264_421_548;
        oracle.setPrice(priceWithDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 100_000 * 1e18;
        uint256 aliceLiquidityAsset = 100_000 * 1e26 / priceWithDecimals;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address charlie = makeAddr("charlie");

        uint256 tradeSize = 50 * 1e26 / priceWithDecimals;

        uint256 liq = perpPair.globalLiquidityStable();

        vm.prank(charlie);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        address bob = makeAddr("bob");

        tradeSize = 50 * 1e26 / priceWithDecimals;

        liq = perpPair.globalLiquidityStable();

        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e10, frontendAddress, fakeReport);

        //CurveMath.computeExactAmountInLong(
        //    3355,
        //    6843264481548,
        //    100000000,
        //    100000000000000000000000,
        //    100000000000000000000000,
        //    1520000000000000710,
        //    100000000,
        //    10000000,
        //    100000000
        //    );
    }

    //Trading fees

    ///@dev Tests the distribution of trading fees to LPs of a long trade
    function testShortTradingFeeLP() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = david;
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1e8 * 1e6;
        amounts[1] = 1e8 * 1e6;
        amounts[2] = 1e8 * 1e6;
        amounts[3] = 1e8 * 1e6;
        mint(stableCoins[0], users, amounts);
        amounts = new uint256[](2);
        amounts[0] = 1e8 * 1e6;
        amounts[1] = 0;
        vm.prank(alice);
        vault.addCollateral(amounts);
        vm.prank(bob);
        vault.addCollateral(amounts);
        vm.prank(charlie);
        vault.addCollateral(amounts);

        uint256 aliceLiquidityStable = 50_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 0;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 charlieLiquidityStable = 0;
        uint256 charlieLiquidityAsset = 300_000 * 1e18;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 tradeSize = 10 * 1e18;

        vm.prank(david);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        //uint256 totalAssetLiquidity = perpPair.globalLiquidityAsset();
        //uint256 totalStableLiquidity = perpPair.globalLiquidityStable();

        (uint256 aliceFinalStable,) = perpPair.getLpLiquidityBalance(alice);
        //(uint256 bobFinalStable ,uint256 bobFinalAsset) = perpPair.getLpLiquidityBalance(bob);
        (uint256 charlieFinalStable, uint256 charlieFinalAsset) = perpPair.getLpLiquidityBalance(charlie);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * tradingFee * 100 / tradingFeeDecimals + flatFee;

        assertTrue(
            inConfidenceInterval(
                UtilMath.diffAbs(aliceLiquidityStable - tradeSize * 100, aliceFinalStable),
                tradingFeeValue * feeLP / feeFractionDecimals,
                100
            ),
            "alice"
        );
        assertTrue(charlieFinalStable == 0 && charlieFinalAsset == charlieLiquidityAsset, "charlie");

        //emit DebugEvent(UtilMath.diffAbs(aliceLiquidityStable - tradeSize*100, aliceFinalStable));
        //emit DebugEvent(tradeSize*tradingFee*100/tradingFeeDecimals*feeLP/feeFractionDecimals);
    }

    ///@dev Tests the distribution of trading fees to LPs of a long trade
    function testLongTradingFeeLP() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = david;
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1e8 * 1e6;
        amounts[1] = 1e8 * 1e6;
        amounts[2] = 1e8 * 1e6;
        amounts[3] = 1e8 * 1e6;
        mint(stableCoins[0], users, amounts);
        amounts = new uint256[](2);
        amounts[0] = 1e8 * 1e6;
        amounts[1] = 0;
        vm.prank(alice);
        vault.addCollateral(amounts);
        vm.prank(bob);
        vault.addCollateral(amounts);
        vm.prank(charlie);
        vault.addCollateral(amounts);

        uint256 aliceLiquidityStable = 50_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 0;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 charlieLiquidityStable = 0;
        uint256 charlieLiquidityAsset = 5_000_000 * 1e18;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 tradeSize = 1000 * 1e18;

        vm.prank(david);
        perpPair.trade(true, tradeSize, 100 * 1e5, charlieLiquidityAsset, frontendAddress, 1, fakeReport);

        //uint256 totalAssetLiquidity = perpPair.globalLiquidityAsset();
        //uint256 totalStableLiquidity = perpPair.globalLiquidityStable();

        (uint256 aliceFinalStable, uint256 aliceFinalAsset) = perpPair.getLpLiquidityBalance(alice);
        (uint256 charlieFinalStable, uint256 charlieFinalAsset) = perpPair.getLpLiquidityBalance(charlie);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * tradingFee / tradingFeeDecimals + flatFee;

        assertTrue(
            inConfidenceInterval(
                charlieFinalStable - (tradeSize - tradingFeeValue), tradingFeeValue * feeLP / feeFractionDecimals, 100
            ),
            "charlie"
        );
        assertTrue(aliceFinalAsset == 0 && aliceFinalStable == aliceLiquidityStable, "alice");

        emit DebugEvent(charlieFinalStable);
        emit DebugEvent(charlieFinalAsset);
    }

    ///@dev Tests the distribution of trading fees of a long trade.
    function testLongTradingFeeDistribution() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * tradingFee / tradingFeeDecimals + flatFee;

        (uint256 FrontendStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 ProtocolStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(feeProtocolAddr);
        assertTrue(FrontendStableBalance == feeFrontend * tradingFeeValue / feeFractionDecimals, "frontend fee");
        assertTrue(
            ProtocolStableBalance
                == (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8,
            "protocol fee"
        );
        (uint256 insFund,) = perpPair.ReadInsuranceFund();
        assertTrue(insFund == 1e8, "Ins fund");

        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 * 1e6;
        amounts[1] = 0;
        vm.prank(frontendAddress);
        coinA.approve(address(vault), MAX_UINT);

        _mint(address(coinA), frontendAddress, 1e6);

        vm.prank(frontendAddress);
        vault.addCollateral(amounts);

        vm.prank(frontendAddress);
        perpPair.closeAndWithdraw(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);
        vm.prank(feeProtocolAddr);
        perpPair.closeAndWithdraw(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);

        console.log("balance A ", coinA.balanceOf(frontendAddress));
        console.log("balance B ", coinB.balanceOf(frontendAddress));
        console.log("collat before ", perpPair.getCollateral(frontendAddress));

        vm.prank(frontendAddress);
        vault.removeAllCollateral(fakeReport);

        console.log("balance A ", coinA.balanceOf(frontendAddress));
        console.log("balance B ", coinB.balanceOf(frontendAddress));
        console.log("collat after ", perpPair.getCollateral(frontendAddress));
    }

    ///@dev Tests the distribution of trading fees of a short trade.
    function testShortTradingFeeDistribution() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 10 * 1e18;

        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * 100 * tradingFee / tradingFeeDecimals + flatFee;

        (uint256 FrontendStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 ProtocolStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(feeProtocolAddr);
        assertTrue(
            inConfidenceInterval(FrontendStableBalance, feeFrontend * tradingFeeValue / feeFractionDecimals, 1000),
            "frontend fee"
        );
        assertTrue(
            inConfidenceInterval(
                ProtocolStableBalance,
                (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / (feeFractionDecimals) - 1e8,
                1000
            ),
            "protocol fee"
        );
        (uint256 insFund,) = perpPair.ReadInsuranceFund();
        assertTrue(insFund == 1e8, "Ins fund");
    }

    ///@dev Tests the distribution of trading fees of a long trade.
    function testLongTradingFeeDistributionZeroAddressFrontend() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, address(0), 1, fakeReport);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * tradingFee / tradingFeeDecimals + flatFee;

        (uint256 FrontendStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 ProtocolStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(feeProtocolAddr);
        (uint256 zeroStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(address(0));

        assertTrue(FrontendStableBalance == 0, "frontend fee");
        assertTrue(zeroStableBalance == 0, "zero fee");
        console.log(
            ProtocolStableBalance,
            (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8
        );
        assertTrue(
            ProtocolStableBalance
                == (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8,
            "protocol fee"
        );
        (uint256 insFund,) = perpPair.ReadInsuranceFund();
        assertTrue(insFund == 1e8, "Ins fund");
    }

    function testShortTradingFeeDistributionZeroAddressFrontend() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 10 * 1e18;

        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, address(0), 1, fakeReport);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * 100 * tradingFee / tradingFeeDecimals + flatFee;

        (uint256 FrontendStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 ProtocolStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(feeProtocolAddr);
        (uint256 zeroStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(address(0));

        assertTrue(FrontendStableBalance == 0, "frontend fee");
        assertTrue(zeroStableBalance == 0, "zero fee");
        console.log(
            ProtocolStableBalance,
            (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8
        );
        assertTrue(
            inConfidenceInterval(
                ProtocolStableBalance,
                (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / (feeFractionDecimals) - 1e8,
                1000
            ),
            "protocol fee"
        );
        (uint256 insFund,) = perpPair.ReadInsuranceFund();
        assertTrue(insFund == 1e8, "Ins fund");
    }

    //FundingFees
    ///@dev Tests the funding fees accumulated by the trader opening a long trade.
    function testTraderFundingFeesTradeLong() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        skip(3600 * 8);
        (, uint256 balanceAsset,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        vm.prank(bob);
        perpPair.trade(
            false, balanceAsset, 100 * 1e5, aliceLiquidityStable + tradeSize * 9 / 10, frontendAddress, 1, fakeReport
        );
        uint256 fundingRate = perpPair.fundingRate();
        bool fundingRateSign = perpPair.fundingRateSign();
        (,,,, uint256 fundingFee, bool fundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);

        assertTrue(inConfidenceInterval(fundingRate, 1e18 / uint256(6), 100) && fundingRateSign == true, "funding rate");
        assertTrue(
            inConfidenceInterval(fundingFee, 1e18 * 10 / uint256(6), 100) && fundingFeeSign == true, "funding fee"
        );
    }

    ///@dev Tests the funding fees accumulated by the trader opening a short trade.
    function testTraderFundingFeesTradeShort() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 10 * 1e18;
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        skip(3600 * 8);
        (uint256 balanceStable,,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        vm.prank(bob);
        perpPair.trade(
            true, balanceStable, 100 * 1e5, aliceLiquidityAsset + tradeSize * 9 / 10, frontendAddress, 1, fakeReport
        );
        uint256 fundingRate = perpPair.fundingRate();
        bool fundingRateSign = perpPair.fundingRateSign();
        (,,,, uint256 fundingFee, bool fundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);

        assertTrue(
            inConfidenceInterval(fundingRate, 1e18 / uint256(6), 100) && fundingRateSign == false, "funding rate"
        );
        assertTrue(
            inConfidenceInterval(fundingFee, 1e18 * 10 / uint256(6), 100) && fundingFeeSign == true, "funding fee"
        );
    }

    ///@dev Tests the funding fees accumulated by the trader opening multiple trades.
    function testTraderFundingFeesMultiTrade() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 1000 * 1e18;
        uint256 tempLiq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, tempLiq - tradeSize / 100, frontendAddress, 1, fakeReport);
        skip(3600 * 1);

        address charlie = makeAddr("charlie");
        tradeSize = 50 * 1e18;
        tempLiq = perpPair.globalLiquidityStable();
        vm.prank(charlie);
        perpPair.trade(false, tradeSize, 100 * 1e5, tempLiq - tradeSize * 100, frontendAddress, 1, fakeReport);
        skip(3600 * 7);

        uint256 fundingRate = perpPair.fundingRate();
        bool fundingRateSign = perpPair.fundingRateSign();
        assertTrue(
            inConfidenceInterval(fundingRate, 1e18 / uint256(48), 100) && fundingRateSign == true, "funding rate 1"
        );

        //(, uint256 balanceAsset, , , , , , ) = perpPair.userVirtualTraderPosition(bob);
        tempLiq = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, 98 * 1e17, 100 * 1e5, tempLiq - 98 * 1e19, frontendAddress, 1, fakeReport);
        skip(3600 * 1);

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(inConfidenceInterval(fundingRate, 5662 * 1e14, 100) && fundingRateSign == false, "funding rate 2");

        //(uint256 balanceStable, , , , , , , ) = perpPair.userVirtualTraderPosition(charlie);
        tempLiq = perpPair.globalLiquidityAsset();
        vm.prank(charlie);
        perpPair.trade(true, 4970 * 1e18, 100 * 1e5, tempLiq - 4970 * 100, frontendAddress, 1, fakeReport);

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(inConfidenceInterval(fundingRate, 6662 * 1e14, 100) && fundingRateSign == false, "funding rate 3");
    }

    ///@dev Tests the funding fees accumulated by the trader opening a long trade.
    function testLpAndTraderFundingFee() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 5000 * 1e18;
        uint256 bobLiquidityAsset = 50 * 1e18;
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        address david = makeAddr("david");
        vm.prank(david);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        skip(3600 * 8);

        vm.prank(bob);
        perpPair.trade(true, 1e18, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        vm.prank(charlie);
        perpPair.trade(true, 1e18, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        vm.prank(david);
        perpPair.trade(true, 1e18, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (,,,, uint256 bobFundingFee, bool bobFundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);
        (,,,, uint256 charlieFundingFee, bool charlieFundingFeeSign,,) = perpPair.userVirtualTraderPosition(charlie);
        (,,,, uint256 davidFundingFee, bool davidFundingFeeSign,,) = perpPair.userVirtualTraderPosition(david);

        console.log(bobFundingFee, bobFundingFeeSign);
        console.log(charlieFundingFee, charlieFundingFeeSign);
        console.log(davidFundingFee, davidFundingFeeSign);

        (uint256 totalFunding, bool totalSign) =
            UtilMath.signedSum(charlieFundingFee, charlieFundingFeeSign, davidFundingFee, davidFundingFeeSign);

        console.log(totalFunding, bobFundingFee);

        assertTrue(
            inConfidenceInterval(totalFunding, bobFundingFee, 100) && totalSign == bobFundingFeeSign,
            "funding fees differ"
        );

        //assertTrue(inConfidenceInterval(fundingRate, 1e18 / uint256(6), 100) && fundingRateSign == true, "funding rate");
        //assertTrue(inConfidenceInterval(fundingFee, 1e18 * 10 / uint256(6), 100) && fundingFeeSign == true, "funding fee");
    }

    ///@dev Tests the funding fees accumulated by the trader opening a long trade.
    function testFundingRateManualUpdate() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        skip(3600 * 8);
        vm.prank(bob);
        perpPair.trade(true, 1e18, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        uint256 fundingRate = perpPair.fundingRate();
        bool fundingRateSign = perpPair.fundingRateSign();
        (,,,, uint256 fundingFee, bool fundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);

        assertTrue(inConfidenceInterval(fundingRate, 1e18 / uint256(6), 100) && fundingRateSign == true, "funding rate");
        assertTrue(
            inConfidenceInterval(fundingFee, 1e18 * 10 / uint256(6), 100) && fundingFeeSign == true, "funding fee"
        );

        skip(3600 * 4);
        perpPair.updateFG(fakeReport);
        perpPair.updateFG(fakeReport);
        perpPair.updateFG(fakeReport);
        skip(3600 * 4);
        perpPair.updateFG(fakeReport);

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(
            inConfidenceInterval(fundingRate, 2 * 1e18 / uint256(6), 100) && fundingRateSign == true, "funding rate"
        );
    }

    ///@dev Tests a complex scenario defined in the notes, 3LP, 3 traders, LP liquidity is *100 to reduce slippage as much as possible
    function testAllFundingFees() public {
        uint256 scale = 10_000;
        uint256 price = 1_000_000 * oracleDecimals / scale;
        oracle.setPrice(price);
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 1_000_000 * 1e18 * oracleDecimals / price;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 0;
        uint256 bobLiquidityAsset = 200_000 * 1e18 * oracleDecimals / price;
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 200_000 * 1e18;
        uint256 charlieLiquidityAsset = 0;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);

        uint256 tempBal;

        address david = makeAddr("david");
        uint256 tradeSize = 1000 * 1e18;
        tempBal = perpPair.globalLiquidityAsset();
        vm.prank(david);
        perpPair.trade(
            true, tradeSize, 100 * 1e5, tempBal - tradeSize * oracleDecimals / price, frontendAddress, 1, fakeReport
        );

        skip(3600);
        price = 1_100_000 * oracleDecimals / scale;
        oracle.setPrice(price);

        address eve = makeAddr("eve");
        vm.prank(alice);
        perpPair.removeLiquidity(1e16, 1e16 * oracleDecimals / price, maxUserLiquidityFee, fakeReport);
        tradeSize = 1100 * 1e18;
        tempBal = perpPair.globalLiquidityAsset();
        vm.prank(eve);
        perpPair.trade(
            true, tradeSize, 100 * 1e5, tempBal - tradeSize * oracleDecimals / price, frontendAddress, 1, fakeReport
        );

        uint256 fundingRate = perpPair.fundingRate();
        bool fundingRateSign = perpPair.fundingRateSign();
        assertTrue(inConfidenceInterval(fundingRate, 1997 * 1e13, 100) && fundingRateSign == true, "funding rate 1");
        skip(3600);

        address farquaad = makeAddr("farquaad");
        vm.prank(farquaad);
        perpPair.addLiquidity(1e16, 1e16 * oracleDecimals / price, maxUserLiquidityFee, fakeReport);
        tradeSize = 1100 * 1e18 * oracleDecimals / price;
        tempBal = perpPair.globalLiquidityStable();
        vm.prank(farquaad);
        perpPair.trade(
            false, tradeSize, 100 * 1e5, tempBal - tradeSize * price / oracleDecimals, frontendAddress, 1, fakeReport
        );

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(inConfidenceInterval(fundingRate, 3 * 1997 * 1e13, 100) && fundingRateSign == true, "funding rate 2");

        skip(3600);
        price = 950_000 * oracleDecimals / scale;
        oracle.setPrice(price);

        tradeSize = 945 * 1e18 * oracleDecimals / price;
        tempBal = perpPair.globalLiquidityStable();
        vm.prank(david);
        perpPair.trade(
            false, tradeSize, 100 * 1e5, tempBal - tradeSize * price / oracleDecimals, frontendAddress, 1, fakeReport
        );
        tradeSize = 945 * 1e18 * oracleDecimals / price;
        tempBal = perpPair.globalLiquidityStable();
        vm.prank(eve);
        perpPair.trade(
            false, tradeSize, 100 * 1e5, tempBal - tradeSize * price / oracleDecimals, frontendAddress, 1, fakeReport
        );

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(
            inConfidenceInterval(fundingRate, (3 * 1997 + 1603) * 1e13, 100) && fundingRateSign == true,
            "funding rate 3"
        );

        skip(3600 * 2);

        tradeSize = 990 * 1e18;
        tempBal = perpPair.globalLiquidityAsset();
        vm.prank(farquaad);
        perpPair.trade(
            true, tradeSize, 100 * 1e5, tempBal - tradeSize * oracleDecimals / price, frontendAddress, 1, fakeReport
        );

        fundingRate = perpPair.fundingRate();
        fundingRateSign = perpPair.fundingRateSign();
        assertTrue(
            inConfidenceInterval(fundingRate, (3 * 1997 + 1603 - 3150) * 1e13, 100) && fundingRateSign == true,
            "funding rate 4"
        );

        vm.prank(alice);
        perpPair.removeLiquidity(1e18, 0, maxUserLiquidityFee, fakeReport);
        assertTrue(
            inConfidenceInterval(fundingRate, (3 * 1997 + 1603 - 3150) * 1e13, 100) && fundingRateSign == true,
            "funding rate 5"
        );
        vm.prank(bob);
        perpPair.removeLiquidity(1e18, 0, maxUserLiquidityFee, fakeReport);
        assertTrue(
            inConfidenceInterval(fundingRate, (3 * 1997 + 1603 - 3150) * 1e13, 100) && fundingRateSign == true,
            "funding rate 6"
        );
        vm.prank(charlie);
        perpPair.removeLiquidity(1e18, 0, maxUserLiquidityFee, fakeReport);
        assertTrue(
            inConfidenceInterval(fundingRate, (3 * 1997 + 1603 - 3150) * 1e13, 100) && fundingRateSign == true,
            "funding rate 7"
        );

        (,,,, uint256 aliceFundingFee, bool aliceFundingFeeSign,,) = perpPair.userVirtualTraderPosition(alice);
        (,,,, uint256 bobFundingFee, bool bobFundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);
        (,,,, uint256 charlieFundingFee, bool charlieFundingFeeSign,,) = perpPair.userVirtualTraderPosition(charlie);
        (,,,, uint256 davidFundingFee, bool davidFundingFeeSign,,) = perpPair.userVirtualTraderPosition(david);
        (,,,, uint256 eveFundingFee, bool eveFundingFeeSign,,) = perpPair.userVirtualTraderPosition(eve);
        (,,,, uint256 farquaadFundingFee, bool farquaadFundingFeeSign,,) = perpPair.userVirtualTraderPosition(farquaad);

        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (bobStableBalance, bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);

        uint256 traderFundingFee = aliceFundingFee;
        bool traderFundingFeeSign = aliceFundingFeeSign;
        uint256 lpFundingFee = davidFundingFee;
        bool lpFundingFeeSign = davidFundingFeeSign;
        (traderFundingFee, traderFundingFeeSign) =
            UtilMath.signedSum(traderFundingFee, traderFundingFeeSign, bobFundingFee, bobFundingFeeSign);
        (traderFundingFee, traderFundingFeeSign) =
            UtilMath.signedSum(traderFundingFee, traderFundingFeeSign, charlieFundingFee, charlieFundingFeeSign);
        (lpFundingFee, lpFundingFeeSign) =
            UtilMath.signedSum(lpFundingFee, lpFundingFeeSign, eveFundingFee, eveFundingFeeSign);
        (lpFundingFee, lpFundingFeeSign) =
            UtilMath.signedSum(lpFundingFee, lpFundingFeeSign, farquaadFundingFee, farquaadFundingFeeSign);

        assertTrue(inConfidenceInterval(traderFundingFee, lpFundingFee, 100), "Total Funding Fee");

        assertTrue(inConfidenceInterval(aliceFundingFee, 1222 * 1e15, 100) && !aliceFundingFeeSign, "alice funding fee");
        console.log(bobFundingFee, charlieFundingFee, davidFundingFee, eveFundingFee);
        assertTrue(inConfidenceInterval(bobFundingFee, 1138 * 1e14, 100) && !bobFundingFeeSign, "bob funding fee");
        assertTrue(
            inConfidenceInterval(charlieFundingFee, 1316 * 1e14, 100) && !charlieFundingFeeSign, "charlie funding fee"
        );
        assertTrue(inConfidenceInterval(davidFundingFee, 7588 * 1e14, 100) && davidFundingFeeSign, "david funding fee");
        assertTrue(inConfidenceInterval(eveFundingFee, 558 * 1e15, 100) && eveFundingFeeSign, "eve funding fee");
        assertTrue(
            inConfidenceInterval(farquaadFundingFee, 157 * 1e15, 100) && farquaadFundingFeeSign, "farquaad funding fee"
        );
        //console.log(perpPair.avgSlippageL());
    }

    ///@dev A long trader that stays healthy after funding accrual must NOT be liquidatable.
    /// The funding double-count (settled by _updateFG, then counted again by the victim's
    /// margin check because the stamp lived in the caller) made a healthy long look
    /// under-margined. Stamping the timestamp inside _updateFG removes the double-count.
    function testLiquidatesHealthyLongAfterFundingDoubleCount() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000 - 41) * 1e18, fakeReport);

        skip(8 hours);

        uint256 trueMarginRatio = UtilMath.calcMR(
            bob,
            initialPrice * oracleDecimals,
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );

        (, uint256 bobAssetBefore,,,,,,) = perpPair.userVirtualTraderPosition(bob);

        assertGt(trueMarginRatio, perpPair.MMR(), "true current MR must remain above MMR");

        address liquidator = makeAddr("charlie");
        uint256 liquidatedSize = bobAssetBefore / 2;

        vm.expectRevert(bytes("LQ1"));
        vm.prank(liquidator);
        perpPair.liquidate(bob, liquidatedSize, fakeReport);

        (, uint256 bobAssetAfter,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        assertEq(bobAssetAfter, bobAssetBefore, "healthy user position unchanged");
    }

    ///@dev Tests liquidation mechanism of a trader that went long.
    function testLiquidationLongTrader() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000 - 60) * 1e18, fakeReport);

        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        uint256 newPrice = 95;
        oracle.setPrice(newPrice * oracleDecimals);

        uint256 marginBefore = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        emit DebugEvent(marginBefore);

        address charlie = makeAddr("charlie");
        (, uint256 assetBalance,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        uint256 perc = 100;

        vm.startSnapshotGas("compute");
        vm.prank(charlie);
        perpPair.liquidate(bob, assetBalance * perc / 100, fakeReport);
        uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        console.log("liquidation: ", used);

        uint256 marginAfter = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        emit DebugEvent(marginAfter);

        //(uint256 bobBalanceStable, uint256 bobBalanceAsset, uint256 bobDebtStable, uint256 bobDebtAsset,,,,,,) =
        //    perpPair.userVirtualTraderPosition(bob);
        (, uint256 charlieBalanceAsset, uint256 charlieDebtStable,,,,,) = perpPair.userVirtualTraderPosition(charlie);

        assertTrue(marginBefore < marginAfter, "margin ratio did not improve");
        /*assertTrue(
            inConfidenceInterval(bobBalanceAsset, tradeSize / initialPrice * (100 - perc) / 100, 100)
                && inConfidenceInterval(
                    bobDebtStable, (1e18 - 1e18 * newPrice / initialPrice * perc / 100) * tradeSize * 100 / 99 / 1e18, 100
                ),
            "liquidated user accounting"
        );*/
        // The liquidator pays (1 - discount) * dyPrime plus discount / insFundFraction * dyPrime
        // to the insurance fund. liquidationDiscount has no setter, so replicate
        // _computeLiquidationDiscount from the live parameter (read via ReadFees()) and the
        // margin ratio at liquidation time; insFundFraction (6) has no on-chain reader.
        (,,,,,, uint256 liqDiscount) = perpPair.ReadFees();
        uint256 appliedDiscount = marginBefore <= MMR / 2
            ? (liqDiscount * (1e10 + (MMR / 2 - marginBefore) * 1e10 / (MMR / 2))) / 1e10
            : (liqDiscount / 2 * (1e10 + (MMR - marginBefore) * 1e10 / (MMR - MMR / 2))) / 1e10;
        uint256 expectedDebtStable = tradeSize * newPrice / initialPrice * perc / 100
            * (feeFractionDecimals - appliedDiscount + appliedDiscount / 6) / feeFractionDecimals;
        assertTrue(
            inConfidenceInterval(charlieBalanceAsset, tradeSize / initialPrice * perc / 100, 100)
                && inConfidenceInterval(charlieDebtStable, expectedDebtStable, 100),
            "liquidator accounting"
        );
    }

    /*
    ///@dev Tests liquidation mechanism of a trader that went short.
    function testLiquidationShortTrader() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 100_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000 - 117) * 1e18, fakeReport);

        uint256 tradeSize = 10 * 1e18;
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        uint256 newPrice = 110;
        oracle.setPrice(newPrice * oracleDecimals);

        uint256 marginBefore = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
            );
        emit DebugEvent(marginBefore);

        address charlie = makeAddr("charlie");
        uint256 perc = 40;
        (,,,uint256 assetDebt,,,,) = perpPair.userVirtualTraderPosition(bob);
        (uint256 insuranceBefore,) = perpPair.ReadInsuranceFund();
        vm.prank(charlie);
        perpPair.liquidate(bob, assetDebt * perc/100, fakeReport);
        (uint256 insuranceAfter,) = perpPair.ReadInsuranceFund();
        uint256 insuranceDiff = insuranceAfter - insuranceBefore;

        uint256 marginAfter = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
            );
        emit DebugEvent(marginAfter);

        (uint256 bobBalanceStable, , , uint256 bobDebtAsset,,,,) = perpPair.userVirtualTraderPosition(bob);
        (uint256 charlieBalanceStable, , ,uint256 charlieDebtAsset, ,,,) = perpPair.userVirtualTraderPosition(charlie);

        //uint256 insfund = perpPair.insuranceFund();

        emit DebugEvent(marginBefore);
        emit DebugEvent(marginAfter);

        emit DebugEvent(bobBalanceStable);
        emit DebugEvent(bobDebtAsset);
        emit DebugEvent(charlieBalanceStable);
        emit DebugEvent(charlieDebtAsset);

        assertTrue(marginBefore < marginAfter, "margin ratio did not improve");
        assertTrue(
            inConfidenceInterval(bobBalanceStable, tradeSize * initialPrice - (tradeSize*perc / 100)*newPrice, 100)
                && inConfidenceInterval(
                    bobDebtAsset, tradeSize*(100 - perc) / 100, 100
                ),
            "liquidated user accounting"
        );
        assertTrue(
            inConfidenceInterval(charlieBalanceStable, (tradeSize*perc / 100)*newPrice, 100)
                && inConfidenceInterval(charlieDebtAsset, tradeSize*perc/100, 100),
            "liquidator accounting"
        );

        uint256 liqPnl = charlieBalanceStable - charlieDebtAsset*newPrice - insuranceDiff;
        console.log(liqPnl);
        uint256 discount = 1e6*liqPnl/charlieBalanceStable;
        console.log(discount);
        require(inConfidenceInterval(discount, _computeLiquidationDiscount(marginBefore), 100),
            "liquidator discount");
        //TODO: add check on liq pnl to account for discount
    }
    */
    ///@dev Tests liquidation mechanism of a trader that had opened both long and short trades.
    function testLiquidationMixedTrader() public {
        uint256 initialPrice = 84_000;
        oracle.setPrice(initialPrice * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 29 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000 - 850) * 1e18, fakeReport);

        uint256 tradeSize1 = 1100 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize1, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        uint256 liq = perpPair.globalLiquidityStable();

        uint256 newPrice = 85_000;
        oracle.setPrice(newPrice * oracleDecimals);
        vm.prank(bob);
        perpPair.trade(false, 300 * 1e18 / newPrice, 1e5, liq, frontendAddress, 1, fakeReport);

        liq = perpPair.globalLiquidityStable();
        uint256 tradeSize2 = 3500 * 1e18 / newPrice;
        vm.prank(bob);
        perpPair.trade(false, tradeSize2, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        newPrice = 110_500;
        oracle.setPrice(newPrice * oracleDecimals);

        uint256 marginBefore = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        emit DebugEvent(marginBefore);

        address charlie = makeAddr("charlie");
        (, uint256 assetBalance,, uint256 assetDebt,,,,) = perpPair.userVirtualTraderPosition(bob);
        uint256 exposition = UtilMath.diffAbs(assetBalance, assetDebt);
        uint256 perc = 50;
        vm.prank(charlie);
        perpPair.liquidate(bob, exposition * perc / 100, fakeReport);

        uint256 marginAfter = UtilMath.calcMR(
            bob,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(bob),
            perpPair.lastOperationTimestamp()
        );
        emit DebugEvent(marginAfter);

        /*(uint256 bobBalanceStable, uint256 bobBalanceAsset, uint256 bobDebtStable, uint256 bobDebtAsset,,,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        (
            uint256 charlieBalanceStable,
            uint256 charlieBalanceAsset,
            uint256 charlieDebtStable,
            uint256 charlieDebtAsset,
            ,
            ,
            ,
            ,
            ,
        ) = perpPair.userVirtualTraderPosition(charlie);
        */
        assertTrue(marginBefore < marginAfter, "margin ratio did not improve");
        /*if(bobDebtAsset != 0){
            assertTrue(
                inConfidenceInterval(bobBalanceStable, tradeSize1 * initialPrice * (100 - perc) / 100, 100)
                    && inConfidenceInterval(
                        bobDebtAsset, (1e18 - 1e18 * initialPrice / newPrice * perc / 100) * tradeSize1 * 100 / 99 / 1e18, 100
                    ),
                "liquidated user short accounting"
            );
        }
        else{
            assertTrue(
                inConfidenceInterval(bobBalanceStable, tradeSize1 * initialPrice * (100 - perc) / 100, 100)
                    && inConfidenceInterval(
                        bobBalanceAsset, (1e18 - 1e18 * initialPrice / newPrice * perc / 100) * tradeSize1 * 100 / 99 / 1e18, 100
                    ),
                "liquidated user short accounting"
            );
        }

        assertTrue(
            inConfidenceInterval(bobBalanceAsset, tradeSize2 / initialPrice * (100 - perc) / 100, 100)
                && inConfidenceInterval(
                    bobDebtStable, (1e18 - 1e18 * newPrice / initialPrice * perc / 100) * tradeSize2 * 100 / 99 / 1e18, 100
                ),
            "liquidated user long accounting"
        );

        assertTrue(
            inConfidenceInterval(charlieBalanceStable, tradeSize1 * initialPrice * perc / 100 * 106/100, 100)
                && inConfidenceInterval(charlieDebtAsset, 0, 100),
            "liquidator short accounting"
        );
        assertTrue(
            inConfidenceInterval(
                charlieBalanceAsset,
                tradeSize2 / initialPrice * perc / 100 - tradeSize1 * initialPrice / newPrice * perc / 100,
                100
            ) && inConfidenceInterval(charlieDebtStable, tradeSize2 * newPrice / initialPrice * perc / 100, 100),
            "liquidator long accounting"
        );*/
    }

    ///@dev Tests liquidation mechanism of an LP.
    function testLiquidationLP() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        address david = makeAddr("david");
        uint256 davidLiquidityStable = 10_000 * 1e18;
        uint256 davidLiquidityAsset = 100 * 1e18;
        vm.prank(david);
        perpPair.addLiquidity(davidLiquidityStable, davidLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address alice = makeAddr("alice");

        uint256 aliceLiquidityStable = 5000 * 1e18;
        uint256 aliceLiquidityAsset = 50 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
        vm.prank(alice);
        Vault(vault).removeCollateral((2 * 10_000_000 - 1010) * 1e18, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 6000 * 1e18;
        vm.prank(bob);
        perpPair.trade(
            true, tradeSize, 100 * 1e5, aliceLiquidityAsset + davidLiquidityAsset, frontendAddress, 1, fakeReport
        );

        uint256 newPrice = 200;
        oracle.setPrice(newPrice * oracleDecimals);

        (uint256 lpStable, uint256 lpAsset) = perpPair.getLpLiquidityBalance(alice);

        emit DebugEvent(lpStable);
        emit DebugEvent(lpAsset);

        uint256 marginBefore = UtilMath.calcMR(
            alice,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(alice),
            perpPair.lastOperationTimestamp()
        );

        address charlie = makeAddr("charlie");
        (, uint256 assetBalance,, uint256 assetDebt,,,,) = perpPair.userVirtualTraderPosition(alice);
        (,,, uint256 assetLPdebt) = perpPair.liquidityPosition(alice);
        uint256 exposition = UtilMath.diffAbs(assetBalance + lpAsset, assetDebt + assetLPdebt);
        uint256 perc = 100;
        vm.prank(charlie);
        perpPair.liquidate(alice, exposition * perc / 100, fakeReport);

        uint256 marginAfter = UtilMath.calcMR(
            alice,
            SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()),
            address(perpPair),
            perpPair.getCollateral(alice),
            perpPair.lastOperationTimestamp()
        );

        //(uint256 aliceLPBalanceStable, uint256 aliceLPBalanceAsset) = perpPair.getLpLiquidityBalance(alice);
        //(, , uint256 aliceDebtStable, uint256 aliceDebtAsset,,,,) =
        //    perpPair.userVirtualTraderPosition(alice);
        /*(
            uint256 charlieBalanceStable,
            ,
            ,
            uint256 charlieDebtAsset,
            ,
            ,
            ,
        ) = perpPair.userVirtualTraderPosition(charlie);
        */

        emit DebugEvent(marginBefore);
        emit DebugEvent(marginAfter);

        assertTrue(marginBefore < marginAfter, "margin ratio did not improve");
        /*assertTrue(
            inConfidenceInterval(aliceLPBalanceStable, aliceLiquidityStable * (100 - perc) / 100, 100)
                && inConfidenceInterval(
                    aliceDebtAsset,
                    (1e18 - 1e18 * initialPrice / newPrice * perc / 100) * aliceLiquidityAsset * 100 / 99 / 1e18,
                    100
                ),
            "liquidated user short accounting"
        );
        assertTrue(
            inConfidenceInterval(aliceLPBalanceAsset, aliceLiquidityAsset * (100 - perc) / 100, 100)
                && inConfidenceInterval(
                    aliceDebtStable,
                    (1e18 - 1e18 * newPrice / initialPrice * perc / 100) * aliceLiquidityStable * 100 / 99 / 1e18,
                    100
                ),
            "liquidated user long accounting"
        );
        assertTrue(
            inConfidenceInterval(charlieBalanceStable, 2200*1e18 * perc / 100, 100)
                && inConfidenceInterval(charlieDebtAsset, 20*96/100*1e18, 100),
            "liquidator short accounting"
        );
        */
    }

    ///@dev Test the base autoClosing feature in profit.
    ///@dev The auto-close lifecycle is observable via ToggledAutoClose: enabling emits the
    /// full config, disabling emits the cleared config with mode 0 in the last two fields.
    function testAutoCloseEmitsToggledEvents() public {
        address bob = makeAddr("bob");

        vm.expectEmit(true, false, false, true, address(perpPair));
        emit ToggledAutoClose(bob, 50e18, 50e18, 1e5, 1e10);
        vm.prank(bob);
        perpPair.enableAutoClose(50e18, 50e18, 1e5, 1e10);

        vm.expectEmit(true, false, false, true, address(perpPair));
        emit ToggledAutoClose(bob, 0, 0, 0, 0);
        vm.prank(bob);
        perpPair.disableAutoClose();
    }

    function testBaseAutoCloseProfit() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(110 * oracleDecimals);

        vm.prank(bob);
        perpPair.enableAutoClose(50, 50, 1e5, 1e10);

        (bool auth,,,,) = perpPair.autoCloseUsersData(bob);

        assertTrue(auth);

        address charlie = makeAddr("charlie");
        // A third-party auto-close logs ToggledAutoClose with mode 1 (last two fields = 1),
        // distinguishing it from a user disable / normal close (mode 0).
        vm.expectEmit(true, false, false, true, address(perpPair));
        emit ToggledAutoClose(bob, 0, 0, 1, 1);
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);

        (auth,,,,) = perpPair.autoCloseUsersData(bob);

        assertFalse(auth);

        uint256 finalCollat = vault.userCollateral(bob);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertTrue(balanceStable == 0 && balanceAsset == 0 && debtStable == 0 && debtAsset == 0, "not closed");
        assertTrue(finalCollat > (1000 + 2 * startingStableAmount) * 1e18, "collateral did not go up");

        (balanceStable,,,,,,,) = perpPair.userVirtualTraderPosition(charlie);
        // autoCloseFee has no setter; derive the expectation from the live parameter.
        (,, uint256 autoCloseFee_,,,,) = perpPair.ReadFees();
        assertTrue(autoCloseFee_ > 0 && balanceStable >= autoCloseFee_, "fee not recieved");
    }

    ///@dev Test the base autoClosing feature in loss.
    function testBaseAutoCloseLoss() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(90 * oracleDecimals);

        vm.prank(bob);
        perpPair.enableAutoClose(50 * 1e18, 50 * 1e18, 1e5, 1e10);

        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);

        uint256 finalCollat = vault.userCollateral(bob);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        assertTrue(balanceStable == 0 && balanceAsset == 0 && debtStable == 0 && debtAsset == 0, "not closed");
        console.log(finalCollat);
        console.log(startingStableAmount);
        console.log(finalCollat - 2 * startingStableAmount);
        assertTrue(finalCollat - 2 * startingStableAmount * 1e18 < 1000 * 1e18, "collateral did not go down");

        (balanceStable,,,,,,,) = perpPair.userVirtualTraderPosition(charlie);
        // autoCloseFee has no setter; derive the expectation from the live parameter.
        (,, uint256 autoCloseFee_,,,,) = perpPair.ReadFees();
        assertTrue(autoCloseFee_ > 0 && balanceStable >= autoCloseFee_, "fee not recieved");
    }

    ///@dev Test trying to close a position without enough loss.
    function testAutoCloseLossRevert() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(100 * oracleDecimals);

        vm.prank(bob);
        perpPair.enableAutoClose(50 * 1e18, 50 * 1e18, 1e5, 1e10);

        address charlie = makeAddr("charlie");
        vm.expectRevert(bytes("A1"));
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);
    }

    ///@dev Test the base autoClosing feature in loss.
    function testAutoCloseProfitRevert() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(102 * oracleDecimals);

        vm.prank(bob);
        perpPair.enableAutoClose(50 * 1e18, 50 * 1e18, 1e5, 1e10);

        address charlie = makeAddr("charlie");
        vm.expectRevert(bytes("A1"));
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);
    }

    ///@dev Test the base autoClosing feature in loss.
    function testAutoCloseUnauthorizedRevert() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(110 * oracleDecimals);

        vm.prank(bob);
        perpPair.enableAutoClose(0, 50 * 1e18, 1e5, 1e10);

        address charlie = makeAddr("charlie");
        vm.expectRevert(bytes("A1"));
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);

        vm.prank(bob);
        perpPair.enableAutoClose(50 * 1e18, 0, 1e5, maxUserLiquidityFee);

        oracle.setPrice(90 * oracleDecimals);

        vm.expectRevert(bytes("A1"));
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);
    }

    ///@dev Test the base autoClosing feature in loss.
    function testAutoCloseWrongDirectionsRevert() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 0;

        uint256 liq = perpPair.globalLiquidityAsset();

        vm.prank(bob);
        vault.addCollateral(collateral);
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(110 * oracleDecimals);

        address charlie = makeAddr("charlie");
        vm.expectRevert(bytes("A1"));
        vm.prank(charlie);
        perpPair.autoCloseUserPosition(bob, charlie, fakeReport);
    }

    ///@dev Test the setter functions.
    function testSetParameters() public {
        perpPair.setUnguardedParameters(
            address(oracle),
            5 * feeFractionDecimals / 100,
            makeAddr("newFee"),
            uint32(1e2) * 12_345,
            12,
            uint32(1e6) / 800,
            10,
            3
        );
    }

    function testLeverageBypass() public {
        uint256 price = 100;
        oracle.setPrice(price * oracleDecimals);
        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 100 * 1e18;
        address alice = makeAddr("alice");
        vm.prank(alice);
        vault.removeAllCollateral(fakeReport);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * 1e6;
        amounts[1] = 1000 * 1e18;
        vm.prank(alice);
        vault.addCollateral(amounts);

        require(perpPair.getCollateral(alice) == 2000 * 1e18);

        vm.prank(alice);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);

        vm.expectRevert();
        vm.prank(alice);
        perpPair.addLiquidity(0, liquidityAsset / 10, maxUserLiquidityFee, fakeReport);

        uint256 tradeSize = 1000 * 1e18;
        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(alice);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(alice);

        debtStable = debtStable > balanceStable ? debtStable - balanceStable : 0;
        debtAsset = debtAsset > balanceAsset ? debtAsset - balanceAsset : 0;

        uint256 totalDebt = debtStable + debtAsset * price;

        console.log(totalDebt);

        vm.expectRevert();
        vm.prank(alice);
        perpPair.addLiquidity(0, liquidityAsset / 10, maxUserLiquidityFee, fakeReport);
    }

    function testSlippageBadDebtExploit() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 100_000 * 1e18;
        uint256 aliceLiquidityAsset = 1000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0 * 1e6;
        amounts[1] = 100_000 * 1e18;

        vm.prank(bob);
        vault.addCollateral(amounts);

        uint256 tradeSize = 1000 * 1e18;
        uint256 liq = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        address charlie = makeAddr("charlie");
        tradeSize = 1000 * 1e18;
        liq = perpPair.globalLiquidityStable();
        //(uint256 shortCurveParameterA , uint256 shortCurveParameterB , , , , , ,) = perpPair.curveParameters();
        uint256 liqAsset = perpPair.globalLiquidityAsset();
        //uint256 input = CurveMath.computeExactAmountInLong(999999 * 1e15, 100 * oracleDecimals, oracleDecimals, liqAsset, liq, liqAsset, shortCurveParameterA, shortCurveParameterB, curveParameterDecimals);
        vm.prank(charlie);
        perpPair.trade(true, 103_729 * 1e18, 100 * 1e5, liqAsset, frontendAddress, 1, fakeReport);

        vm.prank(charlie);
        perpPair.trade(false, 1 * 1e18, 100 * 1e5, liqAsset, frontendAddress, 1, fakeReport);

        liqAsset = perpPair.globalLiquidityAsset();

        vm.expectRevert();
        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e30, frontendAddress, fakeReport);
    }

    function testClosingDustEdgeCase() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 100_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 5000 * 1e18;
        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);
        tradeSize = 100 * 1e18;
        liq = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        oracle.setPrice(200 * oracleDecimals);

        tradeSize = 5500 * 1e18;
        liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        tradeSize = 1 * 1e18;
        liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);
        (uint256 bobStableBalance, uint256 bobAssetBalance, uint256 bobStableDebt, uint256 bobAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        console.log(bobStableBalance, bobAssetBalance, bobStableDebt, bobAssetDebt);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e30, frontendAddress, fakeReport);

        uint256 assets = perpPair.globalLiquidityAsset();
        console.log(assets);
        // After the close, the pool's asset side differs from the initial deposit only by
        // the buy-back residual, which the C0 dust bound caps at
        // max(1e10, globalLiquidityStable / 1e10) in stable value; converted to asset units at
        // the close price of 200.
        vm.assertApproxEqAbs(assets, aliceLiquidityAsset, perpPair.globalLiquidityStable() / 1e10 / 200);
    }

    function testFrontendFeeWaivingContability() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 1000 * 1e18;

        address frontendUsed = address(0);

        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendUsed, 1, fakeReport);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 tradingFeeValue = tradeSize * tradingFee / tradingFeeDecimals + flatFee;
        uint256 actualTradingFeeValue = tradingFeeValue;
        if (frontendUsed == address(0)) {
            actualTradingFeeValue = tradingFeeValue - tradingFeeValue * feeFrontend / feeFractionDecimals;
        }

        (uint256 FrontendStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendAddress);
        (uint256 ProtocolStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(feeProtocolAddr);
        (uint256 zeroStableBalance,,,,,,,) = perpPair.userVirtualTraderPosition(frontendUsed);

        //console.log(aliceLiquidityStable, aliceLiquidityStable+actualTradeSize, liq);
        (uint256 pnlAlice, bool pnlAliceSign) = perpPair.calcPnL(alice, price);
        console.log(pnlAlice, pnlAliceSign);
        console.log(tradingFeeValue / 2);

        vm.assertApproxEqAbs(pnlAlice, tradingFeeValue / 2, pnlAlice / 100);

        assertTrue(FrontendStableBalance == 0, "frontend fee");
        assertTrue(zeroStableBalance == 0, "zero fee");
        console.log(
            ProtocolStableBalance,
            (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8
        );
        assertTrue(
            ProtocolStableBalance
                == (feeFractionDecimals - feeFrontend - feeLP) * tradingFeeValue / feeFractionDecimals - 1e8,
            "protocol fee"
        );
        (uint256 insFund,) = perpPair.ReadInsuranceFund();
        assertTrue(insFund == 1e8, "Ins fund");
    }

    function testZeroPositionRemoveCollateralExploit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        price = 90 * oracleDecimals;
        oracle.setPrice(price);

        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(bob, price);
        console.log(pnl, pnlSign);

        vm.assertTrue(!pnlSign);
        vm.assertApproxEqAbs(pnl, tradeSize / 10, pnl / 30);

        vm.expectRevert();
        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);

        (uint256 bobStableBalance, uint256 bobAssetBalance, uint256 bobStableDebt, uint256 bobAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        vm.prank(bob);
        perpPair.trade(false, bobAssetBalance, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (bobStableBalance, bobAssetBalance, bobStableDebt, bobAssetDebt,,,,) = perpPair.userVirtualTraderPosition(bob);
        console.log(bobAssetBalance, bobAssetDebt);

        if (pnl > 0 && !pnlSign) {
            vm.expectRevert();
        }
        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);

        (pnl, pnlSign) = perpPair.calcPnL(bob, price);
        console.log(perpPair.getCollateral(bob), pnl, pnlSign);
    }

    function testForcingLiquidationExploit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 12_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0 * 1e6;
        amounts[1] = 100 * 1e18;

        vm.prank(bob);
        vault.addCollateral(amounts);

        uint256 tradeSize = 1000 * 1e18;
        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        uint256 mr = UtilMath.calcMR(
            bob, price, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        console.log(mr);

        address charlie = makeAddr("charlie");
        liq = perpPair.globalLiquidityStable();
        tradeSize = (liq - 2000 * 18) / 100;
        vm.prank(charlie);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        mr = UtilMath.calcMR(
            bob, price, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        liq = perpPair.globalLiquidityStable();
        console.log(mr, liq);

        (uint256 bobStableBalance, uint256 bobAssetBalance, uint256 bobStableDebt, uint256 bobAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        address david = makeAddr("david");

        vm.expectRevert(bytes("LQ1"));
        vm.prank(david);
        perpPair.liquidate(bob, bobAssetBalance, fakeReport);
    }

    function testLiquidationBadDebtExploit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 100_000 * 1e18;
        uint256 aliceLiquidityAsset = 1000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        vault.removeAllCollateral(fakeReport);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0 * 1e6;
        // The live curve (A=1e8, B=1e7) makes a full-pool-sized short realize far more
        // slippage than the test-era curve this scenario was solved against (~30k stable
        // baked into balanceStable at open), so bob needs more collateral than the
        // original 25k to clear T1 at open — but must stay under ~44k so the spot-based
        // margin ratio is still liquidatable after the move to 109. The bad-debt
        // condition holds regardless: after charlie's drain, buying back 1000 asset from
        // a pool holding barely more than that costs orders of magnitude more.
        amounts[1] = 40_000 * 1e18;

        vm.prank(bob);
        vault.addCollateral(amounts);

        uint256 tradeSize = 1000 * 1e18;
        uint256 liq = perpPair.globalLiquidityStable();
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, liq, frontendAddress, 1, fakeReport);

        address charlie = makeAddr("charlie");
        tradeSize = 1000 * 1e18;
        liq = perpPair.globalLiquidityStable();
        uint256 liqAsset = perpPair.globalLiquidityAsset();
        // Re-solve the near-pool-drain input against the LIVE curve parameters (the
        // original author's method, previously hardcoded as 102_859e18 for the test-era
        // curve): charlie's long must leave the asset side just ABOVE bob's debt, so the
        // liquidation takes the curve branch whose cost explodes into the spot-price
        // bad-debt fallback.
        uint256 charlieInput;
        {
            (,,, uint256 bobAssetDebt0,,,,) = perpPair.userVirtualTraderPosition(bob);
            (,, uint256 longA, uint256 longB,,,,) = perpPair.curveParameters();
            uint256 targetOut = liqAsset - bobAssetDebt0 - 1e18;
            uint256 exactIn = CurveMath.computeExactAmountInLong(
                targetOut,
                100 * oracleDecimals,
                oracleDecimals,
                liq,
                liq,
                liqAsset,
                longA,
                longB,
                curveParameterDecimals
            );
            (uint256 tradingFee_, uint256 flatFee_,,,,,) = perpPair.ReadFees();
            charlieInput = (exactIn + flatFee_) * tradingFeeDecimals / (tradingFeeDecimals - tradingFee_);
        }
        vm.prank(charlie);
        perpPair.trade(true, charlieInput, 100 * 1e5, liqAsset, frontendAddress, 1, fakeReport);

        liqAsset = perpPair.globalLiquidityAsset();

        price = 109 * oracleDecimals;
        oracle.setPrice(price);

        uint256 mr = UtilMath.calcMR(
            bob, price, address(perpPair), perpPair.getCollateral(bob), perpPair.lastOperationTimestamp()
        );
        liq = perpPair.globalLiquidityStable();
        console.log(mr, liq);

        (uint256 bobStableBalance, uint256 bobAssetBalance, uint256 bobStableDebt, uint256 bobAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        (uint256 bobPnl, bool bobPnlSign) = perpPair.calcPnL(bob, price);

        console.log(bobPnl, bobPnlSign);

        address david = makeAddr("david");
        vm.prank(david);
        perpPair.liquidate(bob, bobAssetDebt, fakeReport);

        (uint256 davidStableBalance, uint256 davidAssetBalance, uint256 davidStableDebt, uint256 davidAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(david);
        console.log(davidStableBalance, davidAssetBalance, davidStableDebt, davidAssetDebt);
        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(david, price);
        console.log(pnl, pnlSign);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset * 100, maxUserLiquidityFee, fakeReport);

        (davidStableBalance, davidAssetBalance, davidStableDebt, davidAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(david);

        console.log(davidStableBalance, davidAssetBalance, davidStableDebt, davidAssetDebt);
        (uint256 pnl2, bool pnlSign2) = perpPair.calcPnL(david, price);
        console.log(pnl2, pnlSign2);

        // After alice re-deepens the pool, david's profit must normalize to the
        // liquidation discount on the spot value of the seized position — the
        // drained-pool windfall (pnl, orders of magnitude larger) must not survive.
        // d replicates _computeLiquidationDiscount at bob's margin ratio; david nets
        // (d - d/6) of spot, the d/6 going to the insurance fund. Tolerance stays a
        // tenth of the pre-re-add distorted pnl, as in the original assert.
        (,,,,,, uint256 liqDiscount) = perpPair.ReadFees();
        uint256 d = mr <= MMR / 2
            ? (liqDiscount * (1e10 + (MMR / 2 - mr) * 1e10 / (MMR / 2))) / 1e10
            : (liqDiscount / 2 * (1e10 + (MMR - mr) * 1e10 / (MMR - MMR / 2))) / 1e10;
        uint256 expectedDiscountValue = (d - d / 6) * (bobAssetDebt * price / oracleDecimals) / feeFractionDecimals;
        vm.assertApproxEqAbs(expectedDiscountValue, pnl2, pnl / 10);
    }

    ///@dev Test that LP exits do not affect total trader exposure after shorts are open.
    function testLpExitDoesNotAffectTraderExposureAfterShorts() public {
        oracle.setPrice(100 * oracleDecimals);

        // === Step 1: large LP deposits full (stable+asset) liquidity ===
        address alice = makeAddr("alice");
        uint256 aliceStable = 10_000 * 1e18;
        uint256 aliceAsset = 100 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        // === Step 2: small LP deposits only asset liquidity ===
        address bob = makeAddr("bob");
        uint256 bobStable = 0;
        uint256 bobAsset = 100 * 1e18;
        vm.prank(bob);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);

        // === Step 3: a few short trades occur ===
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        uint256 shortSize1 = 5 * 1e18;
        uint256 shortSize2 = 7 * 1e18;

        uint256 liq = perpPair.globalLiquidityStable();
        vm.prank(charlie);
        perpPair.trade(false, shortSize1, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        liq = perpPair.globalLiquidityStable();
        vm.prank(david);
        perpPair.trade(false, shortSize2, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        uint256 totalExpBefore = perpPair.totalTraderExposure();

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        uint256 totalExpAfter = perpPair.totalTraderExposure();

        // === Step 7: ensure trader exposures are unchanged ===
        assertTrue(
            inConfidenceInterval(totalExpAfter, totalExpBefore, 10), "Total trader exposure changed after LP exit"
        );
    }

    ///@dev Test that LP exits do not affect total trader exposure after shorts are open.
    function testLpExitDoesNotAffectTraderExposureAfterLongs() public {
        oracle.setPrice(100 * oracleDecimals);

        // === Step 1: large LP deposits full (stable+asset) liquidity ===
        address alice = makeAddr("alice");
        uint256 aliceStable = 10_000 * 1e18;
        uint256 aliceAsset = 100 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        // === Step 2: small LP deposits only asset liquidity ===
        address bob = makeAddr("bob");
        uint256 bobStable = 10_000 * 1e18;
        uint256 bobAsset = 0;
        vm.prank(bob);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);

        // === Step 3: a few long trades occur ===
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        uint256 longSize1 = 500 * 1e18;
        uint256 longSize2 = 700 * 1e18;

        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(charlie);
        perpPair.trade(true, longSize1, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        liq = perpPair.globalLiquidityAsset();
        vm.prank(david);
        perpPair.trade(true, longSize2, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        uint256 totalExpBefore = perpPair.totalTraderExposure();

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        uint256 totalExpAfter = perpPair.totalTraderExposure();

        // === Step 7: ensure trader exposures are unchanged ===
        assertTrue(
            inConfidenceInterval(totalExpAfter, totalExpBefore, 10), "Total trader exposure changed after LP exit"
        );
    }

    ///@dev Test that LP exits do not affect total trader exposure after shorts are open.
    function testRealizePnL() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        // === Step 1: large LP deposits full (stable+asset) liquidity ===
        address alice = makeAddr("alice");
        uint256 aliceStable = 10_000 * 1e18;
        uint256 aliceAsset = 100 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        // === Step 3: a few long trades occur ===
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        uint256 shortSize = 5 * 1e18;
        uint256 longSize = 700 * 1e18;

        uint256 liq = perpPair.globalLiquidityStable();
        vm.prank(charlie);
        perpPair.trade(false, shortSize, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        liq = perpPair.globalLiquidityAsset();
        vm.prank(david);
        perpPair.trade(true, longSize, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        price = 110 * oracleDecimals;
        oracle.setPrice(price);

        uint256 charlieColl1 = perpPair.getCollateral(charlie);
        (uint256 charliePnL1, bool charliePnLSign1) = perpPair.calcPnL(charlie, price);
        uint256 davidColl1 = perpPair.getCollateral(david);
        (uint256 davidPnL1, bool davidPnLSign1) = perpPair.calcPnL(david, price);
        console.log(charlieColl1, charliePnL1, charliePnLSign1);
        console.log(davidColl1, davidPnL1, davidPnLSign1);

        vm.prank(charlie);
        perpPair.realizePnL(fakeReport);
        vm.prank(david);
        perpPair.realizePnL(fakeReport);

        uint256 charlieColl2 = perpPair.getCollateral(charlie);
        (uint256 charliePnL2, bool charliePnLSign2) = perpPair.calcPnL(charlie, price);
        uint256 davidColl2 = perpPair.getCollateral(david);
        (uint256 davidPnL2, bool davidPnLSign2) = perpPair.calcPnL(david, price);
        console.log(charlieColl2, charliePnL2, charliePnLSign2);
        console.log(davidColl2, davidPnL2, davidPnLSign2);

        vm.assertEq(charlieColl2, charlieColl1 - charliePnL1);
        vm.assertEq(davidColl2, davidColl1 + davidPnL1);
        vm.assertEq(charliePnL2, 0);
        vm.assertEq(davidPnL2, 0);
    }

    ///@dev Test that LP exits do not affect total trader exposure after shorts are open.
    function testRealizePnLLP() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        // === Step 1: large LP deposits full (stable+asset) liquidity ===
        address alice = makeAddr("alice");
        uint256 aliceStable = 10_000 * 1e18;
        uint256 aliceAsset = 100 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        // === Step 3: a few long trades occur ===
        address charlie = makeAddr("charlie");
        address david = makeAddr("david");
        uint256 shortSize = 5 * 1e18;
        uint256 longSize = 700 * 1e18;

        uint256 liq = perpPair.globalLiquidityStable();
        vm.prank(charlie);
        perpPair.trade(false, shortSize, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        liq = perpPair.globalLiquidityAsset();
        vm.prank(david);
        perpPair.trade(true, longSize, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);

        price = 110 * oracleDecimals;
        oracle.setPrice(price);

        uint256 aliceColl1 = perpPair.getCollateral(alice);
        (uint256 alicePnL1, bool alicePnLSign1) = perpPair.calcPnL(alice, price);
        console.log(aliceColl1, alicePnL1, alicePnLSign1);

        vm.prank(alice);
        perpPair.realizePnL(fakeReport);

        uint256 aliceColl2 = perpPair.getCollateral(alice);
        (uint256 alicePnL2, bool alicePnLSign2) = perpPair.calcPnL(alice, price);
        console.log(aliceColl2, alicePnL2, alicePnLSign2);

        vm.assertEq(aliceColl2, aliceColl1 - alicePnL1);
        vm.assertEq(alicePnL2, 0);
    }

    function testLpCloseAndWithdraw() public {
        // 1. Set initial oracle price
        oracle.setPrice(100 * oracleDecimals);

        // 2. Create LP (Alice)
        address alice1 = makeAddr("david");
        uint256 aliceLiquidityStable1 = 100_000 * 1e18;
        uint256 aliceLiquidityAsset1 = 1000 * 1e18;

        // 3. LP adds liquidity
        vm.prank(alice1);
        perpPair.addLiquidity(aliceLiquidityStable1, aliceLiquidityAsset1, maxUserLiquidityFee, fakeReport);

        // 2. Create LP (Alice)
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000 * 1e18;
        uint256 aliceLiquidityAsset = 100 * 1e18;

        vm.prank(alice);
        Vault(vault).removeCollateral(((2 * 10_000_000) - 2000) * 1e18, fakeReport);
        // 3. LP adds liquidity
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        perpPair.trade(true, 1000 * 1e18, 0, 0, frontendAddress, 1, fakeReport);

        vm.prank(bob);
        perpPair.trade(false, 1 * 1e17, 0, 0, frontendAddress, 1, fakeReport);

        // 4. Simulate time passing and price change
        skip(1000);
        oracle.setPrice(50 * oracleDecimals);

        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(alice, 10 * oracleDecimals);

        uint256 collBefore = perpPair.getCollateral(alice);
        // 5. LP calls closeAndWithdraw — withdraws all liquidity
        vm.prank(alice);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        uint256 collAfter = perpPair.getCollateral(alice);

        console.log(collBefore, collAfter);

        // 6. Validate LP has no remaining virtual position or debt
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(alice);

        assertTrue(
            balanceStable == 0 && balanceAsset == 0 && debtStable == 0 && debtAsset == 0, "LP position not closed"
        );
    }

    function testTradeSysLpCloseAndWithdraw() public {
        // 1. Set initial oracle price
        oracle.setPrice(100 * oracleDecimals);

        // 2. Create LP (Alice)
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000 * 1e18;
        uint256 aliceLiquidityAsset = 100 * 1e18;

        // 3. LP adds liquidity
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        perpPair.trade(true, 1000 * 1e18, 0, 0, frontendAddress, 1, fakeReport);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        // 5. LP calls closeAndWithdraw — withdraws all liquidity
        vm.prank(alice);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);
    }

    function testSysLpCloseAndWithdraw() public {
        // 1. Set initial oracle price
        uint256 price = 65_000;
        oracle.setPrice(price * oracleDecimals);

        address alice = makeAddr("alice");
        vm.prank(alice);
        Vault(vault).removeCollateral((2 * 10_000_000 - 200_000) * 1e18, fakeReport);
        uint256 aliceLiquidityStable = 400_000 * 1e18;
        uint256 aliceLiquidityAsset = 400_000 * 1e18 / price;

        // 3. LP adds liquidity
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        // 4. Simulate time passing and price change
        skip(1000);
        oracle.setPrice(67_000 * oracleDecimals);

        // 5. LP calls closeAndWithdraw — withdraws all liquidity
        vm.prank(alice);
        multiCallManager.closeAndRemoveAllCollateral(1e5, 0, frontendAddress, fakeReport);

        //perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);
    }

    function testLiquidityVsTraderExposureSymmetry() public {
        // === Setup oracle ===
        oracle.setPrice(100 * oracleDecimals);

        // === Step 1: Alice provides large liquidity ===
        address alice = makeAddr("alice");
        uint256 aliceStable = 100_000 * 1e18;
        uint256 aliceAsset = 1000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        // === Step 2: Bob provides smaller liquidity ===
        address bob = makeAddr("bob");
        uint256 bobStable = 10_000 * 1e18;
        uint256 bobAsset = 100 * 1e18;
        vm.prank(bob);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);

        // === Step 3: Charlie provides same liquidity as Bob ===
        address charlie = makeAddr("charlie");
        uint256 charlieStable = bobStable;
        uint256 charlieAsset = bobAsset;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieStable, charlieAsset, maxUserLiquidityFee, fakeReport);

        // === Step 4: Bob opens a trade ===
        uint256 tradeSize = 1000 * 1e18;
        uint256 liq = perpPair.globalLiquidityAsset();
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 0, liq, frontendAddress, 1, fakeReport);

        // === Step 5: David trades same size as Bob ===
        address david = makeAddr("david");
        vm.prank(david);
        perpPair.trade(true, tradeSize, 0, liq, frontendAddress, 1, fakeReport);

        // === Step 6: simulate a price movement ===
        skip(3600); // advance time
        uint256 price = 105 * oracleDecimals;
        oracle.setPrice(price); // 5% up

        //perpPair.updateFG(fakeReport);
        (uint256 davidPnL, bool davidPnLSign) = UtilMath.calcPnLNoExit(david, price, address(perpPair));
        (uint256 alicePnL, bool alicePnLSign) = UtilMath.calcPnLNoExit(alice, price, address(perpPair));
        (uint256 bobPnL, bool bobPnLSign) = UtilMath.calcPnLNoExit(bob, price, address(perpPair));
        (uint256 charliePnL, bool charliePnLSign) = UtilMath.calcPnLNoExit(charlie, price, address(perpPair));

        (uint256 totalPnl, bool totalPnlSign) = UtilMath.signedSum(alicePnL, alicePnLSign, bobPnL, bobPnLSign);
        (totalPnl, totalPnlSign) = UtilMath.signedSum(totalPnl, totalPnlSign, charliePnL, charliePnLSign);
        (totalPnl, totalPnlSign) = UtilMath.signedSum(totalPnl, totalPnlSign, davidPnL, davidPnLSign);

        (uint256 pnl, bool pnlSign) =
            perpPair.calcPnL(feeProtocolAddr, SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()));
        //console.log("exposition");
        console.log(pnl, pnlSign, "protocol");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(pnl, pnlSign, totalPnl, totalPnlSign);

        (pnl, pnlSign) =
            perpPair.calcPnL(frontendAddress, SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()));
        //console.log("exposition");
        console.log(pnl, pnlSign, "frontend");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(pnl, pnlSign, totalPnl, totalPnlSign);

        (uint256 insFund, bool insFundSign) = perpPair.ReadInsuranceFund();
        console.log(insFund, insFundSign, "insFund");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(insFund, insFundSign, totalPnl, totalPnlSign);

        console.log(totalPnl, "total");

        console.log(alicePnL, alicePnLSign);
        console.log(bobPnL, bobPnLSign);
        console.log(charliePnL, charliePnLSign);
        console.log(davidPnL, davidPnLSign);

        vm.prank(alice);
        perpPair.trade(true, 2 * 1e18, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);
        //vm.prank(bob);
        //perpPair.trade(true, 2*1e18, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);
        //vm.prank(charlie);
        //perpPair.trade(true, 2*1e18, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);
        vm.prank(david);
        perpPair.trade(true, 2 * 1e18, 100 * oracleDecimals, liq, frontendAddress, 1, fakeReport);
        (,, uint256 aLPStableDebt, uint256 bLPAssetDebt) = perpPair.liquidityPosition(alice);
        (uint256 aLPStableBalance, uint256 aLPAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (uint256 aStableBalance, uint256 aAssetBalance, uint256 aStableDebt, uint256 aAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(alice);
        (uint256 bStableBalance, uint256 bAssetBalance, uint256 bStableDebt, uint256 bAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(bob);
        (uint256 cStableBalance, uint256 cAssetBalance, uint256 cStableDebt, uint256 cAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(charlie);
        (uint256 dStableBalance, uint256 dAssetBalance, uint256 dStableDebt, uint256 dAssetDebt,,,,) =
            perpPair.userVirtualTraderPosition(david);

        /*




        ( alicePnL,  alicePnLSign) = UtilMath.calcPnLNoExit(alice, price, address(perpPair));
        ( bobPnL,  bobPnLSign) = UtilMath.calcPnLNoExit(bob, price, address(perpPair));
        ( charliePnL,  charliePnLSign) = UtilMath.calcPnLNoExit(charlie, price, address(perpPair));
        ( davidPnL,  davidPnLSign) = UtilMath.calcPnLNoExit(david, price, address(perpPair));

        ( totalPnl,  totalPnlSign) = UtilMath.signedSum(alicePnL, alicePnLSign, bobPnL, bobPnLSign);
        (totalPnl, totalPnlSign) = UtilMath.signedSum(totalPnl, totalPnlSign, charliePnL, charliePnLSign);
        (totalPnl, totalPnlSign) = UtilMath.signedSum(totalPnl, totalPnlSign, davidPnL, davidPnLSign);

        ( pnl,  pnlSign) = perpPair.calcPnL(feeProtocolAddr, SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()));
        //console.log("exposition");
        console.log(pnl, pnlSign, "protocol");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(pnl, pnlSign, totalPnl, totalPnlSign);

        (pnl, pnlSign) = perpPair.calcPnL(frontendAddress, SafeCast.toUint256(IOracleMiddleware(perpPair.oracle()).getPrice()));
        //console.log("exposition");
        console.log(pnl, pnlSign, "frontend");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(pnl, pnlSign, totalPnl, totalPnlSign);

         insFund = perpPair.insuranceFund();
         insFundSign = perpPair.insuranceFundSign();
        console.log(insFund, insFundSign, "insFund");
        (totalPnl, totalPnlSign) = UtilMath.signedSum(insFund, insFundSign, totalPnl, totalPnlSign);

        console.log(totalPnl, "total");

        console.log(alicePnL, alicePnLSign);
        console.log(bobPnL, bobPnLSign);
        console.log(charliePnL, charliePnLSign);
        console.log(davidPnL, davidPnLSign);



        (,,,, uint256 fundingFeeAlice, bool fundingFeeSignAlice,,) = perpPair.userVirtualTraderPosition(alice);
        (,,,, uint256 fundingFeeBob, bool fundingFeeSignBob,,) = perpPair.userVirtualTraderPosition(bob);
        (,,,, uint256 fundingFeeCharlie, bool fundingFeeSignCharlie,,) = perpPair.userVirtualTraderPosition(charlie);
        (,,,, uint256 fundingFeeDavid, bool fundingFeeSignDavid,,) = perpPair.userVirtualTraderPosition(david);

        console.log(fundingFeeAlice, fundingFeeSignAlice);
        console.log(fundingFeeBob, fundingFeeSignBob);
        console.log(fundingFeeCharlie, fundingFeeSignCharlie);
        console.log(fundingFeeDavid, fundingFeeSignDavid);

        /*
        // === Step 7: gather positions ===
        (
            uint256 bobBalStable, uint256 bobBalAsset,
            uint256 bobDebtStable, uint256 bobDebtAsset, , , ,
        ) = perpPair.userVirtualTraderPosition(bob);

        (
            uint256 davidBalStable, uint256 davidBalAsset,
            uint256 davidDebtStable, uint256 davidDebtAsset, , , ,
        ) = perpPair.userVirtualTraderPosition(david);

        (uint256 charlieBalStable, uint256 charlieBalAsset) = perpPair.getLpLiquidityBalance(charlie);

        // === Step 8: Compute approximate exposures / PnL ===
        // (placeholder math — you’ll plug in your own tolerance-based asserts)
        uint256 bobExposure = bobDebtStable + bobDebtAsset;
        uint256 davidExposure = davidDebtStable + davidDebtAsset;

        uint256 charlieExposure = charlieBalStable + charlieBalAsset;
        uint256 bobPnl = bobBalStable + bobBalAsset; // simplified placeholder
        uint256 davidPnl = davidBalStable + davidBalAsset;
        uint256 charliePnl = charlieBalStable + charlieBalAsset;

        // === Step 9: Assertions (tolerant comparisons) ===
        assertTrue(
            inConfidenceInterval(bobExposure, davidExposure + charlieExposure, 100),
            "Bob exposure not comparable to Charlie+David"
        );
        assertTrue(
            inConfidenceInterval(bobPnl, davidPnl + charliePnl, 100),
            "Bob PnL not comparable to Charlie+David"
        );

        // Optionally print debug values for tuning thresholds
        console.log("Bob exposure:", bobExposure);
        console.log("Charlie exposure:", charlieExposure);
        console.log("David exposure:", davidExposure);
        console.log("Bob PnL:", bobPnl);
        console.log("Charlie PnL:", charliePnl);
        console.log("David PnL:", davidPnl);
        */
    }

    //Test matrix math
    ///@dev Tests the inverse of a matrix computations, including revert if not invertible.
    function testInverseTwoByTwo() public pure {
        int256 liquidityMDecimals = 1e18;
        int256[2][2] memory a = [
            [int256(1) * liquidityMDecimals, int256(0) * liquidityMDecimals],
            [int256(0) * liquidityMDecimals, int256(1) * liquidityMDecimals]
        ];
        int256[2][2] memory inv = MatrixMath.inverseTwoByTwo(a, liquidityMDecimals);
        assertTrue(MatrixMath.equalTwoByTwoMatrix(inv, a), "Error on testInverseTwoByTwo, identity check");

        a = [
            [int256(2) * liquidityMDecimals, int256(3) * liquidityMDecimals],
            [int256(1) * liquidityMDecimals, int256(2) * liquidityMDecimals]
        ];
        inv = MatrixMath.inverseTwoByTwo(a, liquidityMDecimals);
        int256[2][2] memory res = [
            [int256(2) * liquidityMDecimals, int256(-3) * liquidityMDecimals],
            [int256(-1) * liquidityMDecimals, int256(2) * liquidityMDecimals]
        ];
        assertTrue(MatrixMath.equalTwoByTwoMatrix(inv, res), "Error on testInverseTwoByTwo, random matrix check");

        /*
        a = [
            [int256(2) * liquidityMDecimals, int256(3) * liquidityMDecimals],
            [int256(4) * liquidityMDecimals, int256(6) * liquidityMDecimals]
        ];
        vm.expectRevert(bytes("Error on inverseTwoByTwo: determinant is 0"));
        inv = MatrixMath.inverseTwoByTwo(a, liquidityMDecimals);
        */
    }

    function testTradingAsLp() public {
        // 1. Set initial oracle price
        oracle.setPrice(100 * oracleDecimals);

        // 2. Create LP (Alice)
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable1 = 100_000 * 1e18;
        uint256 aliceLiquidityAsset1 = 1000 * 1e18;

        // 3. LP adds liquidity
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable1, aliceLiquidityAsset1, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        perpPair.trade(true, 1000 * 1e18, 0, 0, frontendAddress, 1, fakeReport);

        // 4. Simulate time passing
        skip(1000);

        vm.prank(alice);
        perpPair.trade(false, 200 * 1e16, 0, 0, frontendAddress, 1, fakeReport);

        // 4. Simulate time passing
        skip(1000);

        (, uint256 flatFee,,,,,) = perpPair.ReadFees();
        uint256 totalLiquidityAsset = perpPair.globalLiquidityAsset();
        uint256 minTrade = 1e18;

        uint256 fundingFee;
        bool fundingFeeSign;

        vm.prank(alice);
        perpPair.trade(true, minTrade + flatFee + 1e17, 0, totalLiquidityAsset, frontendAddress, 1, fakeReport);
        (,,,, fundingFee, fundingFeeSign,,) = perpPair.userVirtualTraderPosition(alice);
        console.log(fundingFee, fundingFeeSign);
        vm.prank(bob);
        perpPair.trade(true, minTrade + flatFee + 1e17, 0, totalLiquidityAsset, frontendAddress, 1, fakeReport);
        (,,,, fundingFee, fundingFeeSign,,) = perpPair.userVirtualTraderPosition(bob);
        console.log(fundingFee, fundingFeeSign);
    }

    //Support functions
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
    /*
    function _computeLiquidationDiscount(uint256 marginRatio) private view returns (uint256 discount) {
        uint256 step1 = MMR;
        uint256 step0 = MMR/2;
        uint256 discount1 = perpPair.liquidationDiscount();
        uint256 discount0 = discount1*2;

        if (marginRatio <= step0) {
            unchecked {
                discount = (discount0 / 2 * (1e10 + (step0 - marginRatio) * 1e10 / step0)) / 1e10;
            }
        } else {
            unchecked {
                discount = (discount1 / 2 * (1e10 + (step1 - marginRatio) * 1e10 / (step1 - step0))) / 1e10;
            }
        }
    }
    */
}
