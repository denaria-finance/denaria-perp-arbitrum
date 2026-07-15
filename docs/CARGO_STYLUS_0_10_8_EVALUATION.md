# cargo-stylus 0.10.8 evaluation

Evaluation of upgrading the deploy-machine `cargo-stylus` CLI from 0.10.7 to 0.10.8, as a
**CLI-only** change (the engine crate keeps `stylus-sdk = "0.10.7"`).

## Summary

- **The engine crate stays on `stylus-sdk = "0.10.7"`.** 0.10.8's headline fix — verification of
  large, multi-fragment contracts — is a cargo-stylus CLI (off-chain) fix, not an SDK library
  change, so it needs no code edit, no dependency bump, and no rebuild.
- Upgrading the CLI is **optional** for this project: the deploy artifact is produced by a
  post-build `wasm-opt` pass, and `cargo stylus verify` rebuilds only the plain Cargo output, so it
  cannot reproduce the optimized bytes regardless of CLI version. The deployed artifact is instead
  reproduced deterministically from the published source plus the documented, version-pinned
  `wasm-opt` step. The 0.10.8 verify improvement therefore does not change this project's
  verification story.
- If the CLI is upgraded, do it **CLI-only first**: compare raw/optimized hashes, sizes, fragment
  counts, ABI, tests, activation, and gas against the 0.10.7 baseline, and only consider an SDK bump
  separately, after those checks pass.

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

Keep `stylus-sdk = "0.10.7"` in the engine crate. Treat a 0.10.8 CLI install on the deploy machine
as optional; if adopted, follow the CLI-only-first sequence above and keep the `wasm-opt` +
deterministic-reproduction verification flow unchanged.
