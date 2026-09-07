#!/usr/bin/env bash
# Generate the Arbiscan verification source tree for the Stylus PerpEngine.
#
# Why a generated tree, not this repo as-is: `cargo stylus verify` rebuilds the
# engine from a published source tree and byte-compares the result to the
# on-chain wasm. This repository cannot be that tree for two reasons:
#   1. The verifier expects the contract crate at the repository ROOT, but here
#      the root crate is the curve-math library and the engine lives in
#      perp-engine/.
#   2. The managed project hash binds EVERY .rs file reachable from the build
#      root, including test code (perp-engine/src/tests.rs and the inline parity
#      module in the curve crate). Test code must not be part of the verified
#      source.
# So the verified tree is a small, mechanically-derived rearrangement of this
# repo: the engine crate promoted to the root, the curve crate vendored as a
# child path dependency, and all test code stripped. This script emits it
# deterministically, with assertions that fail loudly if the source layout
# drifts, so the published tree cannot silently diverge from the repo.
#
# Usage:
#   ./script/generate_verify_tree.sh [OUT_DIR]             # generate (default: ./verify-tree)
#   ./script/generate_verify_tree.sh --build [OUT_DIR]     # generate, then build and
#                                                          # check the wasm size + sha256
#   ./script/generate_verify_tree.sh --opt-check [OUT_DIR] # --build, then apply the pinned
#                                                          # wasm-opt recipe and fail if the
#                                                          # deploy artifact exceeds either
#                                                          # activation budget (size, opcodes)
#
# The emitted tree is a build artifact (gitignored). Publish it as the dedicated
# public verification repo, run the throwaway managed deploy + `cargo stylus
# verify` from it, then redeploy production from the same tree.
set -euo pipefail

# Expected raw wasm from building THIS tree. The size matches a plain repo build
# of the engine, but the sha256 differs on purpose: promoting the engine to the
# workspace root changes Rust's crate-metadata hashes, so the tree has its own
# deterministic, path-independent hash. NOTE: this tree wasm is NOT the deployed
# artifact and is OVER the activation cap by design — the deploy artifact is this
# wasm run through the pinned recipe in script/wasm_opt_recipe.sh, which activates.
# Sizes are deliberately not quoted in prose here: EXPECT_SIZE below and the
# deploy-artifact report are the source of truth. Because the deploy path does
# not replay that recipe, `cargo stylus verify` rebuilds this tree and cannot
# reproduce the deployed bytes; re-derive them via the documented wasm-opt step.
EXPECT_SIZE=326426
EXPECT_SHA256=ef021c78379042407cdd4edb6298951027b1fd139f84af12db11e5cb6cb997d2

# --opt-check: activation binds on the DEPLOYED artifact = this wasm after the pinned wasm-opt
# post-pass, on two independent counts — total size, and opcodes in any single function body.
# Both are checked here (against the budgets in script/wasm_opt_recipe.sh) so a change that eats
# either one fails ordinary CI instead of surfacing at deploy.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=script/wasm_opt_recipe.sh
. "$REPO_ROOT/script/wasm_opt_recipe.sh"

DO_BUILD=0
DO_OPT_CHECK=0
OUT_DIR=""
for arg in "$@"; do
    case "$arg" in
    --build) DO_BUILD=1 ;;
    --opt-check)
        DO_BUILD=1
        DO_OPT_CHECK=1
        ;;
    -h | --help)
        sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "unknown option: $arg (use --build, --opt-check or --help)" >&2
        exit 2
        ;;
    *) OUT_DIR="$arg" ;;
    esac
done
OUT_DIR="${OUT_DIR:-$REPO_ROOT/verify-tree}"

# The tuned release profile. In this repo it lives only in the workspace root
# Cargo.toml and perp-engine inherits it via the workspace; in the verify-tree
# the engine IS the root, so it must be declared explicitly or the build falls
# back to the default profile (opt-level=3, no lto) and produces a different,
# larger wasm.
RELEASE_PROFILE='[profile.release]
codegen-units = 1
strip = true
lto = true
panic = "abort"
opt-level = "z"'

# Drop a whole TOML table (its header line and following keys, up to the next
# table header) from stdin.
drop_toml_table() { awk -v t="[$1]" '/^\[/ { skip = ($0 == t) ? 1 : 0 } !skip { print }'; }

die() {
    echo "  [FAIL] $1" >&2
    exit 1
}

# Guard against a destructive OUT_DIR before the rm -rf.
case "$OUT_DIR" in
"" | "/" | "$REPO_ROOT" | "$REPO_ROOT/") die "refusing to generate into '$OUT_DIR'" ;;
esac

