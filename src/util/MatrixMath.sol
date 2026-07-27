// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

library MatrixMath {
    function _absInt(int256 value) private pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    function mulDivSigned(int256 value, int256 multiplier, int256 denominator) internal pure returns (int256) {
        require(denominator != 0, "M0");

        uint256 absResult = Math.mulDiv(_absInt(value), _absInt(multiplier), _absInt(denominator));
        bool positive = (value >= 0) == (multiplier >= 0);
        positive = positive == (denominator >= 0);
        return positive ? SafeCast.toInt256(absResult) : -SafeCast.toInt256(absResult);
    }

    function sumMulDivSigned(
        int256 firstValue,
        int256 firstMultiplier,
        int256 secondValue,
        int256 secondMultiplier,
        int256 denominator
    )
        internal
        pure
        returns (int256)
    {
        require(denominator != 0, "M0");

        uint256 absDenominator = _absInt(denominator);
        (bool firstPositive, uint256 firstQuotient, uint256 firstRemainder) =
            _mulDivParts(firstValue, firstMultiplier, absDenominator);
        (bool secondPositive, uint256 secondQuotient, uint256 secondRemainder) =
            _mulDivParts(secondValue, secondMultiplier, absDenominator);

        if (denominator < 0) {
            firstPositive = !firstPositive;
            secondPositive = !secondPositive;
        }

        if (firstPositive == secondPositive) {
            uint256 quotient = firstQuotient + secondQuotient;
            uint256 remainder = firstRemainder + secondRemainder;
            if (remainder >= absDenominator) quotient += 1;
            return firstPositive ? SafeCast.toInt256(quotient) : -SafeCast.toInt256(quotient);
        }

        if (firstQuotient == secondQuotient && firstRemainder == secondRemainder) return 0;

        bool firstAbsGreater =
            firstQuotient > secondQuotient || (firstQuotient == secondQuotient && firstRemainder > secondRemainder);

        uint256 absDifference;
        bool positive;
        if (firstAbsGreater) {
            absDifference = _subQuotientRemainder(firstQuotient, firstRemainder, secondQuotient, secondRemainder);
            positive = firstPositive;
        } else {
            absDifference = _subQuotientRemainder(secondQuotient, secondRemainder, firstQuotient, firstRemainder);
            positive = secondPositive;
        }

        return positive ? SafeCast.toInt256(absDifference) : -SafeCast.toInt256(absDifference);
    }

    function _mulDivParts(
        int256 value,
        int256 multiplier,
        uint256 absDenominator
    )
        private
        pure
        returns (bool positive, uint256 quotient, uint256 remainder)
    {
        uint256 absValue = _absInt(value);
        uint256 absMultiplier = _absInt(multiplier);
        quotient = Math.mulDiv(absValue, absMultiplier, absDenominator);
        remainder = mulmod(absValue, absMultiplier, absDenominator);
        positive = (value >= 0) == (multiplier >= 0);
    }

    function _subQuotientRemainder(
        uint256 largerQuotient,
        uint256 largerRemainder,
        uint256 smallerQuotient,
        uint256 smallerRemainder
    )
        private
        pure
        returns (uint256)
    {
        if (largerRemainder >= smallerRemainder) {
            return largerQuotient - smallerQuotient;
        }

        if (largerQuotient == smallerQuotient) return 0;

        return largerQuotient - smallerQuotient - 1;
    }

    /// @notice Computes floor((firstValue * firstMultiplier + secondValue * secondMultiplier) / denominator).
    /// @dev Uses full-precision quotient/remainder parts so neither product is materialized in int256.
    ///      The denominator must be positive and negative non-integral results round toward negative infinity.
    /// @param firstValue Signed value of the first product.
    /// @param firstMultiplier Signed multiplier of the first product.
    /// @param secondValue Signed value of the second product.
    /// @param secondMultiplier Signed multiplier of the second product.
    /// @param denominator Positive divisor shared by both products.
    /// @return The mathematical floor of the signed two-product quotient.
    function _sumMulDivSignedFloor(
        int256 firstValue,
        int256 firstMultiplier,
        int256 secondValue,
        int256 secondMultiplier,
        int256 denominator
    )
        private
        pure
        returns (int256)
    {
        require(denominator > 0, "M0");

        uint256 absDenominator = uint256(denominator);
        (bool firstPositive, uint256 firstQuotient, uint256 firstRemainder) =
            _mulDivParts(firstValue, firstMultiplier, absDenominator);
        (bool secondPositive, uint256 secondQuotient, uint256 secondRemainder) =
            _mulDivParts(secondValue, secondMultiplier, absDenominator);

        bool positive;
        uint256 quotient;
        uint256 remainder;

        if (firstPositive == secondPositive) {
            positive = firstPositive;
            quotient = firstQuotient + secondQuotient;
            uint256 combinedRemainder = firstRemainder + secondRemainder;
            if (combinedRemainder >= absDenominator) {
                quotient += 1;
                combinedRemainder -= absDenominator;
            }
            remainder = combinedRemainder;
        } else {
            if (firstQuotient == secondQuotient && firstRemainder == secondRemainder) return 0;

            bool firstAbsGreater =
                firstQuotient > secondQuotient || (firstQuotient == secondQuotient && firstRemainder > secondRemainder);
            uint256 largerQuotient = firstAbsGreater ? firstQuotient : secondQuotient;
            uint256 largerRemainder = firstAbsGreater ? firstRemainder : secondRemainder;
            uint256 smallerQuotient = firstAbsGreater ? secondQuotient : firstQuotient;
            uint256 smallerRemainder = firstAbsGreater ? secondRemainder : firstRemainder;

            positive = firstAbsGreater ? firstPositive : secondPositive;
            if (largerRemainder >= smallerRemainder) {
                quotient = largerQuotient - smallerQuotient;
                remainder = largerRemainder - smallerRemainder;
            } else {
                quotient = largerQuotient - smallerQuotient - 1;
                remainder = absDenominator + largerRemainder - smallerRemainder;
            }
        }

        if (positive) return SafeCast.toInt256(quotient);
        if (remainder != 0) quotient += 1;
        return -SafeCast.toInt256(quotient);
    }

    function _positiveDeterminantFixed(
        int256[2][2] memory matrix,
        int256 liquidityMDecimals
    )
        internal
        pure
        returns (int256 det)
    {
        det = sumMulDivSigned(matrix[0][0], matrix[1][1], -matrix[1][0], matrix[0][1], liquidityMDecimals);
        require(det > 0, "MDET");
    }

    /// @notice Returns ceil(det(matrix) / liquidityMDecimals) and requires it to be positive.
    /// @dev Computes the ceiling as -floor(-det / scale), preserving the conservative LP-recovery bound.
    /// @param matrix Fixed-point 2x2 liquidity matrix whose determinant is normalized.
    /// @param liquidityMDecimals Positive fixed-point scale of the matrix entries.
    /// @return det The normalized determinant rounded toward positive infinity.
    function _positiveDeterminantCeil(
        int256[2][2] memory matrix,
        int256 liquidityMDecimals
    )
        private
        pure
        returns (int256 det)
    {
        det = -_sumMulDivSignedFloor(-matrix[0][0], matrix[1][1], matrix[1][0], matrix[0][1], liquidityMDecimals);
        require(det > 0, "MDET");
    }

    /// @notice Checks whether a fixed-point matrix is exactly the identity multiplied by its scale.
    /// @param matrix Fixed-point 2x2 matrix to inspect.
    /// @param scale Expected value of both diagonal entries.
    /// @return True when both diagonal entries equal scale and both off-diagonal entries are zero.
    function _isScaledIdentity(int256[2][2] memory matrix, int256 scale) private pure returns (bool) {
        return matrix[0][0] == scale && matrix[0][1] == 0 && matrix[1][0] == 0 && matrix[1][1] == scale;
    }

    /// @notice Recover an LP balance as M(t) * M^-1(t0) * v(t0) via adj(M(t0)) / det(M(t0)).
    /// @dev Implements the Section 4 balance-tracking matrix recovery without materializing M^-1(t0).
    function recoverLpBalanceFromSnapshot(
        int256[2][2] memory currentM,
        int256[2][2] memory snapshotM,
        uint256 initialStableBalance,
        uint256 initialAssetBalance,
        int256 liquidityMDecimals
    )
        public
        pure
        returns (int256 stableBalance, int256 assetBalance)
    {
        require(liquidityMDecimals > 0, "M0");
        int256 p = SafeCast.toInt256(initialStableBalance);
        int256 q = SafeCast.toInt256(initialAssetBalance);
        int256 a = snapshotM[0][0];
        int256 b = snapshotM[0][1];
        int256 c = snapshotM[1][0];
        int256 d = snapshotM[1][1];
        int256 detCeil = _positiveDeterminantCeil(snapshotM, liquidityMDecimals);

        if (equalTwoByTwoMatrix(currentM, snapshotM)) return (p, q);

        // Reduce the matrix product before applying the LP vector. Keeping the
        // Q80 production path here as well avoids materializing M * adj(M0) * v.
        // Numerator coefficients round down and the positive determinant rounds
        // up, so a positive recovered LP balance cannot exceed the exact value.
        int256 n00 = _sumMulDivSignedFloor(currentM[0][0], d, -currentM[0][1], c, liquidityMDecimals);
        int256 n01 = _sumMulDivSignedFloor(-currentM[0][0], b, currentM[0][1], a, liquidityMDecimals);
        int256 n10 = _sumMulDivSignedFloor(currentM[1][0], d, -currentM[1][1], c, liquidityMDecimals);
        int256 n11 = _sumMulDivSignedFloor(-currentM[1][0], b, currentM[1][1], a, liquidityMDecimals);
        stableBalance = _sumMulDivSignedFloor(n00, p, n01, q, detCeil);
        assetBalance = _sumMulDivSignedFloor(n10, p, n11, q, detCeil);
    }

    /// @notice Compute DeltaG * M^-1(t0) * v(t0) through adj(M(t0)) without storing M^-1(t0).
    function recoverFundingStarFromSnapshot(
        int256 deltaG0,
        int256 deltaG1,
        int256[2][2] memory snapshotM,
        uint256 initialStableBalance,
        uint256 initialAssetBalance,
        int256 liquidityMDecimals,
        uint256 liquidityGDecimals
    )
        public
        pure
        returns (int256 star)
    {
        require(liquidityMDecimals > 0, "M0");
        int256 p = SafeCast.toInt256(initialStableBalance);
        int256 q = SafeCast.toInt256(initialAssetBalance);
        int256 a = snapshotM[0][0];
        int256 b = snapshotM[0][1];
        int256 c = snapshotM[1][0];
        int256 d = snapshotM[1][1];

        if (_isScaledIdentity(snapshotM, liquidityMDecimals)) {
            return sumMulDivSigned(deltaG0, p, deltaG1, q, SafeCast.toInt256(liquidityGDecimals));
        }

        // Reduce before both the LP-vector dot product and the funding-scale
        // conversion so no Q80/Q88/Q96 intermediate product is materialized.
        int256 w0 = sumMulDivSigned(deltaG0, d, -deltaG1, c, liquidityMDecimals);
        int256 w1 = sumMulDivSigned(-deltaG0, b, deltaG1, a, liquidityMDecimals);
        int256 detFixed = _positiveDeterminantFixed(snapshotM, liquidityMDecimals);
        int256 normalizedStar = sumMulDivSigned(w0, p, w1, q, detFixed);
        star = mulDivSigned(normalizedStar, liquidityMDecimals, SafeCast.toInt256(liquidityGDecimals));
    }

    //Matrix multiplication for 2x2 matrices
    ///@notice This function implements matrix multiplication for 2x2 matrices
    ///@param a first matrix A
    ///@param b second matrix B
    ///@param normalizationDecimals decimal normalization.
    ///@return result $\frac{A\times B}{normalizationDecimals}$
    function matMulTwoByTwo(
        int256[2][2] memory a,
        int256[2][2] memory b,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2][2] memory result)
    {
        result[0][0] = sumMulDivSigned(a[0][0], b[0][0], a[0][1], b[1][0], normalizationDecimals);
        result[0][1] = sumMulDivSigned(a[0][0], b[0][1], a[0][1], b[1][1], normalizationDecimals);
        result[1][0] = sumMulDivSigned(a[1][0], b[0][0], a[1][1], b[1][0], normalizationDecimals);
        result[1][1] = sumMulDivSigned(a[1][0], b[0][1], a[1][1], b[1][1], normalizationDecimals);
    }

    //Inverse of a 2x2 matrix
    ///@notice This function computes the inverse of a 2x2 matrix with determinant 1
    ///@param a input matrix
    ///@return inv inverse of a
    function inverseTwoByTwo(
        int256[2][2] memory a,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2][2] memory inv)
    {
        int256 det = (a[0][0] * a[1][1] - a[1][0] * a[0][1]) / normalizationDecimals;
        require(det != 0, "Error on inverseTwoByTwo: determinant is 0");

        inv[0][0] = a[1][1] * normalizationDecimals / det;
        inv[0][1] = -a[0][1] * normalizationDecimals / det;
        inv[1][0] = -a[1][0] * normalizationDecimals / det;
        inv[1][1] = a[0][0] * normalizationDecimals / det;
    }

    //"Overload" == operator for 2x2 matrices
    ///@notice Check whether two matrices are equal.
    ///@param a matrix A
    ///@param b matrix B
    ///@return result A == B
    function equalTwoByTwoMatrix(int256[2][2] memory a, int256[2][2] memory b) public pure returns (bool result) {
        result = (a[0][0] == b[0][0] && a[0][1] == b[0][1] && a[1][0] == b[1][0] && a[1][1] == b[1][1]);
    }

    //Vector*Matrix 2x2 operation.
    ///@notice Multiply a 2 component vector and a 2x2 matrix.
    ///@param vec vector v
    ///@param mat matrix A
    ///@param normalizationDecimals decimal normalization.
    ///@return result $vA$
    function mulVecMatTwoByTwo(
        int256[2] memory vec,
        int256[2][2] memory mat,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2] memory result)
    {
        result[0] = sumMulDivSigned(vec[0], mat[0][0], vec[1], mat[1][0], normalizationDecimals);
        result[1] = sumMulDivSigned(vec[0], mat[0][1], vec[1], mat[1][1], normalizationDecimals);
    }

    //Matrix*Vector 2x2 operation.
    ///@notice Multiply a 2x2 matrix and a 2 component vector.
    ///@param mat matrix A
    ///@param vec vector v
    ///@param normalizationDecimals decimal normalization.
    ///@return result $Av$
    function mulMatVecTwoByTwo(
        int256[2][2] memory mat,
        int256[2] memory vec,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2] memory result)
    {
        result[0] = sumMulDivSigned(vec[0], mat[0][0], vec[1], mat[0][1], normalizationDecimals);
        result[1] = sumMulDivSigned(vec[0], mat[1][0], vec[1], mat[1][1], normalizationDecimals);
    }

    //Scalar product of 2x2 vectors v1*v2.
    ///@notice Multiply two 2 component vectors.
    ///@param v1 vector v1
    ///@param v2 vector v2
    ///@param normalizationDecimals decimal normalization.
    ///@return result $v1 \cdot v2$
    function scalarTwoByTwo(
        int256[2] memory v1,
        int256[2] memory v2,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256 result)
    {
        result = sumMulDivSigned(v1[0], v2[0], v1[1], v2[1], normalizationDecimals);
    }
}
