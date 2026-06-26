# WASM Size Optimization — Operational Workplan

## Objective

Reduce the engine's **raw** WASM size by **≥16 KB** so the cargo-stylus 0.10.7
*managed* build clears the on-chain activation cap, which is the prerequisite for
Arbiscan source verification of the Stylus engine (see `VERIFICATION.md`).

Two hard constraints bound every change:

1. **Bit-exact parity** with the Solidity reference — identical operations, order,
   truncation and wrap behavior. The differential fixture suite is the gate.
2. **No gas regression** — the engine's ~−11% L2 edge over the Solidity twin and the
   `Error(string)` revert decodability must both be preserved.

## Background

The managed build is the only one cargo-stylus 0.10.7 can reproduce for Arbiscan, and
it does not currently fit under the activation cap:

| Build | Raw size | Status |
| --- | --- | --- |
| Managed-equivalent (local) | 301,472 B | reproducible, **over cap** |
| Managed (documented, Docker) | 298,648 B | reproducible, **over cap** |
| Activation cap | ~282,900 B (~283 KB) | the wall (raw only; compressed already passes) |

Gap to close: **~15.7 KB** (from 298,648) to **~18.6 KB** (from 301,472). The full
toolchain matrix and why compiler-flag levers are exhausted are in `VERIFICATION.md`.

### Reference material evaluated

- "Poseidon go brrr with Stylus" — wasm size/gas optimization techniques for Rust on
  Arbitrum:
  https://www.openzeppelin.com/news/poseidon-go-brr-with-stylus-cryptographic-functions-are-18x-more-gas-efficient-via-rust-on-arbitrum
- `rust-contracts-stylus` crypto library (v0.3.0) — reference implementations of the
  same optimization patterns:
  https://github.com/OpenZeppelin/rust-contracts-stylus/tree/v0.3.0/lib/crypto

### Initial evaluation

The crypto library itself does not apply to Denaria: the engine performs no on-chain
hashing, elliptic-curve, or finite-field arithmetic (runtime `keccak` is a host call,
not in-wasm), so its primitives (Montgomery reduction, Poseidon, field inversion, etc.)
have no call site and would only *add* bytes against a binding cap. The transferable idea
is the size discipline the article applies: **profile the wasm, then outline the
duplicated inlined arithmetic**. Of the OZ-specific levers, only compile-time constant
precomputation applies, in a small form; `#![no_std]` is already effectively in place.

## Root cause (measured)

`ruint` U256 `*`, `+`, `-` are `#[inline(always)]` and expand to ~260 B per
multiplication at `opt-level="z"`. The engine and the embedded `CurveMath` crate contain
~63 U256 `a*b/c` chains that each expand fully inline, and the two liquidity-fee functions
are ~90% identical. This duplicated inlined arithmetic — not any algorithmic choice — is
where the excess bytes live.

## Measured results

Measured on throwaway build trees (the repo itself was not modified):

- Canonical activating build reproduced exactly at **248,532 B raw** — symbol-level
  attribution maps 1:1 to the deployed engine.
- **Fix #1 — outline `a*b/c` into one `#[inline(never)] md(a,b,c)`** across ~63 U256
  sites: **−16,352 B** (canonical). HIGH confidence (built + twiggy-profiled).
- **Fix #2 — dedupe the two liquidity-fee tails** into one
  `liquidity_fee_tail(..., is_deposit)`: **−3,396 B**.
- **Fix #1 + #2 stacked, on the managed-equivalent build: 301,472 → 277,559 B
  (−23,913)** — **~5.3 KB under the activation cap**. Even at the worst-case
  local-vs-Docker drift (~+2.8 KB) the result (~280.4 KB) still fits.
- Parity: all 50 native engine tests, including the `trade_funding` and `liquidity`
  differential fixture replays (`--features stub_boundary`), pass on the patched sources.

**Open caveat:** clearance is so far proven only against a *local approximation* of the
managed build. The only authoritative proof is a throwaway managed deploy followed by
`cargo stylus verify` (Phase 4). The Foundry differential suite and wasm-level fixture
replays were not run on the throwaway trees and are required gates before merge.

## Scope

### In scope — applicable optimizations

| ID | Change | Expected Δ raw | Confidence | Effort | Parity risk |
| --- | --- | --- | --- | --- | --- |
| R1 | Outline `a*b/c` U256 chains → one `#[inline(never)] md(a,b,c)` (~63 sites) | −16,352 B (measured) | HIGH | S–M | none |
| R2 | Dedupe the two liquidity-fee tails | −3,396 B (measured) | HIGH | S | none |
| R3 | Const-ify the 4 `U256::from(10).pow(N)` sites | ~0.5–1.5 KB | MEDIUM | S | none |

R1 + R2 alone are measured to clear the cap; R3 is the only OZ-specific lever that
applies and stacks for free (small size win + a few-hundred-gas win on the MR/PnL and fee
paths). The `pow` sites are `config.rs:53` (1e24, init-only), `internal_logic.rs:56`
(1e13), `CurveMath.rs:745` and `CurveMath.rs:819` (1e18) — all exactly representable, so
the const is bit-identical to the runtime result.

