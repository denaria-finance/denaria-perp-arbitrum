// SPDX-License-Identifier: BUSL-1.1

//! # CurveMath - Stylus (Rust/WASM) port
//!
//! ## Porting notes
//!
//! In Solidity, `uint256` forces tracking the sign separately via `bool`.
//! Every difference uses `diffAbs`, every signed addition uses `signedSum`,
//! and the Newton solver has 8 branches (2^3 sign combinations of b, c, d).
//!
//! In Rust with native `I256` (signed 256-bit), the sign is embedded in the
//! type for coefficient construction. The Newton solver still mirrors the
//! Solidity sign branches because its zero-clamping behavior and truncation
//! order are observable for some coefficient sets.
//!

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![allow(clippy::too_many_arguments)]
#[cfg(feature = "standalone-abi")]
extern crate alloc;

use stylus_sdk::alloy_primitives::{I256, U256};
// The Stylus prelude (StorageType, #[public]/#[entrypoint] machinery) is only
// needed for the standalone-abi build; the pure math below does not use it.
#[cfg(feature = "standalone-abi")]
use stylus_sdk::prelude::*;

// -----------------------------------------------------------------------
// Constants & helpers
// -----------------------------------------------------------------------

const SCALE: I256 = I256::from_limbs([1_000_000_000_000_000_000u64, 0, 0, 0]); // 1e18
const TWO: I256 = I256::from_limbs([2u64, 0, 0, 0]);
const THREE: I256 = I256::from_limbs([3u64, 0, 0, 0]);
const CONVERGENCE_THRESHOLD: I256 = I256::from_limbs([10_000_000_000u64, 0, 0, 0]); // 1e10

pub fn s() -> I256 {
    SCALE
}
pub fn two() -> I256 {
    TWO
}
fn three() -> I256 {
    THREE
}

pub fn i(v: U256) -> I256 {
    match I256::try_from(v) {
        Ok(value) => value,
        Err(_) => panic!("I256"),
    }
}
pub fn u(v: I256) -> U256 {
    match U256::try_from(v) {
        Ok(value) => value,
        Err(_) => panic!("U256"),
    }
}
/// `max(v, 0)` as `U256`. Mirrors the Solidity `v > 0 ? uint256(v) : 0` clamp: a
/// non-positive signed value maps to `0` instead of reverting the way [`u`] does on a
/// negative input. Used to clamp signed LP-recovery legs to the pool floor before the
/// global cap, so an ill-conditioned matrix cannot revert the balance read.
pub fn u_or_zero(v: I256) -> U256 {
    if v > I256::ZERO {
        u(v)
    } else {
        U256::ZERO
    }
}

/// `(a*b)/c` in U256, outlined behind `#[inline(never)]` so the inlined expansion is
/// emitted once instead of at every call site. Uses the same `*` and `/` operators in the
/// same order as the inline form it replaces, so its overflow and truncation behavior is
/// bit-identical — preserving Solidity parity at every replaced site.
#[inline(never)]
pub fn md(a: U256, b: U256, c: U256) -> U256 {
    a * b / c
}

/// `ceil(a*b/c)`. Bit-exact with OZ `Math.mulDiv(a, b, c, Math.Rounding.Ceil)` whenever the
/// product `a*b` fits in 256 bits — the same non-overflow assumption [`md`] already relies on.
#[inline(never)]
pub fn md_ceil(a: U256, b: U256, c: U256) -> U256 {
    let p = a * b;
    let q = p / c;
    if p % c != U256::ZERO {
        q + U256::from(1u64)
    } else {
        q
    }
}

fn signed_parts(v: I256) -> (I256, bool) {
    if v < I256::ZERO {
        (-v, false)
    } else {
        (v, true)
    }
}

fn diff_abs(lhs: I256, rhs: I256) -> (I256, bool) {
    if lhs >= rhs {
        (lhs - rhs, true)
    } else {
        (rhs - lhs, false)
    }
}

fn apply_newton_step(
    x_prev: I256,
    fx: I256,
    fx_sign: bool,
    fpx: I256,
    fpx_sign: bool,
    require_positive_subtraction: bool,
) -> I256 {
    let step = fx * SCALE / fpx;
    if fx_sign == fpx_sign {
        if x_prev > step {
            x_prev - step
        } else {
            assert!(!require_positive_subtraction, "NM1");
            I256::ZERO
        }
    } else {
        x_prev + step
    }
}

// -----------------------------------------------------------------------
// Newton solver - mirrors Solidity sign branches and truncation order
// -----------------------------------------------------------------------

/// Solves `a*x^3 + b*x^2 + c*x + d = 0` via Newton's method.
///
/// Solidity: `newtonMethodCubic` (lines 1087-1274).
pub fn newton_cubic(guess: I256, a: I256, b: I256, c: I256, d: I256) -> I256 {
    let s = SCALE;
    let (b, b_sign) = signed_parts(b);
    let (c, c_sign) = signed_parts(c);
    let (d, d_sign) = signed_parts(d);
    let mut x = guess;

    for _ in 0u32..255 {
        let x_prev = x;

        // Fixed-point powers and reusable terms match Solidity assembly.
        let x2 = x * x / s;
        let x3 = x2 * x / s;
        let ax2 = a * x2 / s;
        let ax3 = a * x3 / s;
        let bx2 = b * x2 / s;
        let bx = b * x_prev / s;
        let cx = c * x_prev / s;

        x = if b_sign && c_sign && d_sign {
            let fx = ax3 + bx2 + cx + d;
            let fpx = THREE * ax2 + TWO * bx + c;
            apply_newton_step(x_prev, fx, true, fpx, true, true)
        } else if b_sign && !c_sign && d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + bx2 + d, cx);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2 + TWO * bx, c);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, false)
        } else if !b_sign && c_sign && d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + cx + d, bx2);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2 + c, TWO * bx);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, true)
        } else if !b_sign && !c_sign && d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + d, bx2 + cx);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2, TWO * bx + c);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, false)
        } else if b_sign && c_sign && !d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + bx2 + cx, d);
            let fpx = THREE * ax2 + TWO * bx + c;
            apply_newton_step(x_prev, fx, fx_sign, fpx, true, false)
        } else if b_sign && !c_sign && !d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + bx2, d + cx);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2 + TWO * bx, c);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, false)
        } else if !b_sign && c_sign && !d_sign {
            let (fx, fx_sign) = diff_abs(ax3 + cx, d + bx2);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2 + c, TWO * bx);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, false)
        } else {
            let (fx, fx_sign) = diff_abs(ax3, d + bx2 + cx);
            let (fpx, fpx_sign) = diff_abs(THREE * ax2, TWO * bx + c);
            apply_newton_step(x_prev, fx, fx_sign, fpx, fpx_sign, false)
        };

        // Convergence check (same threshold as Solidity: 1e10)
        let diff = if x > x_prev { x - x_prev } else { x_prev - x };
        if diff <= CONVERGENCE_THRESHOLD {
            return x;
        }
    }
    panic!("NM2"); // Did not converge - same error as Solidity
}

/// Signed Newton solver for coefficients already constructed by the Rust port.
///
/// This is used by the four high-level curve functions. The public
/// `newton_method_cubic` ABI keeps using `newton_cubic` above because standalone
/// callers pass Solidity-style magnitude/sign pairs and can observe the original
/// branch-specific zero-clamping behavior.
fn newton_cubic_signed(guess: I256, a: I256, b: I256, c: I256, d: I256) -> I256 {
    let s = SCALE;
    let three_a = THREE * a;
    let two_b = TWO * b;
    let mut x = guess;

    for _ in 0u32..255 {
        let x_prev = x;
        let x2 = x * x / s;
        let x3 = x2 * x / s;
        let fx = a * x3 / s + b * x2 / s + c * x / s + d;
        let fpx = three_a * x2 / s + two_b * x / s + c;

        x = x_prev - fx * s / fpx;

        let diff = if x > x_prev { x - x_prev } else { x_prev - x };
        if diff <= CONVERGENCE_THRESHOLD {
            return x;
        }
    }
    panic!("NM2");
}

// -----------------------------------------------------------------------
// Direct cubic coefficients - Long (whitepaper eq. 26)
// Maps to: computeLongReturn (Solidity lines 797-849)
// -----------------------------------------------------------------------

