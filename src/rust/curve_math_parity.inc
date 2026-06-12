use stylus_sdk::alloy_primitives::{I256, U256};
use serde_json::Value;

fn dec(value: &str) -> I256 {
    value.parse::<I256>().unwrap()
}

fn u_dec(value: &str) -> U256 {
    value.parse::<U256>().unwrap()
}

fn signed(value: &str, positive: bool) -> I256 {
    let magnitude = dec(value);
    if positive {
        magnitude
    } else {
        -magnitude
    }
}

fn assert_close(result: I256, expected: I256, denominator: I256, name: &str) {
    let diff = if result > expected {
        result - expected
    } else {
        expected - result
    };
    let expected_abs = if expected < I256::ZERO {
        -expected
    } else {
        expected
    };
    assert!(
        diff <= expected_abs / denominator,
        "{name}: result {result} expected {expected} diff {diff}"
    );
}

fn assert_abs_diff(result: I256, expected: I256, max_diff: I256, name: &str) {
    let diff = if result > expected {
        result - expected
    } else {
        expected - result
    };
    assert!(
        diff <= max_diff,
        "{name}: result {result} expected {expected} diff {diff}"
    );
}

#[derive(Debug)]
struct CommonInputs {
    amount: I256,
    spot_price: I256,
    oracle_dec: I256,
    initial_guess: Option<I256>,
    stable: I256,
    asset: I256,
    parameter_a: I256,
    parameter_b: I256,
    curve_dec: I256,
}

#[derive(Debug)]
struct InverseCoefficients {
    a_prime: I256,
    lambda: I256,
    k: I256,
    a: I256,
    b: I256,
    c: I256,
    d: I256,
}

fn object<'a>(value: &'a Value, key: &str, label: &str) -> &'a Value {
    value
        .get(key)
        .unwrap_or_else(|| panic!("{label}: missing `{key}`"))
}

fn string_field<'a>(value: &'a Value, key: &str, label: &str) -> &'a str {
    object(value, key, label)
        .as_str()
        .unwrap_or_else(|| panic!("{label}: `{key}` must be a string"))
}

fn bool_field(value: &Value, key: &str, label: &str) -> bool {
    object(value, key, label)
        .as_bool()
        .unwrap_or_else(|| panic!("{label}: `{key}` must be a bool"))
}

fn i_field(value: &Value, key: &str, label: &str) -> I256 {
    dec(string_field(value, key, label))
}

fn u_field(value: &Value, key: &str, label: &str) -> U256 {
    u_dec(string_field(value, key, label))
}

fn signed_field(value: &Value, magnitude_key: &str, sign_key: &str, label: &str) -> I256 {
    signed(
        string_field(value, magnitude_key, label),
        bool_field(value, sign_key, label),
    )
}

fn common_inputs(vector: &Value, label: &str) -> CommonInputs {
    let inputs = object(vector, "inputs", label);
    CommonInputs {
        amount: i_field(inputs, "amount", label),
        spot_price: i_field(inputs, "spotPrice", label),
        oracle_dec: i_field(inputs, "oracleDecimals", label),
        initial_guess: inputs
            .get("initialGuess")
            .map(|_| i_field(inputs, "initialGuess", label)),
        stable: i_field(inputs, "stable", label),
        asset: i_field(inputs, "asset", label),
        parameter_a: i_field(inputs, "parameterA", label),
        parameter_b: i_field(inputs, "parameterB", label),
        curve_dec: i_field(inputs, "curveParameterDecimals", label),
    }
}

fn assert_signed_value(
    actual: I256,
    expected: &Value,
    magnitude_key: &str,
    sign_key: &str,
    label: &str,
) {
    let expected_signed = signed_field(expected, magnitude_key, sign_key, label);
    assert_eq!(actual, expected_signed, "{label}:{magnitude_key}");
}

fn compare_with_tolerance(result: I256, expected: I256, tolerance: &str, label: &str) {
    match tolerance {
        "exact" => assert_eq!(result, expected, "{label}"),
        "newton_1e10" => assert_abs_diff(result, expected, dec("10000000000"), label),
        unsupported => panic!("{label}: unsupported tolerance `{unsupported}`"),
    }
}