echo "== generate verification tree =="
echo "  repo : $REPO_ROOT"
echo "  out  : $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/src" "$OUT_DIR/.cargo" "$OUT_DIR/curve-math/src/rust"

# 1) Engine sources at the root, minus the external test module.
for f in "$REPO_ROOT"/perp-engine/src/*.rs; do
    [ "$(basename "$f")" = "tests.rs" ] && continue
    cp "$f" "$OUT_DIR/src/"
done
[ -e "$OUT_DIR/src/tests.rs" ] && die "tests.rs leaked into the tree"

# 2) Strip the trailing `#[cfg(test)] mod tests;` pair from lib.rs. Removing only
#    `mod tests;` would leave a dangling cfg attribute (compile error), so both
#    lines go. Matched by content (not line number) to survive edits above them.
awk '
  { line[NR] = $0 }
  END {
    last = NR
    while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
    if (line[last] == "mod tests;" && line[last-1] == "#[cfg(test)]") { d1 = last; d2 = last - 1 }
    else { print "cfg-test-pair-not-found" > "/dev/stderr"; exit 3 }
    for (i = 1; i <= NR; i++) if (i != d1 && i != d2) print line[i]
  }
' "$REPO_ROOT/perp-engine/src/lib.rs" > "$OUT_DIR/src/lib.rs" || die "lib.rs test-module pair not found (source drifted)"
! grep -q '^mod tests;' "$OUT_DIR/src/lib.rs" || die "mod tests; not stripped from lib.rs"

# 3) Curve crate: copy ONLY Cargo.toml + CurveMath.rs, then strip the inline
#    `#[cfg(test)] mod parity` block (to EOF) from the copy, so no test code
#    reaches the hashed tree.
CM_SRC="$REPO_ROOT/src/rust/CurveMath.rs"
cut_at=$(awk 'prev == "#[cfg(test)]" && $0 ~ /^mod parity[[:space:]]*\{/ { print NR - 1; exit } { prev = $0 }' "$CM_SRC")
[ -n "$cut_at" ] || die "parity test module not found in CurveMath.rs (source drifted)"
head -n "$((cut_at - 1))" "$CM_SRC" > "$OUT_DIR/curve-math/src/rust/CurveMath.rs"
! grep -q 'mod parity' "$OUT_DIR/curve-math/src/rust/CurveMath.rs" || die "parity module not stripped from CurveMath.rs"

# 4) Curve crate Cargo.toml = the repo root Cargo.toml, minus [workspace] (points
#    at perp-engine/, which no longer exists here) and [profile.release] (only the
#    tree root declares it).
drop_toml_table workspace < "$REPO_ROOT/Cargo.toml" | drop_toml_table profile.release > "$OUT_DIR/curve-math/Cargo.toml"
! grep -qE '^\[workspace\]|^\[profile\.release\]' "$OUT_DIR/curve-math/Cargo.toml" || die "workspace/profile not stripped from curve Cargo.toml"

# 5) Engine Cargo.toml at the root: repoint the curve dependency to the vendored
#    child, drop the now-inaccurate "profile inherited from workspace" note, and
#    append an explicit (empty) [workspace] table plus the tuned release profile.
#    The [workspace] table makes this crate its own workspace root, so cargo does
#    not absorb it into a parent workspace when the tree is generated inside
#    another repo (e.g. the default ./verify-tree next to this repo's Cargo.toml).
sed -E 's#(denaria-curve-math-stylus = \{ path = )"\.\."#\1"./curve-math"#' "$REPO_ROOT/perp-engine/Cargo.toml" \
    | sed -E '/release profile is defined once/d; /do not redefine it here/d' \
        > "$OUT_DIR/Cargo.toml"
grep -q 'path = "./curve-math"' "$OUT_DIR/Cargo.toml" || die "curve dependency not repointed to ./curve-math"
! grep -q 'path = "\.\."' "$OUT_DIR/Cargo.toml" || die "stale path = \"..\" remains in engine Cargo.toml"
printf '\n[workspace]\n\n%s\n' "$RELEASE_PROFILE" >> "$OUT_DIR/Cargo.toml"

# 6) Combined single-package cargo-stylus manifest.
printf '[workspace]\n\n[workspace.networks]\n\n[contract]\n' > "$OUT_DIR/Stylus.toml"

# 7) Carry the pinned toolchain, cargo config, and the EXACT lockfile that
#    produced the deployed wasm (a re-resolve could shift transitive versions).
cp "$REPO_ROOT/rust-toolchain.toml" "$OUT_DIR/rust-toolchain.toml"
cp "$REPO_ROOT/.cargo/config.toml" "$OUT_DIR/.cargo/config.toml"
cp "$REPO_ROOT/Cargo.lock" "$OUT_DIR/Cargo.lock"

# 8) Reconcile the lockfile to the new workspace root. Promoting the engine to
#    the root drops the curve crate's dev-dependencies from the resolved graph,
#    so cargo (which cargo-stylus invokes with --locked) rejects the verbatim
#    repo lock. This prunes the now-unused entries offline — no version bumps —
#    leaving the tree buildable and reproducible.
echo "  reconciling Cargo.lock for the new workspace root..."
if ! (cd "$OUT_DIR" && cargo metadata --offline --format-version 1 >/dev/null 2>&1); then
    (cd "$OUT_DIR" && cargo metadata --format-version 1 >/dev/null 2>&1) \
        || die "could not reconcile Cargo.lock (needs cargo and the cached dependencies)"
fi

echo "  [OK] tree generated:"
(cd "$OUT_DIR" && find . -type f | sort | sed 's/^/         /')

if [ "$DO_BUILD" != "1" ]; then
    echo
    echo "  Next: cd '$OUT_DIR' && CARGO_TARGET_DIR=<writable> cargo stylus build"
    echo "        (or re-run this script with --build to build and check the artifact)"
    exit 0
fi

# --build: prove the generated tree reproduces the expected wasm.
echo
echo "== reproducible build (cargo stylus build) =="
TARGET_DIR="$(mktemp -d)"
trap 'rm -rf "$TARGET_DIR"' EXIT
(cd "$OUT_DIR" && CARGO_TARGET_DIR="$TARGET_DIR" cargo stylus build) || die "cargo stylus build failed"

WASM="$(find "$TARGET_DIR" -name '*.wasm' -path '*release*' -size +1k | sort | tail -1)"
[ -n "$WASM" ] || die "no release wasm produced"
SIZE=$(wc -c < "$WASM")
SHA=$(sha256sum "$WASM" | awk '{print $1}')
echo "  wasm  : $WASM"
echo "  size  : $SIZE (expected $EXPECT_SIZE)"
echo "  sha256: $SHA"
echo "          expected $EXPECT_SHA256"

FAIL=0
[ "$SIZE" = "$EXPECT_SIZE" ] || { echo "  [FAIL] size mismatch"; FAIL=1; }
[ "$SHA" = "$EXPECT_SHA256" ] || { echo "  [FAIL] sha256 mismatch — check [profile.release] (step 5) and Cargo.lock (step 7)"; FAIL=1; }
if [ "$FAIL" = 0 ]; then
    echo "  [OK] verification tree reproduces the expected engine wasm."
else
    exit 1
fi

if [ "$DO_OPT_CHECK" = 1 ]; then
    echo
    echo "== activation-budget check (binaryen $BINARYEN_VERSION, pinned recipe) =="
    WOPT="$(resolve_wasm_opt "$TARGET_DIR")" || die "binaryen ${BINARYEN_VERSION} could not be resolved"
    OPT_OUT="$TARGET_DIR/engine.Oz.wasm"
    "$WOPT" "${WASM_OPT_FLAGS[@]}" "$WASM" -o "$OPT_OUT"
    OPT_SIZE=$(wc -c < "$OPT_OUT")
    read -r OPT_FUNCS OPT_MAX_BODY < <(python3 "$REPO_ROOT/script/wasm_max_body.py" "$OPT_OUT")
    # An unmeasured budget must fail the gate, not skip the check: a non-numeric value would make
    # the comparison below error out and be read as "not over the limit".
    case "${OPT_MAX_BODY:-}" in '' | *[!0-9]*) die "could not measure the largest function body" ;; esac
    echo "  optimized size: $OPT_SIZE B (limit $OPT_SIZE_LIMIT)"
    echo "  headroom: $((STYLUS_MAX_WASM_SIZE - OPT_SIZE - DEPLOY_SECTION_OVERHEAD)) B under the $STYLUS_MAX_WASM_SIZE B decompressed budget"
    echo "  functions: $OPT_FUNCS, largest body: $OPT_MAX_BODY B (opcode limit $STYLUS_MAX_FUNC_OPCODES)"
    FAIL=0
    if [ "$OPT_SIZE" -gt "$OPT_SIZE_LIMIT" ]; then
        echo "  [FAIL] optimized artifact exceeds the size budget"
        FAIL=1
    fi
    if [ "$OPT_MAX_BODY" -ge "$STYLUS_MAX_FUNC_OPCODES" ]; then
        echo "  [FAIL] largest function body may exceed the per-function opcode limit"
        FAIL=1
    fi
    [ "$FAIL" = 0 ] || exit 1
    echo "  [OK] deploy artifact fits the activation budget."
fi