/// Computes vAsset output for `size` vStable input (long trade).
pub fn compute_long_return_inner(
    size: I256,       // dy vStable input
    spot_price: I256, // p (oracle price)
    oracle_dec: I256, // oracle decimals (typ. 1e8)
    initial_guess: I256,
    init_stable: I256, // y0 = globalLiquidityStable
    init_asset: I256,  // x0 = globalLiquidityAsset
    param_a: I256,     // longCurveParameterA
    param_b: I256,     // longCurveParameterB
    curve_dec: I256,   // curveParameterDecimals (typ. 1e8)
) -> I256 {
    let s = s();

    // -- lambda = p*x0/oracleDec + size  (Solidity line 55)
    let lambda = spot_price * init_asset / oracle_dec + size;

    // -- x0^2  (Solidity line 62)
    let x_sq = init_asset * init_asset / s;

    // -- a = lambda^3/x0^2  (Solidity lines 71-72)
    let a = lambda * lambda / s * lambda / x_sq;

    // -- b: line-by-line match with computeLongB (lines 103-125) --
    let sp = spot_price * s / oracle_dec; // spotScaled (line 105)
    let sp2 = sp * sp / s; // (line 108)
    let sp3 = sp2 * sp / s; // (line 109)
    let n1 = x_sq * sp3 / s; // (line 110)
    let num = param_a * lambda / curve_dec * n1 / s; // (lines 113-114)
    let den = sp * init_asset / s + init_stable; // (line 117)
    let b1 = num * s / den; // (line 120)
    let lambda_sq = lambda * lambda / s; // (line 123)
    let factor_2b3 = two() * param_b + three() * curve_dec; // (line 124)
    let b2 = lambda_sq * sp / s * factor_2b3 / curve_dec; // (line 125)
    let b = b1 - b2; // <- replaces diffAbs + bSign (lines 128-134)

    // -- c: matches computeLongC (lines 168-186) --
    let p_scaled = sp; // same variable
    let b_plus = (param_b + curve_dec) * s / curve_dec; // bPlusScaled (line 169)

    // c2 = x0^2*p^2*(B+1)*((B+1)+2)  (line 171)
    let c2 = x_sq * p_scaled / s * p_scaled / s * b_plus / s * (b_plus + two() * s) / s;

    // c1: the difference (dy - p*x0) is signed with I256 - no branching needed!
    let init_asset_val = p_scaled * init_asset / s; // (line 173)
                                                    // Math formula: c1_term = A*p^2*x0^2*(dy - p*x0) / (p*x0 + y0)
                                                    // The sign of (size - init_asset_val) determines c1's sign.
    let signed_diff = size - init_asset_val;
    let c1 = x_sq * param_a / curve_dec * p_scaled / s * p_scaled / s * signed_diff
        / (init_asset_val + init_stable); // nom/den (lines 176-178)

    // In Solidity: positiveCase -> c = lambda(c2-c1)/s, else c = lambda(c1+c2)/s.
    // With I256: c1 is already signed, so c = lambda*(c1+c2)/s works for both cases.
    // Solidity computes c1 with |diff| then inverts the sign in positiveCase.
    // Here c1 already carries the correct sign via signed_diff.
    let c = lambda * (c1 + c2) / s;

    // -- d = -p^3*x0^4*(B+1)^2  (lines 210-214, always negative) --
    let d = -(x_sq * p_scaled / s * p_scaled / s * p_scaled / s * init_asset / s * init_asset / s
        * b_plus
        / s
        * b_plus
        / s);

    // -- Solve & return --
    let new_asset = newton_cubic_signed(initial_guess, a, b, c, d);
    init_asset - new_asset // outputSize (line 849)
}

// -----------------------------------------------------------------------
// Direct cubic coefficients - Short (whitepaper eq. 23)
// Maps to: computeShortReturn (Solidity lines 864-912)
// -----------------------------------------------------------------------

pub fn compute_short_return_inner(
    size: I256, // dx vAsset input
    spot_price: I256,
    oracle_dec: I256,
    initial_guess: I256,
    init_stable: I256, // y0
    init_asset: I256,  // x0
    param_a: I256,
    param_b: I256,
    curve_dec: I256,
) -> I256 {
    let s = s();

    // -- lambda = p*size/oracleDec + y0  (line 236)
    let lambda = spot_price * size / oracle_dec + init_stable;

    // -- y0^2  (line 243)
    let y_sq = init_stable * init_stable / s;

    // -- a = lambda^3/y0^2  (reuses computeA)
    let a = lambda * lambda / s * lambda / y_sq;

    // -- b: matches computeShortB (lines 274-278) --
    let den = spot_price * init_asset / oracle_dec + init_stable;
    let b1 = y_sq * param_a / curve_dec * lambda / den; // (lines 274-275)
    let b2 = lambda * lambda / s * (two() * param_b + three() * curve_dec) / curve_dec; // (lines 276-277)
    let b = b1 - b2; // <- replaces diffAbs (line 278)

    // -- c: matches computeShortC (lines 311-344) --
    let p_sum = param_b + curve_dec; // pSum (line 314)
    let part = y_sq * p_sum / curve_dec; // (line 315)
    let c2 = part * p_sum / curve_dec + two() * part; // (line 318)

    let sp_size = spot_price * size / oracle_dec; // (line 320)
    let denom = spot_price * init_asset / oracle_dec + init_stable; // (line 321)
    let base = y_sq * param_a / curve_dec; // (line 323)

    // Whitepaper eq. 23: the term is (p*dx - y0) = (sp_size - init_stable).
    // In Solidity: stableGT branch computes |y0 - p*dx| with separate sign.
    // With I256: the sign is embedded in the difference.
    let signed_diff = sp_size - init_stable;
    let c1 = base * signed_diff / denom;
    // c = lambda(c1 + c2)/s  - unified, no stableGT branch
    let c = lambda * (c1 + c2) / s;

    // -- d = -y0^4*(B+1)^2  (lines 362-363, always negative) --
    let b_plus = (param_b + curve_dec) * s / curve_dec;
    let d = -(y_sq * y_sq / s * b_plus / s * b_plus / s);

    // -- Solve & return --
    let new_stable = newton_cubic_signed(initial_guess, a, b, c, d);
    init_stable - new_stable // outputSize (line 912)
}

// -----------------------------------------------------------------------
// Inverse cubic coefficients - Long (whitepaper eq. 28)
// Maps to: computeExactAmountInLong (Solidity lines 926-991)
// -----------------------------------------------------------------------