fn inverse_long_coefficients(inputs: &CommonInputs) -> InverseCoefficients {
    let s = s();
    let sp = inputs.spot_price * s / inputs.oracle_dec;
    let x = inputs.asset - inputs.amount;
    let x0 = inputs.asset;
    let y0 = inputs.stable;

    let a_prime = inputs.parameter_a * sp / s * sp / s * x0 / s * x0 / s * x0 / s * x0
        / (x0 * sp / s + y0);
    let lambda = -(inputs.spot_price * (x0 - x) / inputs.oracle_dec + y0);
    let k = sp * x0 / s - y0;
    let a = x * x / x0 * x / x0 * s / x0 * s / x0;

    let t1 = a_prime * x / inputs.curve_dec * s / x0 * s / x0 * s / x0 * s / x0;
    let t2 = two() * x * x / x0 * x / x0 * k / s * s / x0 * s / x0;
    let t3 = two() * x * x / s * inputs.spot_price / inputs.oracle_dec
        * (inputs.parameter_b + inputs.curve_dec)
        / inputs.curve_dec
        * s
        / x0
        * s
        / x0;
    let t4_1 = k * x / s - inputs.spot_price * x0 / inputs.oracle_dec * x0 / s;
    let t4 = t4_1 * x / x0 * x / x0 * s / x0 * s / x0;
    let b = t1 + t2 - t3 + t4;

    let k_lam = k + lambda;
    let b_plus = inputs.parameter_b + inputs.curve_dec;
    let ct1 = a_prime * x / inputs.curve_dec * k_lam / x0 * s / x0 * s / x0 * s / x0;
    let ct2 = x0 * x0 / s * b_plus / inputs.curve_dec * b_plus / inputs.curve_dec
        * inputs.spot_price
        / inputs.oracle_dec
        * inputs.spot_price
        / inputs.oracle_dec
        * x
        / x0
        * s
        / x0;
    let ct3 = k * k / s * x / x0 * x / x0 * x / x0 * s / x0;
    let ct4 = two() * x * x / s * b_plus / inputs.curve_dec * inputs.spot_price
        / inputs.oracle_dec
        * k
        / s
        * s
        / x0
        * s
        / x0;
    let ct5_1 = k * x / s - inputs.spot_price * x0 / inputs.oracle_dec * x0 / s;
    let ct5 = two() * ct5_1 * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let ct6 = two() * x * b_plus / inputs.curve_dec * ct5_1 / s * inputs.spot_price
        / inputs.oracle_dec
        * s
        / x0
        * s
        / x0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    let dt1 = x * a_prime / x0 * k / s * lambda / x0 * s / x0 * s / x0 * s / inputs.oracle_dec;
    let temp = k * x / s - inputs.spot_price * x0 / inputs.oracle_dec * x0 / s;
    let dt2 = temp * b_plus / inputs.curve_dec * b_plus / inputs.curve_dec * inputs.spot_price
        / inputs.oracle_dec
        * inputs.spot_price
        / inputs.oracle_dec;
    let dt3 = temp * k / s * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let dt4 = two() * temp * x / s * b_plus / inputs.curve_dec * inputs.spot_price
        / inputs.oracle_dec
        * k
        / s
        * s
        / x0
        * s
        / x0;
    let d = dt1 + dt2 + dt3 - dt4;

    InverseCoefficients {
        a_prime,
        lambda,
        k,
        a,
        b,
        c,
        d,
    }
}

