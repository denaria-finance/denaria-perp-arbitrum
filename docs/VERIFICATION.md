# Verification

The Solidity and Stylus verification paths are different and are described separately.

## Solidity contracts

The Arbitrum Sepolia Solidity contracts are source-verified on Arbiscan via
`forge script --verify` / `forge verify-contract` (with linked library addresses where
needed):

- `StylusPerpMultiCalls` (manager)
- `Vault`
- `LostAndFound`
- `CurveMath`
- `UtilMath`
- `TWAPOracleMiddleware` (oracle)

Note on the oracle: the repository's `TWAPOracleMiddleware` dropped its vendored Chainlink
dependency in favour of minimal local interfaces plus OpenZeppelin `SafeERC20`, so the
current tree compiles to slightly different bytecode than a previously-deployed instance.
At each stack redeploy the oracle is redeployed and re-verified from the current sources so
repo and chain stay aligned.

## Stylus engine

The deployed `PerpEngine` is a Rust/WASM Stylus program. Its **deploy artifact is a
`wasm-opt`-optimised binary**, and this shapes how it is verified.

### Build recipe (reproducible)

- `rust-toolchain.toml`: `nightly-2025-09-01` (+ `rust-src`, `clippy`)
- `.cargo/config.toml`: WASM `build-std` + `-Zlocation-detail=none` (so the binary carries
  no local panic-location paths and is insensitive to comment/line edits)
- `stylus-sdk`: `0.10.8`
- Post-build optimisation: `wasm-opt -Oz` (Binaryen **version_119**, fixed flags) — see
  `script/build_deploy_artifact.sh`

The build is two-stage:

1. `script/generate_verify_tree.sh --build` emits a small, mechanically-generated tree
   (engine crate at the root, curve-math vendored as a child, test files stripped) and
   builds the **raw** engine wasm. It fails if the source layout drifts or the wasm does
   not match the recorded `EXPECT_SIZE` / `EXPECT_SHA256`.
2. `script/build_deploy_artifact.sh` applies the pinned `wasm-opt -Oz` pass to that raw
   wasm, validates it (`wasm-tools`), reports size / fragments / hashes, and (with an RPC)
   runs the read-only `cargo stylus check` activation simulation.

`cargo-stylus` does not run `wasm-opt`; it only brotli-compresses. The optimised artifact is
therefore materially smaller than the raw build and is the binary that is actually deployed
and that must activate.

### Why not Arbiscan managed source-verify

Arbiscan's managed Stylus flow (and `cargo stylus verify`) rebuild the source tree and
compare against the deployed bytes. Because the deployed artifact is the **post-`wasm-opt`**
binary — which a plain source rebuild does not reproduce — the managed flow structurally
cannot byte-match the deployment. **Do not present the wasm-opt'd engine as Arbiscan
source-verified.**

### Path C — reproducible-artifact verification

Provenance is attested by deterministic re-derivation of the exact deployed bytes:

1. rebuild the raw verify-tree wasm (`generate_verify_tree.sh`, matches `EXPECT_SHA256`);
2. re-apply the pinned `wasm-opt -Oz` (Binaryen version_119, same flags);
3. confirm the resulting `sha256` equals the deployed optimised artifact's hash.

The verify-tree build is deterministic and path-independent (promoting the engine to the
tree root changes crate-metadata hashes, so the *raw* tree sha differs from a plain in-repo
build while remaining stable across environments — expected and correct). Deploy the artifact
built **from the tree**, and record both hashes as the verification evidence.

### Recorded hashes

The current recorded hashes are baked into `script/generate_verify_tree.sh`
(`EXPECT_SIZE` / `EXPECT_SHA256`, the raw verify-tree build) and printed by
`script/build_deploy_artifact.sh` (raw + optimised size and sha256). They change with every
engine edit and with the toolchain/SDK/Binaryen versions, so treat the script output — not a
copied number — as the source of truth, and refresh the published address/hash records at
each redeploy.