/// Inverse-long cubic coefficients, extracted so parity tests can check them
/// against Solidity's granular computeAPrimePramLong / computeInverse*Long.
/// Returns `(a_prime, lambda, k, a, b, c, d)` as signed `I256` (sign embedded).
pub fn inverse_long_coefficients(
    output_size: I256,
    spot_price: I256,
    oracle_dec: I256,
    init_stable: I256,
    init_asset: I256,
    param_a: I256,
    param_b: I256,
    curve_dec: I256,
) -> (I256, I256, I256, I256, I256, I256, I256) {
    let s = s();
    let sp = spot_price * s / oracle_dec;
    let x = init_asset - output_size;
    let x0 = init_asset;
    let y0 = init_stable;

    // A' = A*p^2*x0^4 / (p*x0+y0)  (lines 570-584)
    let a_prime = param_a * sp / s * sp / s * x0 / s * x0 / s * x0 / s * x0 / (x0 * sp / s + y0);

    // lambda = -(p*(x0-x)/oracleDec + y0)  (lines 596-609, sign=false in Solidity)
    let lambda = -(spot_price * (x0 - x) / oracle_dec + y0);

    // k = p*x0/oracleDec - y0  (Solidity computeInverseKLong, lines 619-631).
    // Use the raw price / oracle_dec directly, NOT the pre-scaled `sp`. Solidity
    // computes `p*x0/oracleDec`, which equals `sp*x0/s` only when oracleDec
    // divides 1e18 exactly; routing k through `sp` diverged for non-divisor
    // oracle decimals (caught by a golden vector with oracleDec=99999999).
    // `a_prime` keeps using `sp` because Solidity's computeAPrimePramLong scales
    // the price first (scaledP), so that path stays bit-exact.
    let k = spot_price * x0 / oracle_dec - y0;

    // a = x^3/x0^4  (lines 638-641)
    let a = x * x / x0 * x / x0 * s / x0 * s / x0;

    // b - (lines 656-681) - 4 terms with signedSum -> direct with I256
    let t1 = a_prime * x / curve_dec * s / x0 * s / x0 * s / x0 * s / x0;
    let t2 = two() * x * x / x0 * x / x0 * k / s * s / x0 * s / x0;
    let t3 = two() * x * x / s * spot_price / oracle_dec * (param_b + curve_dec) / curve_dec * s
        / x0
        * s
        / x0;
    let t4_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let t4 = t4_1 * x / x0 * x / x0 * s / x0 * s / x0;
    let b = t1 + t2 - t3 + t4;

    // c - (lines 699-736) - 6 terms
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
    let ct4 =
        two() * x * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s / x0 * s / x0;
    let ct5_1 = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let ct5 = two() * ct5_1 * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let ct6 =
        two() * x * b_plus / curve_dec * ct5_1 / s * spot_price / oracle_dec * s / x0 * s / x0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    // d - (lines 753-782) - 4 terms
    let dt1 = x * a_prime / x0 * k / s * lambda / x0 * s / x0 * s / x0 * s / oracle_dec;
    let temp = k * x / s - spot_price * x0 / oracle_dec * x0 / s;
    let dt2 = temp * b_plus / curve_dec * b_plus / curve_dec * spot_price / oracle_dec * spot_price
        / oracle_dec;
    let dt3 = temp * k / s * k / s * x / x0 * x / x0 * s / x0 * s / x0;
    let dt4 = two() * temp * x / s * b_plus / curve_dec * spot_price / oracle_dec * k / s * s / x0
        * s
        / x0;
    let d = dt1 + dt2 + dt3 - dt4;

    (a_prime, lambda, k, a, b, c, d)
}

pub fn compute_exact_in_long_inner(
    output_size: I256,
    spot_price: I256,
    oracle_dec: I256,
    initial_guess: I256,
    init_stable: I256,
    init_asset: I256,
    param_a: I256,
    param_b: I256,
    curve_dec: I256,
) -> I256 {
    let (_a_prime, _lambda, _k, a, b, c, d) = inverse_long_coefficients(
        output_size,
        spot_price,
        oracle_dec,
        init_stable,
        init_asset,
        param_a,
        param_b,
        curve_dec,
    );
    let new_stable = newton_cubic_signed(initial_guess, a, b, c, d);
    new_stable - init_stable // (line 991)
}

// -----------------------------------------------------------------------
// Inverse cubic coefficients - Short (whitepaper eq. 27)
// Maps to: computeExactAmountInShort (Solidity lines 1005-1071)
// -----------------------------------------------------------------------

/// Inverse-short cubic coefficients, extracted so parity tests can check them
/// against Solidity's granular computeAPrimePramShort / computeInverse*Short.
/// Returns `(a_prime, lambda, k, a, b, c, d)` as signed `I256` (sign embedded).
pub fn inverse_short_coefficients(
    output_size: I256,
    spot_price: I256,
    oracle_dec: I256,
    init_stable: I256,
    init_asset: I256,
    param_a: I256,
    param_b: I256,
    curve_dec: I256,
) -> (I256, I256, I256, I256, I256, I256, I256) {
    let s = s();
    let p = spot_price;
    let y = init_stable - output_size;
    let y0 = init_stable;
    let px0 = p * init_asset / oracle_dec;

    // A' = A*y0^4/(px0+y0)  (lines 372-374)
    let a_prime = param_a * y0 / s * y0 / s * y0 / s * y0 / (px0 + y0);

    // lambda = y - y0 - px0  (lines 384-393)
    let lambda = y - y0 - px0;

    // k = y0 - px0  (lines 402-410)
    let k = y0 - px0;

    // a = y^3/y0^4  (lines 418-419)
    let a = y * y / y0 * y / y0 * s / y0 * s / y0;

    // b - (lines 435-459) - 4 terms
    let bt1 = a_prime * y / curve_dec * s / y0 * s / y0 * s / y0 * s / y0 * oracle_dec / p;
    let bt2 = two() * y * y / y0 * y / y0 * oracle_dec / p * k / y0 * s / y0;
    let bt3 = two() * y * (param_b + curve_dec) / curve_dec * y / y0 * s / y0 * oracle_dec / p;
    let bt4_1 = k * y - y0 * y0;
    let bt4 = bt4_1 / s * y / y0 * y / y0 * s / y0 * s / y0 * oracle_dec / p;
    let b = bt1 + bt2 - bt3 + bt4;

    // c - (lines 477-511) - 6 terms
    let k_lam = k + lambda;
    let b_plus = param_b + curve_dec;
    let ct1 = a_prime * s / curve_dec * y / y0 * k_lam / y0 * s / y0 * s / y0 * oracle_dec / p
        * oracle_dec
        / p;
    let ct2 = y * b_plus / curve_dec * b_plus / curve_dec * oracle_dec / p * oracle_dec / p;
    let ct3 = k * k / y0 * y / y0 * y / y0 * y / y0 * oracle_dec / p * oracle_dec / p;
    let ct4 = two() * y * y / y0 * b_plus / curve_dec * k / y0 * oracle_dec / p * oracle_dec / p;
    let ct5_1 = k * y / s - y0 * y0 / s;
    let ct5 =
        two() * k * y / y0 * y / y0 * ct5_1 / s * oracle_dec / p * oracle_dec / p * s / y0 * s / y0;
    let ct6 = two() * y * b_plus / curve_dec * ct5_1 / s * oracle_dec / p * oracle_dec / p * s / y0
        * s
        / y0;
    let c = ct1 + ct2 + ct3 - ct4 + ct5 - ct6;

    // d - (lines 528-559) - 4 terms
    let dt1 = y * s / y0 * a_prime / curve_dec * s / y0 * k / y0 * lambda / y0 * oracle_dec / p
        * oracle_dec
        / p
        * oracle_dec
        / p;
    let temp = k * y / s - y0 * y0 / s;
    let dt2 = temp * b_plus / curve_dec * b_plus / curve_dec * oracle_dec / p * oracle_dec / p
        * oracle_dec
        / p;
    let dt3 =
        temp * k / y0 * k / y0 * y / y0 * y / y0 * oracle_dec / p * oracle_dec / p * oracle_dec / p;
    let dt4 = two() * temp * b_plus / curve_dec * y / y0 * k / y0 * oracle_dec / p * oracle_dec / p
        * oracle_dec
        / p;
    let d = dt1 + dt2 + dt3 - dt4;

    (a_prime, lambda, k, a, b, c, d)
}

pub fn compute_exact_in_short_inner(
    output_size: I256,
    spot_price: I256,
    oracle_dec: I256,
    initial_guess: I256,
    init_stable: I256,
    init_asset: I256,
    param_a: I256,
    param_b: I256,
    curve_dec: I256,
) -> I256 {
    let (_a_prime, _lambda, _k, a, b, c, d) = inverse_short_coefficients(
        output_size,
        spot_price,
        oracle_dec,
        init_stable,
        init_asset,
        param_a,
        param_b,
        curve_dec,
    );
    let new_asset = newton_cubic_signed(initial_guess, a, b, c, d);
    new_asset - init_asset // (line 1070)
}

// -----------------------------------------------------------------------
// MatrixMath internal helpers — bit-exact ports of src/util/MatrixMath.sol.
// Free functions (engine-reusable); the public ABI methods below delegate.
// Matrices are row-major flat: [m00, m01, m10, m11].
// -----------------------------------------------------------------------

/// (A x B) / norm. Solidity `matMulTwoByTwo`.
pub fn mat_mul_2x2(
    a00: I256, a01: I256, a10: I256, a11: I256,
    b00: I256, b01: I256, b10: I256, b11: I256,
    norm: I256,
) -> (I256, I256, I256, I256) {
    (
        (a00 * b00 + a01 * b10) / norm,
        (a00 * b01 + a01 * b11) / norm,
        (a10 * b00 + a11 * b10) / norm,
        (a10 * b01 + a11 * b11) / norm,
    )
}