fn inverse_short_coefficients(inputs: &CommonInputs) -> InverseCoefficients {
    let s = s();
    let p = inputs.spot_price;
    let y = inputs.stable - inputs.amount;
    let y0 = inputs.stable;
    let px0 = p * inputs.asset / inputs.oracle_dec;

    let a_prime = inputs.parameter_a * y0 / s * y0 / s * y0 / s * y0 / (px0 + y0);
    let lambda = y - y0 - px0;
    let k = y0 - px0;
    let a = y * y / y0 * y / y0 * s / y0 * s / y0;

    let bt1 = a_prime * y / inputs.curve_dec * s / y0 * s / y0 * s / y0 * s / y0
        * inputs.oracle_dec
        / p;
    let bt2 = two() * y * y / y0 * y / y0 * inputs.oracle_dec / p * k / y0 * s / y0;
    let bt3 = two() * y * (inputs.parameter_b + inputs.curve_dec) / inputs.curve_dec * y / y0
        * s
        / y0
        * inputs.oracle_dec
        / p;
    let bt4_1 = k * y - y0 * y0;
    let bt4 = bt4_1 / s * y / y0 * y / y0 * s / y0 * s / y0 * inputs.oracle_dec / p;
    let b = bt1 + bt2 - bt3 + bt4;

    let k_lam = k + lambda;
    let b_plus = inputs.parameter_b + inputs.curve_dec;
    let ct1 = a_prime * s / inputs.curve_dec * y / y0 * k_lam / y0 * s / y0 * s / y0
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p;
    let ct2 = y * b_plus / inputs.curve_dec * b_plus / inputs.curve_dec * inputs.oracle_dec / p
        * inputs.oracle_dec
        / p;
    let ct3 =
        k * k / y0 * y / y0 * y / y0 * y / y0 * inputs.oracle_dec / p * inputs.oracle_dec / p;
    let ct4 = two() * y * y / y0 * b_plus / inputs.curve_dec * k / y0 * inputs.oracle_dec / p
        * inputs.oracle_dec
        / p;
    let ct5_1 = k * y / s - y0 * y0 / s;
    let ct5 =
        two() * k * y / y0 * y / y0 * ct5_1 / s * inputs.oracle_dec / p * inputs.oracle_dec / p
            * s
            / y0
            * s
            / y0;
    let ct6 = two() * y * b_plus / inputs.curve_dec * ct5_1 / s * inputs.oracle_dec / p
        * inputs.oracle_dec
        / p
        * s
        / y0
        * s
        / y0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    let dt1 = y * s / y0 * a_prime / inputs.curve_dec * s / y0 * k / y0 * lambda / y0
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p;
    let temp = k * y / s - y0 * y0 / s;
    let dt2 = temp * b_plus / inputs.curve_dec * b_plus / inputs.curve_dec * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p;
    let dt3 = temp * k / y0 * k / y0 * y / y0 * y / y0 * inputs.oracle_dec / p
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p;
    let dt4 = two() * temp * b_plus / inputs.curve_dec * y / y0 * k / y0 * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p
        * inputs.oracle_dec
        / p;
    let d = dt1 + dt2 + dt3 - dt4;

    InverseCoefficients {
        a_prime,
        lambda,
        k,
        a,
        b,
        c,
        d,
    }
}

#[test]
fn generated_solidity_fixture_matches_rust_curve_math() {
    let repo_root = std::env::var("DENARIA_PERP_ROOT").unwrap_or_else(|_| ".".to_owned());
    let fixture_path = format!("{repo_root}/test/fixtures/curve_math_solidity_vectors.json");
    let fixture = std::fs::read_to_string(fixture_path).expect("read CurveMath fixture");
    let root: Value = serde_json::from_str(&fixture).expect("parse CurveMath fixture");

    assert_eq!(
        string_field(&root, "schema", "fixture"),
        "denaria.curve_math.parity.v1"
    );
    let vectors = object(&root, "vectors", "fixture")
        .as_array()
        .expect("fixture vectors must be an array");
    assert_eq!(
        object(&root, "vectorCount", "fixture").as_u64(),
        Some(vectors.len() as u64)
    );

    for vector in vectors {
        let label = string_field(vector, "label", "vector");
        let kind = string_field(vector, "kind", label);
        match kind {
            "public" => assert_public_vector(vector, label),
            "newton" => assert_newton_vector(vector, label),
            "newtonRevert" => assert_newton_revert_vector(vector, label),
            "coefficients" => assert_coefficient_vector(vector, label),
            "matrix" => assert_matrix_vector(vector, label),
            "matrixRevert" => assert_matrix_revert_vector(vector, label),
            "util" => assert_util_vector(vector, label),
            unsupported => panic!("{label}: unsupported vector kind `{unsupported}`"),
        }
    }
}

