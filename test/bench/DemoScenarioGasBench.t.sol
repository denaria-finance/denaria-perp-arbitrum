// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test, console2 } from "forge-std/Test.sol";
import { PerpPair } from "../../src/PerpPair.sol";
import { Vault } from "../../src/Vault.sol";
import { LostAndFound } from "../../src/LostAndFound.sol";
import "../../src/token/USDCe.sol";
import "../../src/test_support/TestPriceProvider.sol";
import "../../src/manager/multiCallManager.sol";
import "../helpers/PerpPairTestDeploymentHelper.sol";

/// Pure-Solidity gas reference for the Arbitrum Sepolia demo sanity sequence:
/// addCollateral 50,000 USDC (6 dec) -> addLiquidity 30,000 stable +
/// 0.479128… asset -> trade long 100e18 -> closeAndWithdraw — executed on the legacy
/// Solidity `PerpPair` with LIVE production parameters (no test-era fixture: constructor
/// curve A=1e8/B=1e7, PerpStorage mainnet params, price frozen at 6261365913505 = the
/// demo oracle price). Measured with vm.startSnapshotGas around the external call, so the
/// figures are CALL-ONLY EVM gas (no 21k intrinsic, no calldata).
/// NOT part of any parity/regression gate; numbers are logged, nothing is asserted about
/// gas. Run: forge test --match-path test/bench/DemoScenarioGasBench.t.sol -vv
contract DemoScenarioGasBenchTest is Test, PerpPairTestDeploymentHelper {
    uint256 constant MAX_UINT = type(uint256).max;
    uint256 constant DEMO_PRICE = 6_261_365_913_505; // 62,613.66 BTC/USD, 1e8 scale

    Vault public vault;
    PerpPair public perpPair;
    LostAndFound public lostAndFound;
    PerpMultiCalls public multiCallManager;
    TestPriceProvider public oracle;

    // Live deploy constructor parameters (.env §6 table, verified on-chain post-init).
    uint256 public MMR = 40_000;
    bytes32 public tickerAsset = bytes32(uint256(0x3078353535333434326434323534343300000000000000000000000000000000));
    uint32 public feeFrontend = 300_000;
    uint32 public feeLP = 500_000;
    address public feeProtocolAddr = makeAddr("denariaProtocol");
    uint256 public tradingFee = 1e15;
    uint256 public flatTradingFee = 12e16;
    uint256 public oracleDecimals = 1e8;
    uint256 public emaParam = 9e7;

    address public trader = makeAddr("demoTrader");
    bytes public fakeReport;

    address[] internal stableCoins;
    uint256[] internal depositThresholds;
    uint256[] internal withdrowalThresholds;
    uint256[] internal stableDecimals;

    function setUp() public {
        // Single 6-decimal stablecoin, like the live Vault (USDC.e + 1e11 thresholds,
        // minCollateralMovement 1e17).
        FiatTokenV2 coin = new FiatTokenV2();
        coin.initialize("USDCe", "USDC.e", "USD", 6, address(this), address(this), address(this), address(this));
        coin.configureMinter(address(this), 1e30);
        stableCoins.push(address(coin));
        depositThresholds.push(1e11);
        withdrowalThresholds.push(1e11);
        stableDecimals.push(1e6);

        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(
            address(multiCallManager), 1e17, stableCoins, depositThresholds, withdrowalThresholds, stableDecimals
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
            emaParam
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));
        lostAndFound = new LostAndFound();
        vault.initializeParameters(address(perpPair), address(lostAndFound));

        oracle.setPrice(DEMO_PRICE); // 1e8-scale, like the live middleware getPrice()

        coin.mint(trader, 1_000_000 * 1e6);
        vm.prank(trader);
        ERC20(address(coin)).approve(address(vault), MAX_UINT);
    }

    /// Reset EVM warm-access state so each measured step pays cold storage/account costs
    /// like a standalone transaction (the live receipts are separate txs).
    function _coolAll() internal {
        vm.cool(address(perpPair));
        vm.cool(address(vault));
        vm.cool(address(oracle));
        vm.cool(stableCoins[0]);
        vm.cool(address(lostAndFound));
    }

    /// One linear scenario so each step sees the same pre-state as the live sequence;
    /// vm.cool() before each measurement emulates per-transaction cold access.
    function testDemoScenarioGas() public {
        // sanity: the mock oracle serves the frozen demo price in 1e8 scale
        assertEq(uint256(uint192(oracle.getPrice())), DEMO_PRICE, "oracle price mismatch");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50_000 * 1e6;

        _coolAll();
        vm.startSnapshotGas("addCollateral_50k");
        vm.prank(trader);
        vault.addCollateral(amounts);
        uint256 gAddCollateral = vm.stopSnapshotGas();

        uint256 liqStable = 30_000 * 1e18;
        uint256 liqAsset = liqStable * oracleDecimals / DEMO_PRICE; // 0.479128… e18, like live

        _coolAll();
        vm.startSnapshotGas("addLiquidity_30k");
        vm.prank(trader);
        perpPair.addLiquidity(liqStable, liqAsset, 1e30, fakeReport);
        uint256 gAddLiquidity = vm.stopSnapshotGas();

        uint256 gLA = perpPair.globalLiquidityAsset();

        _coolAll();
        vm.startSnapshotGas("trade_long_100");
        vm.prank(trader);
        perpPair.trade(true, 100 * 1e18, 0, gLA, feeProtocolAddr, 1, fakeReport);
        uint256 gTrade = vm.stopSnapshotGas();

        _coolAll();
        vm.startSnapshotGas("closeAndWithdraw");
        vm.prank(trader);
        perpPair.closeAndWithdraw(100_000, 1e30, feeProtocolAddr, fakeReport);
        uint256 gClose = vm.stopSnapshotGas();

        console2.log("Solidity PerpPair, live params, demo scenario (call-only EVM gas):");
        console2.log("  addCollateral(50k USDC):", gAddCollateral);
        console2.log("  addLiquidity(30k+0.479):", gAddLiquidity);
        console2.log("  trade(long 100e18):     ", gTrade);
        console2.log("  closeAndWithdraw:       ", gClose);

        // The close must fully exit (trader was also the LP, mirroring the live caveat).
        (uint256 bs, uint256 ba, uint256 ds, uint256 da,,,,) = perpPair.userVirtualTraderPosition(trader);
        assertTrue(bs == 0 && ba == 0 && ds == 0 && da == 0, "position not cleared");
    }
}
