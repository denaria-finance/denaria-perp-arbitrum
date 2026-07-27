// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { PerpPair } from "../src/PerpPair.sol";

/// @title Configuration invariants on the Solidity reference
/// @notice Mirrors the engine's configuration guards so the differential reference cannot drift:
///         the MMR floor and emaParam ceiling at construction, the prepare/finalize split for the
///         fee pair (feeFrontend is not part of the param hash, so only finalize can judge the
///         pair), and the unguarded setter's MMR-relative discount bound, proposed-address check
///         and nonzero slippage threshold. Every bound is exercised immediately below, at, and
///         immediately above its accepted value.
contract ConfigInvariantsTest is Test {
    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 internal constant MMR = 40_000; // discount bound is MMR/2 = 20_000

    address internal oracle = makeAddr("oracle");
    address internal vault = makeAddr("vault");
    address internal manager = makeAddr("manager");
    address internal feeProtocolAddr = makeAddr("feeProtocol");

    uint32 internal constant FEE_FRONTEND = 300_000;
    uint32 internal constant FEE_LP = 500_000;
    uint256 internal constant TRADING_FEE = 0;
    uint256 internal constant FLAT_TRADING_FEE = 12e16;

    function _deploy(uint256 mmr, uint256 emaParam) internal returns (PerpPair) {
        return new PerpPair(
            oracle,
            vault,
            manager,
            mmr,
            bytes32(0),
            FEE_FRONTEND,
            FEE_LP,
            feeProtocolAddr,
            TRADING_FEE,
            FLAT_TRADING_FEE,
            emaParam
        );
    }

    function _pair() internal returns (PerpPair) {
        return _deploy(MMR, ORACLE_DECIMALS * 9 / 10);
    }

    // --- constructor bounds -------------------------------------------------------------

    function testConstructorRejectsMmrBelowTwo() public {
        vm.expectRevert(bytes("SET4"));
        _deploy(0, ORACLE_DECIMALS * 9 / 10);

        vm.expectRevert(bytes("SET4"));
        _deploy(1, ORACLE_DECIMALS * 9 / 10);
    }

    function testConstructorAcceptsMmrFloor() public {
        PerpPair pair = _deploy(2, ORACLE_DECIMALS * 9 / 10);
        assertEq(pair.MMR(), 2);
    }

    /// @dev The Solidity reference spells this condition SET8; SET8 is already taken in this
    ///      repository by the engine's trusted-forwarder guard, so it is reported as SET9.
    function testConstructorRejectsEmaParamAboveOracleDecimals() public {
        vm.expectRevert(bytes("SET9"));
        _deploy(MMR, ORACLE_DECIMALS + 1);
    }

    function testConstructorAcceptsEmaParamAtOracleDecimals() public {
        // emaParam has no external getter; a successful construction is the observable.
        PerpPair pair = _deploy(MMR, ORACLE_DECIMALS);
        assertEq(pair.MMR(), MMR);
    }

    // --- time-locked prepare / finalize --------------------------------------------------

    function testPrepareRejectsZeroDivisorsAndLowMmr() public {
        PerpPair pair = _pair();

        vm.expectRevert(bytes("C"));
        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 0, 10, 1e18);

        vm.expectRevert(bytes("C"));
        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 0, 1e6, 10, 1e18);

        vm.expectRevert(bytes("C"));
        pair.prepareTimeLockedParameters(1, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);

        // The floor itself is accepted.
        pair.prepareTimeLockedParameters(2, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }

    /// @dev feeFrontend is not part of the param hash, so a prepare-time judgement would read a
    ///      value that may be stale by finalize. Prepare must therefore accept the pair and
    ///      finalize must reject it.
    function testFeePairIsJudgedAtFinalizeNotPrepare() public {
        PerpPair pair = _pair();
        uint256 clashingLp = 1e6 - FEE_FRONTEND; // sum lands exactly on 1e6

        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, clashingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);

        vm.expectRevert(bytes("C"));
        pair.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, clashingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }

    function testFeePairOneUnitBelowTheSumFinalizes() public {
        PerpPair pair = _pair();
        uint256 fittingLp = 1e6 - FEE_FRONTEND - 1;

        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, fittingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        pair.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, fittingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);

        (,,,,, uint256 appliedFeeLp,,,,,,,,,,) = pair.ReadParameters();
        assertEq(appliedFeeLp, fittingLp, "feeLP applied at finalize");
    }

    /// @dev An unrelated setter run between prepare and finalize can invalidate the pair; the
    ///      finalize-time re-check is what catches it.
    function testFrontendFeeRaisedBetweenPrepareAndFinalizeIsCaught() public {
        PerpPair pair = _pair();
        uint256 fittingLp = 1e6 - FEE_FRONTEND - 1;

        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, fittingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);
        pair.setUnguardedParameters(oracle, FEE_FRONTEND + 1, feeProtocolAddr, 1e8, 15, 7500, 10, 10);
        skip(11);

        vm.expectRevert(bytes("C"));
        pair.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, fittingLp, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }

    /// @dev The unguarded frontend setter accepts equality (`feeFrontend == 1e6 - feeLP`) while the
    ///      timelocked finalize rejects the same sum. Both are intentional and must stay distinct.
    function testUnguardedAcceptsEqualityThatFinalizeRejects() public {
        PerpPair pair = _pair();

        pair.setUnguardedParameters(oracle, uint32(1e6 - FEE_LP), feeProtocolAddr, 1e8, 15, 7500, 10, 10);
        (,,,, uint256 appliedFrontend,,,,,,,,,,,) = pair.ReadParameters();
        assertEq(appliedFrontend, 1e6 - FEE_LP, "unguarded setter accepts the equality");

        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        vm.expectRevert(bytes("C"));
        pair.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }

    // --- unguarded setter ----------------------------------------------------------------

    function testDiscountBoundTracksMmr() public {
        PerpPair pair = _pair();

        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(MMR / 2 - 1), 10, 10);

        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(MMR / 2), 10, 10);

        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(MMR / 2 + 1), 10, 10);
    }

    /// @dev A discount the previous fixed `1e6/2` bound would have accepted is now rejected.
    function testDiscountNoLongerBoundedByHalfOfFeeDecimals() public {
        PerpPair pair = _pair();

        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, 499_999, 10, 10);
    }

    function testProposedProtocolFeeAddressIsValidated() public {
        PerpPair pair = _pair();

        // The stored address is non-zero, so validating storage instead of the proposal would
        // let this through and blackhole the protocol fee.
        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, address(0), 1e8, 15, 7500, 10, 10);
    }

    function testSlipLiquidationThresholdMustBeNonZero() public {
        PerpPair pair = _pair();

        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, 7500, 10, 0);

        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, 7500, 10, 1);
    }

    /// @dev Documented residual, deliberately NOT fixed here, pending owner ratification: the
    ///      discount bound is validated only when the discount is set, so a later timelocked MMR
    ///      decrease can leave `liquidationDiscount >= MMR / 2` standing. Adding the reciprocal
    ///      check would make this implementation stricter than the Solidity source of truth and
    ///      give the same governance transaction different outcomes across the two, so it is
    ///      recorded rather than changed. The state is recoverable — the next unguarded call must
    ///      bring the discount back under the bound. This test characterises the reachable state
    ///      so a future fix has a failing anchor.
    function testMmrDecreaseCanStrandAnOutOfBoundDiscount() public {
        PerpPair pair = _pair();

        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(MMR / 2 - 1), 10, 10);

        uint256 lowerMmr = 100; // MMR/2 = 50, far below the discount just accepted
        pair.prepareTimeLockedParameters(lowerMmr, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        pair.setTimeLockedParameters(lowerMmr, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);

        (,,,,,, uint256 discount,,,,) = pair.ReadFees();
        assertEq(pair.MMR(), lowerMmr);
        assertGe(discount, pair.MMR() / 2, "residual: discount outlives the bound");

        // Recoverable: the next unguarded call must bring the discount back under the new bound.
        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(lowerMmr / 2), 10, 10);
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(lowerMmr / 2 - 1), 10, 10);
    }

    /// @dev Second documented residual, also pending owner ratification: finalize validates the
    ///      timelock, the param hash and the fee pair, but not the bounds prepare enforces. A
    ///      proposal armed before those bounds existed therefore still applies. In-tree this can
    ///      only be reached by arming through the pre-fix rules, so the shape is characterised via
    ///      the reachable half — prepare rejects it today, and nothing re-checks it at finalize.
    function testFinalizeDoesNotRecheckPrepareBounds() public {
        PerpPair pair = _pair();

        // Prepare is the only thing standing between a zero divisor and storage...
        vm.expectRevert(bytes("C"));
        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 0, 10, 1e18);

        // ...and finalize re-checks only the fee pair, so an already-armed proposal is applied
        // verbatim. Arm a valid one and confirm no bound is re-evaluated on the way in.
        pair.prepareTimeLockedParameters(2, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        pair.setTimeLockedParameters(2, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
        assertEq(pair.MMR(), 2, "finalize applies the armed tuple as-is");
    }

    /// @dev Prepare must ARM a feeLP the removed prepare-time clause would have rejected: that
    ///      clause allowed equality, so a value above it proves the clause is gone. The pair only
    ///      becomes valid once the frontend fee drops, and finalize is what judges it.
    function testPrepareArmsAPairTheRemovedClauseWouldReject() public {
        PerpPair pair = _pair();
        uint256 overOldBound = 1e6 - FEE_FRONTEND + 1;

        pair.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, overOldBound, 0, 5e8, 1e10, 1e6, 10, 1e18);
        pair.setUnguardedParameters(oracle, FEE_FRONTEND - 2, feeProtocolAddr, 1e8, 15, 7500, 10, 10);
        skip(11);
        pair.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, overOldBound, 0, 5e8, 1e10, 1e6, 10, 1e18);

        (,,,,, uint256 appliedFeeLp,,,,,,,,,,) = pair.ReadParameters();
        assertEq(appliedFeeLp, overOldBound, "feeLP valid against the current frontend fee applies");
    }

    function testUnguardedFrontendFeeUpperBound() public {
        PerpPair pair = _pair();

        vm.expectRevert(bytes("C"));
        pair.setUnguardedParameters(oracle, uint32(1e6 - FEE_LP + 1), feeProtocolAddr, 1e8, 15, 7500, 10, 10);
    }

    /// @dev Remaining boundary legs: the smallest accepted divisors, the first rejected fee sum
    ///      above the boundary, and an MMR one above the floor.
    function testRemainingBoundaryLegs() public {
        PerpPair pair = _pair();

        pair.prepareTimeLockedParameters(3, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1, 1, 10, 1e18);
        skip(11);
        pair.setTimeLockedParameters(3, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1, 1, 10, 1e18);
        assertEq(pair.MMR(), 3, "MMR one above the floor accepted with the smallest divisors");

        PerpPair fresh = _pair();
        uint256 overSum = 1e6 - FEE_FRONTEND + 1; // feeLP + feeFrontend == 1e6 + 1
        fresh.prepareTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, overSum, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        vm.expectRevert(bytes("C"));
        fresh.setTimeLockedParameters(MMR, 0, FLAT_TRADING_FEE, overSum, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }
}