fn assert_public_vector(vector: &Value, label: &str) {
    let inputs = common_inputs(vector, label);
    let function_name = string_field(vector, "function", label);
    let initial_guess = inputs
        .initial_guess
        .unwrap_or_else(|| panic!("{label}: missing initialGuess"));
    let result = match function_name {
        "computeLongReturn" => compute_long_return_inner(
            inputs.amount,
            inputs.spot_price,
            inputs.oracle_dec,
            initial_guess,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        "computeShortReturn" => compute_short_return_inner(
            inputs.amount,
            inputs.spot_price,
            inputs.oracle_dec,
            initial_guess,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        "computeExactAmountInLong" => compute_exact_in_long_inner(
            inputs.amount,
            inputs.spot_price,
            inputs.oracle_dec,
            initial_guess,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        "computeExactAmountInShort" => compute_exact_in_short_inner(
            inputs.amount,
            inputs.spot_price,
            inputs.oracle_dec,
            initial_guess,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        unsupported => panic!("{label}: unsupported public function `{unsupported}`"),
    };

    compare_with_tolerance(
        result,
        i_field(vector, "expected", label),
        string_field(vector, "tolerance", label),
        label,
    );

    if let Some(round_trip) = vector.get("roundTrip") {
        assert_round_trip(round_trip, &inputs, result, label);
    }
}

fn assert_round_trip(
    round_trip: &Value,
    inputs: &CommonInputs,
    exact_input: I256,
    label: &str,
) {
    let target = i_field(round_trip, "target", label);
    let result = match string_field(round_trip, "function", label) {
        "computeLongReturn" => compute_long_return_inner(
            exact_input,
            inputs.spot_price,
            inputs.oracle_dec,
            inputs.asset - target,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        "computeShortReturn" => compute_short_return_inner(
            exact_input,
            inputs.spot_price,
            inputs.oracle_dec,
            inputs.stable - target,
            inputs.stable,
            inputs.asset,
            inputs.parameter_a,
            inputs.parameter_b,
            inputs.curve_dec,
        ),
        unsupported => panic!("{label}: unsupported roundTrip function `{unsupported}`"),
    };
    assert_eq!(
        result,
        i_field(round_trip, "expected", label),
        "{label}: roundTrip expected"
    );
    assert_close(result, target, dec("10000"), label);
}

fn assert_newton_vector(vector: &Value, label: &str) {
    let inputs = object(vector, "inputs", label);
    let result = newton_cubic(
        i_field(inputs, "initialGuess", label),
        i_field(inputs, "a", label),
        signed_field(inputs, "b", "bSign", label),
        signed_field(inputs, "c", "cSign", label),
        signed_field(inputs, "d", "dSign", label),
    );
    compare_with_tolerance(
        result,
        i_field(vector, "expected", label),
        string_field(vector, "tolerance", label),
        label,
    );
}

fn assert_newton_revert_vector(vector: &Value, label: &str) {
    assert_eq!(string_field(vector, "expectedRevert", label), "NM1");
    let inputs = object(vector, "inputs", label);
    let result = std::panic::catch_unwind(|| {
        newton_cubic(
            i_field(inputs, "initialGuess", label),
            i_field(inputs, "a", label),
            signed_field(inputs, "b", "bSign", label),
            signed_field(inputs, "c", "cSign", label),
            signed_field(inputs, "d", "dSign", label),
        )
    });
    assert!(result.is_err(), "{label}: expected Rust Newton panic");
}

fn assert_coefficient_vector(vector: &Value, label: &str) {
    let inputs = common_inputs(vector, label);
    let expected = object(vector, "expected", label);
    let result = match string_field(vector, "function", label) {
        "computeExactAmountInLong" => inverse_long_coefficients(&inputs),
        "computeExactAmountInShort" => inverse_short_coefficients(&inputs),
        unsupported => panic!("{label}: unsupported coefficient function `{unsupported}`"),
    };

    assert_eq!(
        result.a_prime,
        i_field(expected, "aPrime", label),
        "{label}:aPrime"
    );
    assert_signed_value(result.lambda, expected, "lambda", "lambdaSign", label);
    assert_signed_value(result.k, expected, "k", "kSign", label);
    assert_eq!(result.a, i_field(expected, "a", label), "{label}:a");
    assert_signed_value(result.b, expected, "b", "bSign", label);
    assert_signed_value(result.c, expected, "c", "cSign", label);
    assert_signed_value(result.d, expected, "d", "dSign", label);
}

fn assert_matrix_vector(vector: &Value, label: &str) {
    let inputs = object(vector, "inputs", label);
    let expected = object(vector, "expected", label);
    match string_field(vector, "op", label) {
        "inverse" => {
            let (r00, r01, r10, r11) = mat_inverse_2x2(
                i_field(inputs, "a00", label),
                i_field(inputs, "a01", label),
                i_field(inputs, "a10", label),
                i_field(inputs, "a11", label),
                i_field(inputs, "norm", label),
            )
            .expect("matrix inverse should not revert");
            assert_eq!(r00, i_field(expected, "r00", label), "{label}:r00");
            assert_eq!(r01, i_field(expected, "r01", label), "{label}:r01");
            assert_eq!(r10, i_field(expected, "r10", label), "{label}:r10");
            assert_eq!(r11, i_field(expected, "r11", label), "{label}:r11");
        }
        "matmul" => {
            let (r00, r01, r10, r11) = mat_mul_2x2(
                i_field(inputs, "a00", label),
                i_field(inputs, "a01", label),
                i_field(inputs, "a10", label),
                i_field(inputs, "a11", label),
                i_field(inputs, "b00", label),
                i_field(inputs, "b01", label),
                i_field(inputs, "b10", label),
                i_field(inputs, "b11", label),
                i_field(inputs, "norm", label),
            );
            assert_eq!(r00, i_field(expected, "r00", label), "{label}:r00");
            assert_eq!(r01, i_field(expected, "r01", label), "{label}:r01");
            assert_eq!(r10, i_field(expected, "r10", label), "{label}:r10");
            assert_eq!(r11, i_field(expected, "r11", label), "{label}:r11");
        }
        "mulvecmat" => {
            let (r0, r1) = vec_mat_2x2(
                i_field(inputs, "v0", label),
                i_field(inputs, "v1", label),
                i_field(inputs, "m00", label),
                i_field(inputs, "m01", label),
                i_field(inputs, "m10", label),
                i_field(inputs, "m11", label),
                i_field(inputs, "norm", label),
            );
            assert_eq!(r0, i_field(expected, "r0", label), "{label}:r0");
            assert_eq!(r1, i_field(expected, "r1", label), "{label}:r1");
        }
        "mulmatvec" => {
            let (r0, r1) = mat_vec_2x2(
                i_field(inputs, "m00", label),
                i_field(inputs, "m01", label),
                i_field(inputs, "m10", label),
                i_field(inputs, "m11", label),
                i_field(inputs, "v0", label),
                i_field(inputs, "v1", label),
                i_field(inputs, "norm", label),
            );
            assert_eq!(r0, i_field(expected, "r0", label), "{label}:r0");
            assert_eq!(r1, i_field(expected, "r1", label), "{label}:r1");
        }
        "scalar" => {
            let result = scalar_2x2(
                i_field(inputs, "v1_0", label),
                i_field(inputs, "v1_1", label),
                i_field(inputs, "v2_0", label),
                i_field(inputs, "v2_1", label),
                i_field(inputs, "norm", label),
            );
            assert_eq!(result, i_field(expected, "r", label), "{label}:r");
        }
        unsupported => panic!("{label}: unsupported matrix op `{unsupported}`"),
    }
}

fn assert_matrix_revert_vector(vector: &Value, label: &str) {
    let inputs = object(vector, "inputs", label);
    let result = mat_inverse_2x2(
        i_field(inputs, "a00", label),
        i_field(inputs, "a01", label),
        i_field(inputs, "a10", label),
        i_field(inputs, "a11", label),
        i_field(inputs, "norm", label),
    );
    assert!(result.is_err(), "{label}: expected matrix inverse revert");
}

fn assert_util_vector(vector: &Value, label: &str) {
    let inputs = object(vector, "inputs", label);
    let expected = object(vector, "expected", label);
    match string_field(vector, "op", label) {
        "signedSum" => {
            let (z, zs) = signed_sum(
                u_field(inputs, "x", label),
                bool_field(inputs, "xs", label),
                u_field(inputs, "y", label),
                bool_field(inputs, "ys", label),
            );
            assert_eq!(z, u_field(expected, "z", label), "{label}:z");
            assert_eq!(zs, bool_field(expected, "zs", label), "{label}:zs");
        }
        "signedSumToInt" => {
            let result = signed_sum_to_int(
                u_field(inputs, "x", label),
                bool_field(inputs, "xs", label),
                u_field(inputs, "y", label),
                bool_field(inputs, "ys", label),
            );
            assert_eq!(result, i_field(expected, "z", label), "{label}:z");
        }
        "diffAbs" => {
            let result = util_diff_abs(u_field(inputs, "x", label), u_field(inputs, "y", label));
            assert_eq!(result, u_field(expected, "z", label), "{label}:z");
        }
        "calcEMA" => {
            let result = calc_ema(
                u_field(inputs, "p", label),
                u_field(inputs, "spotP", label),
                u_field(inputs, "slipDecimals", label),
                u_field(inputs, "oldAverage", label),
                u_field(inputs, "emaParam", label),
            );
            assert_eq!(result, u_field(expected, "z", label), "{label}:z");
        }
        "divCeil" => {
            let result = div_ceil(i_field(inputs, "a", label), i_field(inputs, "b", label));
            assert_eq!(result, i_field(expected, "z", label), "{label}:z");
        }
        "clamp" => {
            let (z, zs) = clamp(
                u_field(inputs, "param", label),
                u_field(inputs, "minFR", label),
                u_field(inputs, "maxFR", label),
                u_field(inputs, "offset", label),
                bool_field(inputs, "sign", label),
            );
            assert_eq!(z, u_field(expected, "z", label), "{label}:z");
            assert_eq!(zs, bool_field(expected, "zs", label), "{label}:zs");
        }
        "reduceValue" => {
            let (new_a, remaining_b) = reduce_value(
                u_field(inputs, "a", label),
                u_field(inputs, "b", label),
            );
            assert_eq!(new_a, u_field(expected, "newA", label), "{label}:newA");
            assert_eq!(
                remaining_b,
                u_field(expected, "remainingB", label),
                "{label}:remainingB"
            );
        }
        "liquidityRemovalFee" => {
            let result = compute_liquidity_removal_fee(
                u_field(inputs, "stable", label),
                u_field(inputs, "asset", label),
                u_field(inputs, "iStable", label),
                u_field(inputs, "iAsset", label),
                u_field(inputs, "price", label),
                u_field(inputs, "oracleDecimals", label),
                u_field(inputs, "maxFee", label),
                u_field(inputs, "minFee", label),
                u_field(inputs, "feeK", label),
                u_field(inputs, "feeDecimals", label),
            );
            assert_eq!(result, u_field(expected, "z", label), "{label}:z");
        }
        "liquidityDepositFee" => {
            let result = compute_liquidity_deposit_fee(
                u_field(inputs, "stable", label),
                u_field(inputs, "asset", label),
                u_field(inputs, "iStable", label),
                u_field(inputs, "iAsset", label),
                u_field(inputs, "price", label),
                u_field(inputs, "oracleDecimals", label),
                u_field(inputs, "maxFee", label),
                u_field(inputs, "minFee", label),
                u_field(inputs, "feeK", label),
                u_field(inputs, "feeDecimals", label),
            );
            assert_eq!(result, u_field(expected, "z", label), "{label}:z");
        }
        unsupported => panic!("{label}: unsupported util op `{unsupported}`"),
    }
}

#[test]
fn solidity_newton_vectors_are_usable_as_rust_solver_corpus() {
    let cases = [
        (
            "short direct",
            "9998500000000000000000000",
            "10002970294039702990000000",
            signed("3071683137956642857142857142857142", true),
            signed("27713493364250000000000000000000000000000", false),
            signed("40000000000000000000000000000000000000000000000", false),
            "9999010002669525949832700",
            true,
        ),
        (
            "long direct",
            "6000000000000000000000",
            "162027001500027777777777777777777",
            signed("57628645699285714285714285714285714285", true),
            signed("328255692557142857142857142857142844285000", false),
            signed("139968000000000000000000000000000000000000000", false),
            "5999666666950319884356",
            true,
        ),
        (
            "inverse short",
            "100000000000000000000000",
            "19997000149997500000000000",
            signed("244655233308332583333333333333331", true),
            signed("6997203457166591666666666666666666684", true),
            signed("3166834987216669166666666666666649999166750", false),
            "100010000028301967018304",
            false,
        ),
        (
            "inverse long",
            "20000000000000000000000000",
            "9997000299990",
            signed("2333229984000299999999", true),
            signed("67998532770002999999999999900", false),
            signed("346665329000009999999999999333366670", true),
            "20001000010714400682285413",
            false,
        ),
    ];

    for (name, guess, a, b, c, d, solidity_expected, solidity_exact) in cases {
        let production = newton_cubic(dec(guess), dec(a), b, c, d);

        if solidity_exact {
            assert_eq!(production, dec(solidity_expected), "{name}");
        } else {
            assert_abs_diff(production, dec(solidity_expected), dec("10000000000"), name);
        }
    }
}

#[test]
fn inverse_long_coefficients_match_solidity_reference_case() {
    let oracle_dec = dec("100000000");
    let curve_dec = dec("100000000");
    let output_size = dec("10000000000000000000");
    let spot_price = dec("10000000000");
    let init_stable = dec("20000000000000000000000000");
    let init_asset = dec("100000000000000000000000");
    let param_a = dec("10000000000");
    let param_b = dec("200000000");
    let s = s();

    let sp = spot_price * s / oracle_dec;
    let x = init_asset - output_size;
    let x0 = init_asset;
    let y0 = init_stable;
    let a_prime =
        param_a * sp / s * sp / s * x0 / s * x0 / s * x0 / s * x0 / (x0 * sp / s + y0);
    let lambda = -(spot_price * (x0 - x) / oracle_dec + y0);
    let k = sp * x0 / s - y0;
    let a = x * x / x0 * x / x0 * s / x0 * s / x0;

    let t1 = a_prime * x / curve_dec * s / x0 * s / x0 * s / x0 * s / x0;
    let t2 = two() * x * x / x0 * x / x0 * k / s * s / x0 * s / x0;
    let t3 = two() * x * x / s * spot_price / oracle_dec * (param_b + curve_dec) / curve_dec
        * s
        / x0
        * s
        / x0;
    let t4_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let t4 = t4_1 * x / x0 * x / x0 * s / x0 * s / x0;
    let b = t1 + t2 - t3 + t4;

    let k_lam = k + lambda;
    let b_plus = param_b + curve_dec;
    let ct1 = a_prime * x / curve_dec * k_lam / x0 * s / x0 * s / x0 * s / x0;
    let ct2 = x0 * x0 / s * b_plus / curve_dec * b_plus / curve_dec * spot_price / oracle_dec
        * spot_price
        / oracle_dec
        * x
        / x0
        * s
        / x0;
    let ct3 = k * k / s * x / x0 * x / x0 * x / x0 * s / x0;
    let ct4 = two() * x * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s / x0
        * s
        / x0;
    let ct5_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let ct5 = two() * ct5_1 * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let ct6 =
        two() * x * b_plus / curve_dec * ct5_1 / s * spot_price / oracle_dec * s / x0 * s / x0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    let dt1 = x * a_prime / x0 * k / s * lambda / x0 * s / x0 * s / x0 * s / oracle_dec;
    let temp = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let dt2 = temp * b_plus / curve_dec * b_plus / curve_dec * spot_price / oracle_dec
        * spot_price
        / oracle_dec;
    let dt3 = temp * k / s * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let dt4 = two() * temp * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s
        / x0
        * s
        / x0;
    let d = dt1 + dt2 + dt3 - dt4;

    assert_eq!(a_prime, dec("333333333333333333333333333"), "aPrime");
    assert_eq!(lambda, -dec("20001000000000000000000000"), "lambda");
    assert_eq!(k, -dec("10000000000000000000000000"), "k");
    assert_eq!(a, dec("9997000299990"), "a");
    assert_eq!(b, dec("2333229984000299999999"), "b");
    assert_eq!(c, -dec("67998532770002999999999999900"), "c");
    assert_eq!(d, dec("346665329000009999999999990000000000"), "d");
}

#[test]
fn inverse_long_default_coefficients_match_solidity_reference_case() {
    let oracle_dec = dec("100000000");
    let curve_dec = dec("100000000");
    let output_size = dec("10000000000000000000");
    let spot_price = dec("300000000000");
    let init_stable = dec("10000000000000000000000000");
    let init_asset = dec("6000000000000000000000");
    let param_a = dec("100000000");
    let param_b = dec("10000000");
    let s = s();

    let sp = spot_price * s / oracle_dec;
    let x = init_asset - output_size;
    let x0 = init_asset;
    let y0 = init_stable;
    let a_prime =
        param_a * sp / s * sp / s * x0 / s * x0 / s * x0 / s * x0 / (x0 * sp / s + y0);
    let lambda = -(spot_price * (x0 - x) / oracle_dec + y0);
    let k = sp * x0 / s - y0;
    let a = x * x / x0 * x / x0 * s / x0 * s / x0;

    let t1 = a_prime * x / curve_dec * s / x0 * s / x0 * s / x0 * s / x0;
    let t2 = two() * x * x / x0 * x / x0 * k / s * s / x0 * s / x0;
    let t3 = two() * x * x / s * spot_price / oracle_dec * (param_b + curve_dec) / curve_dec
        * s
        / x0
        * s
        / x0;
    let t4_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let t4 = t4_1 * x / x0 * x / x0 * s / x0 * s / x0;
    let b = t1 + t2 - t3 + t4;

    let k_lam = k + lambda;
    let b_plus = param_b + curve_dec;
    let ct1 = a_prime * x / curve_dec * k_lam / x0 * s / x0 * s / x0 * s / x0;
    let ct2 = x0 * x0 / s * b_plus / curve_dec * b_plus / curve_dec * spot_price / oracle_dec
        * spot_price
        / oracle_dec
        * x
        / x0
        * s
        / x0;
    let ct3 = k * k / s * x / x0 * x / x0 * x / x0 * s / x0;
    let ct4 = two() * x * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s / x0
        * s
        / x0;
    let ct5_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let ct5 = two() * ct5_1 * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let ct6 =
        two() * x * b_plus / curve_dec * ct5_1 / s * spot_price / oracle_dec * s / x0 * s / x0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    let dt1 = x * a_prime / x0 * k / s * lambda / x0 * s / x0 * s / x0 * s / oracle_dec;
    let temp = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let dt2 = temp * b_plus / curve_dec * b_plus / curve_dec * spot_price / oracle_dec
        * spot_price
        / oracle_dec;
    let dt3 = temp * k / s * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let dt4 = two() * temp * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s
        / x0
        * s
        / x0;
    let d = dt1 + dt2 + dt3 - dt4;

    assert_eq!(a_prime, dec("41657142857142857142857"), "aPrime");
    assert_eq!(lambda, -dec("10030000000000000000000000"), "lambda");
    assert_eq!(k, dec("8000000000000000000000000"), "k");
    assert_eq!(a, dec("165834721450617"), "a");
    assert_eq!(b, -dec("3662636208994708994710"), "b");
    assert_eq!(c, dec("58676464851851851851851865256"), "c");
    assert_eq!(d, -dec("387392186426807760141090817283950617"), "d");
}

#[test]
fn direct_curve_functions_match_solidity_reference_cases() {
    let oracle_dec = dec("100000000");
    let curve_dec = dec("100000000");
    let stable = dec("10000000000000000000000000");
    let asset = dec("6000000000000000000000");
    let param_a = dec("100000000");
    let param_b = dec("10000000");

    let long_result = compute_long_return_inner(
        dec("1000000000000000000000"),
        dec("300000000000"),
        oracle_dec,
        dec("5999700000000000000000"),
        stable,
        asset,
        param_a,
        param_b,
        curve_dec,
    );
    assert_close(
        long_result,
        dec("333333049680115644"),
        dec("100000"),
        "computeLongReturn",
    );

    let short_result = compute_short_return_inner(
        dec("330000000000000000"),
        dec("300000000000"),
        oracle_dec,
        dec("9998500000000000000000000"),
        stable,
        asset,
        param_a,
        param_b,
        curve_dec,
    );
    assert_close(
        short_result,
        dec("989997330479323900000"),
        dec("100000"),
        "computeShortReturn",
    );
}

#[test]
fn exact_curve_functions_match_solidity_reference_cases() {
    let oracle_dec = dec("100000000");
    let curve_dec = dec("100000000");
    let stable = dec("10000000000000000000000000");
    let asset = dec("6000000000000000000000");
    let param_a = dec("100000000");
    let param_b = dec("10000000");

    let exact_long = compute_exact_in_long_inner(
        dec("10000000000000000000"),
        dec("300000000000"),
        oracle_dec,
        dec("10030000000000000000000000"),
        stable,
        asset,
        param_a,
        param_b,
        curve_dec,
    );
    assert_close(
        exact_long,
        dec("30000000000000000000000"),
        dec("10000"),
        "computeExactAmountInLong",
    );

    let exact_short = compute_exact_in_short_inner(
        dec("1000000000000000000000"),
        dec("10000000000"),
        oracle_dec,
        dec("6010000000000000000000"),
        stable,
        asset,
        param_a,
        param_b,
        curve_dec,
    );
    assert_close(
        exact_short,
        dec("10000000000000000000"),
        dec("10000"),
        "computeExactAmountInShort",
    );
}
