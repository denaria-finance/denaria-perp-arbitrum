// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { PerpPair } from "../src/PerpPair.sol";

/// @dev Pokes epoch storage directly so the cap can be driven to its boundary without staging a
///      full LP history. `rollEligible` sets a decayed matrix, which makes the next snapshot
///      refresh attempt a rollover.
contract LiquidityEpochCapHarness is PerpPair {
    constructor() PerpPair(address(1), address(2), address(3), 38_000, bytes32(0), 0, 0, address(4), 0, 0, 0) { }

    function setEpochs(uint256 oldestEpoch, uint256 currentEpochId) external {
        oldestActiveLiquidityEpoch = oldestEpoch;
        currentLiquidityEpoch = currentEpochId;
    }

    function setEpoch(uint256 epochId, uint256 activeLpCount, bool rollEligible) external {
        LiquidityEpoch storage epoch = liquidityEpochs[epochId];
        int256 liquidityMDecimal = decimals.liquidityMDecimals;
        int256 matrixValue = rollEligible ? int256(1) : liquidityMDecimal;

        epoch.liquidityM = [[matrixValue, int256(0)], [int256(0), matrixValue]];
        epoch.activeLpCount = activeLpCount;
    }

    function setLp(address user, uint256 epochId, uint256 stableBalance, uint256 assetBalance) external {
        LiquidityPosition storage position = liquidityPosition[user];
        position.initialStableBalance = stableBalance;
        position.initialAssetBalance = assetBalance;
        position.snapshotM = liquidityEpochs[epochId].liquidityM;
        liquidityPositionEpoch[user] = epochId;
    }

    function refresh(address user, uint256 stableBalance, uint256 assetBalance) external {
        _updateSnapshots(user, stableBalance, assetBalance);
    }

    function epochCount(uint256 epochId) external view returns (uint256) {
        return liquidityEpochs[epochId].activeLpCount;
    }

    function currentEpoch() external view returns (uint256) {
        return currentLiquidityEpoch;
    }

    function lpEpoch(address user) external view returns (uint256) {
        return liquidityPositionEpoch[user];
    }
}

/// @title Liquidity-epoch rollover cap regressions
/// @notice The cap must be evaluated against epochs that are actually OCCUPIED, measured AFTER the
///         migrating LP has released its old slot. Measuring the epoch-id span instead counts
///         drained middle epochs against the cap, so a rollover reverts `LECAP` while slots are in
///         fact free — and because liquidation and close both refresh snapshots, that freeze
///         reaches far beyond liquidity provision.
contract LiquidityEpochCapRegressionTest is Test {
    LiquidityEpochCapHarness internal pair;
    address internal victim = makeAddr("victim");
    address internal target = makeAddr("target");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        pair = new LiquidityEpochCapHarness();
    }

    /// @dev The sole occupant of the oldest epoch migrates: its release must be visible to the
    ///      census the rollover performs, otherwise the window looks full and reverts.
    function testSoleOldestLpMigrationFreesSlotBeforeRolloverCap() public {
        pair.setEpochs(0, 7);
        for (uint256 i; i < 7; i++) {
            pair.setEpoch(i, 1, false);
        }
        pair.setEpoch(7, 1, true);
        pair.setLp(victim, 0, 1e18, 1e18);

        pair.refresh(victim, 1e18, 1e18);

        assertEq(pair.currentEpoch(), 8, "roll should use freed oldest slot");
        assertEq(pair.lpEpoch(victim), 8, "victim should migrate to new epoch");
        assertEq(pair.epochCount(0), 0, "oldest epoch should be empty");
        assertEq(pair.epochCount(8), 1, "new epoch should track migrated LP");
    }

    /// @dev Six drained middle epochs sit inside the window. Under span arithmetic they consume the
    ///      whole cap; under an occupancy census they cost nothing.
    function testEmptyMiddleEpochsDoNotConsumeRolloverCap() public {
        pair.setEpochs(0, 7);
        pair.setEpoch(0, 1, false);
        pair.setEpoch(1, 0, false);
        pair.setEpoch(2, 0, false);
        pair.setEpoch(3, 0, false);
        pair.setEpoch(4, 0, false);
        pair.setEpoch(5, 0, false);
        pair.setEpoch(6, 0, false);
        pair.setEpoch(7, 1, true);

        pair.refresh(target, 1e18, 1e18);

        assertEq(pair.currentEpoch(), 8, "roll should ignore empty middle epochs");
        assertEq(pair.lpEpoch(target), 8, "new LP should enter rolled epoch");
        assertEq(pair.epochCount(8), 1, "new epoch should track LP");
    }

    /// @dev A permissionless refresh by a third party moves an LP forward. That must not burn the
    ///      slot a later rollover needs.
    function testPermissionlessSnapshotDoesNotSpendFreedSlot() public {
        pair.setEpochs(0, 7);
        pair.setEpoch(0, 1, false);
        pair.setEpoch(1, 1, false);
        pair.setEpoch(2, 1, false);
        pair.setEpoch(3, 1, false);
        pair.setEpoch(4, 1, false);
        pair.setEpoch(5, 1, false);
        pair.setEpoch(6, 1, false);
        pair.setEpoch(7, 0, false);
        pair.setLp(victim, 6, 1e18, 1e18);
        pair.setLp(target, 3, 1e18, 1e18);

        vm.prank(keeper);
        pair.refresh(victim, 1e18, 1e18);
        assertEq(pair.lpEpoch(victim), 7, "keeper refresh should move victim into current epoch");
        assertEq(pair.epochCount(6), 0, "victim should vacate old epoch");
        assertEq(pair.epochCount(7), 1, "current epoch should track victim");

        pair.setEpoch(7, 1, true);
        pair.refresh(target, 1e18, 1e18);

        assertEq(pair.currentEpoch(), 8, "later rollover should still fit under live cap");
        assertEq(pair.lpEpoch(target), 8, "target should migrate during later rollover");
    }

    /// @dev The cap itself must still bind: eight genuinely occupied epochs leave no slot, and the
    ///      rollover has to revert rather than grow the window.
    function testFullyOccupiedWindowStillRevertsLecap() public {
        pair.setEpochs(0, 7);
        for (uint256 i; i < 7; i++) {
            pair.setEpoch(i, 1, false);
        }
        pair.setEpoch(7, 1, true);
        // A brand-new LP releases nothing, so all eight epochs stay occupied.
        vm.expectRevert(bytes("LECAP"));
        pair.refresh(target, 1e18, 1e18);
    }

    /// @dev A same-epoch refresh must leave the refcount unchanged: the decrement and the
    ///      unconditional re-increment have to cancel exactly, not drift.
    function testSameEpochRefreshLeavesCountUnchanged() public {
        pair.setEpochs(0, 3);
        pair.setEpoch(3, 1, false);
        pair.setLp(victim, 3, 1e18, 1e18);

        pair.refresh(victim, 2e18, 2e18);

        assertEq(pair.currentEpoch(), 3, "no rollover was due");
        assertEq(pair.lpEpoch(victim), 3, "LP stays in its epoch");
        assertEq(pair.epochCount(3), 1, "refcount must not drift on a same-epoch refresh");
    }
}
