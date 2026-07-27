// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MatrixMath } from "../src/util/MatrixMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Library-level regression tests for bounded matrix recovery and conservative rounding.
contract MatrixMathRoundingTest is Test {
    int256 internal constant Q80 = int256(1) << 80;
    uint256 internal constant G_SCALE = 1e24;
    // At the 1e-12 determinant rollover floor, one Q80 matrix-unit error can
    // amplify to at most 1e12 internal stable units (0.000001 at 18 decimals).
    uint256 internal constant APPROVED_FEE_ROUNDING_DUST = 1e12;

    /// @dev Sign-agnostic bound to [lo, hi]; uint256(x) wraps negatives, mod keeps it in range.
    function _boundInt(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        uint256 range = uint256(hi - lo) + 1;
        return lo + int256(uint256(x) % range);
    }

    function testFuzz_recoverLpBalanceRoundsAgainstLp(
        int256 a,
        int256 b,
        int256 c,
        int256 d,
        int256 m00,
        int256 m01,
        int256 m10,
        int256 m11,
        uint256 p,
        uint256 q
    )
        public
        pure
    {
        // Keep snapshots inside the production rollover domain and balances large enough to cover
        // billion-token LPs while leaving the exact reference numerators representable in int256.
        a = _boundInt(a, -Q80, Q80);
        b = _boundInt(b, -Q80, Q80);
        c = _boundInt(c, -Q80, Q80);
        d = _boundInt(d, -Q80, Q80);
        m00 = _boundInt(m00, -Q80, Q80);
        m01 = _boundInt(m01, -Q80, Q80);
        m10 = _boundInt(m10, -Q80, Q80);
        m11 = _boundInt(m11, -Q80, Q80);
        p = bound(p, 0, uint256(1) << 91);
        q = bound(q, 0, uint256(1) << 91);

        int256 det = a * d - c * b; // snapshot determinant; library requires it > 0
        vm.assume(det > Q80 * Q80 / int256(1e12));

        // Re-form the exact integer numerators the library builds before its single division by det.
        int256 ip = int256(p);
        int256 iq = int256(q);
        int256 u0 = d * ip - b * iq;
        int256 u1 = -c * ip + a * iq;
        int256 z0 = m00 * u0 + m01 * u1; // exact stable numerator
        int256 z1 = m10 * u0 + m11 * u1; // exact asset numerator

        int256[2][2] memory snapshotM = [[a, b], [c, d]];
        int256[2][2] memory currentM = [[m00, m01], [m10, m11]];

        (int256 stableBalance, int256 assetBalance) =
            MatrixMath.recoverLpBalanceFromSnapshot(currentM, snapshotM, p, q, Q80);

        _assertRoundsAgainstLp(stableBalance, z0, det, p, q, "stable");
        _assertRoundsAgainstLp(assetBalance, z1, det, p, q, "asset");
    }

    function testQ80MatrixGrowthCannotOverflowLpRecovery() public pure {
        uint256 p = uint256(1) << 200;
        int256[2][2] memory snapshotM = [[Q80, int256(0)], [int256(0), Q80]];
        int256[2][2] memory currentM = [[Q80 * 2, int256(0)], [int256(0), Q80]];

        (int256 stableBalance, int256 assetBalance) =
            MatrixMath.recoverLpBalanceFromSnapshot(currentM, snapshotM, p, 0, Q80);

        assertEq(stableBalance, int256(p * 2));
        assertEq(assetBalance, 0);
    }

    function testQ80FundingRecoveryCannotOverflow() public pure {
        uint256 k = uint256(1) << 100;
        uint256 p = uint256(Q80) * k * 2;
        int256[2][2] memory snapshotM = [[Q80 * 2, int256(0)], [int256(0), Q80]];

        int256 star = MatrixMath.recoverFundingStarFromSnapshot(int256(G_SCALE), 0, snapshotM, p, 0, Q80, G_SCALE);

        assertEq(star, int256(p / 2));
    }

    function testQ88FinalDotProductCannotOverflow() public pure {
        int256 q88 = int256(1) << 88;
        uint256 k = uint256(1) << 90;
        uint256 p = uint256(q88) * k * 2;
        int256[2][2] memory snapshotM = [[q88 * 2, int256(0)], [int256(0), q88]];

        int256 star = MatrixMath.recoverFundingStarFromSnapshot(int256(G_SCALE), 0, snapshotM, p, 0, q88, G_SCALE);

        assertEq(star, int256(p / 2));
    }

    function testFuzz_AssetOnlyFeeStaysWithinApprovedDust(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 dSeed,
        uint256 aXSeed,
        uint256 aYSeed,
        uint256 qSeed
    )
        public
        pure
    {
        uint256 scale = uint256(Q80);
        int256 a = int256(bound(aSeed, scale / 2, scale * 2));
        int256 b = int256(bound(bSeed, 0, scale));
        int256 c = int256(bound(cSeed, 0, scale));
        int256 d = int256(bound(dSeed, scale / 2, scale * 2));
        int256 det = a * d - c * b;
        vm.assume(det > Q80 * Q80 / int256(1e12));

        int256 aX = int256(bound(aXSeed, 0, scale / 100));
        int256 aY = int256(bound(aYSeed, 0, scale / 100));
        uint256 q = bound(qSeed, 0, uint256(1) << 80);
        int256 increment0 = (aY * c + aX * a) / Q80;
        int256 increment1 = (aY * d + aX * b) / Q80;

        int256[2][2] memory snapshotM = [[a, b], [c, d]];
        int256[2][2] memory currentM = [[a + increment0, b + increment1], [c, d]];
        (int256 stableBalance, int256 assetBalance) =
            MatrixMath.recoverLpBalanceFromSnapshot(currentM, snapshotM, 0, q, Q80);

        uint256 exactFeeShare = Math.mulDiv(uint256(aY), q, scale);
        assertLe(stableBalance > 0 ? uint256(stableBalance) : 0, exactFeeShare + APPROVED_FEE_ROUNDING_DUST);
        assertLe(assetBalance > 0 ? uint256(assetBalance) : 0, q);
    }

    function testNearRolloverLargeLpRecoveryStaysWithinDynamicDust() public pure {
        int256 k = Q80 / int256(1e12);
        int256 a = Q80;
        int256 b = Q80 - k;
        int256 c = b;
        int256 d = Q80;
        int256 aX = Q80 / 15_000;
        int256 aY = Q80 * 7 / 1000;
        uint256 q = 2_000_000_000 * 1e18;

        int256 increment0 = (aY * c + aX * a) / Q80;
        int256 increment1 = (aY * d + aX * b) / Q80;
        int256[2][2] memory snapshotM = [[a, b], [c, d]];
        int256[2][2] memory currentM = [[a + increment0, b + increment1], [c, d]];

        (int256 stableBalance, int256 assetBalance) =
            MatrixMath.recoverLpBalanceFromSnapshot(currentM, snapshotM, 0, q, Q80);
        int256 det = a * d - c * b;
        int256 u0 = -b * int256(q);
        int256 u1 = a * int256(q);
        int256 z0 = currentM[0][0] * u0 + currentM[0][1] * u1;
        int256 z1 = currentM[1][0] * u0 + currentM[1][1] * u1;

        _assertRoundsAgainstLp(stableBalance, z0, det, 0, q, "near-rollover stable");
        _assertRoundsAgainstLp(assetBalance, z1, det, 0, q, "near-rollover asset");

        uint256 exactStable = uint256(z0 / det);
        assertGt(
            _recoveryDynamicDust(q, exactStable, uint256(det)),
            APPROVED_FEE_ROUNDING_DUST,
            "large LP did not exceed the fixed-dust domain"
        );
    }

    function _recoveryDynamicDust(
        uint256 totalInitialBalance,
        uint256 exactFloor,
        uint256 detRaw
    )
        internal
        pure
        returns (uint256)
    {
        // Each normalized coefficient floor loses less than its associated LP balance.
        // The determinant ceil adds less than one normalized determinant unit, and the
        // final floor loses less than one unit. This expression bounds all three stages.
        return Math.mulDiv(totalInitialBalance + exactFloor + 1, uint256(Q80), detRaw, Math.Rounding.Ceil) + 1;
    }

    function _assertRoundsAgainstLp(
        int256 recovered,
        int256 z,
        int256 det,
        uint256 p,
        uint256 q,
        string memory side
    )
        internal
        pure
    {
        if (z >= 0) {
            uint256 exactFloor = uint256(z / det);
            uint256 recoveredClamped = recovered > 0 ? uint256(recovered) : 0;
            uint256 dynamicDust = _recoveryDynamicDust(p + q, exactFloor, uint256(det));
            uint256 lowerBound = exactFloor > dynamicDust ? exactFloor - dynamicDust : 0;

            assertLe(recoveredClamped, exactFloor, string.concat(side, ": recovered exceeds exact stored-matrix value"));
            assertGe(recoveredClamped, lowerBound, string.concat(side, ": recovery under-credit exceeds dynamic dust"));
        } else {
            // Negative recovered is clamped to 0 by getLpLiquidityBalance; truncation toward zero
            // and floor toward negative infinity are both system-favorable once clamped.
            assertLe(recovered, 0, string.concat(side, ": negative branch returned positive"));
        }
    }
}
