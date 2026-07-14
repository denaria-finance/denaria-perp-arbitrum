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
    bytes32 tickerAsset;
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
            stablecoin.configureMinter(MasterMinter, 1e50);
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

    //test curvemath. Expected values obtained with python.
    ///@dev Test long return function.
    function testComputeLongReturn() public {
        uint256 size = 1000 * currencyDecimals;
        uint256 spotPrice = 3000 * oracleDecimals;
        uint256 globalLiquidityAsset = 6000 * currencyDecimals;
        uint256 initialGuess = globalLiquidityAsset - 3 * currencyDecimals / 10;
        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(10_000_000 * 1e18, 6000 * 1e18, maxUserLiquidityFee, fakeReport);

        uint256 expected = 333_333_049_680_115_644;
        uint256 tolerance = 10; //0.01% tolerance

        (,, uint256 longCurveParameterA, uint256 longCurveParameterB,,,,) = perpPair.curveParameters();

        uint256 result = CurveMath.computeLongReturn(
            size,
            spotPrice,
            oracleDecimals,
            initialGuess,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );

        assert(
            (result < expected * (100_000 + tolerance) / 100_000)
                && (result > expected * (100_000 - tolerance) / 100_000)
        );
    }

    ///@dev Test short return function.
    function testComputeShortReturn() public {
        uint256 size = 33 * currencyDecimals / 100;
        uint256 spotPrice = 3000 * oracleDecimals;
        uint256 globalLiquidityStable = 10_000_000 * currencyDecimals;
        uint256 initialGuess = globalLiquidityStable - 1500 * currencyDecimals;

        oracle.setPrice(spotPrice);
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(10_000_000 * 1e18, 6000 * 1e18, maxUserLiquidityFee, fakeReport);

        uint256 expected = 989_997_330_479_323_900_000;
        uint256 tolerance = 10; //0.01% tolerance

        (uint256 shortCurveParameterA, uint256 shortCurveParameterB,,,,,,) = perpPair.curveParameters();

        uint256 result = CurveMath.computeShortReturn(
            size,
            spotPrice,
            oracleDecimals,
            initialGuess,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        assert(
            (result < expected * (100_000 + tolerance) / 100_000)
                && (result > expected * (100_000 - tolerance) / 100_000)
        );
        //TODO: aggiungere test per altri casi
    }

    ///@dev Test cubic parameters computations for short trades.
    function testCubicParametersShort() public view {
        //SHORT
        uint256 size = 330_000_000_000_000_000;
        uint256 price = 300_000_000_000;
        uint256 ySquare = 100_000_000_000_000_000_000_000_000_000_000;
        uint256 initialStable = 10_000_000 * 1e18;
        uint256 initialAsset = 6000 * 1e18;
        //uint256 curveParameterDecimals = 1e8;
        uint256 shortCurveParameterA = 100 * curveParameterDecimals;
        uint256 shortCurveParameterB = 1 * curveParameterDecimals;

        uint256 lambda = CurveMath.computeShortLambda(price, size, oracleDecimals, initialStable);
        assertTrue(lambda == 10_000_990_000_000_000_000_000_000, "Error on testCubicParameters: lambdaShort");
        uint256 a = CurveMath.computeA(lambda, ySquare);
        assertTrue(a == 10_002_970_294_039_702_990_000_000, "Error on testCubicParameters: aShort");
        (uint256 b, bool bSign) = CurveMath.computeShortB(
            ySquare,
            price,
            oracleDecimals,
            initialStable,
            initialAsset,
            lambda,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );
        assertTrue(b == 3_071_683_137_956_642_857_142_857_142_857_142, "Error on testCubicParameters: bShort");
        assertTrue(bSign, "Error on testCubicParameters: bSignShort");
        (uint256 c, bool cSign) = CurveMath.computeShortC(
            size,
            ySquare,
            price,
            oracleDecimals,
            initialStable,
            initialAsset,
            lambda,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );
        assertTrue(c == 27_713_493_364_250_000_000_000_000_000_000_000_000_000, "Error on testCubicParameters: cShort");
        assertTrue(!cSign, "Error on testCubicParameters: cSignShort");
        uint256 d = CurveMath.computeShortD(ySquare, shortCurveParameterB, curveParameterDecimals);
        assertTrue(
            d == 40_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000, "Error on testCubicParameters: dShort"
        );
    }

    ///@dev Test cubic parameters computations for long trades.
    function testCubicParametersLong() public view {
        //LONG
        uint256 size = 1_000_000_000_000_000_000_000;
        uint256 price = 300_000_000_000;
        uint256 initialStable = 10_000_000 * 1e18;
        uint256 initialAsset = 6000 * 1e18;
        //uint256 curveParameterDecimals = 1e8;
        uint256 longCurveParameterA = 100 * curveParameterDecimals;
        uint256 longCurveParameterB = 1 * curveParameterDecimals;
        uint256 xSquare = 36 * 1e24;

        uint256 lambda = CurveMath.computeLongLambda(price, size, initialAsset, oracleDecimals);
        assertTrue(lambda == 18_001_000_000_000_000_000_000_000, "Error on testCubicParameters: lambdaLong");
        uint256 a = CurveMath.computeA(lambda, xSquare);
        assertTrue(a == 162_027_001_500_027_777_777_777_777_777_777, "Error on testCubicParameters: aLong");
        (uint256 b, bool bSign) = CurveMath.computeLongB(
            xSquare,
            price,
            lambda,
            initialAsset,
            initialStable,
            oracleDecimals,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        assertTrue(b == 57_628_645_699_285_714_285_714_285_714_285_714_285, "Error on testCubicParameters: bLong");
        assertTrue(bSign, "Error on testCubicParameters: bSignLong");
        (uint256 c, bool cSign) = CurveMath.computeLongC(
            size,
            xSquare,
            price,
            lambda,
            initialAsset,
            initialStable,
            oracleDecimals,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        assertTrue(c == 328_255_692_557_142_857_142_857_142_857_142_844_285_000, "Error on testCubicParameters: cLong");
        assertTrue(!cSign, "Error on testCubicParameters: cSignLong");
        uint256 d = CurveMath.computeLongD(
            xSquare, price, initialAsset, oracleDecimals, longCurveParameterB, curveParameterDecimals
        );
        assertTrue(
            d == 139_968_000_000_000_000_000_000_000_000_000_000_000_000_000, "Error on testCubicParameters: dLong"
        );
    }

    ///@dev Test cubic parameter for the exact amount in short.
    function testCubicParametersInverseShort() public view {
        //SHORT
        uint256 size = 1000 * 1e18;
        uint256 price = 100 * oracleDecimals;
        uint256 initialStable = 20_000_000 * 1e18;
        uint256 initialAsset = 100_000 * 1e18;
        //uint256 curveParameterDecimals = 1e8;
        uint256 shortCurveParameterA = 100 * curveParameterDecimals;
        uint256 shortCurveParameterB = 2 * curveParameterDecimals;

        uint256 aPrime = CurveMath.computeAPrimePramShort(
            shortCurveParameterA, initialStable, price * initialAsset / oracleDecimals
        );
        (uint256 lambda, bool lambdaSign) = CurveMath.computeInverseLambdaShort(
            initialStable - size, initialStable, price * initialAsset / oracleDecimals
        );
        (uint256 k, bool kSign) = CurveMath.computeInverseKShort(initialStable, price * initialAsset / oracleDecimals);

        uint256 a = CurveMath.computeInverseAShort(initialStable - size, initialStable);
        (uint256 b, bool bSign) = CurveMath.computeInverseBShort(
            aPrime,
            initialStable - size,
            price,
            k,
            kSign,
            shortCurveParameterB,
            initialStable,
            curveParameterDecimals,
            oracleDecimals
        );
        (uint256 c, bool cSign) = CurveMath.computeInverseCShort(
            aPrime,
            price,
            initialStable - size,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            initialStable,
            curveParameterDecimals,
            oracleDecimals
        );
        (uint256 d, bool dSign) = CurveMath.computeInverseDShort(
            aPrime,
            price,
            initialStable - size,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            initialStable,
            curveParameterDecimals,
            oracleDecimals
        );

        assertTrue(aPrime == 53_333_333_333_333_333_333_333_333_333_333, "aPrime");
        assertTrue(lambda == 10_001_000 * 1e18 && !lambdaSign, "lambda");
        assertTrue(k == 10_000_000 * 1e18 && kSign, "k");
        assertTrue(a == 49_992_500_374, "a");
        console.log(b);
        assertTrue(b == 611_638_083_270_831_458 && bSign, "b");
        assertTrue(c == 17_493_008_642_916_479_166_667 && cSign, "c");
        assertTrue(d == 7_917_087_468_041_672_916_666_666_666 && !dSign, "d");
    }

    ///@dev Test cubic parameter for the exact amount in long.
    function testCubicParametersInverseLong() public view {
        //Long
        uint256 size = 10 * 1e18;
        uint256 price = 100 * oracleDecimals;
        uint256 initialStable = 20_000_000 * 1e18;
        uint256 initialAsset = 100_000 * 1e18;
        //uint256 curveParameterDecimals = 1e8;
        uint256 shortCurveParameterA = 100 * curveParameterDecimals;
        uint256 shortCurveParameterB = 2 * curveParameterDecimals;

        uint256 aPrime =
            CurveMath.computeAPrimePramLong(shortCurveParameterA, price, initialAsset, initialStable, oracleDecimals);
        (uint256 lambda, bool lambdaSign) =
            CurveMath.computeInverseLambdaLong(price, initialAsset - size, initialAsset, initialStable, oracleDecimals);
        (uint256 k, bool kSign) = CurveMath.computeInverseKLong(price, initialAsset, initialStable, oracleDecimals);

        uint256 a = CurveMath.computeInverseALong(initialAsset - size, initialAsset);
        (uint256 b, bool bSign) = CurveMath.computeInverseBLong(
            aPrime,
            initialAsset - size,
            price,
            k,
            kSign,
            shortCurveParameterB,
            initialAsset,
            oracleDecimals,
            curveParameterDecimals
        );
        (uint256 c, bool cSign) = CurveMath.computeInverseCLong(
            aPrime,
            initialAsset - size,
            price,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            initialAsset,
            oracleDecimals,
            curveParameterDecimals
        );
        (uint256 d, bool dSign) = CurveMath.computeInverseDLong(
            aPrime,
            initialAsset - size,
            price,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            initialAsset,
            oracleDecimals,
            curveParameterDecimals
        );

        assertTrue(aPrime == 333_333_333_333_333_333_333_333_333, "aPrime");
        assertTrue(lambda == 20_001_000 * 1e18 && !lambdaSign, "lambda");
        assertTrue(k == 10_000_000 * 1e18 && !kSign, "k");
        assertTrue(a == 9_997_000_299_990, "a");
        assertTrue(b == 2_333_229_984_000_299_999_999 && bSign, "b");
        assertTrue(c == 67_998_532_770_002_999_999_999_999_900 && !cSign, "c");
        assertTrue(d == 346_665_329_000_009_999_999_999_990_000_000_000 && dSign, "d");
    }

    ///@dev Test the output of the newton method for a short trade.
    function testNewtonMethodShort() public {
        uint256 a = 10_002_970_294_039_702_990_000_000;
        uint256 b = 3_071_683_137_956_642_857_142_857_142_857_142;
        bool bSign = true;
        uint256 c = 27_713_493_364_250_000_000_000_000_000_000_000_000_000;
        bool cSign = false;
        uint256 d = 40_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000;
        uint256 globalLiquidityStable = 10_000_000 * currencyDecimals;
        uint256 initialGuess = globalLiquidityStable - 1500 * currencyDecimals;

        uint256 result = CurveMath.newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, false);
        assertTrue(result == 9_999_010_002_669_525_949_832_700, "Error on testNewtonMethod: shortValues");
    }

    ///@dev Test the output of the newton method for a long trade.
    function testNewtonMethodLong() public {
        uint256 a = 162_027_001_500_027_777_777_777_777_777_777;
        uint256 b = 57_628_645_699_285_714_285_714_285_714_285_714_285;
        bool bSign = true;
        uint256 c = 328_255_692_557_142_857_142_857_142_857_142_844_285_000;
        bool cSign = false;
        uint256 d = 139_968_000_000_000_000_000_000_000_000_000_000_000_000_000;
        uint256 globalLiquidityAsset = 6000 * currencyDecimals;
        uint256 initialGuess = globalLiquidityAsset;

        uint256 result = CurveMath.newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, false);
        assertTrue(result == 5_999_666_666_950_319_884_356, "Error on testNewtonMethod: longValues");
    }

    ///@dev Test the output of the newton method for the exact amount in short.
    function testNewtonMethodInverseShort() public {
        uint256 a = 19_997_000_149_997_500_000_000_000;
        uint256 b = 244_655_233_308_332_583_333_333_333_333_331;
        bool bSign = true;
        uint256 c = 6_997_203_457_166_591_666_666_666_666_666_666_684;
        bool cSign = true;
        uint256 d = 3_166_834_987_216_669_166_666_666_666_666_649_999_166_750;
        bool dSign = false;
        uint256 initialGuess = 100_000 * 1e18;

        uint256 result = CurveMath.newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, dSign);
        assertTrue(
            UtilMath.diffAbs(result, 100_010_000_028_301_967_018_304) < 1e10, "Error on testNewtonMethod: shortValues"
        );
    }

    ///@dev Test the output of the newton method for the exact amount in long.
    function testNewtonMethodInverseLong() public {
        uint256 a = 9_997_000_299_990;
        uint256 b = 2_333_229_984_000_299_999_999;
        bool bSign = true;
        uint256 c = 67_998_532_770_002_999_999_999_999_900;
        bool cSign = false;
        uint256 d = 346_665_329_000_009_999_999_999_999_333_366_670;
        bool dSign = true;
        uint256 initialGuess = 20_000_000 * 1e18;

        uint256 result = CurveMath.newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, dSign);
        assertTrue(
            UtilMath.diffAbs(result, 20_001_000_010_714_400_682_285_413) < 1e10, "Error on testNewtonMethod: longValues"
        );
    }

    ///@dev Test the return of the exact amount in function for longs.
    function testcomputeExactAmountInLong() public {
        uint256 outputSize = 10 * currencyDecimals;
        uint256 spotPrice = 3000 * oracleDecimals;
        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(10_000_000 * 1e18, 6000 * 1e18, maxUserLiquidityFee, fakeReport);
        uint256 initialGuess = 10_030_000 * 1e18;

        uint256 expected = 30_000 * 1e18;
        uint256 tolerance = 10; //0.01% tolerance

        (uint256 shortCurveParameterA, uint256 shortCurveParameterB,,,,,,) = perpPair.curveParameters();

        uint256 result = CurveMath.computeExactAmountInLong(
            outputSize,
            spotPrice,
            oracleDecimals,
            initialGuess,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        uint256 actualOutput = CurveMath.computeLongReturn(
            result,
            spotPrice,
            oracleDecimals,
            6000 * 1e18,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        assert(
            (result < expected * (100_000 + tolerance) / 100_000)
                && (result > expected * (100_000 - tolerance) / 100_000)
        );
        assertTrue(inConfidenceInterval(outputSize, actualOutput, tolerance), "out=actualOut");
    }

    ///@dev Test the return of the exact amount in function for shorts.
    function testcomputeExactAmountInShort() public {
        uint256 outputSize = 1000 * currencyDecimals;
        uint256 spotPrice = 100 * oracleDecimals;
        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(10_000_000 * 1e18, 6000 * 1e18, maxUserLiquidityFee, fakeReport);
        uint256 initialGuess = 6010 * 1e18;

        uint256 expected = 10 * 1e18;
        uint256 tolerance = 10; //0.01% tolerance

        (uint256 shortCurveParameterA, uint256 shortCurveParameterB,,,,,,) = perpPair.curveParameters();

        uint256 result = CurveMath.computeExactAmountInShort(
            outputSize,
            spotPrice,
            oracleDecimals,
            initialGuess,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        uint256 actualOutput = CurveMath.computeShortReturn(
            result,
            spotPrice,
            oracleDecimals,
            10_000_000 * 1e18,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        assert(
            (result < expected * (100_000 + tolerance) / 100_000)
                && (result > expected * (100_000 - tolerance) / 100_000)
        );
        assertTrue(inConfidenceInterval(outputSize, actualOutput, tolerance), "out=actualOut");
    }

    //test add liquidity
    //Base case, 1lp, two sided
    ///@dev Test the addLiquidity function with a single LP and balanced liquidity
    function testAddLiquidityBase() public {
        oracle.setPrice(100 * oracleDecimals);
        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 100 * 1e18;
        //uint256 fee = perpPair.computeLiquidityDepositFee(liquidityStable, liquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);
        assert(
            perpPair.globalLiquidityStable() == liquidityStable && perpPair.globalLiquidityAsset() == liquidityAsset
            //&& perpPair.globalSharesStable() == liquidityStable && perpPair.globalSharesAsset() == liquidityAsset
        );
    }

    //Only stable, 1lp
    ///@dev Test the addLiquidity function with a single LP and only stable liquidity
    function testAddLiquidityOnlyStable() public {
        oracle.setPrice(100 * oracleDecimals);
        uint256 liquidityStable = 5000 * 1e18;
        uint256 liquidityAsset = 0;
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);
        assert(
            perpPair.globalLiquidityStable() == liquidityStable && perpPair.globalLiquidityAsset() == liquidityAsset
            //&& perpPair.globalSharesStable() == liquidityStable && perpPair.globalSharesAsset() == liquidityAsset
        );
    }

    //Only asset, 1lp
    ///@dev Test the addLiquidity function with a single LP and only asset liquidity
    function testAddLiquidityOnlyAsset() public {
        //only asset, 1 lp
        oracle.setPrice(100 * oracleDecimals);
        uint256 liquidityStable = 0;
        uint256 liquidityAsset = 50 * 1e18;
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);
        assert(
            perpPair.globalLiquidityStable() == liquidityStable && perpPair.globalLiquidityAsset() == liquidityAsset
            //&& perpPair.globalSharesStable() == liquidityStable && perpPair.globalSharesAsset() == liquidityAsset
        );
    }

    //Two sided, 2lp
    ///@dev Test the addLiquidity function with a two LP and balanced liquidity
    function testAddLiquidityTwoLp() public {
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000 * 1e18;
        uint256 aliceLiquidityAsset = 100 * 1e18;
        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 5000 * 1e18;
        uint256 bobLiquidityAsset = 200 * 1e18;

        oracle.setPrice(100 * oracleDecimals);

        uint256 aliceFee = 0;
        uint256 aliceFeeStable = aliceLiquidityStable * aliceFee / liquidityFeeDecimals;
        uint256 aliceFeeAsset = aliceLiquidityAsset * aliceFee / liquidityFeeDecimals;

        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        assertTrue(
            perpPair.globalLiquidityStable() == aliceLiquidityStable
                && perpPair.globalLiquidityAsset() == aliceLiquidityAsset,
            "Global liquidity"
        );
        //assertTrue(perpPair.globalSharesStable() == aliceLiquidityStable && perpPair.globalSharesAsset() == aliceLiquidityAsset,"Global shares");
        assertTrue(
            aliceStableBalance == aliceLiquidityStable && aliceAssetBalance == aliceLiquidityAsset, "Alice liquidity"
        );
        //assertTrue(aliceStableShares == aliceLiquidityStable && aliceAssetShares == aliceLiquidityAsset, "Alice shares");

        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();

        uint256 bobFee = FeeManager.computeLiquidityDepositFee(
            bobLiquidityStable,
            bobLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 bobFeeStable = bobLiquidityStable * bobFee / liquidityFeeDecimals;
        uint256 bobFeeAsset = bobLiquidityAsset * bobFee / liquidityFeeDecimals;

        uint256 totalFeeStable = aliceFeeStable + bobFeeStable;
        uint256 totalFeeAsset = aliceFeeAsset + bobFeeAsset;

        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        assertTrue(
            perpPair.globalLiquidityStable() == aliceLiquidityStable + bobLiquidityStable
                && perpPair.globalLiquidityAsset() == aliceLiquidityAsset + bobLiquidityAsset,
            "Final global liquidity"
        );
        //assertTrue(perpPair.globalSharesStable() == aliceLiquidityStable+bobLiquidityStable &&
        //        perpPair.globalSharesAsset() == aliceLiquidityAsset+bobLiquidityAsset
        //        ,"Final global shares");
        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(aliceStableShares, aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        // assertTrue(
        //     inConfidenceInterval(aliceStableBalance, aliceLiquidityStable + totalFeeStable + totalFeeAsset*100, 10000)
        //         && inConfidenceInterval(aliceAssetBalance, aliceLiquidityAsset, 10000),
        //     "Alice final liquidity"
        // );
        // assertTrue(
        //     inConfidenceInterval(bobStableBalance, bobLiquidityStable - bobFeeStable - bobFeeAsset*100, 10000)
        //         && inConfidenceInterval(bobAssetBalance, bobLiquidityAsset , 10000),
        //     "Bob final liquidity"
        // );
        //assertTrue(aliceStableShares == aliceLiquidityStable && aliceAssetShares == aliceLiquidityAsset, "Alice final shares");
        //assertTrue(bobStableShares == bobLiquidityStable && bobAssetShares == bobLiquidityAsset, "Bob final shares");
    }

    //Two sided, 2lp, 2 deposits
    ///@dev Test the addLiquidity function with a two LP and balanced liquidity, one LP does two deposits.
    function testAddLiquidityMultipleDeposits() public {
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 10_000 * 1e18;
        uint256 aliceLiquidityAsset = 100 * 1e18;
        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 15_000 * 1e18;
        uint256 bobLiquidityAsset = 100 * 1e18;

        oracle.setPrice(100 * oracleDecimals);

        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();

        uint256 aliceFee = FeeManager.computeLiquidityDepositFee(
            aliceLiquidityStable,
            aliceLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 aliceFeeStable = aliceLiquidityStable * aliceFee / liquidityFeeDecimals;
        uint256 aliceFeeAsset = aliceLiquidityAsset * aliceFee / liquidityFeeDecimals;
        uint256 bobFee = FeeManager.computeLiquidityDepositFee(
            bobLiquidityStable,
            bobLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 bobFeeStable = bobLiquidityStable * bobFee / liquidityFeeDecimals;
        uint256 bobFeeAsset = bobLiquidityAsset * bobFee / liquidityFeeDecimals;
        uint256 aliceFee2 = FeeManager.computeLiquidityDepositFee(
            aliceLiquidityStable / 2,
            aliceLiquidityAsset * 2,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 aliceFeeStable2 = aliceLiquidityStable / 2 * aliceFee2 / liquidityFeeDecimals;
        uint256 aliceFeeAsset2 = aliceLiquidityAsset * 2 * aliceFee2 / liquidityFeeDecimals;

        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable / 2, aliceLiquidityAsset * 2, maxUserLiquidityFee, fakeReport);

        assertTrue(
            perpPair.globalLiquidityStable() == aliceLiquidityStable * 3 / 2 + bobLiquidityStable
                && perpPair.globalLiquidityAsset() == aliceLiquidityAsset * 3 + bobLiquidityAsset,
            "Final global liquidity"
        );
        //assertTrue(perpPair.globalSharesStable() == aliceLiquidityStable*3/2+bobLiquidityStable-aliceFeeStable-aliceFeeStable2-bobFeeStable &&
        //        perpPair.globalSharesAsset() == aliceLiquidityAsset*3+bobLiquidityAsset-aliceFeeAsset-aliceFeeAsset2-bobFeeAsset
        //        ,"Final global shares");
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);

        uint256 totalAliceFeeStable =
            (aliceFeeStable + aliceFeeStable2 + bobFeeStable) * aliceStableBalance / perpPair.globalLiquidityStable();
        uint256 totalAliceFeeAsset =
            (aliceFeeAsset + aliceFeeAsset2 + bobFeeAsset) * aliceAssetBalance / perpPair.globalLiquidityAsset();
        uint256 totalBobFeeStable =
            (aliceFeeStable + aliceFeeStable2 + bobFeeStable) * bobStableBalance / perpPair.globalLiquidityStable();
        uint256 totalBobFeeAsset =
            (aliceFeeAsset + aliceFeeAsset2 + bobFeeAsset) * bobAssetBalance / perpPair.globalLiquidityAsset();

        assertTrue(
            inConfidenceInterval(
                aliceStableBalance,
                aliceLiquidityStable * 3 / 2 + totalAliceFeeStable - aliceFeeStable - aliceFeeStable2,
                100
            )
            && inConfidenceInterval(
                aliceAssetBalance, aliceLiquidityAsset * 3 + totalAliceFeeAsset - aliceFeeAsset - aliceFeeAsset2, 100
            ),
            "Alice final liquidity"
        );
        assertTrue(
            inConfidenceInterval(bobStableBalance, bobLiquidityStable + totalBobFeeStable - bobFeeStable, 100)
                && inConfidenceInterval(bobAssetBalance, bobLiquidityAsset + totalBobFeeAsset - bobFeeAsset, 100),
            "Bob final liquidity"
        );
        //assertTrue(aliceStableShares == aliceLiquidityStable*3/2-aliceFeeStable-aliceFeeStable2 && aliceAssetShares == aliceLiquidityAsset*3-aliceFeeAsset-aliceFeeAsset2, "Alice final shares");
        //assertTrue(bobStableShares == bobLiquidityStable-bobFeeStable && bobAssetShares == bobLiquidityAsset-bobFeeAsset , "Bob final shares");
    }

    //Only asset then both, 1lp
    ///@dev Test the addLiquidity function with a single LP and only asset liquidity
    function testAddLiquidityOnlyAssetFeeEdgeCase() public {
        //only asset, 1 lp
        oracle.setPrice(100 * oracleDecimals);
        uint256 aliceLiquidityStable = 0;
        uint256 aliceLiquidityAsset = 50 * 1e18;
        address alice = makeAddr("alice");

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 5000 * 1e18;
        uint256 bobLiquidityAsset = 200 * 1e18;

        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
        assert(
            perpPair.globalLiquidityStable() == aliceLiquidityStable
                && perpPair.globalLiquidityAsset() == aliceLiquidityAsset
            //&& perpPair.globalSharesStable() == aliceLiquidityStable && perpPair.globalSharesAsset() == aliceLiquidityAsset
        );

        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (aliceLiquidityStable, aliceLiquidityAsset) = perpPair.getLpLiquidityBalance(alice);
        (bobLiquidityStable, bobLiquidityAsset) = perpPair.getLpLiquidityBalance(bob);

        assert(
            perpPair.globalLiquidityStable() == aliceLiquidityStable + bobLiquidityStable
                && perpPair.globalLiquidityAsset() == aliceLiquidityAsset + bobLiquidityAsset
            //&& perpPair.globalSharesStable() == aliceLiquidityStable + bobLiquidityStable && perpPair.globalSharesAsset() == aliceLiquidityAsset + bobLiquidityAsset
        );
    }

    ///@dev Test the addLiquidity function reverting because of maxFee
    function testAddLiquidityFeeRevert() public {
        oracle.setPrice(100 * oracleDecimals);
        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 100 * 1e18;
        //uint256 fee = perpPair.computeLiquidityDepositFee(liquidityStable, liquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        vm.expectRevert(bytes("L2"));
        vm.prank(bob);
        perpPair.addLiquidity(liquidityStable * 2, liquidityAsset / 2, 1e18, fakeReport);
    }

    //test remove Liqudity
    ///@dev Test the remove liquidity function base case, 1 LP removes liquidity after depositing it.
    function testRemoveLiquidity1() public {
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        oracle.setPrice(100 * oracleDecimals);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 1_000_000 * 1e18;
        uint256 bobLiquidityAsset = 10_000 * 1e18;

        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();

        uint256 bobFee = FeeManager.computeLiquidityDepositFee(
            bobLiquidityStable,
            bobLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 bobFeeValue = (bobLiquidityStable + bobLiquidityAsset * 100) * bobFee / liquidityFeeDecimals;
        bobLiquidityStable -= bobFeeValue;

        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 0;
        uint256 charlieLiquidityAsset = 4000 * 1e18;
        uint256 charlieFee = FeeManager.computeLiquidityDepositFee(
            charlieLiquidityStable,
            charlieLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 charlieFeeValue =
            (charlieLiquidityStable + charlieLiquidityAsset * 100) * charlieFee / liquidityFeeDecimals;
        charlieLiquidityAsset -= charlieFeeValue / 100;

        address david = makeAddr("david");
        uint256 davidLiquidityStable = 200_000 * 1e18;
        uint256 davidLiquidityAsset = 0;
        uint256 davidFee = FeeManager.computeLiquidityDepositFee(
            davidLiquidityStable,
            davidLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(david);
        perpPair.addLiquidity(davidLiquidityStable, davidLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 davidFeeValue = (davidLiquidityStable + davidLiquidityAsset * 100) * davidFee / liquidityFeeDecimals;
        davidLiquidityStable -= davidFeeValue;

        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        uint256 aliceFeeRemoval = FeeManager.computeLiquidityRemovalFee(
            aliceStableBalance,
            aliceAssetBalance,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 aliceFeeValueRemoval =
            (aliceStableBalance + aliceAssetBalance * 100) * aliceFeeRemoval / liquidityFeeDecimals;
        vm.prank(alice);
        perpPair.removeLiquidity(aliceStableBalance, aliceAssetBalance, maxUserLiquidityFee, fakeReport); //fully exit

        uint256 charlieFeeRemoval = FeeManager.computeLiquidityRemovalFee(
            0,
            charlieLiquidityAsset * 3 / 4,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        uint256 charlieFeeValueRemoval =
            (charlieLiquidityAsset * 3 / 4 * 100) * charlieFeeRemoval / liquidityFeeDecimals;
        vm.prank(charlie);
        perpPair.removeLiquidity(0, charlieLiquidityAsset * 3 / 4, maxUserLiquidityFee, fakeReport); //remove 3/4 of his liquidity

        (uint256 davidStableBalance, uint256 davidAssetBalance) = perpPair.getLpLiquidityBalance(david);
        //uint256 davidFeeRemoval = perpPair.computeLiquidityRemovalFee(davidStableBalance/2, 0, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        //uint256 davidFeeValueRemoval = (davidStableBalance/2)*davidFeeRemoval/liquidityFeeDecimals;
        vm.prank(david);
        perpPair.removeLiquidity(davidStableBalance / 2, 0, maxUserLiquidityFee, fakeReport); //remove 1/2 of liquidity

        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        //(uint256 charlieStableShares, uint256 charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        //(uint256 davidStableShares, uint256 davidAssetShares) = perpPair.getLpLiquidityShares(david);
        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        (uint256 charlieStableBalance, uint256 charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);
        (uint256 davidStableBalance1,) = perpPair.getLpLiquidityBalance(david);

        //assertTrue(charlieStableShares==0 && charlieAssetShares == charlieLiquidityAsset/4, "charlie");
        //assertTrue(aliceStableShares==0 && aliceAssetShares == 0, "alice");
        //assertTrue(davidStableShares==davidLiquidityStable/2 && davidAssetShares == 0, "david");
        //assertTrue(bobStableShares==bobLiquidityStable && bobAssetShares == bobLiquidityAsset, "bob");
        assertTrue(aliceStableBalance == 0 && aliceAssetBalance == 0, "alice");

        // assertTrue(
        //     inConfidenceInterval(
        //         bobStableBalance, bobLiquidityStable + (aliceFeeValueRemoval + davidFeeValue + charlieFeeValue) / 2, 100
        //     ) && inConfidenceInterval(bobAssetBalance, bobLiquidityAsset, 100),
        //     "bob"
        // );
        // console.log(charlieStableBalance);
        // assertTrue(
        //     inConfidenceInterval(
        //         charlieStableBalance, charlieLiquidityStable + (aliceFeeValueRemoval + davidFeeValue) * 100 / 635, 100
        //     ) && inConfidenceInterval(charlieAssetBalance, charlieLiquidityAsset / 4, 100),
        //     "charlie"
        // );
        // assertTrue(
        //     inConfidenceInterval(
        //         davidStableBalance1, davidStableBalance / 2 + (aliceFeeValueRemoval + charlieFeeValueRemoval) / 5, 100
        //     ) && davidAssetBalance == 0,
        //     "david"
        // );
    }

    ///@dev Test the remove liquidity function guards, trying to remove more than available or less than the minimum possible.
    function testRemoveLiquidityRevert() public {
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        oracle.setPrice(100 * oracleDecimals);

        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 2_000_000 * 1e18;
        uint256 bobLiquidityAsset = 20_000 * 1e18;
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        vm.expectRevert(bytes("L5"));
        vm.prank(alice);
        perpPair.removeLiquidity(aliceStableBalance + 1, 0, maxUserLiquidityFee, fakeReport);

        vm.expectRevert(bytes("L5"));
        vm.prank(alice);
        perpPair.removeLiquidity(0, aliceAssetBalance + 1, maxUserLiquidityFee, fakeReport);

        vm.expectRevert(bytes("L5"));
        vm.prank(alice);
        perpPair.removeLiquidity(aliceStableBalance + 1, aliceAssetBalance + 1, maxUserLiquidityFee, fakeReport);
    }

    // ///@dev Test the remove liquidity function after 1 trade long has been performed on the liquidity.
    // function testRemoveLiquidityAfterTradeLong() public {
    //     address alice = makeAddr("alice");
    //     uint256 aliceLiquidityStable = 1_000_000 * 1e18;
    //     uint256 aliceLiquidityAsset = 10_000 * 1e18;
    //     oracle.setPrice(100 * oracleDecimals);

    //     vm.prank(alice);
    //     perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
    //     address bob = makeAddr("bob");
    //     uint256 bobLiquidityStable = 2_000_000 * 1e18;
    //     uint256 bobLiquidityAsset = 0;
    //     vm.prank(bob);
    //     perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
    //     address charlie = makeAddr("charlie");
    //     uint256 charlieLiquidityStable = 0;
    //     uint256 charlieLiquidityAsset = 20_000 * 1e18;
    //     vm.prank(charlie);
    //     perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

    //     address david = makeAddr("david");
    //     uint256 tradeSize = 1000 * 1e18;

    //     //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
    //     (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
    //     //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
    //     (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
    //     //(uint256 charlieStableShares, uint256 charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
    //     (uint256 charlieStableBalance, uint256 charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);

    //     uint256 totalLiquidityAsset = aliceAssetBalance + bobAssetBalance + charlieAssetBalance;
    //     assertTrue(totalLiquidityAsset == perpPair.globalLiquidityAsset(), "global assets");

    //     vm.prank(david);
    //     perpPair.trade(true, tradeSize, 100 * oracleDecimals, totalLiquidityAsset, frontendAddress, 1, fakeReport);

    //     //(aliceStableShares, aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
    //     (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
    //     //(bobStableShares, bobAssetShares) = perpPair.getLpLiquidityShares(bob);
    //     (bobStableBalance, bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
    //     //(charlieStableShares, charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
    //     (charlieStableBalance, charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);

    //     uint256 stableLiq = perpPair.globalLiquidityStable();
    //     uint256 assetLiq = perpPair.globalLiquidityAsset();

    //     (, , , uint256 _charlieLpDebtAsset) = perpPair.liquidityPosition(charlie);

    //     vm.prank(charlie);
    //     perpPair.removeLiquidity(charlieStableBalance, charlieAssetBalance, maxUserLiquidityFee, fakeReport);
    //     //(charlieStableShares, charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
    //     (uint256 charlieLpStableBalance,) = perpPair.getLpLiquidityBalance(charlie);
    //     (, , , uint256 charlieLpDebtAsset) = perpPair.liquidityPosition(charlie);
    //     //(uint256 _aliceStableShares, uint256 _aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
    //     (uint256 _aliceStableBalance, uint256 _aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
    //     //(uint256 _bobStableShares, uint256 _bobAssetShares) = perpPair.getLpLiquidityShares(bob);
    //     (uint256 _bobStableBalance, uint256 _bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);

    //     uint256 tolerance = 100;

    //     //assertTrue(charlieStableShares == 0 && charlieAssetShares == 0, "charlie shares");
    //     assertTrue(charlieLpStableBalance == 0 && charlieLpStableBalance == 0, "charlie lp_balance");

    //     (uint256 min, uint256 max, uint256 k) = perpPair.ReadLiquidityFeeParameters();

    //     uint256 withdFee = FeeManager.computeLiquidityRemovalFee(
    //         charlieStableBalance,
    //         charlieAssetBalance,
    //         stableLiq,
    //         assetLiq,
    //         100 * oracleDecimals,
    //         oracleDecimals,
    //         min,
    //         max,
    //         k,
    //         liquidityFeeDecimals
    //     );
    //     (uint256 _charlieStableBalance, uint256 _charlieAssetBalance,,,,,,) =
    //         perpPair.userVirtualTraderPosition(charlie);
    //     uint256 charlieFeeStable = withdFee * charlieStableBalance / liquidityFeeDecimals;
    //     uint256 charlieFeeAsset = withdFee * charlieAssetBalance / liquidityFeeDecimals;
    //     uint256 charlieFee = charlieFeeStable + charlieFeeAsset * 100;

    //     //assertTrue(inConfidenceInterval(_aliceStableShares, aliceStableShares, tolerance) &&
    //     //        inConfidenceInterval(_aliceAssetShares, aliceAssetShares, tolerance),
    //     //        "alice shares");
    //     assertTrue(
    //         inConfidenceInterval(_aliceStableBalance, aliceStableBalance + charlieFee / 2, tolerance)
    //             && inConfidenceInterval(_aliceAssetBalance, aliceAssetBalance, tolerance),
    //         "alice balance"
    //     );
    //     //assertTrue(_bobStableShares == bobStableShares &&
    //     //        _bobAssetShares == 0,
    //     //        "bob shares");
    //     assertTrue(
    //         inConfidenceInterval(_bobStableBalance, bobStableBalance + charlieFee / 2, tolerance)
    //             && inConfidenceInterval(_bobAssetBalance, bobAssetBalance, tolerance),
    //         "bob balance"
    //     );

    //     assertTrue(
    //         inConfidenceInterval(_charlieStableBalance, 0, tolerance),
    //         "charlie stable balance"
    //     );

    //     console.log(charlieLpDebtAsset, charlieAssetBalance);
    //     assertTrue(
    //         inConfidenceInterval(charlieLpDebtAsset, _charlieLpDebtAsset - charlieAssetBalance, tolerance),
    //         "charlie stable balance"
    //     );
    // }

    ///@dev Test the remove liquidity function after 1 trade short has been performed on the liquidity.
    function testRemoveLiquidityAfterTradeShort() public {
        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        oracle.setPrice(100 * oracleDecimals);

        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);
        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 0; //100000*1e18;
        uint256 bobLiquidityAsset = 20_000 * 1e18;
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 1_000_000 * 1e18;
        uint256 charlieLiquidityAsset = 0;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);
        (,, uint256 _bobLpDebtStable_,) = perpPair.liquidityPosition(bob);

        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(uint256 charlieStableShares, uint256 charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        (uint256 charlieStableBalance, uint256 charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);

        uint256 totalLiquidityStable = aliceStableBalance + bobStableBalance + charlieStableBalance;
        assertTrue(
            inConfidenceInterval(totalLiquidityStable, perpPair.globalLiquidityStable(), 100_000_000_000),
            "global stable"
        );
        address david = makeAddr("david");
        uint256 tradeSize = 10 * 1e18;
        vm.prank(david);
        perpPair.trade(false, tradeSize, 100 * oracleDecimals, totalLiquidityStable, frontendAddress, 1, fakeReport);

        //(aliceStableShares, aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //(bobStableShares, bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        (bobStableBalance, bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(charlieStableShares, charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        (charlieStableBalance, charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);
        (,, uint256 _charlieLpDebtStable,) = perpPair.liquidityPosition(charlie);

        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();
        uint256 withdFee = FeeManager.computeLiquidityRemovalFee(
            charlieStableBalance,
            charlieAssetBalance,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        //emit DebugEvent(withdFee);
        uint256 charlieFee = withdFee * (charlieStableBalance + charlieAssetBalance * 100) / liquidityFeeDecimals;
        vm.prank(charlie);
        perpPair.removeLiquidity(charlieStableBalance, charlieAssetBalance, maxUserLiquidityFee, fakeReport);
        //(charlieStableShares, charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        (uint256 charlieLpStableBalance,) = perpPair.getLpLiquidityBalance(charlie);
        (,, uint256 charlieLpDebtStable,) = perpPair.liquidityPosition(charlie);
        //(uint256 _aliceStableShares, uint256 _aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 _aliceStableBalance, uint256 _aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //(uint256 _bobStableShares, uint256 _bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        (uint256 _bobStableBalance, uint256 _bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);

        uint256 tolerance = 100;

        //assertTrue(charlieStableShares == 0 && charlieAssetShares == 0, "charlie shares");
        assertTrue(charlieLpStableBalance == 0 && charlieLpStableBalance == 0, "charlie lp_balance");

        (uint256 _charlieStableBalance, uint256 _charlieAssetBalance,,,,,,) =
            perpPair.userVirtualTraderPosition(charlie);

        emit DebugEvent(charlieFee);
        //assertTrue(inConfidenceInterval(_aliceStableShares, aliceStableShares, tolerance) &&
        //        inConfidenceInterval(_aliceAssetShares, aliceAssetShares, tolerance),
        //        "alice shares");
        assertTrue(
            inConfidenceInterval(_aliceStableBalance, aliceStableBalance + charlieFee / 2, tolerance)
                && inConfidenceInterval(_aliceAssetBalance, aliceAssetBalance, tolerance),
            "alice balance"
        );
        //assertTrue(_bobStableShares == bobStableShares &&
        //        _bobAssetShares == bobAssetShares,
        //        "bob shares");
        // assertTrue(
        //     inConfidenceInterval(_bobAssetBalance, bobAssetBalance, tolerance)
        //         && inConfidenceInterval(_bobStableBalance, bobStableBalance + charlieFee / 2, tolerance),
        //     "bob balance"
        // );

        assertTrue(inConfidenceInterval(_charlieAssetBalance, charlieAssetBalance, tolerance), "charlie Asset balance");

        console.log(charlieLpDebtStable, _charlieLpDebtStable, charlieStableBalance);
        // assertTrue(
        //     inConfidenceInterval(charlieLpDebtStable, _charlieLpDebtStable - charlieStableBalance + charlieFee, tolerance),
        //     "charlie stable balance"
        // );
    }

    //test liquidity values after trades
    ///@dev Test the liqudity accounting after a trade long happends. 1 lp, 1 trade long.
    function testTradeLongLiquidity() public {
        uint256 price = 65_000;
        oracle.setPrice(65_000 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 200_000 * 1e18;
        uint256 aliceLiquidityAsset = 200_000 * 1e18 / price;
        //uint256 aliceFee = perpPair.computeLiquidityDepositFee(aliceLiquidityStable, aliceLiquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 90 * 1e18;

        //perpPair.returnTradeInfo(true, 3000*1e18, 1500*1e18, 83000*1e8);
        vm.startSnapshotGas("compute");
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        console.log("long: ", used);

        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        assertTrue(debtStable == tradeSize && debtAsset == 0, "debt");
        //assertTrue(balanceStable == 0 && inConfidenceInterval(balanceAsset, tradeSize / 100, 100), "balance");

        //assertTrue(
        //    inConfidenceInterval(perpPair.globalLiquidityStable(), aliceLiquidityStable + tradeSize, 100)
        //        && inConfidenceInterval(perpPair.globalLiquidityAsset(), aliceLiquidityAsset - tradeSize / 100, 100),
        //    "Global liquidity"
        //);
        //assertTrue(inConfidenceInterval(perpPair.globalSharesStable(), aliceLiquidityStable+tradeSize, 100) &&
        //        perpPair.globalSharesAsset() == aliceLiquidityAsset
        //        , "Global shares");

        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        //(uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //assertTrue(
        //    inConfidenceInterval(aliceStableBalance, aliceLiquidityStable + tradeSize, 100)
        //        && inConfidenceInterval(aliceAssetBalance, aliceLiquidityAsset - tradeSize / 100, 100),
        //    "Alice liquidity"
        //);
        //assertTrue(inConfidenceInterval(aliceStableShares, aliceLiquidityStable+tradeSize, 100) &&
        //        aliceAssetShares == aliceLiquidityAsset
        //        , "Alice shares");

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);
    }

    ///@dev Test the liqudity accounting after a trade short happens. 1 lp, 1 short trade.
    function testTradeShortLiquidity() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");

        uint256 tradeSize = 10 * 1e18;

        vm.prank(bob);
        vm.startSnapshotGas("compute");
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);
        uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        console.log("short: ", used);

        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(bob);

        assertTrue(debtStable == 0 && debtAsset == tradeSize, "debt");
        assertTrue(balanceAsset == 0 && inConfidenceInterval(balanceStable, tradeSize * 100, 100), "balance");

        assertTrue(
            inConfidenceInterval(perpPair.globalLiquidityStable(), aliceLiquidityStable + tradeSize, 100)
                && inConfidenceInterval(perpPair.globalLiquidityAsset(), aliceLiquidityAsset - tradeSize / 100, 100),
            "Global liquidity"
        );
        //assertTrue(inConfidenceInterval(perpPair.globalSharesAsset(), aliceLiquidityAsset+tradeSize, 100) &&
        //        perpPair.globalSharesStable() == aliceLiquidityStable
        //        , "Global shares");
        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        assertTrue(
            inConfidenceInterval(aliceStableBalance, aliceLiquidityStable - tradeSize * 100, 100)
                && inConfidenceInterval(aliceAssetBalance, aliceLiquidityAsset + tradeSize, 100),
            "Alice liquidity"
        );
        //assertTrue(inConfidenceInterval(aliceAssetShares, aliceLiquidityAsset+tradeSize, 100) &&
        //        aliceStableShares == aliceLiquidityStable
        //        , "Alice shares");
    }

    ///@dev Test the liqudity accounting after a trade long happens. 3 lps, 1 long trade.
    function testTradeLong3LpLiquidity() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 2_000_000 * 1e18;
        uint256 bobLiquidityAsset = 0;
        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();
        uint256 bobFee = FeeManager.computeLiquidityDepositFee(
            bobLiquidityStable,
            bobLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 bobLiquidityStableFee = bobLiquidityStable * bobFee / liquidityFeeDecimals;

        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 0;
        uint256 charlieLiquidityAsset = 20_000 * 1e18;
        uint256 charlieFee = FeeManager.computeLiquidityDepositFee(
            charlieLiquidityStable,
            charlieLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 charlieLiquidityStableFee = charlieLiquidityStable * charlieFee / liquidityFeeDecimals;

        uint256 totalLiquidityStable = perpPair.globalLiquidityStable();
        uint256 totalLiquidityAsset = perpPair.globalLiquidityAsset();

        address david = makeAddr("david");
        uint256 tradeSize = 1000 * 1e18;

        vm.prank(david);
        perpPair.trade(true, tradeSize, 100 * oracleDecimals, totalLiquidityAsset, frontendAddress, 1, fakeReport);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(david);
        assertTrue(debtStable == tradeSize && debtAsset == 0, "debt");
        assertTrue(balanceStable == 0 && inConfidenceInterval(balanceAsset, tradeSize / 100, 100), "balance");
        assertTrue(
            inConfidenceInterval(perpPair.globalLiquidityStable(), totalLiquidityStable + tradeSize, 100)
                && inConfidenceInterval(perpPair.globalLiquidityAsset(), totalLiquidityAsset - tradeSize / 100, 100),
            "Global liquidity"
        );
        //assertTrue(inConfidenceInterval(perpPair.globalSharesStable(), totalLiquidityStable+tradeSize, 100) &&
        //        perpPair.globalSharesAsset() == totalLiquidityAsset
        //        , "Global shares");

        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(uint256 charlieStableShares, uint256 charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        (uint256 charlieStableBalance, uint256 charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);

        assertTrue(
            inConfidenceInterval(
                aliceStableBalance,
                aliceLiquidityStable + tradeSize / 3 * 101 / 100 + bobLiquidityStableFee + charlieLiquidityStableFee
                    / 3,
                100
            ) && inConfidenceInterval(aliceAssetBalance, aliceLiquidityAsset - tradeSize / 300, 100),
            "Alice liquidity"
        );
        //assertTrue(inConfidenceInterval(aliceStableShares, aliceLiquidityStable+tradeSize/3, 100) && aliceAssetShares == aliceLiquidityAsset, "Alice shares");

        assertTrue(
            inConfidenceInterval(
                bobStableBalance, bobLiquidityStable - bobLiquidityStableFee + charlieLiquidityStableFee * 2 / 3, 100
            ) && inConfidenceInterval(bobAssetBalance, bobLiquidityAsset, 100),
            "Bob liquidity"
        );
        //assertTrue(bobStableShares == bobLiquidityStable && bobAssetShares == bobLiquidityAsset, "Bob shares");

        assertTrue(
            inConfidenceInterval(
                charlieStableBalance, charlieLiquidityStable + tradeSize * 2 / 3 - charlieLiquidityStableFee, 100
            ) && inConfidenceInterval(charlieAssetBalance, charlieLiquidityAsset - tradeSize * 2 / 300, 100),
            "charlie liquidity"
        );
        //assertTrue(inConfidenceInterval(charlieStableShares, charlieLiquidityStable+tradeSize*2/3, 100) && charlieAssetShares == charlieLiquidityAsset, "charlie shares");
    }

    ///@dev Test the liqudity accounting after a trade long happens. 3 lps, 1 short trade.
    function testTradeShort3LpLiquidity() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 2_000_000 * 1e18;
        uint256 bobLiquidityAsset = 0;
        (,,, uint256 min, uint256 max, uint256 k,,,,,) = perpPair.ReadFees();
        uint256 bobFee = FeeManager.computeLiquidityDepositFee(
            bobLiquidityStable,
            bobLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 bobLiquidityStableFee = bobLiquidityStable * bobFee / liquidityFeeDecimals;
        uint256 bobLiquidityAssetFee = bobLiquidityAsset * bobFee / liquidityFeeDecimals;

        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 0;
        uint256 charlieLiquidityAsset = 20_000 * 1e18;
        uint256 charlieFee = FeeManager.computeLiquidityDepositFee(
            charlieLiquidityStable,
            charlieLiquidityAsset,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            100 * oracleDecimals,
            oracleDecimals,
            max,
            min,
            k,
            liquidityFeeDecimals
        );
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);
        uint256 charlieLiquidityStableFee = charlieLiquidityStable * charlieFee / liquidityFeeDecimals;
        uint256 charlieLiquidityAssetFee = charlieLiquidityAsset * charlieFee / liquidityFeeDecimals;

        uint256 totalLiquidityStable = perpPair.globalLiquidityStable();
        uint256 totalLiquidityAsset = perpPair.globalLiquidityAsset();

        address david = makeAddr("david");
        uint256 tradeSize = 10 * 1e18;

        vm.prank(david);
        perpPair.trade(false, tradeSize, 100 * oracleDecimals, totalLiquidityStable, frontendAddress, 1, fakeReport);
        (uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
            perpPair.userVirtualTraderPosition(david);
        assertTrue(debtStable == 0 && debtAsset == tradeSize, "debt");
        assertTrue(inConfidenceInterval(balanceStable, tradeSize * 100, 100) && balanceAsset == 0, "balance");
        assertTrue(
            inConfidenceInterval(perpPair.globalLiquidityStable(), totalLiquidityStable - tradeSize * 100, 100)
                && inConfidenceInterval(perpPair.globalLiquidityAsset(), totalLiquidityAsset + tradeSize, 100),
            "Global liquidity"
        );
        //assertTrue(inConfidenceInterval(perpPair.globalSharesAsset(), totalLiquidityAsset+tradeSize, 100) &&
        //        perpPair.globalSharesStable() == totalLiquidityStable
        //        , "Global shares");

        //(uint256 aliceStableShares, uint256 aliceAssetShares) = perpPair.getLpLiquidityShares(alice);
        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        //(uint256 bobStableShares, uint256 bobAssetShares) = perpPair.getLpLiquidityShares(bob);
        (uint256 bobStableBalance, uint256 bobAssetBalance) = perpPair.getLpLiquidityBalance(bob);
        //(uint256 charlieStableShares, uint256 charlieAssetShares) = perpPair.getLpLiquidityShares(charlie);
        (uint256 charlieStableBalance, uint256 charlieAssetBalance) = perpPair.getLpLiquidityBalance(charlie);

        // assertTrue(
        //     inConfidenceInterval(
        //         aliceStableBalance,
        //         aliceLiquidityStable - tradeSize * 100 / 3 * 101 / 100 + bobLiquidityStableFee
        //             + charlieLiquidityStableFee / 3,
        //         100
        //     )
        //         && inConfidenceInterval(
        //             aliceAssetBalance,
        //             aliceLiquidityAsset + tradeSize / 3 * 101 / 100 + bobLiquidityAssetFee + charlieLiquidityAssetFee,
        //             100
        //         ),
        //     "Alice liquidity"
        // );
        //assertTrue(inConfidenceInterval(aliceAssetShares, aliceLiquidityAsset+tradeSize/3, 100) && aliceStableShares == aliceLiquidityStable, "Alice shares");

        assertTrue(
            inConfidenceInterval(
                bobStableBalance,
                bobLiquidityStable - tradeSize * 200 / 3 * 98 / 100 - bobLiquidityStableFee + charlieLiquidityStableFee
                    * 2 / 3,
                100
            )
            && inConfidenceInterval(
                bobAssetBalance, bobLiquidityAsset + tradeSize * 2 / 3 * 99 / 100 - bobLiquidityAssetFee, 100
            ),
            "bob liquidity"
        );
        //assertTrue(inConfidenceInterval(bobAssetShares, bobLiquidityAsset+tradeSize*2/3, 100) && bobStableShares == bobLiquidityStable, "bob shares");

        assertTrue(
            inConfidenceInterval(charlieStableBalance, charlieLiquidityStable - charlieLiquidityStableFee, 100)
                && inConfidenceInterval(charlieAssetBalance, charlieLiquidityAsset - charlieLiquidityAssetFee, 100),
            "Charlie liquidity"
        );
        //assertTrue(inConfidenceInterval(charlieStableShares, charlieLiquidityStable, 100) && charlieAssetShares == charlieLiquidityAsset, "Charlie shares");
    }

    ///@dev Tests the guard mechanism that prevents multiple small trades from being more efficient than a single trade of equal size to their sum.
    function testConsecutiveSplitTrades() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 2000 * 1e18;
        uint256 aliceLiquidityAsset = 20 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 10 * 1e18;
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        vm.prank(alice);
        perpPair.removeLiquidity(0, 11 * 1e18, maxUserLiquidityFee, fakeReport);

        uint256 globStable = perpPair.globalLiquidityStable();
        uint256 globAsset = perpPair.globalLiquidityAsset();
        console.log("GOTHEREBITCH1");
        vm.prank(alice);
        perpPair.addLiquidity(
            aliceLiquidityStable - globStable, aliceLiquidityAsset - globAsset, maxUserLiquidityFee, fakeReport
        );

        //uint256 log1 = perpPair.globalLiquidityStable();
        skip(30);

        address charlie = makeAddr("charlie");
        for (uint256 i; i < 100; i++) {
            globStable = perpPair.globalLiquidityStable();
            vm.prank(charlie);
            perpPair.trade(false, tradeSize / 100, 100 * 1e5, globStable, frontendAddress, 1, fakeReport);
        }

        vm.prank(alice);
        perpPair.removeLiquidity(1000 * 1e18, 10 * 1e18, maxUserLiquidityFee, fakeReport);

        globStable = perpPair.globalLiquidityStable();
        globAsset = perpPair.globalLiquidityAsset();
        console.log("GOTHEREBITCH2");
        vm.prank(alice);
        perpPair.addLiquidity(
            aliceLiquidityStable - globStable, aliceLiquidityAsset - globAsset, maxUserLiquidityFee, fakeReport
        );

        //uint256 log2 = perpPair.globalLiquidityStable();

        address david = makeAddr("david");
        for (uint256 i; i < 100; i++) {
            skip(30);
            globStable = perpPair.globalLiquidityStable();
            vm.prank(david);
            perpPair.trade(false, tradeSize / 100, 100 * 1e5, globStable, frontendAddress, 1, fakeReport);
        }
        (uint256 bobBalanceStable,,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        //(uint256 charlieBalanceStable,,,,,,,) =
        //    perpPair.userVirtualTraderPosition(charlie);
        (uint256 davidBalanceStable,,,,,,,) = perpPair.userVirtualTraderPosition(david);

        //assertTrue(inConfidenceInterval(bobBalanceStable, charlieBalanceStable, 1000), "exploit works");
        assertTrue(davidBalanceStable > bobBalanceStable, "waiting does not reset");
    }

    ///@dev Test the remove liquidity exploit.
    function testRemoveLiquidityExploit() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address charlie = makeAddr("charlie");
        uint256 charlieLiquidityStable = 1_000_000 * 1e18;
        uint256 charlieLiquidityAsset = 10_000 * 1e18;
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(false, tradeSize, 100 * 1e5, aliceLiquidityStable, frontendAddress, 1, fakeReport);

        price = 100 * oracleDecimals;
        oracle.setPrice(price);

        (uint256 aliceStableBalance, uint256 aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);

        vm.prank(alice);
        perpPair.removeLiquidity(aliceStableBalance, aliceAssetBalance, maxUserLiquidityFee, fakeReport); //fully exit

        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        console.log(aliceStableBalance, aliceAssetBalance);

        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(alice, price);

        uint256 collBefore = perpPair.getCollateral(alice);

        console.log(pnl, pnlSign);

        vm.prank(alice);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        uint256 collAfter = perpPair.getCollateral(alice);
        console.log(collBefore, collAfter);

        (uint256 expectedColl, bool sign) = UtilMath.signedSum(collBefore, true, pnl, pnlSign);
        console.log(expectedColl, sign);

        (aliceStableBalance, aliceAssetBalance) = perpPair.getLpLiquidityBalance(alice);
        assertTrue(aliceStableBalance == 0 && aliceAssetBalance == 0, "alice not to 0");
        assertLe(collAfter, expectedColl, "gained through exploit");
    }

    ///@dev Test the remove liquidity exploit.
    function testRemoveLiquidityExploit2() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 100_000 * 1e18;
        uint256 aliceLiquidityAsset = 100_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        Vault(vault).removeCollateral((2 * 10_000_000 - 50) * 1e18, fakeReport);

        uint256 charlieLiquidityStable = 0 * 1e18;
        uint256 charlieLiquidityAsset = 5 * 1e18;
        vm.expectRevert();
        vm.prank(charlie);
        perpPair.addLiquidity(charlieLiquidityStable, charlieLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (uint256 lpStableBalance, uint256 lpAssetBalance) = perpPair.getLpLiquidityBalance(charlie);
        console.log(lpStableBalance, lpAssetBalance);

        //vm.expectRevert();
        //vm.prank(charlie);
        //perpPair.removeLiquidity(0 * 1e18, 5 * 1e18, maxUserLiquidityFee, fakeReport);

        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(charlie, price);
        (uint256 coll) = perpPair.getCollateral(charlie);

        console.log(pnl, pnlSign);
    }

    /// @dev simple sanity test: batchLiquidate two long traders, their MR improves and the liquidator gets a position
    ///@dev A user cannot liquidate their own position: the shared liquidate body rejects
    /// user == msg.sender with LQ0 before any oracle/margin work, so no position setup is needed.
    function testSelfLiquidationRevert() public {
        address bob = makeAddr("bob");
        vm.expectRevert(bytes("LQ0"));
        vm.prank(bob);
        perpPair.liquidate(bob, 1000 * 1e18, fakeReport);
    }

    function testBatchLiquidateTwoLongTraders() public {
        uint256 initialPrice = 100;
        oracle.setPrice(initialPrice * oracleDecimals);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        // Alice provides liquidity
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000 - 100) * 1e18, fakeReport);
        vm.prank(charlie);
        Vault(vault).removeCollateral((2 * 10_000_000 - 100) * 1e18, fakeReport);

        // Both open the same long trade
        uint256 tradeSize = 1000 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        vm.prank(charlie);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        // Price goes down → they become liquidatable
        uint256 newPrice = 40;
        oracle.setPrice(newPrice * oracleDecimals);

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

        // Prepare batch call
        address liquidator = makeAddr("david");

        (, uint256 bobAssetBalance,,,,,,) = perpPair.userVirtualTraderPosition(bob);
        (, uint256 charlieAssetBalance,,,,,,) = perpPair.userVirtualTraderPosition(charlie);

        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = charlie;

        uint256[] memory sizes = new uint256[](2);
        sizes[0] = bobAssetBalance;
        sizes[1] = charlieAssetBalance;

        // Call your helper
        vm.prank(liquidator);
        multiCallManager.batchLiquidate(users, sizes, fakeReport);

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
    }

    function testZeroLPLiquidity() public {
        oracle.setPrice(100 * oracleDecimals);

        address charlie = makeAddr("charlie");
        address[] memory users = new address[](1);
        users[0] = charlie;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e30 * 1e6 * 2;
        mint(stableCoins[0], users, amounts);

        amounts[0] = 1e30 * 1e18 * 2;
        mint(stableCoins[1], users, amounts);

        amounts = new uint256[](2);
        amounts[0] = 1e30 * 1e6;
        amounts[1] = 1e30 * 1e18;
        vm.prank(charlie);
        vault.addCollateral(amounts);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 100_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 1_000_000 * 1e18;
        //uint256 aliceFee = perpPair.computeLiquidityDepositFee(aliceLiquidityStable, aliceLiquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        // Keep bob's deposit negligible vs alice's pool (1e10 times smaller) while clearing
        // the L1 minimumLiquidityMovement guard (1e16 value, no setter).
        uint256 bobLiquidityStable = 100 * 1e14;
        uint256 bobLiquidityAsset = 1 * 1e14;
        //uint256 bobFee = perpPair.computeLiquidityDepositFee(bobLiquidityStable, bobLiquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, maxUserLiquidityFee, fakeReport);

        uint256 tradeSize = 10_000_000 * 1e18;

        for (uint256 i; i < 15; i++) {
            // Stop before a long that could leave the asset side under the post-trade T3
            // floor (1e18 value): the zero-slippage output bound of the next trade is
            // tradeSize of value. The live curve (A=1e8, B=1e7) drains the pool faster
            // than the test-era curve this loop was sized for; the dust-LP accounting
            // being tested only needs the pool to swing hard, not a fixed trade count.
            if (perpPair.globalLiquidityAsset() * 100 <= tradeSize + 1e18) break;
            vm.prank(charlie);
            perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
            skip(10);
        }
        vm.prank(charlie);
        perpPair.trade(false, tradeSize / 100, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        skip(10);

        //perpPair.returnTradeInfo(true, 3000*1e18, 1500*1e18, 83000*1e8);
        //vm.startSnapshotGas("compute");
        //vm.prank(charlie);
        //perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        //uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        //console.log("long: ", used);
        //vm.prank(charlie);
        //perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        //vm.prank(charlie);
        //perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        //vm.prank(charlie);
        //perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        //vm.prank(charlie);
        //perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);

        (uint256 stableBal, uint256 assetBal) = perpPair.getLpLiquidityBalance(bob);
        (uint256 stableBal2, uint256 assetBal2) = perpPair.getLpLiquidityBalance(alice);
        uint256 stableLiq = perpPair.globalLiquidityStable();
        uint256 assetLiq = perpPair.globalLiquidityAsset();

        console.log(stableBal, assetBal);
        console.log(stableBal2, assetBal2);
        console.log(stableLiq, assetLiq);
    }

    //test liquidity values after trades
    ///@dev Test the liqudity accounting after a trade long happends. 1 lp, 1 trade long.
    function testTradeLongLiquidityZeroColl() public {
        oracle.setPrice(100 * oracleDecimals);

        address alice = makeAddr("alice");
        uint256 aliceLiquidityStable = 1_000_000 * 1e18;
        uint256 aliceLiquidityAsset = 10_000 * 1e18;
        //uint256 aliceFee = perpPair.computeLiquidityDepositFee(aliceLiquidityStable, aliceLiquidityAsset, perpPair.globalLiquidityStable(), perpPair.globalLiquidityAsset(), 100*oracleDecimals);
        vm.prank(alice);
        perpPair.addLiquidity(aliceLiquidityStable, aliceLiquidityAsset, maxUserLiquidityFee, fakeReport);

        address bob = makeAddr("bob");
        vm.prank(bob);
        Vault(vault).removeCollateral((2 * 10_000_000) * 1e18 - 5 * 1e17, fakeReport);

        uint256 tradeSize = 1 * 1e18;

        //perpPair.returnTradeInfo(true, 3000*1e18, 1500*1e18, 83000*1e8);
        vm.startSnapshotGas("compute");
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, aliceLiquidityAsset, frontendAddress, 1, fakeReport);
        uint256 used = vm.stopSnapshotGas(); // returns gas between start/stop
        console.log("long: ", used);

        (uint256 pnl, bool pnlSign) = perpPair.calcPnL(bob, 60 * oracleDecimals);
        console.log(pnl, pnlSign);
        console.log(perpPair.getCollateral(bob));

        //(uint256 balanceStable, uint256 balanceAsset, uint256 debtStable, uint256 debtAsset,,,,) =
        //    perpPair.userVirtualTraderPosition(bob);

        oracle.setPrice(60 * oracleDecimals);

        vm.expectRevert(bytes("C1"));
        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);
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
