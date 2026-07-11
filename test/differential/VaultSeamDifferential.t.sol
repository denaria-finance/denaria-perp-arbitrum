// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { PerpPair } from "../../src/PerpPair.sol";
import { Vault } from "../../src/Vault.sol";
import { VaultLegacy } from "./VaultLegacy.sol";
import { LostAndFound } from "../../src/LostAndFound.sol";
import "../../src/token/USDCe.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/test_support/TestPriceProvider.sol";
import "../../src/manager/multiCallManager.sol";
import "../helpers/PerpPairTestDeploymentHelper.sol";

/// @title Vault seam-dedup differential
/// @notice Proves the seam-read dedup refactor of src/Vault.sol is behaviour-identical to the
///         pre-refactor Vault. It stands up TWO full, identically-configured perp stacks — one on
///         the refactored `Vault`, one on the frozen `VaultLegacy` snapshot — sharing one oracle
///         and one set of stablecoins, drives BOTH through the same operations (LP seed, trade,
///         then a battery of collateral ops across in/out-of-window times and profit/loss prices),
///         and asserts the two vaults' full observable state stays bit-identical after every step.
///         A single divergence — a different snapshot flip (#2) or a different PnL/MR gate from the
///         reused price (#7) — would break parity. Includes a fuzzed op sequence.
contract VaultSeamDifferentialTest is Test, PerpPairTestDeploymentHelper {
    uint256 constant MAX_UINT = type(uint256).max;
    uint256 constant ratioDecimals = 1e8;
    uint256 constant oracleDecimals = 1e8;
    uint256 constant collateralDecimals = 1e18;
    uint256 constant MMR = 38 * 1e6 / 1000;
    uint32 constant feeFractionDecimals = 1e6;
    uint32 constant feeFrontend = 5 * feeFractionDecimals / 100;
    uint32 constant feeLP = 5 * feeFractionDecimals / 10;
    uint256 constant tradingFee = 1 * 1e18 / 1000;
    uint256 constant flatTradingFee = 1e17;
    uint256 constant maxUserLiquidityFee = 1e30;
    bytes32 constant tickerAsset = bytes32(0);

    address constant MasterMinter = address(0xBEEF);
    address constant Pauser = address(0xBEEF);
    address constant Blacklister = address(0xBEEF);
    address constant Owner = address(0xBEEF);
    address constant feeProtocolAddr = address(0xFEE);
    address constant frontendAddress = address(0xFE);
    address constant alice = address(0xA11CE); // liquidity provider
    address constant bob = address(0xB0B); // trader

    address[] stableCoinsCfg;
    uint256[] depositThresholds;
    uint256[] withdrawalThresholds;
    uint256[] stableDecimalsCfg;
    uint256 constant numStableCoins = 2;

    TestPriceProvider oracle;

    // Stack A: refactored Vault. Stack B: frozen legacy Vault.
    Vault vaultA;
    PerpPair perpA;
    VaultLegacy vaultB;
    PerpPair perpB;

    ERC20 coinA;
    ERC20 coinB;

    bytes emptyReport;

    function setUp() public {
        // --- shared stablecoins + oracle ---
        uint8[2] memory dec = [6, 18];
        for (uint256 i; i < numStableCoins; i++) {
            FiatTokenV2 sc = new FiatTokenV2();
            sc.initialize("USDCe", "USDC.e", "USD", dec[i], MasterMinter, Pauser, Blacklister, Owner);
            vm.prank(MasterMinter);
            sc.configureMinter(MasterMinter, 1e40);
            stableCoinsCfg.push(address(sc));
            depositThresholds.push(1 * ratioDecimals);
            withdrawalThresholds.push(1 * ratioDecimals / 10);
        }
        stableDecimalsCfg.push(1e6);
        stableDecimalsCfg.push(1e18);

        oracle = new TestPriceProvider();

        (vaultA, perpA) = _deployStackRefactored();
        (vaultB, perpB) = _deployStackLegacy();

        coinA = ERC20(stableCoinsCfg[0]);
        coinB = ERC20(stableCoinsCfg[1]);

        oracle.setPrice(100 * oracleDecimals);

        _fund(alice);
        _fund(bob);
    }

    function _deployStackRefactored() internal returns (Vault v, PerpPair p) {
        PerpMultiCalls mgr = new PerpMultiCalls();
        v = new Vault(address(mgr), 100, stableCoinsCfg, depositThresholds, withdrawalThresholds, stableDecimalsCfg);
        p = _deployPerpPairForTest(
            address(oracle),
            address(v),
            address(mgr),
            MMR,
            tickerAsset,
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );
        mgr.initializeAddresses(address(p), address(v));
        LostAndFound laf = new LostAndFound();
        laf.grantRole(laf.VAULT_ROLE(), address(v));
        v.initializeParameters(address(p), address(laf));
        _restoreTestEraParameters(
            p, address(oracle), feeFrontend, feeProtocolAddr, MMR, tradingFee, flatTradingFee, feeLP
        );
    }

    function _deployStackLegacy() internal returns (VaultLegacy v, PerpPair p) {
        PerpMultiCalls mgr = new PerpMultiCalls();
        v = new VaultLegacy(
            address(mgr),
            address(oracle),
            100,
            stableCoinsCfg,
            depositThresholds,
            withdrawalThresholds,
            stableDecimalsCfg
        );
        p = _deployPerpPairForTest(
            address(oracle),
            address(v),
            address(mgr),
            MMR,
            tickerAsset,
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );
        mgr.initializeAddresses(address(p), address(v));
        LostAndFound laf = new LostAndFound();
        laf.grantRole(laf.VAULT_ROLE(), address(v));
        v.initializeParameters(address(p), address(laf));
        _restoreTestEraParameters(
            p, address(oracle), feeFrontend, feeProtocolAddr, MMR, tradingFee, flatTradingFee, feeLP
        );
    }

    function _fund(address u) internal {
        vm.startPrank(MasterMinter);
        FiatTokenV2(stableCoinsCfg[0]).mint(u, 1_000_000_000 * 1e6);
        FiatTokenV2(stableCoinsCfg[1]).mint(u, 1_000_000_000 * 1e18);
        vm.stopPrank();
        vm.startPrank(u);
        coinA.approve(address(vaultA), MAX_UINT);
        coinB.approve(address(vaultA), MAX_UINT);
        coinA.approve(address(vaultB), MAX_UINT);
        coinB.approve(address(vaultB), MAX_UINT);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Operations applied to BOTH stacks identically.
    // -------------------------------------------------------------------------

    function _addBoth(address u, uint256 a0, uint256 a1) internal {
        uint256[] memory a = new uint256[](numStableCoins);
        a[0] = a0;
        a[1] = a1;
        vm.prank(u);
        vaultA.addCollateral(a);
        vm.prank(u);
        vaultB.addCollateral(a);
        _assertParity("addCollateral");
    }

    function _addLiquidityBoth(address u, uint256 s, uint256 a) internal {
        vm.prank(u);
        perpA.addLiquidity(s, a, maxUserLiquidityFee, emptyReport);
        vm.prank(u);
        perpB.addLiquidity(s, a, maxUserLiquidityFee, emptyReport);
    }

    function _tradeBoth(address u, bool dir, uint256 size) internal {
        vm.prank(u);
        perpA.trade(dir, size, 0, 0, frontendAddress, 1, emptyReport);
        vm.prank(u);
        perpB.trade(dir, size, 0, 0, frontendAddress, 1, emptyReport);
    }

    /// @dev removeCollateral on both; asserts identical success/revert, then parity.
    function _removeBoth(address u, uint256 amount) internal {
        vm.prank(u);
        (bool okA,) = address(vaultA).call(abi.encodeCall(Vault.removeCollateral, (amount, emptyReport)));
        vm.prank(u);
        (bool okB,) = address(vaultB).call(abi.encodeCall(VaultLegacy.removeCollateral, (amount, emptyReport)));
        assertEq(okA, okB, "removeCollateral success/revert diverged");
        _assertParity("removeCollateral");
    }

    function _removeAllBoth(address u) internal {
        vm.prank(u);
        (bool okA,) = address(vaultA).call(abi.encodeCall(Vault.removeAllCollateral, (emptyReport)));
        vm.prank(u);
        (bool okB,) = address(vaultB).call(abi.encodeCall(VaultLegacy.removeAllCollateral, (emptyReport)));
        assertEq(okA, okB, "removeAllCollateral success/revert diverged");
        _assertParity("removeAllCollateral");
    }

    /// @dev Full observable-state parity between the two vaults.
    function _assertParity(string memory ctx) internal view {
        assertEq(vaultA.totalCollateral(), vaultB.totalCollateral(), string.concat(ctx, ": totalCollateral"));
        assertEq(
            vaultA.lastSnapshotTimestamp(),
            vaultB.lastSnapshotTimestamp(),
            string.concat(ctx, ": lastSnapshotTimestamp")
        );
        assertEq(
            vaultA.totalCollateralRatio(coinA), vaultB.totalCollateralRatio(coinA), string.concat(ctx, ": totalRatioA")
        );
        assertEq(
            vaultA.totalCollateralRatio(coinB), vaultB.totalCollateralRatio(coinB), string.concat(ctx, ": totalRatioB")
        );
        _assertUserParity(alice, ctx, "alice");
        _assertUserParity(bob, ctx, "bob");
    }

    function _assertUserParity(address u, string memory ctx, string memory who) internal view {
        assertEq(vaultA.userCollateral(u), vaultB.userCollateral(u), string.concat(ctx, ": ", who, " collateral"));
        assertEq(
            vaultA.userCollateralRatio(u, coinA),
            vaultB.userCollateralRatio(u, coinA),
            string.concat(ctx, ": ", who, " ratioA")
        );
        assertEq(
            vaultA.userCollateralRatio(u, coinB),
            vaultB.userCollateralRatio(u, coinB),
            string.concat(ctx, ": ", who, " ratioB")
        );
    }

    // -------------------------------------------------------------------------
    // Scripted full flow: LP seed -> open position -> collateral ops across time & price.
    // -------------------------------------------------------------------------

    function test_diff_scriptedFullFlow() public {
        vm.warp(1_000_000);

        // Alice provides collateral + liquidity on both stacks.
        _addBoth(alice, 10_000_000 * 1e6, 10_000_000 * 1e18);
        _addLiquidityBoth(alice, 1_000_000 * 1e18, 10_000 * 1e18);

        // Bob deposits and opens a long on both stacks.
        _addBoth(bob, 5000 * 1e6, 5000 * 1e18);
        _tradeBoth(bob, true, 1000 * 1e18);

        // In-window collateral op (guard must skip the engine read on both, no flip).
        vm.warp(1_000_100);
        _addBoth(bob, 100 * 1e6, 100 * 1e18);

        // Price moves up (profit): partial removeCollateral exercises the PnL/MR gates (#7 price reuse).
        oracle.setPrice(108 * oracleDecimals);
        vm.warp(1_000_500);
        _removeBoth(bob, 500 * 1e18);

        // Price moves down (loss): another partial remove near the margin.
        oracle.setPrice(94 * oracleDecimals);
        vm.warp(1_002_000);
        _removeBoth(bob, 200 * 1e18);

        // Out-of-window op crossing ratioLockTime (+max randomDelta): snapshot must flip identically.
        oracle.setPrice(100 * oracleDecimals);
        vm.warp(1_002_000 + 86_400 + 7201);
        _addBoth(bob, 300 * 1e6, 300 * 1e18);

        // Alice removes part of her (large) collateral, then bob removes all.
        _removeBoth(alice, 1_000_000 * 1e18);
        _removeAllBoth(bob);
    }

    // -------------------------------------------------------------------------
    // Fuzzed op sequence over a pre-opened position.
    // -------------------------------------------------------------------------

    function testFuzz_diff_collateralOps(uint256[8] calldata seeds) public {
        vm.warp(2_000_000);
        _addBoth(alice, 10_000_000 * 1e6, 10_000_000 * 1e18);
        _addLiquidityBoth(alice, 1_000_000 * 1e18, 10_000 * 1e18);
        _addBoth(bob, 5000 * 1e6, 5000 * 1e18);
        _tradeBoth(bob, true, 1000 * 1e18);

        uint256 t = 2_000_000;
        for (uint256 i; i < seeds.length; i++) {
            uint256 s = seeds[i];
            // advance time by 0 .. ~1.1 days so both in-window and out-of-window paths get hit
            t += s % 100_000;
            vm.warp(t);
            // nudge the price within a safe band so removes don't all revert on PnL
            oracle.setPrice((90 + (s % 20)) * oracleDecimals);

            address u = (s % 3 == 0) ? alice : bob;
            uint256 op = (s >> 8) % 3;
            if (op == 0) {
                uint256 units = 1 + (s % 500);
                _addBoth(u, units * 1e6, units * 1e18);
            } else if (op == 1) {
                uint256 amt = 1e18 + (s % (400 * 1e18));
                _removeBoth(u, amt);
            } else {
                _removeAllBoth(u);
            }
        }
    }
}