### Optional headroom — not required for the cap

- Extend outlining to chains skipped by the conservative pass
  (`inverse_long_coefficients`, residual `execute_trade`/`liquidate_impl`): est. −4 to
  −10 KB, MEDIUM, unmeasured.
- Const-ify the 12 fixed `*_decimals`/`clamp_*` storage fields: est. −2.5 to −5 KB plus a
  small gas win, MEDIUM, unmeasured (storage-layout change → requires a fresh deploy).

### Out of scope (rejected)

- The crypto primitives themselves (no call site; size-positive).
- `wasm-opt`/binaryen post-link passes — would break managed-build reproducibility and
  forfeit the Arbiscan verification this work exists to obtain.
- Contract splitting / alternative SDKs — require SDK > 0.10.7 and forfeit 0.10.7 managed
  verification; the engine's storage is one tightly-coupled blob.
- Routing division through `math_div` host calls — high parity risk (host DIV returns 0
  on divide-by-zero where `ruint` panics) and likely gas-neutral after marshalling.

## Implementation plan (phase by phase)

Each implementation phase ends with the full parity gate green and a measured raw-size
delta on both build profiles. Commit names are proposed at the end of each phase; nothing
is committed automatically.

- **Phase 0 — setup.** Branch `opt/stylus-wasm-size`; this plan. *(current)*
- **Phase 1 — R1 (`md` outlining).** Add the helper to `src/rust/CurveMath.rs`; replace
  the ~63 **U256** `a*b/c` sites with `cm::md(...)`, nesting as `md(md(a,b,c), d, e)` for
  the multi-element chains. **Leave all I256 sites untouched** (signed magnitude/sign and
  `div_ceil` semantics are the high-risk surface). **Patch by hand, per site** — an
  automated pass mis-handles nested chains, `U256::from(nested())`, and mistyped I256
  sites. Files: `src/rust/CurveMath.rs` plus call sites in
  `perp-engine/src/{trade,liquidation,close,liquidity,internal_logic,funding}.rs`.
- **Phase 2 — R2 (fee-tail dedupe).** Factor the shared tail of
  `compute_liquidity_removal_fee` (`CurveMath.rs:730`) and
  `compute_liquidity_deposit_fee` (`CurveMath.rs:801`) into one
  `#[inline(never)] liquidity_fee_tail(..., is_deposit: bool)`; they differ only in the
  first `num` term and three branch points. Files: `src/rust/CurveMath.rs`.
- **Phase 3 — R3 (const pow).** Replace the 4 runtime `pow` calls with module-level
  `const` `U256::from_limbs([...])` declarations. Files: `perp-engine/src/config.rs`,
  `perp-engine/src/internal_logic.rs`, `src/rust/CurveMath.rs`.
- **Phase 4 — managed verification gate.** Build the managed-equivalent profile, confirm
  raw size ≤ 282,900 B with margin, then a throwaway managed deploy + `cargo stylus
  verify` on a disposable address. **This is the only authoritative proof of clearance.**
  Only after it passes is a production redeploy + Arbiscan submission warranted.

## Parity gate (must pass before each phase is considered done)

1. `cargo test` — 50 native engine tests including the differential fixture replays
   (`test/fixtures/{trade_funding,liquidity,close_pnl,liquidation}_differential.json`,
   `--features stub_boundary`) and the curve-math tests.
2. The Foundry/forge differential suite and the wasm-level fixture replays.
3. The c0 envelope harness (`test/c0_envelope/C0EnvelopeSweep.t.sol`) — mandatory for any
   change touching the close/dust path (the `max(1e10, globalLiquidityStable/1e10)` bound
   read after buy-back).

## Measurement

After each phase, build both profiles from `VERIFICATION.md`'s matrix and record raw
bytes:

- **Canonical activating build** — for fast, fine-grained attribution (`twiggy top`,
  `twiggy dominators` on the unstripped variant).
- **Managed-equivalent build** — the figure that decides cap clearance.

Raw size = byte length of the produced `.wasm`. Track the running total against the
298,648 B / 301,472 B baselines and the ~282,900 B cap.

## Acceptance criteria

- Managed-equivalent raw size ≤ 282,900 B with margin.
- `cargo stylus verify` passes on a throwaway managed deploy.
- The full parity gate is green at every phase.
- Gas is unchanged within noise (the ~22–25k WASM entry pedestal is size-insensitive; the
  −11% edge is preserved).

## Rollback

The branch is isolated from `main`. Each phase is an independent, revertible change; if
any parity gate fails, revert that phase's diff and re-profile. No production redeploy
happens until Phase 4 passes.

## Outcome

On completion, the measured results and the verified managed build fold into
`VERIFICATION.md` (replacing the current "engine diet, levers exhausted" framing of the
size exit), and the engine becomes eligible for Arbiscan source verification.