/// Inverse of a 2x2 matrix. Bit-exact port of Solidity `inverseTwoByTwo`:
/// it computes the determinant generally and DIVIDES by it (it does NOT assume
/// determinant 1), and reverts on a zero determinant — the bare adjugate
/// `(a11, -a01, -a10, a00)` would match Solidity only when the normalized
/// determinant is exactly 1.
pub fn mat_inverse_2x2(
    a00: I256, a01: I256, a10: I256, a11: I256,
    norm: I256,
) -> Result<(I256, I256, I256, I256), Vec<u8>> {
    let det = (a00 * a11 - a10 * a01) / norm;
    if det == I256::ZERO {
        return Err(b"Error on inverseTwoByTwo: determinant is 0".to_vec());
    }
    Ok((
        a11 * norm / det,
        -a01 * norm / det,
        -a10 * norm / det,
        a00 * norm / det,
    ))
}

/// v x M / norm. Solidity `mulVecMatTwoByTwo`.
pub fn vec_mat_2x2(
    v0: I256, v1: I256, m00: I256, m01: I256, m10: I256, m11: I256, norm: I256,
) -> (I256, I256) {
    ((v0 * m00 + v1 * m10) / norm, (v0 * m01 + v1 * m11) / norm)
}

/// M x v / norm. Solidity `mulMatVecTwoByTwo`.
pub fn mat_vec_2x2(
    m00: I256, m01: I256, m10: I256, m11: I256, v0: I256, v1: I256, norm: I256,
) -> (I256, I256) {
    ((v0 * m00 + v1 * m01) / norm, (v0 * m10 + v1 * m11) / norm)
}

/// v1 . v2 / norm. Solidity `scalarTwoByTwo`.
pub fn scalar_2x2(v1_0: I256, v1_1: I256, v2_0: I256, v2_1: I256, norm: I256) -> I256 {
    (v1_0 * v2_0 + v1_1 * v2_1) / norm
}

// -----------------------------------------------------------------------
// UtilMath signed helpers — bit-exact ports of src/util/UtilMath.sol.
// The engine carries signed quantities as native I256, so signed_sum_to_int
// is the primary form; signed_sum reproduces Solidity's (magnitude, sign)
// pair exactly, including the sign assigned to a zero result.
// -----------------------------------------------------------------------

// UtilMath helpers consumed by the engine; dead_code allowed for the
// standalone (engine-less) build.
/// |x - y|. Solidity `UtilMath.diffAbs`.
#[allow(dead_code)]
pub fn util_diff_abs(x: U256, y: U256) -> U256 {
    if x >= y {
        x - y
    } else {
        y - x
    }
}

/// z = x + y over (magnitude, sign) pairs. Solidity `UtilMath.signedSum`
/// (Yul). Same-sign reverts "SS1" on magnitude overflow (matches the Solidity
/// `require`); for differing signs zSign = (x > y) == signX, so a zero result
/// inherits sign `!signX` when x <= y — preserved here for bit-exactness.
#[allow(dead_code)]
pub fn signed_sum(x: U256, sign_x: bool, y: U256, sign_y: bool) -> (U256, bool) {
    if sign_x == sign_y {
        (x.checked_add(y).expect("SS1"), sign_x)
    } else if x > y {
        (x - y, sign_x)
    } else {
        (y - x, !sign_x)
    }
}

/// z = x + y as a signed I256. Solidity `UtilMath.signedSumToInt`.
#[allow(dead_code)]
pub fn signed_sum_to_int(x: U256, sign_x: bool, y: U256, sign_y: bool) -> I256 {
    let (magnitude, sign) = signed_sum(x, sign_x, y, sign_y);
    let z = i(magnitude);
    if sign {
        z
    } else {
        -z
    }
}

// -----------------------------------------------------------------------
// UtilMath pure helpers used by the funding + trade paths. Bit-exact ports
// of src/util/UtilMath.sol; dead_code allowed for the standalone build.
// -----------------------------------------------------------------------

/// |p - spotP| * decimals / spotP. Solidity `UtilMath.calcSlip`.
#[allow(dead_code)]
pub fn calc_slip(p: U256, spot_p: U256, decimals: U256) -> U256 {
    md(util_diff_abs(p, spot_p), decimals, spot_p)
}

/// EMA update. Solidity `UtilMath.calcEMA`:
/// `oldAverage*emaParam/slipDecimals + slip*(slipDecimals - emaParam)/slipDecimals`.
#[allow(dead_code)]
pub fn calc_ema(p: U256, spot_p: U256, slip_decimals: U256, old_average: U256, ema_param: U256) -> U256 {
    let slip = calc_slip(p, spot_p, slip_decimals);
    md(old_average, ema_param, slip_decimals) + md(slip, slip_decimals - ema_param, slip_decimals)
}

/// Ceil-division of signed integers. Solidity `UtilMath.divCeil` (Yul): adds 1
/// to the truncated quotient only when there is a remainder AND the operands
/// share a sign (so it rounds toward +inf for same-sign, toward zero otherwise).
#[allow(dead_code)]
pub fn div_ceil(a: I256, b: I256) -> I256 {
    let q = a / b;
    let has_rem = (a % b) != I256::ZERO;
    let same_sign = (a < I256::ZERO) == (b < I256::ZERO);
    if has_rem && same_sign {
        q + I256::ONE
    } else {
        q
    }
}

/// Funding-rate clamp. Solidity `UtilMath.clamp` (ClampParameters passed flat as
/// min_fr/max_fr/offset, matching the engine's flattened storage).
#[allow(dead_code)]
pub fn clamp(funding_rate_parameter: U256, min_fr: U256, max_fr: U256, offset: U256, sign: bool) -> (U256, bool) {
    if funding_rate_parameter > max_fr {
        if sign {
            (max_fr, true)
        } else {
            signed_sum(max_fr, false, offset, true)
        }
    } else if funding_rate_parameter < min_fr {
        if sign {
            (min_fr, true)
        } else {
            signed_sum(min_fr, false, offset, true)
        }
    } else if sign {
        (funding_rate_parameter, true)
    } else {
        signed_sum(funding_rate_parameter, false, offset, true)
    }
}

/// Reduce `a` by `b`: returns `(max(a-b,0), max(b-a,0))`. Solidity
/// `UtilMath.reduceValue` (used by `_removeLiquidity` to repay LP debt before
/// crediting balances). Saturating, matching the Yul `unchecked` branches.
#[allow(dead_code)]
pub fn reduce_value(a: U256, b: U256) -> (U256, U256) {
    if a < b {
        (U256::ZERO, b - a)
    } else {
        (a - b, U256::ZERO)
    }
}

