// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import "../src/token/USDCe.sol";
import "../src/util/CurveMath.sol";
import "../src/util/MatrixMath.sol";
import "../src/util/UtilMath.sol";
import "../src/manager/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/test_support/TestPriceProvider.sol";
import "../src/manager/multiCallManager.sol";
import "./helpers/PerpPairTestDeploymentHelper.sol";

contract PerpPairFuzzTest is Test, PerpPairTestDeploymentHelper {
    uint256 MAX_UINT = 2 ** 256 - 1;
    Vault public vault;
    PerpPair public perpPair;
    PerpMultiCalls public multiCallManager;
    uint256 public MMRDecimals = 1e6;
    uint256 public MMR = 38 * MMRDecimals / 1000;
    bytes32 public tickerAsset;
    string public tickerCurrency;
    uint256 public tradingFeeDecimals = 1e8;
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
    uint256 startingStableAmount = 1_000_000_000_000_000;
    bytes public fakeReport;
    uint256 public maxUserLiquidityFee = 1_000_000_000 * 1e18;

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
            stablecoin.configureMinter(MasterMinter, MAX_UINT);
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
            tickerAsset,
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));

        vault.initializeParameters(address(perpPair), address(1));

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

    ///@dev Test long return function in a close-to-zero slippage scenario.
    function testFuzzComputeLongReturn(uint256 size) public {
        size = bound(size, 1e12, 1_000_000 * 1e18);

        uint256 spotPrice = 1 * oracleDecimals;
        uint256 globalLiquidityStable = 7_000_000_000 * currencyDecimals;
        uint256 globalLiquidityAsset = 7_000_000_000 * currencyDecimals * oracleDecimals / spotPrice;
        uint256 initialGuess = globalLiquidityAsset - size * oracleDecimals / spotPrice;
        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(globalLiquidityStable, globalLiquidityAsset, maxUserLiquidityFee, fakeReport);

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

        uint256 expected = size * oracleDecimals / spotPrice;
        uint256 tolerance = 10_000; //Actual tolerance is 1/tolerance, so 0.01%

        assertTrue(inConfidenceInterval(result, expected, tolerance), "Long return");
    }

    ///@dev Test long return function.
    function testFuzzLongAndInverseLong(uint256 size) public {
        size = bound(size, 1e12, 500_000 * 1e18);

        uint256 spotPrice = 100 * oracleDecimals;
        uint256 globalLiquidityStable = 700_000 * currencyDecimals;
        uint256 globalLiquidityAsset = 700_000 * currencyDecimals * oracleDecimals / spotPrice;
        uint256 initialGuess = globalLiquidityAsset - size * oracleDecimals / spotPrice;
        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(globalLiquidityStable, globalLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (,, uint256 longCurveParameterA, uint256 longCurveParameterB,,,,) = perpPair.curveParameters();

        uint256 tradeReturn = CurveMath.computeLongReturn(
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

        initialGuess = globalLiquidityStable;
        uint256 excpectedInput = CurveMath.computeExactAmountInLong(
            tradeReturn,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );

        // Mirror of the production C0 dust bound (perpTrade.sol _closeAndWithdraw): the
        // inversion residual of the 1e8 fixed-point Newton solver grows with pool depth,
        // so the tolerance is max(absolute floor, pool side / 1e10).
        uint256 tolerance = 1e10;
        if (globalLiquidityStable / 1e10 > tolerance) tolerance = globalLiquidityStable / 1e10;

        assertLt(UtilMath.diffAbs(size, excpectedInput), tolerance, "Long return");
    }

    ///@dev Test long return function.
    function testFuzzLongAndInverseShort(uint256 size) public {
        size = bound(size, 1e12, 500_000 * 1e18);

        uint256 spotPrice = 100 * oracleDecimals;
        uint256 globalLiquidityStable = 700_000 * currencyDecimals;
        uint256 globalLiquidityAsset = 700_000 * currencyDecimals * oracleDecimals / spotPrice;

        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(globalLiquidityStable, globalLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (uint256 shortCurveParameterA, uint256 shortCurveParameterB,,,,,,) = perpPair.curveParameters();

        size = size * oracleDecimals / spotPrice;
        uint256 initialGuess = globalLiquidityStable;

        uint256 tradeReturn = CurveMath.computeShortReturn(
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

        initialGuess = globalLiquidityAsset;
        uint256 excpectedInput = CurveMath.computeExactAmountInShort(
            tradeReturn,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        // Same residual model as the long round-trip above, in asset units: the pool term
        // uses the asset side the short inversion works on.
        uint256 tolerance = 1e10;
        if (globalLiquidityAsset / 1e10 > tolerance) tolerance = globalLiquidityAsset / 1e10;

        assertLt(UtilMath.diffAbs(size, excpectedInput), tolerance, "Short return");
    }

    function testMetamorphicSlippageLong(uint256 size1, uint256 size2) public {
        size2 = bound(size2, 1e15, 500_000 * 1e18);
        size1 = bound(size1, size2 + 1e15, 500_000 * 1e18 + 1e15);

        uint256 spotPrice = 100 * oracleDecimals;
        uint256 globalLiquidityStable = 500_010 * currencyDecimals;
        uint256 globalLiquidityAsset = 500_010 * currencyDecimals * oracleDecimals / spotPrice;

        oracle.setPrice(spotPrice);

        address alice = makeAddr("alice");
        vm.prank(alice);
        perpPair.addLiquidity(globalLiquidityStable, globalLiquidityAsset, maxUserLiquidityFee, fakeReport);

        (,, uint256 longCurveParameterA, uint256 longCurveParameterB,,,,) = perpPair.curveParameters();

        uint256 initialGuess = globalLiquidityAsset;

        uint256 tradeReturn1 = CurveMath.computeLongReturn(
            size1,
            spotPrice,
            oracleDecimals,
            initialGuess,
            perpPair.globalLiquidityStable(),
            perpPair.globalLiquidityAsset(),
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        uint256 actualPrice1 = size1 * oracleDecimals / tradeReturn1;

        skip(3600);

        initialGuess = globalLiquidityAsset;
        uint256 tradeReturn2 = CurveMath.computeLongReturn(
            size2,
            spotPrice,
            oracleDecimals,
            initialGuess,
            globalLiquidityStable,
            globalLiquidityAsset,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        uint256 actualPrice2 = size2 * oracleDecimals / tradeReturn2;

        //uint256 a = UtilMath.diffAbs(tradeReturn1, tradeReturn2);
        assertGt(tradeReturn1, tradeReturn2, "Trade Returns");
        //a = UtilMath.diffAbs(actualPrice2, spotPrice);
        assertGe(actualPrice2, spotPrice, "slippage vs oracle");
        //a = UtilMath.diffAbs(actualPrice1, actualPrice2);
        console.log(actualPrice1, actualPrice2);
        assertGe(actualPrice1, actualPrice2, "Slippages relation");
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
}
