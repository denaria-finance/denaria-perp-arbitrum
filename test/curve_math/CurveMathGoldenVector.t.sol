// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import "../../src/util/CurveMath.sol";
import "../../src/util/MatrixMath.sol";
import "../../src/util/UtilMath.sol";
import "../../src/manager/FeeManager.sol";

contract CurveMathGoldenVectorTest is Test {
    using Strings for uint256;

    string internal constant FIXTURE_PATH = "/test/fixtures/curve_math_solidity_vectors.json";
    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 internal constant CURVE_DECIMALS = 1e8;
    uint256 internal constant CURRENCY_DECIMALS = 1e18;

    enum PublicFunction {
        LongReturn,
        ShortReturn,
        ExactAmountInLong,
        ExactAmountInShort
    }

    struct PublicVectorInput {
        string label;
        PublicFunction fnType;
        uint256 amount;
        uint256 spotPrice;
        uint256 initialGuess;
        uint256 stable;
        uint256 asset;
        uint256 parameterA;
        uint256 parameterB;
    }

    struct CoefficientVectorInput {
        string label;
        bool inverseLong;
        uint256 amount;
        uint256 spotPrice;
        uint256 stable;
        uint256 asset;
        uint256 parameterA;
        uint256 parameterB;
    }

    struct NewtonVectorInput {
        string label;
        uint256 initialGuess;
        uint256 a;
        uint256 b;
        bool bSign;
        uint256 c;
        bool cSign;
        uint256 d;
        bool dSign;
    }

    struct InverseCoefficients {
        uint256 aPrime;
        uint256 lambda;
        bool lambdaSign;
        uint256 k;
        bool kSign;
        uint256 a;
        uint256 b;
        bool bSign;
        uint256 c;
        bool cSign;
        uint256 d;
        bool dSign;
    }

    struct LiqFeeInput {
        uint256 stable;
        uint256 asset;
        uint256 iStable;
        uint256 iAsset;
        uint256 price;
        uint256 oracleDecimals;
        uint256 maxFee;
        uint256 minFee;
        uint256 feeK;
        uint256 feeDecimals;
    }

    function testWriteGoldenVectorFixture() public {
        string memory fixture = buildFixture();
        string memory fixtureDir = string.concat(vm.projectRoot(), "/test/fixtures");
        string memory fixturePath = string.concat(vm.projectRoot(), FIXTURE_PATH);

        vm.createDir(fixtureDir, true);
        vm.writeFile(fixturePath, fixture);
        assertEq(vm.readFile(fixturePath), fixture, "fixture write mismatch");
    }

    function testPositivePositivePositiveNewtonVectorReverts() public {
        vm.expectRevert(bytes("NM1"));
        this.callPositivePositivePositiveNewtonVector();
    }

    function callPositivePositivePositiveNewtonVector() external pure returns (uint256) {
        return CurveMath.newtonMethodCubic(1e18, 1e18, 1e18, 1e18, 1e18, true, true, true);
    }

    function buildFixture() internal pure returns (string memory) {
        string memory vectors = "";
        uint256 count = 0;

        (vectors, count) = appendPublicVectors(vectors, count);
        (vectors, count) = appendMatrixVectors(vectors, count);
        (vectors, count) = appendOracleDecimalsVectors(vectors, count);
        (vectors, count) = appendCoefficientVectors(vectors, count);
        (vectors, count) = appendNewtonVectors(vectors, count);
        (vectors, count) = appendMatrixUtilVectors(vectors, count);

        return string(
            abi.encodePacked(
                "{\n",
                '  "schema": "denaria.curve_math.parity.v1",\n',
                '  "generatedBy": "test/curve_math/CurveMathGoldenVector.t.sol",\n',
                '  "reference": "src/util/CurveMath.sol",\n',
                '  "target": "src/rust/CurveMath.rs",\n',
                '  "vectorCount": ',
                count.toString(),
                ",\n",
                '  "vectors": [\n',
                vectors,
                "\n",
                "  ]\n",
                "}\n"
            )
        );
    }

    function appendPublicVectors(string memory vectors, uint256 count) internal pure returns (string memory, uint256) {
        uint256 stable = 10_000_000 * CURRENCY_DECIMALS;
        uint256 asset = 6000 * CURRENCY_DECIMALS;

        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "direct-long-default-b-0p1",
                    PublicFunction.LongReturn,
                    1000 * CURRENCY_DECIMALS,
                    3000 * ORACLE_DECIMALS,
                    5_999_700 * 1e15,
                    stable,
                    asset,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "direct-short-default-b-0p1",
                    PublicFunction.ShortReturn,
                    33 * 1e16,
                    3000 * ORACLE_DECIMALS,
                    9_998_500 * CURRENCY_DECIMALS,
                    stable,
                    asset,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "exact-long-default-b-0p1",
                    PublicFunction.ExactAmountInLong,
                    10 * CURRENCY_DECIMALS,
                    3000 * ORACLE_DECIMALS,
                    10_030_000 * CURRENCY_DECIMALS,
                    stable,
                    asset,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "exact-short-default-b-0p1",
                    PublicFunction.ExactAmountInShort,
                    1000 * CURRENCY_DECIMALS,
                    100 * ORACLE_DECIMALS,
                    6010 * CURRENCY_DECIMALS,
                    stable,
                    asset,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "exact-long-zero-b",
                    PublicFunction.ExactAmountInLong,
                    10 * CURRENCY_DECIMALS,
                    100 * ORACLE_DECIMALS,
                    10_001_000 * CURRENCY_DECIMALS,
                    stable,
                    100_000 * CURRENCY_DECIMALS,
                    100 * CURVE_DECIMALS,
                    0
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "exact-long-b-2p0",
                    PublicFunction.ExactAmountInLong,
                    10 * CURRENCY_DECIMALS,
                    100 * ORACLE_DECIMALS,
                    20_000_000 * CURRENCY_DECIMALS,
                    20_000_000 * CURRENCY_DECIMALS,
                    100_000 * CURRENCY_DECIMALS,
                    100 * CURVE_DECIMALS,
                    2 * CURVE_DECIMALS
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            publicVector(
                PublicVectorInput(
                    "live-incident-exact-long-short-pnl",
                    PublicFunction.ExactAmountInLong,
                    25_622_478_376_441_680,
                    7_802_151_532_000,
                    484_042_894_805_638_440_639_332,
                    484_042_894_805_638_440_639_332,
                    6_592_552_649_200_534_689,
                    1e8,
                    1e7
                )
            ),
            count
        );

        return (vectors, count);
    }

    // Broader deterministic parity matrix: same balanced pool, additional
    // parameter regimes (B = 0 / 1.0, A = 10), larger sizes, and both
    // directions. The Rust consumer dispatches by kind/function, so these are
    // covered with no extra Rust code. initialGuess is derived from the
    // zero-slippage estimate via autoGuess(), which reproduces the hand-picked
    // guesses used by the original public vectors and converges for these
    // regimes.
    function appendMatrixVectors(string memory vectors, uint256 count) internal pure returns (string memory, uint256) {
        uint256 stable = 10_000_000 * CURRENCY_DECIMALS;
        uint256 asset = 6000 * CURRENCY_DECIMALS;
        uint256 p = 3000 * ORACLE_DECIMALS;

        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-long-a10-b0p1",
                PublicFunction.LongReturn,
                2000 * CURRENCY_DECIMALS,
                p,
                stable,
                asset,
                10 * CURVE_DECIMALS,
                1e7
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-long-b1p0", PublicFunction.LongReturn, 1000 * CURRENCY_DECIMALS, p, stable, asset, 1e8, 1e8
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-long-b0", PublicFunction.LongReturn, 1000 * CURRENCY_DECIMALS, p, stable, asset, 1e8, 0
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-long-large", PublicFunction.LongReturn, 50_000 * CURRENCY_DECIMALS, p, stable, asset, 1e8, 1e7
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector("matrix-short-b1p0", PublicFunction.ShortReturn, 33 * 1e16, p, stable, asset, 1e8, 1e8),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector("matrix-short-b0", PublicFunction.ShortReturn, 5 * 1e17, p, stable, asset, 1e8, 0),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-exact-long-a10",
                PublicFunction.ExactAmountInLong,
                5 * CURRENCY_DECIMALS,
                p,
                stable,
                asset,
                10 * CURVE_DECIMALS,
                1e7
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            matrixVector(
                "matrix-exact-short-b1p0",
                PublicFunction.ExactAmountInShort,
                2000 * CURRENCY_DECIMALS,
                100 * ORACLE_DECIMALS,
                stable,
                asset,
                1e8,
                1e8
            ),
            count
        );

        return (vectors, count);
    }

    function matrixVector(
        string memory label,
        PublicFunction fnType,
        uint256 amount,
        uint256 spotPrice,
        uint256 stable,
        uint256 asset,
        uint256 parameterA,
        uint256 parameterB
    )
        internal
        pure
        returns (string memory)
    {
        uint256 guess = autoGuess(fnType, amount, spotPrice, stable, asset);
        return publicVector(
            PublicVectorInput(label, fnType, amount, spotPrice, guess, stable, asset, parameterA, parameterB)
        );
    }

    function autoGuess(
        PublicFunction fnType,
        uint256 amount,
        uint256 spotPrice,
        uint256 stable,
        uint256 asset
    )
        internal
        pure
        returns (uint256)
    {
        if (fnType == PublicFunction.LongReturn) {
            return asset - amount * ORACLE_DECIMALS / spotPrice;
        }
        if (fnType == PublicFunction.ShortReturn) {
            return stable - amount * spotPrice / ORACLE_DECIMALS;
        }
        if (fnType == PublicFunction.ExactAmountInLong) {
            return stable + amount * spotPrice / ORACLE_DECIMALS;
        }
        return asset + amount * ORACLE_DECIMALS / spotPrice;
    }

    // Oracle/curve-decimals coverage. The whole prior matrix uses
    // oracleDecimals=1e8 (a divisor of 1e18), which structurally cannot detect
    // the inverse-long k-formula divergence the parity audit (2026-06-03) found:
    // Rust computed k via the pre-scaled price sp=p*1e18/oracle, which only
    // equals Solidity's k=p*x0/oracle when oracle divides 1e18. These vectors
    // pin the fix with a non-divisor oracle (99999999), an 18-decimal divisor
    // control, an inverse-short guard (already bit-exact), and the direct-short
    // stableGT branch (the audit's false-positive, locked as bit-exact).
    function appendOracleDecimalsVectors(
        string memory vectors,
        uint256 count
    )
        internal
        pure
        returns (string memory, uint256)
    {
        uint256 stable = 10_000_000 * CURRENCY_DECIMALS;
        uint256 asset = 6000 * CURRENCY_DECIMALS;

        // Primary witness: non-divisor oracle exercises the fixed k formula.
        (vectors, count) = append(
            vectors,
            oracleVector(
                "oracle-nondivisor-exact-long",
                PublicFunction.ExactAmountInLong,
                10 * CURRENCY_DECIMALS,
                3000 * 1e8,
                99_999_999,
                1e8,
                10_030_000 * CURRENCY_DECIMALS,
                stable,
                asset,
                1e8,
                1e7
            ),
            count
        );
        // (A dedicated 18-decimal divisor "control" was dropped: Solidity's
        // CurveMath itself overflows for an 18-decimal price on this pool, and
        // all 29 prior vectors already use oracleDecimals=1e8 — a divisor of
        // 1e18 — so they are the divisor control that confirms the fix is not
        // over-broad.)
        // Guard: inverse-short with non-divisor oracle stays bit-exact (Solidity
        // computes px0 once), so the long fix must not be mirrored into short.
        (vectors, count) = append(
            vectors,
            oracleVector(
                "oracle-nondivisor-exact-short",
                PublicFunction.ExactAmountInShort,
                1000 * CURRENCY_DECIMALS,
                100 * 1e8,
                99_999_999,
                1e8,
                6010 * CURRENCY_DECIMALS,
                stable,
                asset,
                1e8,
                1e7
            ),
            count
        );
        // Direct-short stableGT branch with a non-trivial remainder in
        // base*diff/denom: the audit (incorrectly) flagged this as divergent;
        // lock the verified equivalence -trunc(x)=trunc(-x) as an exact vector.
        (vectors, count) = append(
            vectors,
            oracleVector(
                "direct-short-stablegt-remainder",
                PublicFunction.ShortReturn,
                1 * CURRENCY_DECIMALS,
                1 * 1e8,
                1e8,
                1e17,
                45 * 1e17,
                5 * CURRENCY_DECIMALS,
                10 * CURRENCY_DECIMALS,
                1e18,
                1e17
            ),
            count
        );

        return (vectors, count);
    }

    // Builds a "public" vector with explicit oracleDecimals and curveDecimals
    // (the standard publicVector path hardcodes both to 1e8).
    function oracleVector(
        string memory label,
        PublicFunction fnType,
        uint256 amount,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 curveDecimals,
        uint256 initialGuess,
        uint256 stable,
        uint256 asset,
        uint256 parameterA,
        uint256 parameterB
    )
        internal
        pure
        returns (string memory)
    {
        uint256 expected = oracleExpected(
            fnType,
            amount,
            spotPrice,
            oracleDecimals,
            curveDecimals,
            initialGuess,
            stable,
            asset,
            parameterA,
            parameterB
        );
        string memory roundTrip = "";
        if (fnType == PublicFunction.ExactAmountInLong) {
            uint256 rt = CurveMath.computeLongReturn(
                expected,
                spotPrice,
                oracleDecimals,
                asset - amount,
                stable,
                asset,
                parameterA,
                parameterB,
                curveDecimals
            );
            roundTrip = roundTripJson("computeLongReturn", amount, rt);
        } else if (fnType == PublicFunction.ExactAmountInShort) {
            uint256 rt = CurveMath.computeShortReturn(
                expected,
                spotPrice,
                oracleDecimals,
                stable - amount,
                stable,
                asset,
                parameterA,
                parameterB,
                curveDecimals
            );
            roundTrip = roundTripJson("computeShortReturn", amount, rt);
        }

        return string(
            abi.encodePacked(
                "    {",
                '"kind":"public",',
                '"label":"',
                label,
                '",',
                '"function":"',
                publicFunctionName(fnType),
                '",',
                '"tolerance":"exact",',
                '"inputs":',
                oracleCurveInputsJson(
                    amount,
                    spotPrice,
                    oracleDecimals,
                    initialGuess,
                    stable,
                    asset,
                    parameterA,
                    parameterB,
                    curveDecimals
                ),
                ",",
                '"expected":"',
                expected.toString(),
                '"',
                roundTrip,
                "}"
            )
        );
    }

    function oracleExpected(
        PublicFunction fnType,
        uint256 amount,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 curveDecimals,
        uint256 initialGuess,
        uint256 stable,
        uint256 asset,
        uint256 parameterA,
        uint256 parameterB
    )
        internal
        pure
        returns (uint256)
    {
        if (fnType == PublicFunction.LongReturn) {
            return CurveMath.computeLongReturn(
                amount, spotPrice, oracleDecimals, initialGuess, stable, asset, parameterA, parameterB, curveDecimals
            );
        }
        if (fnType == PublicFunction.ShortReturn) {
            return CurveMath.computeShortReturn(
                amount, spotPrice, oracleDecimals, initialGuess, stable, asset, parameterA, parameterB, curveDecimals
            );
        }
        if (fnType == PublicFunction.ExactAmountInLong) {
            return CurveMath.computeExactAmountInLong(
                amount, spotPrice, oracleDecimals, initialGuess, stable, asset, parameterA, parameterB, curveDecimals
            );
        }
        return CurveMath.computeExactAmountInShort(
            amount, spotPrice, oracleDecimals, initialGuess, stable, asset, parameterA, parameterB, curveDecimals
        );
    }

    function oracleCurveInputsJson(
        uint256 amount,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 stable,
        uint256 asset,
        uint256 parameterA,
        uint256 parameterB,
        uint256 curveDecimals
    )
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "{",
                '"amount":"',
                amount.toString(),
                '",',
                '"spotPrice":"',
                spotPrice.toString(),
                '",',
                '"oracleDecimals":"',
                oracleDecimals.toString(),
                '",',
                '"initialGuess":"',
                initialGuess.toString(),
                '",',
                '"stable":"',
                stable.toString(),
                '",',
                '"asset":"',
                asset.toString(),
                '",',
                '"parameterA":"',
                parameterA.toString(),
                '",',
                '"parameterB":"',
                parameterB.toString(),
                '",',
                '"curveParameterDecimals":"',
                curveDecimals.toString(),
                '"',
                "}"
            )
        );
    }

    function appendCoefficientVectors(
        string memory vectors,
        uint256 count
    )
        internal
        pure
        returns (string memory, uint256)
    {
        (vectors, count) = append(
            vectors,
            coefficientVector(
                CoefficientVectorInput(
                    "inverse-long-default-b-0p1-coefficients",
                    true,
                    10 * CURRENCY_DECIMALS,
                    3000 * ORACLE_DECIMALS,
                    10_000_000 * CURRENCY_DECIMALS,
                    6000 * CURRENCY_DECIMALS,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            coefficientVector(
                CoefficientVectorInput(
                    "inverse-short-default-b-0p1-coefficients",
                    false,
                    1000 * CURRENCY_DECIMALS,
                    100 * ORACLE_DECIMALS,
                    10_000_000 * CURRENCY_DECIMALS,
                    6000 * CURRENCY_DECIMALS,
                    1e8,
                    1e7
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            coefficientVector(
                CoefficientVectorInput(
                    "inverse-long-b-2p0-coefficients",
                    true,
                    10 * CURRENCY_DECIMALS,
                    100 * ORACLE_DECIMALS,
                    20_000_000 * CURRENCY_DECIMALS,
                    100_000 * CURRENCY_DECIMALS,
                    100 * CURVE_DECIMALS,
                    2 * CURVE_DECIMALS
                )
            ),
            count
        );

        return (vectors, count);
    }

    function appendNewtonVectors(string memory vectors, uint256 count) internal pure returns (string memory, uint256) {
        (vectors, count) = append(
            vectors,
            newtonVector(
                NewtonVectorInput(
                    "newton-branch-positive-negative-negative-short-direct",
                    9_998_500 * CURRENCY_DECIMALS,
                    10_002_970_294_039_702_990_000_000,
                    3_071_683_137_956_642_857_142_857_142_857_142,
                    true,
                    27_713_493_364_250_000_000_000_000_000_000_000_000_000,
                    false,
                    40_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000,
                    false
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            newtonVector(
                NewtonVectorInput(
                    "newton-branch-positive-negative-positive-inverse-long",
                    20_000_000 * CURRENCY_DECIMALS,
                    9_997_000_299_990,
                    2_333_229_984_000_299_999_999,
                    true,
                    67_998_532_770_002_999_999_999_999_900,
                    false,
                    346_665_329_000_009_999_999_999_999_333_366_670,
                    true
                )
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            newtonVector(
                NewtonVectorInput(
                    "newton-branch-positive-positive-negative-inverse-short",
                    100_000 * CURRENCY_DECIMALS,
                    19_997_000_149_997_500_000_000_000,
                    244_655_233_308_332_583_333_333_333_333_331,
                    true,
                    6_997_203_457_166_591_666_666_666_666_666_666_684,
                    true,
                    3_166_834_987_216_669_166_666_666_666_666_649_999_166_750,
                    false
                )
            ),
            count
        );
        (vectors, count) = append(vectors, newtonRevertVector("newton-branch-positive-positive-positive-revert"), count);
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-positive-positive-negative-synthetic", true, true, false), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-positive-negative-negative-synthetic", true, false, false), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-positive-negative-positive-synthetic", true, false, true), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-negative-positive-positive-synthetic", false, true, true), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-negative-positive-negative-synthetic", false, true, false), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-negative-negative-positive-synthetic", false, false, true), count
        );
        (vectors, count) = append(
            vectors, newtonRootVector("newton-branch-negative-negative-negative-synthetic", false, false, false), count
        );

        return (vectors, count);
    }

    function publicVector(PublicVectorInput memory input) internal pure returns (string memory) {
        uint256 expected = publicOutput(input);
        string memory roundTrip = "";

        if (input.fnType == PublicFunction.ExactAmountInLong) {
            uint256 roundTripExpected = CurveMath.computeLongReturn(
                expected,
                input.spotPrice,
                ORACLE_DECIMALS,
                input.asset - input.amount,
                input.stable,
                input.asset,
                input.parameterA,
                input.parameterB,
                CURVE_DECIMALS
            );
            roundTrip = roundTripJson("computeLongReturn", input.amount, roundTripExpected);
        } else if (input.fnType == PublicFunction.ExactAmountInShort) {
            uint256 roundTripExpected = CurveMath.computeShortReturn(
                expected,
                input.spotPrice,
                ORACLE_DECIMALS,
                input.stable - input.amount,
                input.stable,
                input.asset,
                input.parameterA,
                input.parameterB,
                CURVE_DECIMALS
            );
            roundTrip = roundTripJson("computeShortReturn", input.amount, roundTripExpected);
        }

        return string(
            abi.encodePacked(
                "    {",
                '"kind":"public",',
                '"label":"',
                input.label,
                '",',
                '"function":"',
                publicFunctionName(input.fnType),
                '",',
                '"tolerance":"exact",',
                '"inputs":',
                publicInputsJson(input),
                ",",
                '"expected":"',
                expected.toString(),
                '"',
                roundTrip,
                "}"
            )
        );
    }

    function coefficientVector(CoefficientVectorInput memory input) internal pure returns (string memory) {
        InverseCoefficients memory coeffs =
            input.inverseLong ? inverseLongCoefficients(input) : inverseShortCoefficients(input);

        return string(
            abi.encodePacked(
                "    {",
                '"kind":"coefficients",',
                '"label":"',
                input.label,
                '",',
                '"function":"',
                input.inverseLong ? "computeExactAmountInLong" : "computeExactAmountInShort",
                '",',
                '"tolerance":"exact",',
                '"inputs":',
                coefficientInputsJson(input),
                ",",
                '"expected":',
                coefficientsJson(coeffs),
                "}"
            )
        );
    }

    function newtonRootVector(
        string memory label,
        bool bSign,
        bool cSign,
        bool dSign
    )
        internal
        pure
        returns (string memory)
    {
        uint256 a = 1e18;
        uint256 b = bSign ? 1e18 : 2e18;
        uint256 c = cSign ? 1e18 : 2e18;
        uint256 d;

        if (bSign && cSign && !dSign) {
            d = a + b + c;
        } else if (bSign && !cSign && dSign) {
            c = a + b + 1e18;
            d = 1e18;
        } else if (bSign && !cSign && !dSign) {
            c = 1e18;
            d = a + b - c;
        } else if (!bSign && cSign && dSign) {
            b = a + c + 1e18;
            d = 1e18;
        } else if (!bSign && cSign && !dSign) {
            b = 1e18;
            d = a + c - b;
        } else if (!bSign && !cSign && dSign) {
            b = 1e18;
            c = 2e18;
            d = b + c - a;
        } else if (!bSign && !cSign && !dSign) {
            b = 2 * 1e17;
            c = 3 * 1e17;
            d = a - b - c;
        } else {
            revert("unsupported positive-positive-positive root vector");
        }

        return newtonVector(NewtonVectorInput(label, 1e18, a, b, bSign, c, cSign, d, dSign));
    }

    function newtonRevertVector(string memory label) internal pure returns (string memory) {
        NewtonVectorInput memory input = NewtonVectorInput(label, 1e18, 1e18, 1e18, true, 1e18, true, 1e18, true);
        return string(
            abi.encodePacked(
                "    {",
                '"kind":"newtonRevert",',
                '"label":"',
                label,
                '",',
                '"function":"newtonMethodCubic",',
                '"expectedRevert":"NM1",',
                '"inputs":',
                newtonInputsJson(input),
                "}"
            )
        );
    }

    function newtonVector(NewtonVectorInput memory input) internal pure returns (string memory) {
        uint256 expected = CurveMath.newtonMethodCubic(
            input.initialGuess, input.a, input.b, input.c, input.d, input.bSign, input.cSign, input.dSign
        );

        return string(
            abi.encodePacked(
                "    {",
                '"kind":"newton",',
                '"label":"',
                input.label,
                '",',
                '"function":"newtonMethodCubic",',
                '"tolerance":"newton_1e10",',
                '"inputs":',
                newtonInputsJson(input),
                ",",
                '"expected":"',
                expected.toString(),
                '"',
                "}"
            )
        );
    }

    function publicOutput(PublicVectorInput memory input) internal pure returns (uint256) {
        if (input.fnType == PublicFunction.LongReturn) {
            return CurveMath.computeLongReturn(
                input.amount,
                input.spotPrice,
                ORACLE_DECIMALS,
                input.initialGuess,
                input.stable,
                input.asset,
                input.parameterA,
                input.parameterB,
                CURVE_DECIMALS
            );
        }
        if (input.fnType == PublicFunction.ShortReturn) {
            return CurveMath.computeShortReturn(
                input.amount,
                input.spotPrice,
                ORACLE_DECIMALS,
                input.initialGuess,
                input.stable,
                input.asset,
                input.parameterA,
                input.parameterB,
                CURVE_DECIMALS
            );
        }
        if (input.fnType == PublicFunction.ExactAmountInLong) {
            return CurveMath.computeExactAmountInLong(
                input.amount,
                input.spotPrice,
                ORACLE_DECIMALS,
                input.initialGuess,
                input.stable,
                input.asset,
                input.parameterA,
                input.parameterB,
                CURVE_DECIMALS
            );
        }
        return CurveMath.computeExactAmountInShort(
            input.amount,
            input.spotPrice,
            ORACLE_DECIMALS,
            input.initialGuess,
            input.stable,
            input.asset,
            input.parameterA,
            input.parameterB,
            CURVE_DECIMALS
        );
    }

    function inverseLongCoefficients(CoefficientVectorInput memory input)
        internal
        pure
        returns (InverseCoefficients memory coeffs)
    {
        coeffs.aPrime = CurveMath.computeAPrimePramLong(
            input.parameterA, input.spotPrice, input.asset, input.stable, ORACLE_DECIMALS
        );
        (coeffs.lambda, coeffs.lambdaSign) = CurveMath.computeInverseLambdaLong(
            input.spotPrice, input.asset - input.amount, input.asset, input.stable, ORACLE_DECIMALS
        );
        (coeffs.k, coeffs.kSign) =
            CurveMath.computeInverseKLong(input.spotPrice, input.asset, input.stable, ORACLE_DECIMALS);
        coeffs.a = CurveMath.computeInverseALong(input.asset - input.amount, input.asset);
        (coeffs.b, coeffs.bSign) = CurveMath.computeInverseBLong(
            coeffs.aPrime,
            input.asset - input.amount,
            input.spotPrice,
            coeffs.k,
            coeffs.kSign,
            input.parameterB,
            input.asset,
            ORACLE_DECIMALS,
            CURVE_DECIMALS
        );
        (coeffs.c, coeffs.cSign) = CurveMath.computeInverseCLong(
            coeffs.aPrime,
            input.asset - input.amount,
            input.spotPrice,
            coeffs.k,
            coeffs.kSign,
            coeffs.lambda,
            coeffs.lambdaSign,
            input.parameterB,
            input.asset,
            ORACLE_DECIMALS,
            CURVE_DECIMALS
        );
        (coeffs.d, coeffs.dSign) = CurveMath.computeInverseDLong(
            coeffs.aPrime,
            input.asset - input.amount,
            input.spotPrice,
            coeffs.k,
            coeffs.kSign,
            coeffs.lambda,
            coeffs.lambdaSign,
            input.parameterB,
            input.asset,
            ORACLE_DECIMALS,
            CURVE_DECIMALS
        );
    }

    function inverseShortCoefficients(CoefficientVectorInput memory input)
        internal
        pure
        returns (InverseCoefficients memory coeffs)
    {
        uint256 px0 = input.spotPrice * input.asset / ORACLE_DECIMALS;
        coeffs.aPrime = CurveMath.computeAPrimePramShort(input.parameterA, input.stable, px0);
        (coeffs.lambda, coeffs.lambdaSign) =
            CurveMath.computeInverseLambdaShort(input.stable - input.amount, input.stable, px0);
        (coeffs.k, coeffs.kSign) = CurveMath.computeInverseKShort(input.stable, px0);
        coeffs.a = CurveMath.computeInverseAShort(input.stable - input.amount, input.stable);
        (coeffs.b, coeffs.bSign) = CurveMath.computeInverseBShort(
            coeffs.aPrime,
            input.stable - input.amount,
            input.spotPrice,
            coeffs.k,
            coeffs.kSign,
            input.parameterB,
            input.stable,
            CURVE_DECIMALS,
            ORACLE_DECIMALS
        );
        (coeffs.c, coeffs.cSign) = CurveMath.computeInverseCShort(
            coeffs.aPrime,
            input.spotPrice,
            input.stable - input.amount,
            coeffs.k,
            coeffs.kSign,
            coeffs.lambda,
            coeffs.lambdaSign,
            input.parameterB,
            input.stable,
            CURVE_DECIMALS,
            ORACLE_DECIMALS
        );
        (coeffs.d, coeffs.dSign) = CurveMath.computeInverseDShort(
            coeffs.aPrime,
            input.spotPrice,
            input.stable - input.amount,
            coeffs.k,
            coeffs.kSign,
            coeffs.lambda,
            coeffs.lambdaSign,
            input.parameterB,
            input.stable,
            CURVE_DECIMALS,
            ORACLE_DECIMALS
        );
    }

    function append(
        string memory vectors,
        string memory vector,
        uint256 count
    )
        internal
        pure
        returns (string memory, uint256)
    {
        return (count == 0 ? vector : string.concat(vectors, ",\n", vector), count + 1);
    }

    function publicFunctionName(PublicFunction fnType) internal pure returns (string memory) {
        if (fnType == PublicFunction.LongReturn) return "computeLongReturn";
        if (fnType == PublicFunction.ShortReturn) return "computeShortReturn";
        if (fnType == PublicFunction.ExactAmountInLong) return "computeExactAmountInLong";
        return "computeExactAmountInShort";
    }

    function publicInputsJson(PublicVectorInput memory input) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "{",
                '"amount":"',
                input.amount.toString(),
                '",',
                '"spotPrice":"',
                input.spotPrice.toString(),
                '",',
                '"oracleDecimals":"',
                ORACLE_DECIMALS.toString(),
                '",',
                '"initialGuess":"',
                input.initialGuess.toString(),
                '",',
                '"stable":"',
                input.stable.toString(),
                '",',
                '"asset":"',
                input.asset.toString(),
                '",',
                '"parameterA":"',
                input.parameterA.toString(),
                '",',
                '"parameterB":"',
                input.parameterB.toString(),
                '",',
                '"curveParameterDecimals":"',
                CURVE_DECIMALS.toString(),
                '"',
                "}"
            )
        );
    }

    function coefficientInputsJson(CoefficientVectorInput memory input) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "{",
                '"amount":"',
                input.amount.toString(),
                '",',
                '"spotPrice":"',
                input.spotPrice.toString(),
                '",',
                '"oracleDecimals":"',
                ORACLE_DECIMALS.toString(),
                '",',
                '"stable":"',
                input.stable.toString(),
                '",',
                '"asset":"',
                input.asset.toString(),
                '",',
                '"parameterA":"',
                input.parameterA.toString(),
                '",',
                '"parameterB":"',
                input.parameterB.toString(),
                '",',
                '"curveParameterDecimals":"',
                CURVE_DECIMALS.toString(),
                '"',
                "}"
            )
        );
    }

    function newtonInputsJson(NewtonVectorInput memory input) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "{",
                '"initialGuess":"',
                input.initialGuess.toString(),
                '",',
                '"a":"',
                input.a.toString(),
                '",',
                '"b":"',
                input.b.toString(),
                '",',
                '"bSign":',
                boolJson(input.bSign),
                ",",
                '"c":"',
                input.c.toString(),
                '",',
                '"cSign":',
                boolJson(input.cSign),
                ",",
                '"d":"',
                input.d.toString(),
                '",',
                '"dSign":',
                boolJson(input.dSign),
                "}"
            )
        );
    }

    function coefficientsJson(InverseCoefficients memory coeffs) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "{",
                '"aPrime":"',
                coeffs.aPrime.toString(),
                '",',
                '"lambda":"',
                coeffs.lambda.toString(),
                '",',
                '"lambdaSign":',
                boolJson(coeffs.lambdaSign),
                ",",
                '"k":"',
                coeffs.k.toString(),
                '",',
                '"kSign":',
                boolJson(coeffs.kSign),
                ",",
                '"a":"',
                coeffs.a.toString(),
                '",',
                '"b":"',
                coeffs.b.toString(),
                '",',
                '"bSign":',
                boolJson(coeffs.bSign),
                ",",
                '"c":"',
                coeffs.c.toString(),
                '",',
                '"cSign":',
                boolJson(coeffs.cSign),
                ",",
                '"d":"',
                coeffs.d.toString(),
                '",',
                '"dSign":',
                boolJson(coeffs.dSign),
                "}"
            )
        );
    }

    function roundTripJson(
        string memory functionName,
        uint256 target,
        uint256 expected
    )
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                ",",
                '"roundTrip":{',
                '"function":"',
                functionName,
                '",',
                '"target":"',
                target.toString(),
                '",',
                '"expected":"',
                expected.toString(),
                '"',
                "}"
            )
        );
    }

    function boolJson(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }

    // -------------------------------------------------------------------
    // MatrixMath + UtilMath golden vectors (bit-exact ports live in
    // src/rust/CurveMath.rs). Signed values are emitted as signed decimal
    // strings (parsed in Rust via I256::from_dec_str). The inverse vectors
    // include a det != 1 case (proves the Rust full-inverse fix vs the old
    // adjugate-only path) and a det == 0 revert case.
    // -------------------------------------------------------------------
    function appendMatrixUtilVectors(
        string memory vectors,
        uint256 count
    )
        internal
        pure
        returns (string memory, uint256)
    {
        (vectors, count) = append(vectors, inverseVector("matrix-inverse-det2", 4, 2, 3, 2, 1), count);
        (vectors, count) = append(vectors, inverseVector("matrix-inverse-det1", 3, 1, 5, 2, 1), count);
        (vectors, count) = append(vectors, inverseRevertVector("matrix-inverse-det0", 2, 2, 2, 2, 1), count);
        (vectors, count) = append(vectors, matMulVector("matrix-matmul", 2, 3, 4, 5, 7, 1, 2, 9, 1), count);
        (vectors, count) = append(vectors, mulVecMatVector("matrix-mulvecmat", 2, 3, 1, 2, 3, 4, 1), count);
        (vectors, count) = append(vectors, mulMatVecVector("matrix-mulmatvec", 1, 2, 3, 4, 2, 3, 1), count);
        (vectors, count) = append(vectors, scalarVector("matrix-scalar", 2, 3, 4, 5, 1), count);
        // MatrixMath Q80 adjugate primitives (bit-exact ports in src/rust/CurveMath.rs).
        int256 s = int256(1) << 80;
        // mulDivSigned: sign combinations + truncation + a 512-bit product (S*S/S).
        (vectors, count) = append(vectors, mulDivSignedVector("mds-pos-trunc", 7, 3, 2), count);
        (vectors, count) = append(vectors, mulDivSignedVector("mds-neg-value", -7, 3, 2), count);
        (vectors, count) = append(vectors, mulDivSignedVector("mds-neg-denom", 7, 3, -2), count);
        (vectors, count) = append(vectors, mulDivSignedVector("mds-both-neg", -7, -3, 2), count);
        (vectors, count) = append(vectors, mulDivSignedVector("mds-q80-512bit", s, s, s), count);
        // sumMulDivSigned: same-sign no-carry, same-sign carry, opposite-sign borrow (both
        // directions), exact cancellation, negative denominator.
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-same-nocarry", 7, 3, 5, 2, 4), count);
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-same-carry", 7, 3, 9, 3, 4), count);
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-opp-first-greater", 7, 3, -5, 2, 4), count);
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-opp-second-greater", 5, 2, -7, 3, 4), count);
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-cancel-zero", 5, 2, -5, 2, 4), count);
        (vectors, count) = append(vectors, sumMulDivSignedVector("smds-neg-denom", 7, 3, 5, 2, -4), count);
        // recoverLpBalanceFromSnapshot: fresh identity reconstructs exactly; a degraded snapshot
        // exercises the adjugate/det path at Q80 scale.
        (vectors, count) = append(
            vectors, recoverLpVector("recover-lp-identity", mk(s, 0, 0, s), mk(s, 0, 0, s), 1e24, 1e21, s), count
        );
        (vectors, count) = append(
            vectors,
            recoverLpVector("recover-lp-degraded", mk(3 * s, 0, 0, s), mk(2 * s, 0, 0, s), 1e24, 1e21, s),
            count
        );
        // recoverFundingStarFromSnapshot: funding star at Q80 matrix scale + 1e24 G scale.
        (vectors, count) = append(
            vectors, recoverStarVector("recover-star-identity", 1e20, 1e18, mk(s, 0, 0, s), 1e24, 1e21, s, 1e24), count
        );
        // SLOW PATH: liquidityMDecimals > 2^80 (Q88) routes recovery through the bounded
        // sumMulDivSigned reduction (dead in production but must stay bit-identical for parity).
        int256 q88 = int256(1) << 88;
        (vectors, count) = append(
            vectors,
            recoverLpVector("recover-lp-slowpath-q88", mk(q88, 0, 0, q88), mk(q88, 0, 0, q88), 1e24, 1e21, q88),
            count
        );
        (vectors, count) = append(
            vectors,
            recoverLpVector(
                "recover-lp-slowpath-q88-degraded", mk(3 * q88, 0, 0, q88), mk(2 * q88, 0, 0, q88), 1e24, 1e21, q88
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            recoverStarVector("recover-star-slowpath-q88", 1e20, 1e18, mk(q88, 0, 0, q88), 1e24, 1e21, q88, 1e24),
            count
        );
        // OFF-DIAGONAL / MIXED-SIGN: exercise the cross terms (-b*q, -c*p, m01*u1, m10*u0,
        // -m10*m01) that the diagonal vectors above leave dead — a b<->c transposition or a
        // cross-term sign error would surface here. Snapshot det = 4-1 = 3 (scaled) > 0.
        (vectors, count) = append(
            vectors,
            recoverLpVector("recover-lp-mixed-q80", mk(2 * s, -s, s, 3 * s), mk(2 * s, s, s, 2 * s), 1e24, 1e21, s),
            count
        );
        (vectors, count) = append(
            vectors,
            recoverLpVector(
                "recover-lp-mixed-q88", mk(2 * q88, -q88, q88, 3 * q88), mk(2 * q88, q88, q88, 2 * q88), 1e24, 1e21, q88
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            recoverStarVector("recover-star-mixed-q80", 1e20, -1e18, mk(2 * s, s, s, 2 * s), 1e24, 1e21, s, 1e24),
            count
        );
        (vectors, count) = append(
            vectors,
            recoverStarVector(
                "recover-star-mixed-q88", 1e20, -1e18, mk(2 * q88, q88, q88, 2 * q88), 1e24, 1e21, q88, 1e24
            ),
            count
        );
        (vectors, count) = append(vectors, signedSumVector("util-signedsum-same", 100, true, 50, true), count);
        (vectors, count) = append(vectors, signedSumVector("util-signedsum-diff-xgty", 100, true, 50, false), count);
        (vectors, count) = append(vectors, signedSumVector("util-signedsum-diff-xlty", 50, true, 100, false), count);
        (vectors, count) = append(vectors, signedSumVector("util-signedsum-diff-eq", 50, true, 50, false), count);
        (vectors, count) = append(vectors, signedSumToIntVector("util-ssint-pos", 100, true, 50, false), count);
        (vectors, count) = append(vectors, signedSumToIntVector("util-ssint-neg", 50, true, 100, false), count);
        (vectors, count) = append(vectors, diffAbsVector("util-diffabs", 100, 50), count);
        // calcEMA
        (vectors, count) = append(vectors, calcEmaVector("util-calcema", 110, 100, 1e8, 50, 90_000_000), count);
        // divCeil (signed): same-sign rounds up, opposite-sign truncates
        (vectors, count) = append(vectors, divCeilVector("util-divceil-pos-rem", 7, 2), count);
        (vectors, count) = append(vectors, divCeilVector("util-divceil-pos-norem", 6, 2), count);
        (vectors, count) = append(vectors, divCeilVector("util-divceil-neg-num", -7, 2), count);
        (vectors, count) = append(vectors, divCeilVector("util-divceil-both-neg", -7, -2), count);
        // reduceValue (saturating subtraction, used by _removeLiquidity)
        (vectors, count) = append(vectors, reduceValueVector("util-reduceval-agtb", 100, 30), count);
        (vectors, count) = append(vectors, reduceValueVector("util-reduceval-altb", 30, 100), count);
        (vectors, count) = append(vectors, reduceValueVector("util-reduceval-eq", 50, 50), count);
        // computeLiquidityRemovalFee (FeeManager): full formula (both ratio branches),
        // maxFee/minFee shortcuts, waived (near-empty pool), and maxFee==0.
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-firstbranch-full", LiqFeeInput(1e23, 4e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-elsebranch-full", LiqFeeInput(1e24, 1e20, 18e24, 61e20, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-maxfee-shortcut", LiqFeeInput(1e23, 5e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-minfee-shortcut", LiqFeeInput(5e23, 1e20, 2e25, 5e21, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-waived-zero", LiqFeeInput(15e18, 1995e15, 20e18, 2e18, 1000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector("liqfee-maxfee-zero", LiqFeeInput(1e23, 1e20, 2e25, 5e21, 3000e8, 1e8, 0, 0, 1e10, 1e10)),
            count
        );
        // One-sided pools: a fully-removed side (initial == 0) waives the removal fee (parity with
        // the deposit fee's existing guard) instead of dividing through the zeroed side.
        (vectors, count) = append(
            vectors,
            liqFeeVector("liqfee-initstable-zero", LiqFeeInput(0, 1e20, 0, 2e25, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector("liqfee-initasset-zero", LiqFeeInput(1e24, 0, 2e25, 0, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)),
            count
        );
        // computeLiquidityDepositFee (FeeManager): full formula (both ratio branches),
        // minFee shortcut, empty-pool (initial==0) and maxFee==0 zero short-circuits.
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-firstbranch-full", LiqFeeInput(1e23, 4e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-elsebranch-full", LiqFeeInput(1e24, 1e20, 18e24, 61e20, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-minfee-shortcut", LiqFeeInput(1e23, 1e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-empty-pool-zero", LiqFeeInput(1e24, 1e20, 0, 0, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-initasset-zero", LiqFeeInput(1e24, 1e20, 2e25, 0, 3000e8, 1e8, 5e8, 1e7, 1e10, 1e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-maxfee-zero", LiqFeeInput(1e23, 1e20, 2e25, 5e21, 3000e8, 1e8, 0, 0, 1e10, 1e10)
            ),
            count
        );
        // feeK != feeDecimals + minFee*feeDecimals not divisible by maxFee: distinguishes
        // the DEPOSIT num chain `minFee*feeK/maxFee*(rd+d1)/rd` from the REMOVAL num chain
        // `minFee*feeDec/maxFee*feeK/feeDec*(rd+d1)/rd` (which collapse when feeK==feeDec).
        (vectors, count) = append(
            vectors,
            liqDepositFeeVector(
                "liqdepfee-feek-ne-feedec",
                LiqFeeInput(1e23, 4e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 33_333_333, 1e10, 2e10)
            ),
            count
        );
        (vectors, count) = append(
            vectors,
            liqFeeVector(
                "liqfee-feek-ne-feedec", LiqFeeInput(1e23, 4e21, 2e25, 5e21, 3000e8, 1e8, 5e8, 33_333_333, 1e10, 2e10)
            ),
            count
        );
        return (vectors, count);
    }

    function reduceValueVector(string memory label, uint256 a, uint256 b) internal pure returns (string memory) {
        (uint256 newA, uint256 remainingB) = UtilMath.reduceValue(a, b);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"reduceValue","inputs":{"a":"',
                a.toString(),
                '","b":"',
                b.toString(),
                '"},"expected":{"newA":"',
                newA.toString(),
                '","remainingB":"',
                remainingB.toString(),
                '"}}'
            )
        );
    }

    function liqFeeVector(string memory label, LiqFeeInput memory inp) internal pure returns (string memory) {
        uint256 z = FeeManager.computeLiquidityRemovalFee(
            inp.stable,
            inp.asset,
            inp.iStable,
            inp.iAsset,
            inp.price,
            inp.oracleDecimals,
            inp.maxFee,
            inp.minFee,
            inp.feeK,
            inp.feeDecimals
        );
        string memory in1 = string(
            abi.encodePacked(
                '"stable":"',
                inp.stable.toString(),
                '","asset":"',
                inp.asset.toString(),
                '","iStable":"',
                inp.iStable.toString(),
                '","iAsset":"',
                inp.iAsset.toString(),
                '","price":"',
                inp.price.toString(),
                '","oracleDecimals":"',
                inp.oracleDecimals.toString()
            )
        );
        string memory in2 = string(
            abi.encodePacked(
                '","maxFee":"',
                inp.maxFee.toString(),
                '","minFee":"',
                inp.minFee.toString(),
                '","feeK":"',
                inp.feeK.toString(),
                '","feeDecimals":"',
                inp.feeDecimals.toString(),
                '"'
            )
        );
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"liquidityRemovalFee","inputs":{',
                in1,
                in2,
                '},"expected":{"z":"',
                z.toString(),
                '"}}'
            )
        );
    }

    function liqDepositFeeVector(string memory label, LiqFeeInput memory inp) internal pure returns (string memory) {
        uint256 z = FeeManager.computeLiquidityDepositFee(
            inp.stable,
            inp.asset,
            inp.iStable,
            inp.iAsset,
            inp.price,
            inp.oracleDecimals,
            inp.maxFee,
            inp.minFee,
            inp.feeK,
            inp.feeDecimals
        );
        string memory in1 = string(
            abi.encodePacked(
                '"stable":"',
                inp.stable.toString(),
                '","asset":"',
                inp.asset.toString(),
                '","iStable":"',
                inp.iStable.toString(),
                '","iAsset":"',
                inp.iAsset.toString(),
                '","price":"',
                inp.price.toString(),
                '","oracleDecimals":"',
                inp.oracleDecimals.toString()
            )
        );
        string memory in2 = string(
            abi.encodePacked(
                '","maxFee":"',
                inp.maxFee.toString(),
                '","minFee":"',
                inp.minFee.toString(),
                '","feeK":"',
                inp.feeK.toString(),
                '","feeDecimals":"',
                inp.feeDecimals.toString(),
                '"'
            )
        );
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"liquidityDepositFee","inputs":{',
                in1,
                in2,
                '},"expected":{"z":"',
                z.toString(),
                '"}}'
            )
        );
    }

    function calcEmaVector(
        string memory label,
        uint256 p,
        uint256 spotP,
        uint256 slipDecimals,
        uint256 oldAverage,
        uint256 emaParam
    )
        internal
        pure
        returns (string memory)
    {
        uint256 z = UtilMath.calcEMA(p, spotP, slipDecimals, oldAverage, emaParam);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"calcEMA","inputs":{"p":"',
                p.toString(),
                '","spotP":"',
                spotP.toString(),
                '","slipDecimals":"',
                slipDecimals.toString(),
                '","oldAverage":"',
                oldAverage.toString(),
                '","emaParam":"',
                emaParam.toString(),
                '"},"expected":{"z":"',
                z.toString(),
                '"}}'
            )
        );
    }

    function divCeilVector(string memory label, int256 a, int256 b) internal pure returns (string memory) {
        int256 z = UtilMath.divCeil(a, b);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"divCeil","inputs":{"a":"',
                intStr(a),
                '","b":"',
                intStr(b),
                '"},"expected":{"z":"',
                intStr(z),
                '"}}'
            )
        );
    }

    function intStr(int256 v) internal pure returns (string memory) {
        if (v >= 0) {
            return uint256(v).toString();
        }
        return string.concat("-", uint256(-v).toString());
    }

    function mk(int256 a00, int256 a01, int256 a10, int256 a11) internal pure returns (int256[2][2] memory m) {
        m[0][0] = a00;
        m[0][1] = a01;
        m[1][0] = a10;
        m[1][1] = a11;
    }

    function mkv(int256 v0, int256 v1) internal pure returns (int256[2] memory v) {
        v[0] = v0;
        v[1] = v1;
    }

    function inverseVector(
        string memory label,
        int256 a00,
        int256 a01,
        int256 a10,
        int256 a11,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        int256[2][2] memory r = MatrixMath.inverseTwoByTwo(mk(a00, a01, a10, a11), norm);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"inverse","inputs":{"a00":"',
                intStr(a00),
                '","a01":"',
                intStr(a01),
                '","a10":"',
                intStr(a10),
                '","a11":"',
                intStr(a11),
                '","norm":"',
                intStr(norm),
                '"},"expected":{"r00":"',
                intStr(r[0][0]),
                '","r01":"',
                intStr(r[0][1]),
                '","r10":"',
                intStr(r[1][0]),
                '","r11":"',
                intStr(r[1][1]),
                '"}}'
            )
        );
    }

    function inverseRevertVector(
        string memory label,
        int256 a00,
        int256 a01,
        int256 a10,
        int256 a11,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                '    {"kind":"matrixRevert","label":"',
                label,
                '","op":"inverse","inputs":{"a00":"',
                intStr(a00),
                '","a01":"',
                intStr(a01),
                '","a10":"',
                intStr(a10),
                '","a11":"',
                intStr(a11),
                '","norm":"',
                intStr(norm),
                '"}}'
            )
        );
    }

    function matMulVector(
        string memory label,
        int256 a00,
        int256 a01,
        int256 a10,
        int256 a11,
        int256 b00,
        int256 b01,
        int256 b10,
        int256 b11,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        int256[2][2] memory r = MatrixMath.matMulTwoByTwo(mk(a00, a01, a10, a11), mk(b00, b01, b10, b11), norm);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"matmul","inputs":{"a00":"',
                intStr(a00),
                '","a01":"',
                intStr(a01),
                '","a10":"',
                intStr(a10),
                '","a11":"',
                intStr(a11),
                '","b00":"',
                intStr(b00),
                '","b01":"',
                intStr(b01),
                '","b10":"',
                intStr(b10),
                '","b11":"',
                intStr(b11),
                '","norm":"',
                intStr(norm),
                '"},"expected":{"r00":"',
                intStr(r[0][0]),
                '","r01":"',
                intStr(r[0][1]),
                '","r10":"',
                intStr(r[1][0]),
                '","r11":"',
                intStr(r[1][1]),
                '"}}'
            )
        );
    }

    function mulVecMatVector(
        string memory label,
        int256 v0,
        int256 v1,
        int256 m00,
        int256 m01,
        int256 m10,
        int256 m11,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        int256[2] memory r = MatrixMath.mulVecMatTwoByTwo(mkv(v0, v1), mk(m00, m01, m10, m11), norm);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"mulvecmat","inputs":{"v0":"',
                intStr(v0),
                '","v1":"',
                intStr(v1),
                '","m00":"',
                intStr(m00),
                '","m01":"',
                intStr(m01),
                '","m10":"',
                intStr(m10),
                '","m11":"',
                intStr(m11),
                '","norm":"',
                intStr(norm),
                '"},"expected":{"r0":"',
                intStr(r[0]),
                '","r1":"',
                intStr(r[1]),
                '"}}'
            )
        );
    }

    function mulMatVecVector(
        string memory label,
        int256 m00,
        int256 m01,
        int256 m10,
        int256 m11,
        int256 v0,
        int256 v1,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        int256[2] memory r = MatrixMath.mulMatVecTwoByTwo(mk(m00, m01, m10, m11), mkv(v0, v1), norm);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"mulmatvec","inputs":{"m00":"',
                intStr(m00),
                '","m01":"',
                intStr(m01),
                '","m10":"',
                intStr(m10),
                '","m11":"',
                intStr(m11),
                '","v0":"',
                intStr(v0),
                '","v1":"',
                intStr(v1),
                '","norm":"',
                intStr(norm),
                '"},"expected":{"r0":"',
                intStr(r[0]),
                '","r1":"',
                intStr(r[1]),
                '"}}'
            )
        );
    }

    function scalarVector(
        string memory label,
        int256 a0,
        int256 a1,
        int256 b0,
        int256 b1,
        int256 norm
    )
        internal
        pure
        returns (string memory)
    {
        int256 r = MatrixMath.scalarTwoByTwo(mkv(a0, a1), mkv(b0, b1), norm);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"scalar","inputs":{"v1_0":"',
                intStr(a0),
                '","v1_1":"',
                intStr(a1),
                '","v2_0":"',
                intStr(b0),
                '","v2_1":"',
                intStr(b1),
                '","norm":"',
                intStr(norm),
                '"},"expected":{"r":"',
                intStr(r),
                '"}}'
            )
        );
    }

    function mulDivSignedVector(
        string memory label,
        int256 value,
        int256 multiplier,
        int256 denominator
    )
        internal
        pure
        returns (string memory)
    {
        int256 r = MatrixMath.mulDivSigned(value, multiplier, denominator);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"mulDivSigned","inputs":{"value":"',
                intStr(value),
                '","multiplier":"',
                intStr(multiplier),
                '","denominator":"',
                intStr(denominator),
                '"},"expected":{"r":"',
                intStr(r),
                '"}}'
            )
        );
    }

    function sumMulDivSignedVector(
        string memory label,
        int256 fv,
        int256 fm,
        int256 sv,
        int256 sm,
        int256 denom
    )
        internal
        pure
        returns (string memory)
    {
        int256 r = MatrixMath.sumMulDivSigned(fv, fm, sv, sm, denom);
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                '","op":"sumMulDivSigned","inputs":{"fv":"',
                intStr(fv),
                '","fm":"',
                intStr(fm),
                '","sv":"',
                intStr(sv),
                '","sm":"',
                intStr(sm),
                '","denom":"',
                intStr(denom),
                '"},"expected":{"r":"',
                intStr(r),
                '"}}'
            )
        );
    }

    function recoverLpVector(
        string memory label,
        int256[2][2] memory cur,
        int256[2][2] memory snap,
        uint256 initStable,
        uint256 initAsset,
        int256 lmDec
    )
        internal
        pure
        returns (string memory)
    {
        (int256 stableBal, int256 assetBal) =
            MatrixMath.recoverLpBalanceFromSnapshot(cur, snap, initStable, initAsset, lmDec);
        string memory inA = string(
            abi.encodePacked(
                '","op":"recoverLp","inputs":{"c00":"',
                intStr(cur[0][0]),
                '","c01":"',
                intStr(cur[0][1]),
                '","c10":"',
                intStr(cur[1][0]),
                '","c11":"',
                intStr(cur[1][1]),
                '","s00":"',
                intStr(snap[0][0]),
                '","s01":"',
                intStr(snap[0][1])
            )
        );
        string memory inB = string(
            abi.encodePacked(
                '","s10":"',
                intStr(snap[1][0]),
                '","s11":"',
                intStr(snap[1][1]),
                '","initStable":"',
                initStable.toString(),
                '","initAsset":"',
                initAsset.toString(),
                '","lmDec":"',
                intStr(lmDec),
                '"}'
            )
        );
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"',
                label,
                inA,
                inB,
                ',"expected":{"stable":"',
                intStr(stableBal),
                '","asset":"',
                intStr(assetBal),
                '"}}'
            )
        );
    }

    function recoverStarVector(
        string memory label,
        int256 dg0,
        int256 dg1,
        int256[2][2] memory snap,
        uint256 initStable,
        uint256 initAsset,
        int256 lmDec,
        uint256 gDec
    )
        internal
        pure
        returns (string memory)
    {
        int256 star = MatrixMath.recoverFundingStarFromSnapshot(dg0, dg1, snap, initStable, initAsset, lmDec, gDec);
        string memory inA = string(
            abi.encodePacked(
                '","op":"recoverFundingStar","inputs":{"dg0":"',
                intStr(dg0),
                '","dg1":"',
                intStr(dg1),
                '","s00":"',
                intStr(snap[0][0]),
                '","s01":"',
                intStr(snap[0][1]),
                '","s10":"',
                intStr(snap[1][0]),
                '","s11":"',
                intStr(snap[1][1])
            )
        );
        string memory inB = string(
            abi.encodePacked(
                '","initStable":"',
                initStable.toString(),
                '","initAsset":"',
                initAsset.toString(),
                '","lmDec":"',
                intStr(lmDec),
                '","gDec":"',
                gDec.toString(),
                '"}'
            )
        );
        return string(
            abi.encodePacked(
                '    {"kind":"matrix","label":"', label, inA, inB, ',"expected":{"star":"', intStr(star), '"}}'
            )
        );
    }

    function signedSumVector(
        string memory label,
        uint256 x,
        bool signX,
        uint256 y,
        bool signY
    )
        internal
        pure
        returns (string memory)
    {
        (uint256 z, bool zSign) = UtilMath.signedSum(x, signX, y, signY);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"signedSum","inputs":{"x":"',
                x.toString(),
                '","xs":',
                boolJson(signX),
                ',"y":"',
                y.toString(),
                '","ys":',
                boolJson(signY),
                '},"expected":{"z":"',
                z.toString(),
                '","zs":',
                boolJson(zSign),
                "}}"
            )
        );
    }

    function signedSumToIntVector(
        string memory label,
        uint256 x,
        bool signX,
        uint256 y,
        bool signY
    )
        internal
        pure
        returns (string memory)
    {
        int256 z = UtilMath.signedSumToInt(x, signX, y, signY);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"signedSumToInt","inputs":{"x":"',
                x.toString(),
                '","xs":',
                boolJson(signX),
                ',"y":"',
                y.toString(),
                '","ys":',
                boolJson(signY),
                '},"expected":{"z":"',
                intStr(z),
                '"}}'
            )
        );
    }

    function diffAbsVector(string memory label, uint256 x, uint256 y) internal pure returns (string memory) {
        uint256 z = UtilMath.diffAbs(x, y);
        return string(
            abi.encodePacked(
                '    {"kind":"util","label":"',
                label,
                '","op":"diffAbs","inputs":{"x":"',
                x.toString(),
                '","y":"',
                y.toString(),
                '"},"expected":{"z":"',
                z.toString(),
                '"}}'
            )
        );
    }
}