/// Liquidity-removal fee. Bit-exact port of `FeeManager.computeLiquidityRemovalFee`
/// (pure). `ratioDecimals` is the Solidity literal `1e18`. Returns the fee in
/// `liquidityFeeDecimals` units. All intermediate divisions truncate toward zero
/// exactly as the Solidity `unchecked`-free arithmetic does (the original is not
/// `unchecked`, so it would revert on overflow; U256 ops here panic on overflow,
/// matching that revert semantics).
#[allow(dead_code)]
#[allow(clippy::too_many_arguments)]
pub fn compute_liquidity_removal_fee(
    stable_liquidity: U256,
    asset_liquidity: U256,
    initial_stable_liquidity: U256,
    initial_asset_liquidity: U256,
    price: U256,
    oracle_decimals: U256,
    liquidity_max_fee: U256,
    liquidity_min_fee: U256,
    liquidity_fee_k: U256,
    liquidity_fee_decimals: U256,
) -> U256 {
    if liquidity_max_fee == U256::ZERO {
        return U256::ZERO;
    }
    // A fully one-sided pool (one side entirely removed) has no meaningful removal fee; waive it
    // before the fee curve, which otherwise divides through the zeroed side. The deposit fee
    // already carries this guard.
    if initial_stable_liquidity == U256::ZERO || initial_asset_liquidity == U256::ZERO {
        return U256::ZERO;
    }
    let ratio_decimals = U256::from(10u64).pow(U256::from(18u64)); // 1e18
    let ten_e18 = U256::from(10u64) * ratio_decimals; // 10e18
    // Fees waived if almost no liquidity is left in the pool.
    if (initial_stable_liquidity - stable_liquidity) < ten_e18
        && (initial_asset_liquidity - asset_liquidity) < md(ten_e18, oracle_decimals, price)
    {
        return U256::ZERO;
    }
    let p;
    let p_prime;
    let p_second;
    if md(initial_stable_liquidity, ratio_decimals, initial_asset_liquidity)
        > md(price, ratio_decimals, oracle_decimals)
    {
        if initial_asset_liquidity == asset_liquidity {
            return liquidity_max_fee;
        }
        p = md(price, ratio_decimals, oracle_decimals);
        p_prime = md(initial_stable_liquidity, ratio_decimals, initial_asset_liquidity);
        p_second = md(
            initial_stable_liquidity - stable_liquidity,
            ratio_decimals,
            initial_asset_liquidity - asset_liquidity,
        );
    } else {
        if initial_stable_liquidity == stable_liquidity {
            return U256::ZERO; // last LP leaving pays no fee
        }
        p = md(ratio_decimals, oracle_decimals, price);
        p_prime = md(initial_asset_liquidity, ratio_decimals, initial_stable_liquidity);
        p_second = md(
            initial_asset_liquidity - asset_liquidity,
            ratio_decimals,
            initial_stable_liquidity - stable_liquidity,
        );
    }
    if p_second < p_prime && p_second > p {
        return liquidity_min_fee;
    }
    let rel_price_diff1_sq =
        md(md(util_diff_abs(p_prime, p), util_diff_abs(p_prime, p), p), ratio_decimals, p);
    let rel_price_diff2_sq =
        md(md(util_diff_abs(p_second, p), util_diff_abs(p_second, p), p), ratio_decimals, p);
    let num = md(
        md(
            md(liquidity_min_fee, liquidity_fee_decimals, liquidity_max_fee),
            liquidity_fee_k,
            liquidity_fee_decimals,
        ),
        ratio_decimals + rel_price_diff1_sq,
        ratio_decimals,
    ) + md(rel_price_diff2_sq, liquidity_fee_decimals, ratio_decimals);
    let den = md(liquidity_fee_k, ratio_decimals + rel_price_diff1_sq, ratio_decimals)
        + md(rel_price_diff2_sq, liquidity_fee_decimals, ratio_decimals);
    md(num, liquidity_max_fee, den)
}

/// Liquidity-DEPOSIT fee. Bit-exact port of `FeeManager.computeLiquidityDepositFee`
/// (pure). DISTINCT from the removal fee: empty-pool / maxFee==0 short-circuits to 0
/// (no "fees-waived near-empty" check, no maxFee/minFee corner sub-branches); `pSecond`
/// uses `initial + new` (deposit grows the pool); and the `num` first term is
/// `minFee * feeK / maxFee * (rd + d1) / rd` (a different truncation chain than the
/// removal fee's). Truncation toward zero throughout; U256 ops panic on overflow,
/// matching the Solidity checked-arithmetic revert.
#[allow(dead_code)]
#[allow(clippy::too_many_arguments)]
pub fn compute_liquidity_deposit_fee(
    stable_liquidity: U256,
    asset_liquidity: U256,
    initial_stable_liquidity: U256,
    initial_asset_liquidity: U256,
    price: U256,
    oracle_decimals: U256,
    liquidity_max_fee: U256,
    liquidity_min_fee: U256,
    liquidity_fee_k: U256,
    liquidity_fee_decimals: U256,
) -> U256 {
    if initial_stable_liquidity == U256::ZERO || initial_asset_liquidity == U256::ZERO {
        return U256::ZERO;
    }
    if liquidity_max_fee == U256::ZERO {
        return U256::ZERO;
    }
    let ratio_decimals = U256::from(10u64).pow(U256::from(18u64)); // 1e18
    let p;
    let p_prime;
    let p_second;
    if md(initial_stable_liquidity, ratio_decimals, initial_asset_liquidity)
        > md(price, ratio_decimals, oracle_decimals)
    {
        p = md(price, ratio_decimals, oracle_decimals);
        p_prime = md(initial_stable_liquidity, ratio_decimals, initial_asset_liquidity);
        p_second = md(
            initial_stable_liquidity + stable_liquidity,
            ratio_decimals,
            initial_asset_liquidity + asset_liquidity,
        );
    } else {
        p = md(ratio_decimals, oracle_decimals, price);
        p_prime = md(initial_asset_liquidity, ratio_decimals, initial_stable_liquidity);
        p_second = md(
            initial_asset_liquidity + asset_liquidity,
            ratio_decimals,
            initial_stable_liquidity + stable_liquidity,
        );
    }
    if p_second < p_prime && p_second > p {
        return liquidity_min_fee;
    }
    let rel_price_diff1_sq =
        md(md(util_diff_abs(p_prime, p), util_diff_abs(p_prime, p), p), ratio_decimals, p);
    let rel_price_diff2_sq =
        md(md(util_diff_abs(p_second, p), util_diff_abs(p_second, p), p), ratio_decimals, p);
    let num = md(
        md(liquidity_min_fee, liquidity_fee_k, liquidity_max_fee),
        ratio_decimals + rel_price_diff1_sq,
        ratio_decimals,
    ) + md(rel_price_diff2_sq, liquidity_fee_decimals, ratio_decimals);
    let den = md(liquidity_fee_k, ratio_decimals + rel_price_diff1_sq, ratio_decimals)
        + md(rel_price_diff2_sq, liquidity_fee_decimals, ratio_decimals);
    md(num, liquidity_max_fee, den)
}

// -----------------------------------------------------------------------
// Public Stylus ABI — only for the standalone CurveMath program.
//
// Gated behind `standalone-abi` (default-on) so this crate can ALSO be used as
// a plain math library dependency by the perp-engine crate WITHOUT pulling in a
// second `#[entrypoint]` (which would clash with the engine's own entrypoint in
// the final wasm). The engine depends on this crate with default-features=false
// and consumes only the `pub` math functions above.
// -----------------------------------------------------------------------

#[cfg(feature = "standalone-abi")]
sol_storage! {
    #[entrypoint]
    pub struct CurveMath {}
}

#[cfg(feature = "standalone-abi")]
#[public]
impl CurveMath {
    /// Compute vAsset output for `size` vStable input (long trade).
    pub fn compute_long_return(
        &self,
        size: U256,
        spot_price: U256,
        oracle_decimals: U256,
        initial_guess: U256,
        global_liquidity_stable: U256,
        global_liquidity_asset: U256,
        long_curve_parameter_a: U256,
        long_curve_parameter_b: U256,
        curve_parameter_decimals: U256,
    ) -> Result<U256, Vec<u8>> {
        let result = compute_long_return_inner(
            i(size),
            i(spot_price),
            i(oracle_decimals),
            i(initial_guess),
            i(global_liquidity_stable),
            i(global_liquidity_asset),
            i(long_curve_parameter_a),
            i(long_curve_parameter_b),
            i(curve_parameter_decimals),
        );
        Ok(u(result))
    }

    /// Compute vStable output for `size` vAsset input (short trade).
    pub fn compute_short_return(
        &self,
        size: U256,
        spot_price: U256,
        oracle_decimals: U256,
        initial_guess: U256,
        global_liquidity_stable: U256,
        global_liquidity_asset: U256,
        short_curve_parameter_a: U256,
        short_curve_parameter_b: U256,
        curve_parameter_decimals: U256,
    ) -> Result<U256, Vec<u8>> {
        let result = compute_short_return_inner(
            i(size),
            i(spot_price),
            i(oracle_decimals),
            i(initial_guess),
            i(global_liquidity_stable),
            i(global_liquidity_asset),
            i(short_curve_parameter_a),
            i(short_curve_parameter_b),
            i(curve_parameter_decimals),
        );
        Ok(u(result))
    }

