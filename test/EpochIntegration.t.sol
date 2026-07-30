// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPair } from "../src/PerpPair.sol";
import { PerpPairTest } from "./PerpPair.t.sol";
import { FiatTokenV2 } from "../src/token/USDCe.sol";

/// @dev PerpPair subclass exposing the two epoch internals these end-to-end tests observe (the current
///      accounting epoch and a given epoch's determinant). Everything else runs through the real
///      public entrypoints, so the reference logic under test is unmodified.
contract EpochHarness is PerpPair {
    constructor(
        address o,
        address v,
        address m,
        uint256 mmr,
        bytes32 t,
        uint32 ff,
        uint32 fl,
        address fp,
        uint256 tf,
        uint256 ftf,
        uint256 ema
    )
        PerpPair(o, v, m, mmr, t, ff, fl, fp, tf, ftf, ema)
    { }

    function exposedCurrentLiquidityEpoch() external view returns (uint256) {
        return currentLiquidityEpoch;
    }

    function exposedLiquidityEpochDeterminant(uint256 epochId) external view returns (int256) {
        return _liquidityEpochDeterminant(epochId);
    }
}

/// @dev End-to-end epoch tests driven entirely through the real public entrypoints. Reuses the full
///      PerpPairTest deployment stack (Vault, token, oracle, manager, collateral) and only swaps the
///      deployed PerpPair for the exposed harness. The determinant-collapse condition is
///      reproduced by REAL trade churn (poking the matrix would break snapshot/matrix consistency),
///      so the epoch roll and the LP-snapshot migration are exercised through addLiquidity /
///      updateLpSnapshot / realizePnL exactly as in production.
contract EpochIntegrationTest is PerpPairTest {
    uint256 internal constant BTC_PRICE = 6_689_150_000_000; // 66,891.5 * 1e8
    int256 internal constant Q80_SCALE = int256(uint256(1) << 80);

    address internal aliceLp;
    address internal bobLp = makeAddr("bob");
    address internal charlieCaller = makeAddr("charlie");
    address internal davidChurn = makeAddr("david");
    address internal eveChurn = makeAddr("eve");

    function _deployPerpPairForTest(
        address oracle_,
        address vault_,
        address multiCallManager_,
        uint256 mmr_,
        bytes32 tickerAssetCurrency_,
        uint32 feeFrontend_,
        uint32 feeLP_,
        address feeProtocolAddr_,
        uint256 tradingFee_,
        uint256 flatTradingFee_,
        uint256 emaParam_
    )
        internal
        override
        returns (PerpPair)
    {
        return new EpochHarness(
            oracle_,
            vault_,
            multiCallManager_,
            mmr_,
            tickerAssetCurrency_,
            feeFrontend_,
            feeLP_,
            feeProtocolAddr_,
            tradingFee_,
            flatTradingFee_,
            emaParam_
        );
    }

    function _harness() internal view returns (EpochHarness) {
        return EpochHarness(address(perpPair));
    }

    function _diffAbs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _fundWhaleCollateral(address user, uint256 amount18) internal {
        vm.prank(MasterMinter);
        FiatTokenV2(stableCoins[1]).mint(user, amount18);
        uint256[] memory col = new uint256[](2);
        col[1] = amount18;
        vm.prank(user);
        vault.addCollateral(col);
    }

    function _attemptFractionalLong(uint256 tradeBps) internal {
        skip(120);
        uint256 longSize = ((perpPair.globalLiquidityAsset() * BTC_PRICE) / oracleDecimals) * tradeBps / 10_000;
        uint256 assetLiquidity = perpPair.globalLiquidityAsset();
        vm.prank(davidChurn);
        try perpPair.trade(true, longSize, 1, assetLiquidity, frontendAddress, 1, fakeReport) { } catch { }
    }

    function _attemptFractionalShort(uint256 tradeBps) internal {
        skip(120);
        uint256 shortSize = ((perpPair.globalLiquidityStable() * oracleDecimals) / BTC_PRICE) * tradeBps / 10_000;
        uint256 stableLiquidity = perpPair.globalLiquidityStable();
        vm.prank(eveChurn);
        try perpPair.trade(false, shortSize, 1, stableLiquidity, frontendAddress, 1, fakeReport) { } catch { }
    }

    /// @dev Seed a BTC-like pool with `aliceLp` as the incumbent LP, then churn it with real
    ///      alternating long/short trades until epoch 0's determinant decays below the roll threshold
    ///      (scale / 1e12). Trades never roll the epoch themselves — the roll only fires on the next
    ///      snapshot write.
    function _prepareIllConditionedPool() internal {
        oracle.setPrice(BTC_PRICE);
        aliceLp = makeAddr("alice");
        uint256 aliceStable = 1_000_000 * 1e18;
        uint256 aliceAsset = (aliceStable * oracleDecimals) / BTC_PRICE;
        vm.prank(aliceLp);
        perpPair.addLiquidity(aliceStable, aliceAsset, maxUserLiquidityFee, fakeReport);

        _fundWhaleCollateral(davidChurn, 1_000_000_000 * 1e18);
        _fundWhaleCollateral(eveChurn, 1_000_000_000 * 1e18);

        int256 minHealthyDeterminant = Q80_SCALE / int256(1e12);
        for (uint256 i; i < 200 && _harness().exposedLiquidityEpochDeterminant(0) > minHealthyDeterminant; i++) {
            for (uint256 j; j < 5; j++) {
                _attemptFractionalLong(1000);
                _attemptFractionalShort(1000);
            }
        }

        assertEq(_harness().exposedCurrentLiquidityEpoch(), 0, "trades alone must not roll the epoch");
        assertLe(_harness().exposedLiquidityEpochDeterminant(0), minHealthyDeterminant, "pool did not ill-condition");
    }

    ///@dev Core property: once the current epoch's matrix is ill-conditioned, the next LP
    ///     snapshot rolls a FRESH identity epoch and reconstructs instantly against it, while the
    ///     incumbent LP stays pinned to (and keeps reconstructing against) its own decayed epoch.
    function testEpochRollsNewLpSnapshotToFreshBasisAfterIllConditioning() public {
        _prepareIllConditionedPool();
        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 0, "incumbent LP should be epoch 0");

        uint256 bobStable = 20_000 * 1e18;
        uint256 bobAsset = (bobStable * oracleDecimals) / BTC_PRICE;
        vm.prank(bobLp);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);

        assertEq(_harness().exposedCurrentLiquidityEpoch(), 1, "new LP add should roll the epoch");
        assertEq(perpPair.getLpLiquidityEpoch(bobLp), 1, "new LP snapshots in the fresh epoch");
        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 0, "incumbent LP stays in the old epoch");

        (uint256 initialStable, uint256 initialAsset,,) = perpPair.liquidityPosition(bobLp);
        (uint256 liveStable, uint256 liveAsset) = perpPair.getLpLiquidityBalance(bobLp);
        assertEq(liveStable, initialStable, "fresh-epoch instant stable reconstruction");
        assertEq(liveAsset, initialAsset, "fresh-epoch instant asset reconstruction");
    }

    ///@dev A keeper can force an incumbent LP's snapshot to migrate into the current epoch via
    ///     updateLpSnapshot without materially changing its withdrawable balance.
    function testAnyoneCanForceLpSnapshotToCurrentEpoch() public {
        _prepareIllConditionedPool();

        uint256 bobStable = 20_000 * 1e18;
        uint256 bobAsset = (bobStable * oracleDecimals) / BTC_PRICE;
        vm.prank(bobLp);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);
        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 0, "alice starts in the old epoch");

        (uint256 stableBefore, uint256 assetBefore) = perpPair.getLpLiquidityBalance(aliceLp);
        vm.prank(charlieCaller);
        perpPair.updateLpSnapshot(aliceLp, fakeReport);
        (uint256 stableAfter, uint256 assetAfter) = perpPair.getLpLiquidityBalance(aliceLp);

        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 1, "manual refresh migrates alice to the current epoch");
        assertLt(_diffAbs(stableAfter, stableBefore), 1e14, "manual refresh materially changed the stable balance");
        assertLt(_diffAbs(assetAfter, assetBefore), 1e10, "manual refresh materially changed the asset balance");
    }

    ///@dev realizePnL settles funding AND migrates the caller's LP snapshot into the current epoch.
    function testRealizePnlRefreshesLpSnapshotToCurrentEpoch() public {
        _prepareIllConditionedPool();

        uint256 bobStable = 20_000 * 1e18;
        uint256 bobAsset = (bobStable * oracleDecimals) / BTC_PRICE;
        vm.prank(bobLp);
        perpPair.addLiquidity(bobStable, bobAsset, maxUserLiquidityFee, fakeReport);
        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 0, "alice starts in the old epoch");

        (uint256 stableBefore, uint256 assetBefore) = perpPair.getLpLiquidityBalance(aliceLp);
        vm.prank(aliceLp);
        perpPair.realizePnL(fakeReport);
        (uint256 stableAfter, uint256 assetAfter) = perpPair.getLpLiquidityBalance(aliceLp);

        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 1, "realizePnL migrates the LP snapshot");
        assertLt(_diffAbs(stableAfter, stableBefore), 1e14, "realizePnL materially changed the stable balance");
        assertLt(_diffAbs(assetAfter, assetBefore), 1e10, "realizePnL materially changed the asset balance");
    }

    ///@dev SOLVENCY ACROSS EPOCHS — the property every other epoch test here stops short of. Each
    /// LP reconstructs its balance against its OWN accounting epoch's matrix, so with three LPs
    /// pinned to three different epochs there are three independent reconstructions reading one
    /// shared pool. `getLpLiquidityBalance` clamps each LP individually to the globals, which says
    /// nothing about their SUM: if a cross-epoch reconstruction over-credits, the LPs collectively
    /// hold claims the pool cannot honour and the last one out cannot be paid. Nothing pinned that
    /// sum — the existing tests roll a single epoch and only check ids and one LP's drift.
    function testLpClaimsAcrossThreeEpochsNeverExceedThePool() public {
        // Roll #1: alice stays in epoch 0, bob lands in the fresh epoch 1.
        _prepareIllConditionedPool();
        uint256 bobStable = 20_000 * 1e18;
        vm.prank(bobLp);
        perpPair.addLiquidity(bobStable, (bobStable * oracleDecimals) / BTC_PRICE, maxUserLiquidityFee, fakeReport);
        assertEq(_harness().exposedCurrentLiquidityEpoch(), 1, "first roll");

        // Churn epoch 1 down the same way, then roll #2 with a third LP.
        int256 minHealthyDeterminant = Q80_SCALE / int256(1e12);
        for (uint256 i; i < 200 && _harness().exposedLiquidityEpochDeterminant(1) > minHealthyDeterminant; i++) {
            for (uint256 j; j < 5; j++) {
                _attemptFractionalLong(1000);
                _attemptFractionalShort(1000);
            }
        }
        assertLe(_harness().exposedLiquidityEpochDeterminant(1), minHealthyDeterminant, "epoch 1 did not decay");

        // Reuse a setUp-funded address: a fresh one holds no vault collateral, and a fully
        // debt-financed LP add then prices to a zero-magnitude LOSS which trips the C1 bad-debt
        // guard (`0 < 0` is false). Minting alone is not enough either — `addCollateral` needs the
        // ERC20 approval that setUp grants only to the named users.
        address carolLp = charlieCaller;
        uint256 carolStable = 15_000 * 1e18;
        vm.prank(carolLp);
        perpPair.addLiquidity(carolStable, (carolStable * oracleDecimals) / BTC_PRICE, maxUserLiquidityFee, fakeReport);
        assertEq(_harness().exposedCurrentLiquidityEpoch(), 2, "second roll");

        // Three LPs, three distinct epochs — the state the invariant has to hold over.
        assertEq(perpPair.getLpLiquidityEpoch(aliceLp), 0, "alice pinned to epoch 0");
        assertEq(perpPair.getLpLiquidityEpoch(bobLp), 1, "bob pinned to epoch 1");
        assertEq(perpPair.getLpLiquidityEpoch(carolLp), 2, "carol pinned to epoch 2");

        (uint256 aS, uint256 aA) = perpPair.getLpLiquidityBalance(aliceLp);
        (uint256 bS, uint256 bA) = perpPair.getLpLiquidityBalance(bobLp);
        (uint256 cS, uint256 cA) = perpPair.getLpLiquidityBalance(carolLp);

        assertLe(aS + bS + cS, perpPair.globalLiquidityStable(), "LP stable claims exceed the pool");
        assertLe(aA + bA + cA, perpPair.globalLiquidityAsset(), "LP asset claims exceed the pool");

        // And the pool is not merely large enough by accident: the incumbent still holds a real
        // claim, so the bound above is being tested against a live multi-LP distribution.
        assertGt(aS, 0, "incumbent LP lost its stable claim entirely");
    }
}
