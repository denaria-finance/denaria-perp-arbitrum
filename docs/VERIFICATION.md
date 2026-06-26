# Verification

The Solidity and Stylus verification paths are different and should not be described as
one combined mechanism.

## Solidity Contracts

The latest Arbitrum Sepolia Solidity contracts are source-verified on Arbiscan:

- `StylusPerpMultiCalls`
- `Vault`
- `LostAndFound`
- `CurveMath`
- `UtilMath`
- `TWAPOracleMiddleware`

The Solidity verification flow uses `forge script --verify` or
`forge verify-contract`, with linked library addresses where needed.

Note on the deployed oracle: after verification, the repository's
`TWAPOracleMiddleware` dropped its vendored Chainlink dependency in favor of minimal
local interfaces and the OpenZeppelin `SafeERC20`. The on-chain instance remains
verified with its original sources (Arbiscan snapshots them), but the current tree
compiles to slightly different bytecode — at the next stack redeploy the oracle should
be redeployed and re-verified from the cleaned sources to realign repo and chain.

## Stylus Engine

The deployed `PerpEngine` is reproducibly buildable from the pinned repository toolchain:

- `rust-toolchain.toml`: `nightly-2026-06-10`
- `.cargo/config.toml`: WASM `build-std`, `-Cpanic=immediate-abort`, and
  `-Zlocation-detail=none`
- `stylus-sdk`: `0.10.7`

The latest deployed engine artifact hash recorded for the Arbitrum Sepolia stack is:

```text
957e7cd63894c198f611d8e035b84b9586e9e70154bd463df2644b1a29bacaf4
```

This is reproducible-build evidence, not full Arbiscan Stylus source verification.

## Current Arbiscan Stylus Blocker

Arbiscan's Stylus verification flow relies on cargo-stylus managed deployment metadata:
cargo-stylus injects a project hash during managed builds, and verification rebuilds the
source tree and compares that hash.

The current engine deployments were made from a prebuilt WASM file. That path does not
inject the managed project hash, so those deployed engine instances cannot pass the
Arbiscan/cargo-stylus managed verification flow after the fact.

The controlled path to full Stylus source verification is:

1. produce a cargo-stylus managed build that fits the Stylus activation limits;
2. perform a throwaway managed deploy;
3. prove `cargo stylus verify --deployment-tx <tx>` succeeds;
4. only then redeploy the real stack with the same managed source tree.

## Source Hosting Constraint

Arbiscan's Git-fetch Stylus flow expects the contract crate at the repository root. The
current project keeps the engine in `perp-engine/` inside a wider contracts repository.

For public verification, the cleanest structure is a dedicated public verification repo:

```text
Cargo.toml
Cargo.lock
rust-toolchain.toml
Stylus.toml
src/
curve-math/
```

The engine crate should live at the root, and the curve-math crate should be vendored as
a child path. Strip tests from that verification tree if they are not intended to be
published; Stylus project hashes include all `.rs` files in the project.

## Toolchain Matrix

For Arbiscan verification the engine must be built by the cargo-stylus 0.10.7 managed
flow AND activate under the on-chain raw-size limit (~283 KB). The two requirements pull
in opposite directions across toolchains:

| Toolchain | Raw size | Activates | Managed-buildable |
| --- | --- | --- | --- |
| nightly-2026-06-10 + `-Cpanic=immediate-abort` | 248.5 KB | yes | no — cargo-stylus 0.10.7 injects the pre-rename `build-std-features=panic_immediate_abort`, which this nightly rejects |
| stable | 328 KB | no | yes |
| nightly-2025-09-01 + `build-std-features=panic_immediate_abort` (before the size diet) | 298.6 KB | no | yes |

### Resolution

The dominant contributor to engine code size was the inlined expansion of ruint U256
multiply-then-divide arithmetic, repeated across the curve solver and the engine hot
paths. Outlining that arithmetic behind a single helper reduces the pre-rename nightly
managed build from **298.6 KB to 259.9 KB raw** — clearing the activation cap with
~22.5 KB of headroom. That build both activates on-chain and is reproducible by the
cargo-stylus 0.10.7 managed/verify flow, so it is the pinned recipe:

- `rust-toolchain.toml`: `nightly-2025-09-01`
- `.cargo/config.toml`: `rustflags = ["-Zlocation-detail=none"]` only — cargo-stylus
  injects `build-std` + `panic_immediate_abort` for the wasm build itself, so host
  `cargo test` stays on the default std.

`cargo stylus build` produces the 259,864-byte artifact; a plain `cargo build --release
--target wasm32-unknown-unknown` matches it byte-for-byte when the managed flags are added
explicitly (`-Z build-std=std,panic_abort -Z build-std-features=panic_immediate_abort`).

Do not present a future Stylus deployment as Arbiscan source-verified until a managed
throwaway deploy has passed `cargo stylus verify`.

## Verification Source Tree

This repository cannot serve directly as the Arbiscan fetch source, for two reasons:

1. Arbiscan cannot verify a contract crate in a repository subdirectory, and the engine
   lives in `perp-engine/` (the root crate is the curve-math library).
2. The managed project hash binds **every `.rs` file** reachable from the build root —
   including `perp-engine/src/tests.rs` and the inline test module in
   `src/rust/CurveMath.rs`. Tests must not be part of the on-chain-verified source.

The verification source must therefore be a small, mechanically generated tree:

```text
Cargo.toml          engine package at the root
Cargo.lock
rust-toolchain.toml
Stylus.toml         [contract]
.cargo/config.toml
src/                engine modules, tests.rs removed, `mod tests` line removed
curve-math/         the curve crate as a child path dependency, test module stripped
```

Generate it from this repository with a committed script (so it cannot drift), publish it
as the dedicated public verification repo, run the managed throwaway deploy + verify from
it, and only then redeploy the production stack from the same tree.