    /// Compute vStable input needed for exact `output_size` vAsset output (long).
    pub fn compute_exact_amount_in_long(
        &self,
        output_size: U256,
        spot_price: U256,
        oracle_decimals: U256,
        initial_guess: U256,
        global_liquidity_stable: U256,
        global_liquidity_asset: U256,
        long_curve_parameter_a: U256,
        long_curve_parameter_b: U256,
        curve_parameter_decimals: U256,
    ) -> Result<U256, Vec<u8>> {
        assert!(global_liquidity_asset >= output_size, "INVL1");
        let result = compute_exact_in_long_inner(
            i(output_size),
            i(spot_price),
            i(oracle_decimals),
            i(initial_guess),
            i(global_liquidity_stable),
            i(global_liquidity_asset),
            i(long_curve_parameter_a),
            i(long_curve_parameter_b),
            i(curve_parameter_decimals),
        );
        Ok(u(result))
    }

    /// Compute vAsset input needed for exact `output_size` vStable output (short).
    pub fn compute_exact_amount_in_short(
        &self,
        output_size: U256,
        spot_price: U256,
        oracle_decimals: U256,
        initial_guess: U256,
        global_liquidity_stable: U256,
        global_liquidity_asset: U256,
        short_curve_parameter_a: U256,
        short_curve_parameter_b: U256,
        curve_parameter_decimals: U256,
    ) -> Result<U256, Vec<u8>> {
        assert!(global_liquidity_stable >= output_size, "INVS1");
        let result = compute_exact_in_short_inner(
            i(output_size),
            i(spot_price),
            i(oracle_decimals),
            i(initial_guess),
            i(global_liquidity_stable),
            i(global_liquidity_asset),
            i(short_curve_parameter_a),
            i(short_curve_parameter_b),
            i(curve_parameter_decimals),
        );
        Ok(u(result))
    }

    /// Newton's method for cubic equations - Solidity-compatible interface.
    ///
    /// Accepts (magnitude, sign) pairs matching the original Solidity signature.
    /// sign convention: true = positive, false = negative.
    /// Coefficient `a` is always positive so it has no sign parameter.
    pub fn newton_method_cubic(
        &self,
        initial_guess: U256,
        a: U256,
        b: U256,
        c: U256,
        d: U256,
        b_sign: bool,
        c_sign: bool,
        d_sign: bool,
    ) -> Result<U256, Vec<u8>> {
        // Convert (magnitude, sign) pairs to signed I256
        let a_s = i(a); // always positive
        let b_s = if b_sign { i(b) } else { -i(b) };
        let c_s = if c_sign { i(c) } else { -i(c) };
        let d_s = if d_sign { i(d) } else { -i(d) };

        let result = newton_cubic(i(initial_guess), a_s, b_s, c_s, d_s);
        Ok(u(result))
    }

    // -------------------------------------------------------------------
    // MatrixMath - 2x2 matrix operations for LP balance tracking
    // See whitepaper Section 4: "Algorithm for efficiently tracking LP balances"
    //
    // Matrices are passed as 4 flat I256 values in row-major order:
    //   [a00, a01, a10, a11] represents [[a00, a01], [a10, a11]]
    //
    // The Solidity proxy translates between int256[2][2] and flat form.
    // -------------------------------------------------------------------

    /// 2x2 matrix multiplication: result = (A x B) / normalizationDecimals
    pub fn mat_mul_two_by_two(
        &self,
        a00: I256,
        a01: I256,
        a10: I256,
        a11: I256,
        b00: I256,
        b01: I256,
        b10: I256,
        b11: I256,
        normalization_decimals: I256,
    ) -> Result<(I256, I256, I256, I256), Vec<u8>> {
        Ok(mat_mul_2x2(a00, a01, a10, a11, b00, b01, b10, b11, normalization_decimals))
    }

    /// 2x2 matrix inverse. Bit-exact with Solidity `MatrixMath.inverseTwoByTwo`:
    /// divides the adjugate by the (normalized) determinant and reverts when the
    /// determinant is zero. `normalization_decimals` matches the Solidity
    /// signature (the LP code calls it with `liquidityMDecimals`).
    pub fn inverse_two_by_two(
        &self,
        a00: I256,
        a01: I256,
        a10: I256,
        a11: I256,
        normalization_decimals: I256,
    ) -> Result<(I256, I256, I256, I256), Vec<u8>> {
        mat_inverse_2x2(a00, a01, a10, a11, normalization_decimals)
    }

    /// Check equality of two 2x2 matrices.
    pub fn equal_two_by_two_matrix(
        &self,
        a00: I256,
        a01: I256,
        a10: I256,
        a11: I256,
        b00: I256,
        b01: I256,
        b10: I256,
        b11: I256,
    ) -> Result<bool, Vec<u8>> {
        Ok(a00 == b00 && a01 == b01 && a10 == b10 && a11 == b11)
    }

    /// Vector x Matrix: result = v x M / normalizationDecimals
    pub fn mul_vec_mat_two_by_two(
        &self,
        v0: I256,
        v1: I256,
        m00: I256,
        m01: I256,
        m10: I256,
        m11: I256,
        normalization_decimals: I256,
    ) -> Result<(I256, I256), Vec<u8>> {
        Ok(vec_mat_2x2(v0, v1, m00, m01, m10, m11, normalization_decimals))
    }

    /// Matrix x Vector: result = M x v / normalizationDecimals
    pub fn mul_mat_vec_two_by_two(
        &self,
        m00: I256,
        m01: I256,
        m10: I256,
        m11: I256,
        v0: I256,
        v1: I256,
        normalization_decimals: I256,
    ) -> Result<(I256, I256), Vec<u8>> {
        Ok(mat_vec_2x2(m00, m01, m10, m11, v0, v1, normalization_decimals))
    }

    /// Scalar (dot) product of two 2-component vectors.
    pub fn scalar_two_by_two(
        &self,
        v1_0: I256,
        v1_1: I256,
        v2_0: I256,
        v2_1: I256,
        normalization_decimals: I256,
    ) -> Result<I256, Vec<u8>> {
        Ok(scalar_2x2(v1_0, v1_1, v2_0, v2_1, normalization_decimals))
    }
}

// -----------------------------------------------------------------------
// Parity tests against the Solidity-generated golden vectors
//
// Fixture: test/fixtures/curve_math_solidity_vectors.json, produced by
// test/curve_math/CurveMathGoldenVector.t.sol from src/util/CurveMath.sol.
// Tolerance policy:
//   - "public" vectors: exact equality with the Solidity output.
//   - "newton"/"newton_1e10" vectors: |got - expected| <= 1e10 (the same
//     convergence threshold both solvers use).
//   - "newtonRevert" vectors: the solver must panic (NM1).
//   - "coefficients" vectors: checked separately in `coefficient_vectors`
//     against the extracted inverse-coefficient helpers.
// -----------------------------------------------------------------------
#[cfg(test)]
mod parity {
    use super::*;
    use serde_json::Value;
    use std::panic::{catch_unwind, set_hook, take_hook, AssertUnwindSafe};
    use std::string::String;
    use std::vec::Vec as StdVec;

    const FIXTURE: &str = include_str!("../../test/fixtures/curve_math_solidity_vectors.json");

