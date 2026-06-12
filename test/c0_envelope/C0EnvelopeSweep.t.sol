// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// =====================================================================================
/// C0 DUST-BOUND ENVELOPE REGRESSION HARNESS
/// Regression coverage for the pool-relative C0 dust bound.
///
/// Historically, closeAndWithdraw required the post-buy-back residual to satisfy an
/// ABSOLUTE bound (perpTrade.sol: |balanceAsset - debtAsset| * price / oracleDecimals
/// < 1e10). The production curve parameters (A=1e8, B=1e7, hardcoded in the PerpPair
/// constructor) amplify the CurveMath.computeExactAmountInLong inversion residual far
/// past that bound — the residual scales with POOL DEPTH, not position size — bricking
/// ordinary short closes (51/60 cells at a 10x pool). The bound is now
/// max(1e10, globalLiquidityStable / 1e10), mirrored bit-exactly in
/// perp-engine/src/close.rs.
///
/// This sweep deploys the stack exactly like test/PerpPair.t.sol (production constructor
/// literals) and grids: side {SHORT, LONG} x notional {50,100,500,1000,5000,20000}e18
/// stable value x price move {1,5,10,25,50}% x direction {adverse, favorable} x pool
/// {1x = 1M stable/10k asset, 10x}. For each cell it predicts the close residual by
/// replicating the close math off-chain, attempts closeAndWithdraw via try/catch, logs a
/// grid row, and asserts prediction/outcome consistency against the production bound.
/// Every cell must close successfully; a C0 revert on any cell means the residual
/// envelope outgrew the bound (e.g. after a curve- or solver-parameter change) and the
/// bound must be recalibrated.
/// =====================================================================================

import { Test, console2 } from "forge-std/Test.sol";
import { PerpPair } from "../../src/PerpPair.sol";
import { Vault } from "../../src/Vault.sol";
import { LostAndFound } from "../../src/LostAndFound.sol";
import "../../src/token/USDCe.sol";
import "../../src/util/CurveMath.sol";
import "../../src/test_support/TestPriceProvider.sol";
import "../../src/manager/multiCallManager.sol";
import "../helpers/PerpPairTestDeploymentHelper.sol";

