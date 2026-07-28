// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PerpPair } from "../src/PerpPair.sol";
import { PerpPairTest } from "./PerpPair.t.sol";

/// @dev PerpPair subclass that can seed an LP whose recovered balances clamp to zero while its
///      snapshot is still active and carries unsettled funding. The state is reached in production by
///      matrix decay against an adverse pool; seeding it directly keeps the test deterministic. Only
///      storage is written — the close path under test runs through the real entrypoint.
contract ActiveSnapshotHarness is PerpPair {
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

    function exposedLiquidityGScale() external view returns (uint256) {
        return decimals.liquidityGDecimals;
    }

    /// @dev Seeds `user` with an active snapshot whose recovery is negative — so both visible legs
    ///      clamp to zero — while the epoch's row G has advanced past the position's own G snapshot,
    ///      leaving `initialStableBalance`-scaled funding pending.
    function seedZeroVisibleActiveLpSnapshot(
        address user,
        uint256 initialStableBalance,
        int256 pendingG0,
        uint256 backingStable,
        uint256 backingAsset
    )
        external
    {
        int256 liquidityMScale = decimals.liquidityMDecimals;
        LiquidityEpoch storage epoch = liquidityEpochs[currentLiquidityEpoch];
        epoch.liquidityM = [[-liquidityMScale, int256(0)], [int256(0), -liquidityMScale]];
        epoch.matrixRowG = [pendingG0, int256(0)];
        epoch.activeLpCount += 1;

        LiquidityPosition storage position = liquidityPosition[user];
        position.initialStableBalance = initialStableBalance;
        position.initialAssetBalance = 0;
        position.debtStable = 0;
        position.debtAsset = 0;
        position.snapshotM = [[liquidityMScale, int256(0)], [int256(0), liquidityMScale]];
        delete position.snapshotG;
        liquidityPositionEpoch[user] = currentLiquidityEpoch;

        globalLiquidityStable = backingStable;
        globalLiquidityAsset = backingAsset;
    }
}

/// @dev An LP whose visible balances and debts have all decayed to zero can still hold an active
///      snapshot carrying unsettled funding. Close eligibility keyed only on the visible values
///      skipped the removal path for it, so the pending funding was never settled and the LP walked
///      away from a debt it owed the pool.
contract ActiveSnapshotCloseTest is PerpPairTest {
    uint256 internal constant BTC_PRICE = 6_689_150_000_000; // 66,891.5 * 1e8

    address internal lpUser = makeAddr("bob");

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
        return new ActiveSnapshotHarness(
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

    function _harness() internal view returns (ActiveSnapshotHarness) {
        return ActiveSnapshotHarness(address(perpPair));
    }

    ///@dev Core property: closing settles the pending LP funding and retires the snapshot even though
    ///     every visible balance and debt reads zero.
    function testCloseSettlesFundingOnAZeroVisibleActiveSnapshot() public {
        oracle.setPrice(BTC_PRICE);

        uint256 pendingFunding = 1e18;
        uint256 backingStable = 1_000_000 * 1e18;
        uint256 backingAsset = (backingStable * oracleDecimals) / BTC_PRICE;
        _harness()
            .seedZeroVisibleActiveLpSnapshot(
                lpUser, pendingFunding, int256(_harness().exposedLiquidityGScale()), backingStable, backingAsset
            );

        (uint256 lpStableBalance, uint256 lpAssetBalance) = perpPair.getLpLiquidityBalance(lpUser);
        assertEq(lpStableBalance, 0, "seeded LP stable balance should be clamped to zero");
        assertEq(lpAssetBalance, 0, "seeded LP asset balance should be clamped to zero");

        (uint256 fundingBefore, bool fundingBeforeSign) = perpPair.computeFundingFee(lpUser);
        assertEq(fundingBefore, pendingFunding, "pending LP funding not seeded");
        assertTrue(fundingBeforeSign, "pending LP funding should be payable");

        uint256 collateralBefore = vault.userCollateral(lpUser);
        vm.prank(lpUser);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        assertEq(collateralBefore - vault.userCollateral(lpUser), pendingFunding, "close skipped pending LP funding");
        (uint256 fundingAfter,) = perpPair.computeFundingFee(lpUser);
        assertEq(fundingAfter, 0, "close left pending LP funding");
        (uint256 initialStable, uint256 initialAsset,,) = perpPair.liquidityPosition(lpUser);
        assertEq(initialStable | initialAsset, 0, "close left the LP snapshot active");
    }

    ///@dev The widened condition must not drag a plain trader with no LP snapshot into the removal
    ///     path: a zero position still closes as a no-op.
    function testCloseOnAZeroPositionWithoutSnapshotRemainsANoOp() public {
        oracle.setPrice(BTC_PRICE);

        uint256 collateralBefore = vault.userCollateral(lpUser);
        vm.prank(lpUser);
        perpPair.closeAndWithdraw(1e5, 0, frontendAddress, fakeReport);

        assertEq(vault.userCollateral(lpUser), collateralBefore, "no-snapshot close must not move collateral");
        (uint256 initialStable, uint256 initialAsset,,) = perpPair.liquidityPosition(lpUser);
        assertEq(initialStable | initialAsset, 0, "no-snapshot close must not create LP state");
    }
}