    fn u256(text: &str) -> U256 {
        U256::from_str_radix(text, 10).unwrap_or_else(|_| panic!("bad u256: {text}"))
    }
    fn idec(text: &str) -> I256 {
        I256::from_dec_str(text).unwrap_or_else(|_| panic!("bad i256: {text}"))
    }
    fn mag(text: &str) -> I256 {
        i(u256(text))
    }
    fn signed(magnitude: &str, sign: bool) -> I256 {
        let m = mag(magnitude);
        if sign {
            m
        } else {
            -m
        }
    }
    fn input<'a>(v: &'a Value, key: &str) -> &'a str {
        v["inputs"][key]
            .as_str()
            .unwrap_or_else(|| panic!("missing input '{key}'"))
    }

    fn run_public(func: &str, v: &Value, amount: I256) -> I256 {
        let sp = mag(input(v, "spotPrice"));
        let od = mag(input(v, "oracleDecimals"));
        let guess = mag(input(v, "initialGuess"));
        let stable = mag(input(v, "stable"));
        let asset = mag(input(v, "asset"));
        let pa = mag(input(v, "parameterA"));
        let pb = mag(input(v, "parameterB"));
        let cd = mag(input(v, "curveParameterDecimals"));
        match func {
            "computeLongReturn" => {
                compute_long_return_inner(amount, sp, od, guess, stable, asset, pa, pb, cd)
            }
            "computeShortReturn" => {
                compute_short_return_inner(amount, sp, od, guess, stable, asset, pa, pb, cd)
            }
            "computeExactAmountInLong" => {
                compute_exact_in_long_inner(amount, sp, od, guess, stable, asset, pa, pb, cd)
            }
            "computeExactAmountInShort" => {
                compute_exact_in_short_inner(amount, sp, od, guess, stable, asset, pa, pb, cd)
            }
            other => panic!("unknown public function: {other}"),
        }
    }

    fn newton_from_vector(v: &Value) -> (I256, I256, I256, I256, I256) {
        let guess = mag(input(v, "initialGuess"));
        let a = mag(input(v, "a"));
        let b = signed(input(v, "b"), v["inputs"]["bSign"].as_bool().unwrap());
        let c = signed(input(v, "c"), v["inputs"]["cSign"].as_bool().unwrap());
        let d = signed(input(v, "d"), v["inputs"]["dSign"].as_bool().unwrap());
        (guess, a, b, c, d)
    }

    // Dependency-free randomized property test ("fuzz") for `u_or_zero`, the clamp the
    // negative-LP-balance fix applies before the U256 cast. Over 100k pseudo-random signed
    // inputs it must (a) never panic and (b) equal `max(v, 0)` — passing positives through
    // unchanged like `u()`, mapping every non-positive value to 0. `u()` itself panics on a
    // negative input, which is exactly the DoS the clamp removes.
    #[test]
    fn u_or_zero_fuzz_clamps_negatives() {
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        for _ in 0..100_000 {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            // Magnitude < 2^128 (product of two u64) is always a valid I256.
            let magnitude = U256::from(state) * U256::from(state ^ 0xA5A5_A5A5_A5A5_A5A5u64);
            let vi = i(magnitude);
            let v = if state & 1 == 0 { vi } else { -vi };
            let got = u_or_zero(v);
            if v > I256::ZERO {
                assert_eq!(got, u(v), "positive leg passes through unchanged: {v}");
            } else {
                assert_eq!(got, U256::ZERO, "non-positive leg clamps to 0: {v}");
            }
        }
        // Boundary cases.
        assert_eq!(u_or_zero(I256::ZERO), U256::ZERO);
        assert_eq!(u_or_zero(I256::MINUS_ONE), U256::ZERO);
        assert_eq!(u_or_zero(i(U256::from(1u64))), U256::from(1u64));
    }

    // Removal-fee one-sided-pool guard: a pool with either initial side entirely removed has no
    // meaningful removal fee and must return 0 (matching the deposit fee's existing guard) instead
    // of dividing through the zeroed side. Explicit cases + a randomized property check.
    #[test]
    fn removal_fee_waives_one_sided_pool() {
        let od = u256("100000000"); // 1e8
        let price = u256("300000000000"); // 3000e8
        let max_fee = u256("500000000"); // 5e8
        let min_fee = U256::ZERO;
        let k = u256("10000000000"); // 1e10
        let fee_dec = u256("10000000000"); // 1e10
        let some = u256("1000000000000000000000"); // 1000e18

        // asset-only pool (initial stable == 0) -> 0
        assert_eq!(
            compute_liquidity_removal_fee(U256::ZERO, some, U256::ZERO, some, price, od, max_fee, min_fee, k, fee_dec),
            U256::ZERO,
            "initial stable == 0 waives the removal fee"
        );
        // stable-only pool (initial asset == 0) -> 0
        assert_eq!(
            compute_liquidity_removal_fee(some, U256::ZERO, some, U256::ZERO, price, od, max_fee, min_fee, k, fee_dec),
            U256::ZERO,
            "initial asset == 0 waives the removal fee"
        );

        // Randomized property: whenever either initial side is 0, the fee is 0 and it never panics.
        let mut state: u64 = 0xD1B5_4A32_D192_ED03;
        for _ in 0..50_000 {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            let s = U256::from(state) * U256::from(1_000_000u64);
            let a = U256::from(state ^ 0x5555_5555_5555_5555u64) * U256::from(1_000_000u64);
            let (init_s, init_a) = if state & 1 == 0 { (U256::ZERO, a) } else { (s, U256::ZERO) };
            let fee = compute_liquidity_removal_fee(
                s.min(init_s),
                a.min(init_a),
                init_s,
                init_a,
                price,
                od,
                max_fee,
                min_fee,
                k,
                fee_dec,
            );
            assert_eq!(fee, U256::ZERO, "one-sided initial pool must waive the fee");
        }
    }

    #[test]
    fn golden_vectors_match_rust_port() {
        let root: Value = serde_json::from_str(FIXTURE).expect("parse fixture json");
        let vectors = root["vectors"].as_array().expect("vectors array");

        let mut checked = 0u32;
        let mut failures: StdVec<String> = StdVec::new();

        for v in vectors {
            let kind = v["kind"].as_str().unwrap();
            let label = v["label"].as_str().unwrap_or("<unlabeled>");
            match kind {
                "public" => {
                    let func = v["function"].as_str().unwrap();
                    let amount = mag(input(v, "amount"));
                    let expected = mag(v["expected"].as_str().unwrap());
                    let got = run_public(func, v, amount);
                    if got != expected {
                        failures.push(format!(
                            "[public] {label} ({func}): got {got}, expected {expected}"
                        ));
                    }
                    checked += 1;
                }
                "newton" => {
                    let (guess, a, b, c, d) = newton_from_vector(v);
                    let expected = mag(v["expected"].as_str().unwrap());
                    let got = newton_cubic(guess, a, b, c, d);
                    let diff = if got > expected { got - expected } else { expected - got };
                    if diff > CONVERGENCE_THRESHOLD {
                        failures.push(format!(
                            "[newton] {label}: got {got}, expected {expected}, diff {diff} > 1e10"
                        ));
                    }
                    checked += 1;
                }
                "newtonRevert" => {
                    let (guess, a, b, c, d) = newton_from_vector(v);
                    let prev = take_hook();
                    set_hook(std::boxed::Box::new(|_| {}));
                    let result = catch_unwind(AssertUnwindSafe(|| newton_cubic(guess, a, b, c, d)));
                    set_hook(prev);
                    if let Ok(value) = result {
                        failures.push(format!(
                            "[newtonRevert] {label}: expected revert (NM1), got {value}"
                        ));
                    }
                    checked += 1;
                }
                "coefficients" => {
                    let func = v["function"].as_str().unwrap();
                    let amount = mag(input(v, "amount"));
                    let sp = mag(input(v, "spotPrice"));
                    let od = mag(input(v, "oracleDecimals"));
                    let stable = mag(input(v, "stable"));
                    let asset = mag(input(v, "asset"));
                    let pa = mag(input(v, "parameterA"));
                    let pb = mag(input(v, "parameterB"));
                    let cd = mag(input(v, "curveParameterDecimals"));
                    let (a_prime, lambda, k, a, b, c, d) = match func {
                        "computeExactAmountInLong" => {
                            inverse_long_coefficients(amount, sp, od, stable, asset, pa, pb, cd)
                        }
                        "computeExactAmountInShort" => {
                            inverse_short_coefficients(amount, sp, od, stable, asset, pa, pb, cd)
                        }
                        other => panic!("unknown coefficients function: {other}"),
                    };
                    let exp = &v["expected"];
                    let exp_mag = |key: &str| mag(exp[key].as_str().unwrap());
                    let exp_signed = |key: &str, sign_key: &str| {
                        signed(exp[key].as_str().unwrap(), exp[sign_key].as_bool().unwrap())
                    };
                    let coeffs: [(&str, I256, I256); 7] = [
                        ("aPrime", a_prime, exp_mag("aPrime")),
                        ("lambda", lambda, exp_signed("lambda", "lambdaSign")),
                        ("k", k, exp_signed("k", "kSign")),
                        ("a", a, exp_mag("a")),
                        ("b", b, exp_signed("b", "bSign")),
                        ("c", c, exp_signed("c", "cSign")),
                        ("d", d, exp_signed("d", "dSign")),
                    ];
                    for (name, got, want) in coeffs.iter() {
                        if got != want {
                            failures.push(format!(
                                "[coefficients] {label} ({func}) {name}: got {got}, expected {want}"
                            ));
                        }
                    }
                    checked += 1;
                }
                "matrix" => {
                    let op = v["op"].as_str().unwrap();
                    let inp = &v["inputs"];
                    let geti = |k: &str| idec(inp[k].as_str().unwrap());
                    let exp = &v["expected"];
                    let got: StdVec<(&str, I256)> = match op {
                        "inverse" => {
                            let r = mat_inverse_2x2(
                                geti("a00"), geti("a01"), geti("a10"), geti("a11"), geti("norm"),
                            )
                            .expect("inverse should not revert");
                            std::vec![("r00", r.0), ("r01", r.1), ("r10", r.2), ("r11", r.3)]
                        }
                        "matmul" => {
                            let r = mat_mul_2x2(
                                geti("a00"), geti("a01"), geti("a10"), geti("a11"),
                                geti("b00"), geti("b01"), geti("b10"), geti("b11"), geti("norm"),
                            );
                            std::vec![("r00", r.0), ("r01", r.1), ("r10", r.2), ("r11", r.3)]
                        }
                        "mulvecmat" => {
                            let r = vec_mat_2x2(
                                geti("v0"), geti("v1"), geti("m00"), geti("m01"), geti("m10"),
                                geti("m11"), geti("norm"),
                            );
                            std::vec![("r0", r.0), ("r1", r.1)]
                        }
                        "mulmatvec" => {
                            let r = mat_vec_2x2(
                                geti("m00"), geti("m01"), geti("m10"), geti("m11"), geti("v0"),
                                geti("v1"), geti("norm"),
                            );
                            std::vec![("r0", r.0), ("r1", r.1)]
                        }
                        "scalar" => {
                            let r = scalar_2x2(
                                geti("v1_0"), geti("v1_1"), geti("v2_0"), geti("v2_1"), geti("norm"),
                            );
                            std::vec![("r", r)]
                        }
                        other => panic!("unknown matrix op: {other}"),
                    };
                    for (name, value) in got {
                        let want = idec(exp[name].as_str().unwrap());
                        if value != want {
                            failures.push(format!(
                                "[matrix] {label} ({op}) {name}: got {value}, expected {want}"
                            ));
                        }
                    }
                    checked += 1;
                }
                "matrixRevert" => {
                    let inp = &v["inputs"];
                    let geti = |k: &str| idec(inp[k].as_str().unwrap());
                    let r = mat_inverse_2x2(
                        geti("a00"), geti("a01"), geti("a10"), geti("a11"), geti("norm"),
                    );
                    if r.is_ok() {
                        failures.push(format!("[matrixRevert] {label}: expected Err (det=0), got Ok"));
                    }
                    checked += 1;
                }
                "util" => {
                    let op = v["op"].as_str().unwrap();
                    let inp = &v["inputs"];
                    let exp = &v["expected"];
                    match op {
                        "signedSum" => {
                            let (z, zs) = signed_sum(
                                u256(inp["x"].as_str().unwrap()),
                                inp["xs"].as_bool().unwrap(),
                                u256(inp["y"].as_str().unwrap()),
                                inp["ys"].as_bool().unwrap(),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            let wzs = exp["zs"].as_bool().unwrap();
                            if z != wz || zs != wzs {
                                failures.push(format!(
                                    "[util] {label} signedSum: got ({z},{zs}), expected ({wz},{wzs})"
                                ));
                            }
                        }
                        "signedSumToInt" => {
                            let z = signed_sum_to_int(
                                u256(inp["x"].as_str().unwrap()),
                                inp["xs"].as_bool().unwrap(),
                                u256(inp["y"].as_str().unwrap()),
                                inp["ys"].as_bool().unwrap(),
                            );
                            let wz = idec(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!("[util] {label} signedSumToInt: got {z}, expected {wz}"));
                            }
                        }
                        "diffAbs" => {
                            let z = util_diff_abs(
                                u256(inp["x"].as_str().unwrap()),
                                u256(inp["y"].as_str().unwrap()),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!("[util] {label} diffAbs: got {z}, expected {wz}"));
                            }
                        }
                        "calcEMA" => {
                            let z = calc_ema(
                                u256(inp["p"].as_str().unwrap()),
                                u256(inp["spotP"].as_str().unwrap()),
                                u256(inp["slipDecimals"].as_str().unwrap()),
                                u256(inp["oldAverage"].as_str().unwrap()),
                                u256(inp["emaParam"].as_str().unwrap()),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!("[util] {label} calcEMA: got {z}, expected {wz}"));
                            }
                        }
                        "divCeil" => {
                            let z = div_ceil(idec(inp["a"].as_str().unwrap()), idec(inp["b"].as_str().unwrap()));
                            let wz = idec(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!("[util] {label} divCeil: got {z}, expected {wz}"));
                            }
                        }
                        "clamp" => {
                            let (z, zs) = clamp(
                                u256(inp["param"].as_str().unwrap()),
                                u256(inp["minFR"].as_str().unwrap()),
                                u256(inp["maxFR"].as_str().unwrap()),
                                u256(inp["offset"].as_str().unwrap()),
                                inp["sign"].as_bool().unwrap(),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            let wzs = exp["zs"].as_bool().unwrap();
                            if z != wz || zs != wzs {
                                failures.push(format!(
                                    "[util] {label} clamp: got ({z},{zs}), expected ({wz},{wzs})"
                                ));
                            }
                        }
                        "reduceValue" => {
                            let (new_a, rem_b) = reduce_value(
                                u256(inp["a"].as_str().unwrap()),
                                u256(inp["b"].as_str().unwrap()),
                            );
                            let wa = u256(exp["newA"].as_str().unwrap());
                            let wb = u256(exp["remainingB"].as_str().unwrap());
                            if new_a != wa || rem_b != wb {
                                failures.push(format!(
                                    "[util] {label} reduceValue: got ({new_a},{rem_b}), expected ({wa},{wb})"
                                ));
                            }
                        }
                        "liquidityRemovalFee" => {
                            let z = compute_liquidity_removal_fee(
                                u256(inp["stable"].as_str().unwrap()),
                                u256(inp["asset"].as_str().unwrap()),
                                u256(inp["iStable"].as_str().unwrap()),
                                u256(inp["iAsset"].as_str().unwrap()),
                                u256(inp["price"].as_str().unwrap()),
                                u256(inp["oracleDecimals"].as_str().unwrap()),
                                u256(inp["maxFee"].as_str().unwrap()),
                                u256(inp["minFee"].as_str().unwrap()),
                                u256(inp["feeK"].as_str().unwrap()),
                                u256(inp["feeDecimals"].as_str().unwrap()),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!(
                                    "[util] {label} liquidityRemovalFee: got {z}, expected {wz}"
                                ));
                            }
                        }
                        "liquidityDepositFee" => {
                            let z = compute_liquidity_deposit_fee(
                                u256(inp["stable"].as_str().unwrap()),
                                u256(inp["asset"].as_str().unwrap()),
                                u256(inp["iStable"].as_str().unwrap()),
                                u256(inp["iAsset"].as_str().unwrap()),
                                u256(inp["price"].as_str().unwrap()),
                                u256(inp["oracleDecimals"].as_str().unwrap()),
                                u256(inp["maxFee"].as_str().unwrap()),
                                u256(inp["minFee"].as_str().unwrap()),
                                u256(inp["feeK"].as_str().unwrap()),
                                u256(inp["feeDecimals"].as_str().unwrap()),
                            );
                            let wz = u256(exp["z"].as_str().unwrap());
                            if z != wz {
                                failures.push(format!(
                                    "[util] {label} liquidityDepositFee: got {z}, expected {wz}"
                                ));
                            }
                        }
                        other => panic!("unknown util op: {other}"),
                    }
                    checked += 1;
                }
                other => panic!("unknown vector kind: {other}"),
            }
        }

        println!(
            "golden-vector parity: {checked} vectors checked, {} failed",
            failures.len()
        );
        assert!(
            failures.is_empty(),
            "golden-vector parity failures:\n{}",
            failures.join("\n")
        );
    }
}
