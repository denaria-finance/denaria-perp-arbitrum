# cargo-stylus 0.10.8 adoption

The project has been updated from `cargo-stylus` / `stylus-sdk` 0.10.7 to **0.10.8**.

## Summary

- **`stylus-sdk = "0.10.8"`** in the engine, curve-math, and verify-tree crates, with the matching
  0.10.8 CLI on the deploy machine. 0.10.8's headline fix (verification of large, multi-fragment
  contracts) is a CLI-side change; the SDK bump itself is a minor codegen change over 0.10.7.
- **Validated after the bump:** engine 81/81 and curve-math 9/9 tests pass, `clippy -D warnings` is
  clean, the deploy artifact was rebuilt (same raw size, 314,597 B; a different sha, since codegen
  changed) and re-derived through the pinned `wasm-opt` pass, and activation was re-confirmed on
  Arbitrum Sepolia via the read-only `cargo stylus check` (priced data fee). `ruint` stays `< 1.17`
  (0.10.8's constraint), so SDK storage encoding is unaffected.
- **The verification story is unchanged by the bump.** The deployed artifact is produced by a
  post-build `wasm-opt` pass, and `cargo stylus verify` rebuilds only the plain Cargo output, so it
  cannot reproduce the optimized bytes regardless of SDK/CLI version. Provenance stays **Path C**:
  deterministic re-derivation from the published source plus the version-pinned `wasm-opt` step (see
  `docs/VERIFICATION.md`).

## Caveats observed

- **Docker verify runner swallows the child exit status.** The outer runner waits for the child
  process but does not propagate its exit code, so an inner byte-mismatch can still surface as an
  outer success. Do not treat a zero exit as proof of verification — require an explicit positive
  success marker in the output and reject any failure text.
- **`--source-files-for-project-hash` is not fully wired.** The flag exists but current argument
  forwarding does not apply it; do not rely on it until fixed upstream.
- **Constructor deploys.** Deploying an engine that uses a Stylus `#[constructor]` requires the
  canonical `StylusDeployer` on the target chain; the CLI routes the atomic deploy+activate+init
  through it. On a chain without that contract, the deploy still activates but the constructor does
  **not** run, leaving the engine uninitialized — always confirm initialization after deploy.

## Recommendation

Keep the `wasm-opt` + deterministic Path-C reproduction verification flow; the 0.10.8 verify
improvement does not apply to a wasm-opt'd artifact. Re-run the full validation (tests, clippy,
artifact re-derivation, on-chain activation check) on any future SDK / CLI / toolchain / Binaryen
bump before deploying.