contract C0EnvelopeSweepTest is Test, PerpPairTestDeploymentHelper {
    uint256 constant MAX_UINT = type(uint256).max;

    Vault public vault;
    PerpPair public perpPair;
    LostAndFound public lostAndFound;
    PerpMultiCalls public multiCallManager;
    TestPriceProvider public oracle;

    // Same constructor inputs as the canary tests in test/PerpPair.t.sol
    uint256 public MMRDecimals = 1e6;
    uint256 public MMR = 38 * MMRDecimals / 1000;
    bytes32 public tickerAsset;
    uint256 public tradingFeeDecimals = 1e18;
    uint32 public feeFractionDecimals = 1e6;
    uint32 public feeFrontend = 5 * feeFractionDecimals / 100;
    address public frontendAddress = makeAddr("frontend");
    uint32 public feeLP = 5 * feeFractionDecimals / 10;
    address public feeProtocolAddr = makeAddr("denaria");
    uint256 public tradingFee = 1 * tradingFeeDecimals / 1000; // 1e15
    uint256 public flatTradingFee = 1e17;
    uint256 public oracleDecimals = 1e8;
    string public tokenName = "USDCe";
    string public tokenSymbol = "USDC.e";
    string public tokenCurrency = "USD";
    address public MasterMinter = makeAddr("Megamind");
    address public Pauser = makeAddr("Megamind");
    address public Blacklister = makeAddr("Megamind");
    address public Owner = makeAddr("Megamind");
    uint256 startingStableAmount = 100_000_000; // larger than canary so the 10x pool fits
    bytes public fakeReport;
    uint256 public maxUserLiquidityFee = 1e30;

    address[] public stableCoins;
    uint256[] public depositThresholds;
    uint256[] public withdrowalThresholds;
    uint256[] public stableDecimals;

    address alice; // LP
    address bob; // trader

    uint256 constant P0 = 100 * 1e8; // open price
    uint256 constant DUST_BOUND = 1e10;

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
            stablecoin.configureMinter(MasterMinter, 1e40);
            stableCoins.push(address(stablecoin));
            depositThresholds.push(1e8);
            withdrowalThresholds.push(1e8);
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
        // PerpPair constructor hardcodes the PRODUCTION curve params (A=1e8, B=1e7).
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

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; i++) {
            vm.prank(users[i]);
            coinA.approve(address(vault), MAX_UINT);
            vm.prank(users[i]);
            coinB.approve(address(vault), MAX_UINT);

            vm.prank(MasterMinter);
            FiatTokenV2(stableCoins[0]).mint(users[i], startingStableAmount * 1e6 * 2);
            vm.prank(MasterMinter);
            FiatTokenV2(stableCoins[1]).mint(users[i], startingStableAmount * 1e18 * 2);

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = startingStableAmount * 1e6;
            amounts[1] = startingStableAmount * 1e18;
            vm.prank(users[i]);
            vault.addCollateral(amounts);
        }
    }

    // ----------------------------------------------------------------------------
    // Sweep entry points
    // ----------------------------------------------------------------------------

    function testSweepShortBasePool() public {
        _runSweep(false, 1);
    }

    function testSweepShort10xPool() public {
        _runSweep(false, 10);
    }

    function testSweepLongBasePool() public {
        _runSweep(true, 1);
    }

    function testSweepLong10xPool() public {
        _runSweep(true, 10);
    }

    // ----------------------------------------------------------------------------
    // Sweep machinery
    // ----------------------------------------------------------------------------

    function _runSweep(bool isLong, uint256 poolMult) internal {
        oracle.setPrice(P0);

        // Canary pool magnitudes (testCloseAndWithdrawShortProfit): 1M stable + 10k asset @ 100
        uint256 liqStable = poolMult * 1_000_000 * 1e18;
        uint256 liqAsset = poolMult * 10_000 * 1e18;
        vm.prank(alice);
        perpPair.addLiquidity(liqStable, liqAsset, maxUserLiquidityFee, fakeReport);

        console2.log(
            string.concat(
                "=== SWEEP side=",
                isLong ? "LONG" : "SHORT",
                " pool=",
                vm.toString(poolMult),
                "x (",
                vm.toString(liqStable / 1e18),
                " stable / ",
                vm.toString(liqAsset / 1e18),
                " asset) P0=100 ==="
            )
        );
        console2.log("notional(stable) | move | outcome | predictedResidual / predictedBound");

        uint256[6] memory notionals = [uint256(50), 100, 500, 1000, 5000, 20_000];
        uint256[5] memory moves = [uint256(1), 5, 10, 25, 50];

        uint256 snap = vm.snapshotState();
        for (uint256 n; n < notionals.length; n++) {
            for (uint256 d; d < 2; d++) {
                bool adverse = (d == 0);
                for (uint256 m; m < moves.length; m++) {
                    _runCell(isLong, notionals[n], adverse, moves[m]);
                    vm.revertToState(snap);
                    snap = vm.snapshotState();
                }
            }
        }
    }

    function _runCell(bool isLong, uint256 notional, bool adverse, uint256 movePct) internal {
        // --- open position at P0 ---
        if (isLong) {
            // long size is in vStable; T2: size >= minimumTradeSize (48e18)
            uint256 size = notional * 1e18;
            uint256 guess = perpPair.globalLiquidityAsset(); // read BEFORE prank (would consume it)
            vm.prank(bob);
            perpPair.trade(true, size, 100 * 1e5, guess, frontendAddress, 1, fakeReport);
        } else {
            // short size is in vAsset; T2: size*price/oracleDec >= 48e18
            uint256 size = notional * 1e18 * oracleDecimals / P0;
            uint256 guess = perpPair.globalLiquidityStable(); // read BEFORE prank (would consume it)
            vm.prank(bob);
            perpPair.trade(false, size, 100 * 1e5, guess, frontendAddress, 1, fakeReport);
        }

        skip(1000);

        // --- move oracle ---
        // adverse for LONG = price down; adverse for SHORT = price up
        bool priceUp = isLong ? !adverse : adverse;
        uint256 p1 = priceUp ? P0 * (100 + movePct) / 100 : P0 * (100 - movePct) / 100;
        oracle.setPrice(p1);

        // --- predict residual and bound (SHORT closes go through the exact-amount-in
        //     long buy-back) ---
        uint256 predictedResidual;
        uint256 predictedBound = DUST_BOUND;
        if (!isLong) {
            predictedResidual = _predictShortCloseResidual(p1);
            // Production bound: max(1e10, globalLiquidityStable / 1e10), pool term read
            // pre-close (the post-trade read in the contract only differs by the
            // buy-back notional, far inside the 88x envelope margin).
            uint256 poolTerm = perpPair.globalLiquidityStable() / 1e10;
            if (poolTerm > predictedBound) predictedBound = poolTerm;
        }

        // --- attempt close ---
        string memory outcome;
        vm.prank(bob);
        try perpPair.closeAndWithdraw(1e5, 1e30, frontendAddress, fakeReport) {
            outcome = "SUCCESS";
        } catch Error(string memory reason) {
            outcome = string.concat("REVERT(", reason, ")");
        } catch {
            outcome = "REVERT(raw)";
        }

        // --- log grid row ---
        string memory moveStr = string.concat(adverse ? "adv" : "fav", " ", vm.toString(movePct), "% ");
        string memory residStr = isLong
            ? "n/a (C0 path not reached for pure longs)"
            : string.concat(vm.toString(predictedResidual), " / ", vm.toString(predictedBound));
        console2.log(
            string.concat(
                isLong ? "LONG  " : "SHORT ",
                _pad(vm.toString(notional), 6),
                " | ",
                moveStr,
                priceUp ? "(P->up)  " : "(P->down)",
                " | ",
                outcome,
                " | resid=",
                residStr
            )
        );

        // consistency check between predicted residual and observed outcome (shorts only)
        if (!isLong) {
            bool predictedRevert = predictedResidual >= predictedBound;
            bool observedC0 = keccak256(bytes(outcome)) == keccak256(bytes("REVERT(C0)"));
            assertEq(predictedRevert, observedC0, "predicted vs observed C0 outcome diverged");
            assertEq(observedC0, false, "C0 residual envelope outgrew the production bound");
        }
    }

    /// @dev Replicates _closeAndWithdraw's buy-back math for a pure SHORT position of `bob`
    ///      (balanceAsset == 0, debtAsset > 0) at close price `price`, with dy0/dx0 reset
    ///      (guaranteed because price moved and >6s elapsed since the last curve update).
    ///      Returns |tradeReturn - debtAsset| * price / oracleDecimals — the value compared
    ///      against the 1e10 dust bound at perpTrade.sol:463.
    function _predictShortCloseResidual(uint256 price) internal view returns (uint256) {
        (,,, uint256 debtAsset,,,,) = perpPair.userVirtualTraderPosition(bob);
        uint256 gLS = perpPair.globalLiquidityStable();
        uint256 gLA = perpPair.globalLiquidityAsset();
        (,, uint256 longA, uint256 longB,,,,) = perpPair.curveParameters();

        // perpTrade.sol:440-454 (dy0 = dx0 = 0 after reset)
        uint256 exactIn =
            CurveMath.computeExactAmountInLong(debtAsset, price, oracleDecimals, gLS, gLS, gLA, longA, longB, 1e8);
        uint256 inputNeeded = (exactIn + flatTradingFee) * tradingFeeDecimals / (tradingFeeDecimals - tradingFee);

        // _trade long branch with frontendAddress != address(0) (perpTrade.sol:121,139-149)
        uint256 tradingFeeAmount = inputNeeded * tradingFee / tradingFeeDecimals + flatTradingFee;
        uint256 effSize = inputNeeded - tradingFeeAmount;
        uint256 tradeReturn =
            CurveMath.computeLongReturn(effSize, price, oracleDecimals, gLA, gLS, gLA, longA, longB, 1e8);

        uint256 diff = tradeReturn > debtAsset ? tradeReturn - debtAsset : debtAsset - tradeReturn;
        return diff * price / oracleDecimals;
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        while (b.length < width) {
            b = abi.encodePacked(b, " ");
        }
        return string(b);
    }
}
