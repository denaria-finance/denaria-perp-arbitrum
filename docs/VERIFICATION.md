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
- Post-build optimisation: Binaryen **version_119** with the flag list in
  `script/wasm_opt_recipe.sh`, which both the build script and the CI gate read

The recipe and the budgets live in a single file because the artifact reproduces only when the
version and the flags match exactly, and because a limit that drifts between the build script
and the CI gate is a limit nothing enforces.

Activation applies **two independent budgets**, and a module that clears one can fail the
other:

- **Size** — `MaxWasmSize` on the decompressed module as submitted, which is the optimised
  artifact plus the `project_hash` section cargo-stylus appends. The ArbOS 60 value is 262,144
  bytes, confirmed against Arbitrum Sepolia: builds of this engine at 272,003 B and 277,107 B
  are rejected and the boundary sits on 256 KiB.
- **Opcodes** — no single function body may carry more than 65,536.

Binaryen's `-Oz` default inlines single-use callees into the SDK router hard enough to break
the second budget while staying inside the first, so the recipe caps that inlining. The engine
currently clears the size budget by roughly 2.5 KB, which is thin: treat the budget as a
standing constraint on what can be added to the on-chain surface, not as a formality.

The build is two-stage:

1. `script/generate_verify_tree.sh --build` emits a small, mechanically-generated tree
   (engine crate at the root, curve-math vendored as a child, test files stripped) and
   builds the **raw** engine wasm. It fails if the source layout drifts or the wasm does
   not match the recorded `EXPECT_SIZE` / `EXPECT_SHA256`. `--opt-check` additionally
   applies the recipe and fails on either activation budget.
2. `script/build_deploy_artifact.sh` applies the pinned recipe to that raw wasm, validates
   it (`wasm-tools`), checks both budgets, reports size / fragments / hashes, and (with an
   RPC) runs the read-only `cargo stylus check` activation simulation.

Neither budget is inferable from the source, so both are gated mechanically: a size-only
gate stays green while the artifact becomes unactivatable.

The deploy path does not apply the recipe itself — it takes the optimised file and
brotli-compresses it. That file, materially smaller than the raw build, is the binary actually
deployed and the one that must activate.

### Why not Arbiscan managed source-verify

Arbiscan's managed Stylus flow (and `cargo stylus verify`) rebuild the source tree and
compare against the deployed bytes. Because the deployed artifact is the **post-`wasm-opt`**
binary — which a plain source rebuild does not reproduce — the managed flow structurally
cannot byte-match the deployment. **Do not present the wasm-opt'd engine as Arbiscan
source-verified.**

### Path C — reproducible-artifact verification

Provenance is attested by deterministic re-derivation of the exact deployed bytes:

1. rebuild the raw verify-tree wasm (`generate_verify_tree.sh`, matches `EXPECT_SHA256`);
2. re-apply the pinned recipe (Binaryen version_119, the same flag list);
3. confirm the resulting `sha256` equals the deployed optimised artifact's hash.

The verify-tree build is deterministic and path-independent (promoting the engine to the
tree root changes crate-metadata hashes, so the *raw* tree sha differs from a plain in-repo
build while remaining stable across environments — expected and correct). Deploy the artifact
built **from the tree**, and record both hashes as the verification evidence.

### Tooling caveats

Observed while adopting the current `cargo-stylus` line; none is fixed upstream yet, and each
can silently produce a false "verified" or a half-deployed engine.

- **The Docker verify runner swallows the child exit status.** The outer runner waits for the
  inner process but does not propagate its exit code, so a byte MISMATCH inside can still
  surface as an outer success. Never treat a zero exit as proof: require an explicit positive
  success marker in the output and reject any failure text. Still the case on the current line
  — the image build checks its exit code, the container run does not.
- **There is no way to shape the hashed file set.** `--source-files-for-project-hash` was never
  wired, and the current line has dropped it: the hash covers every `.rs`, `Cargo.toml` and
  `Cargo.lock` under the build root, unconditionally. Control it by controlling the tree you
  publish — which is what `generate_verify_tree.sh` is for.
- **The `[wasm-opt]` table cannot yet carry this engine.** cargo-stylus 0.10.9 added an opt-in
  `[wasm-opt]` table in `Stylus.toml` that pins a Binaryen version and flags, applies them on
  both deploy and verification, and folds them into the project hash — which is exactly the
  mechanism this repo needs to retire the `--wasm-file` path. It does not work for a Rust
  contract yet: the optimisation runs *after* the normalisation that removes the `DataCount`
  section, so the section wasm-opt emits under `--enable-bulk-memory` (mandatory — the compiler
  already emits bulk-memory instructions, and wasm-opt refuses the input without it) survives
  into the deployed bytes and activation rejects the module. The same bytes activate through
  `--wasm-file`, where the normalisation runs last. Re-evaluate at the next release.
- **A `#[constructor]` deploy needs the canonical `StylusDeployer` on the target chain.** The
  CLI routes the atomic deploy+activate+initialize through it. On a chain without that
  contract the deploy still activates but the constructor does **not** run, leaving the engine
  uninitialized — always confirm initialization after deploying, whichever path was used.

### Recorded hashes

The current recorded hashes are baked into `script/generate_verify_tree.sh`
(`EXPECT_SIZE` / `EXPECT_SHA256`, the raw verify-tree build) and printed by
`script/build_deploy_artifact.sh` (raw + optimised size and sha256). They change with every
engine edit and with the toolchain/SDK/Binaryen versions, so treat the script output — not a
copied number — as the source of truth, and refresh the published address/hash records at
each redeploy.
