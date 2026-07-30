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

    // --- liquidation-discount scale: what the MMR bounds are actually load-bearing for -------
    //
    // `liquidationDecimals` (1e6, `PerpStorage.Decimals`) is the scale the discount is expressed
    // in. The liquidation transfer computes `liquidationDecimals - discount`, so a discount above
    // that scale is an underflow — and `_computeLiquidationDiscount` returns up to TWICE the
    // stored `liquidationDiscount` (at margin ratio 0, the deepest bad-debt case). The two bounds
    // that keep the doubled value under the scale live in different functions, and only their
    // CONJUNCTION is sufficient: `setUnguardedParameters` requires `discount < MMR / 2`, and the
    // timelocked path requires `MMR < 1e6`.
    uint256 internal constant LIQUIDATION_DECIMALS = 1e6;

    /// @dev The timelock bound is exactly sufficient — and only just. At the largest MMR the
    ///      timelocked path accepts, the largest compliant discount still doubles to strictly
    ///      under the liquidation scale, with four units to spare. This is the property that
    ///      makes the live configuration safe (MMR 40_000 doubles to 39_998, ~25x of headroom).
    function testTimelockMmrCeilingKeepsTheDoubledDiscountUnderTheLiquidationScale() public {
        uint256 maxTimelockedMmr = 1e6 - 1; // prepare requires _MMR < 1e6
        PerpPair pair = _deploy(maxTimelockedMmr, ORACLE_DECIMALS * 9 / 10);

        uint32 maxCompliantDiscount = uint32(maxTimelockedMmr / 2 - 1); // strict `< MMR / 2`
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, maxCompliantDiscount, 10, 10);

        (,,,,,, uint256 discount,,,,) = pair.ReadFees();
        assertEq(discount, maxCompliantDiscount, "discount stored");
        assertLt(2 * discount, LIQUIDATION_DECIMALS, "doubled discount must stay under the liquidation scale");
    }

    /// @dev The gap: the `MMR < 1e6` ceiling exists ONLY on the timelocked path. The constructor
    ///      bounds MMR from below (SET4) and not from above, so a deployment can start beyond the
    ///      ceiling the same contract later enforces on itself.
    function testConstructorAcceptsAnMmrTheTimelockedPathRejects() public {
        PerpPair beyondCeiling = _deploy(1e6, ORACLE_DECIMALS * 9 / 10);
        assertEq(beyondCeiling.MMR(), 1e6, "constructor accepts an MMR at the timelocked ceiling");

        vm.expectRevert(bytes("C"));
        beyondCeiling.prepareTimeLockedParameters(1e6, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
    }

    /// @dev Consequence of that gap, characterised at its exact threshold: past a constructor MMR
    ///      of 1_000_004 the largest compliant discount doubles PAST the liquidation scale, so
    ///      `liquidationDecimals - discount` in `_liquidatePosition` underflows on a deep bad-debt
    ///      liquidation. The two implementations then disagree: this one reverts on checked
    ///      arithmetic, while the engine's U256 subtraction wraps and sizes the transfer from a
    ///      value just under 2^256. Documented, not fixed: reaching it needs a maintenance margin
    ///      above 100%, which only governance can set and which makes every position instantly
    ///      liquidatable. See the engine-side twin,
    ///      `liquidation_discount_can_exceed_the_liquidation_scale`.
    function testConstructorMmrAboveTheCeilingAdmitsAnUnderflowingDiscount() public {
        uint256 mmrPastTheThreshold = 1_000_004;
        PerpPair pair = _deploy(mmrPastTheThreshold, ORACLE_DECIMALS * 9 / 10);

        uint32 compliantDiscount = uint32(mmrPastTheThreshold / 2 - 1); // 500_001, accepted by the setter
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, compliantDiscount, 10, 10);

        (,,,,,, uint256 discount,,,,) = pair.ReadFees();
        assertGt(2 * discount, LIQUIDATION_DECIMALS, "the accepted discount doubles past the liquidation scale");

        // One notch lower is still safe, which pins the threshold rather than merely bracketing it.
        PerpPair belowThreshold = _deploy(mmrPastTheThreshold - 2, ORACLE_DECIMALS * 9 / 10);
        belowThreshold.setUnguardedParameters(
            oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(mmrPastTheThreshold / 2 - 2), 10, 10
        );
        (,,,,,, uint256 safeDiscount,,,,) = belowThreshold.ReadFees();
        assertEq(2 * safeDiscount, LIQUIDATION_DECIMALS, "one notch lower lands exactly on the scale, not past it");
    }

    /// @dev The residual documented above as the MMR-decrease stranding, stated as the invariant it
    ///      breaks rather than as the bound it violates: `discount < MMR / 2` exists so that the
    ///      largest liquidation bonus (twice the stored discount) cannot exceed the maintenance
    ///      margin that is supposed to cover it. After an MMR decrease the stored discount is
    ///      unchanged, so that relation inverts — a liquidation near the new threshold hands the
    ///      liquidator more than the whole margin buffer, and the excess is bad debt.
    function testMmrDecreaseInvertsTheBonusVersusMarginBufferRelation() public {
        PerpPair pair = _pair();
        pair.setUnguardedParameters(oracle, FEE_FRONTEND, feeProtocolAddr, 1e8, 15, uint32(MMR / 2 - 1), 10, 10);

        (,,,,,, uint256 discount,,,,) = pair.ReadFees();
        assertLt(2 * discount, pair.MMR(), "bonus ceiling sits under the margin buffer while the bound holds");

        uint256 lowerMmr = 100;
        pair.prepareTimeLockedParameters(lowerMmr, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);
        skip(11);
        pair.setTimeLockedParameters(lowerMmr, 0, FLAT_TRADING_FEE, FEE_LP, 0, 5e8, 1e10, 1e6, 10, 1e18);

        (,,,,,, uint256 strandedDiscount,,,,) = pair.ReadFees();
        assertEq(strandedDiscount, discount, "the decrease leaves the discount untouched");
        assertGt(2 * strandedDiscount, pair.MMR(), "bonus ceiling now exceeds the entire margin buffer");
    }
}
