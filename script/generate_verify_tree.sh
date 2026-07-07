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
#   ./script/generate_verify_tree.sh [OUT_DIR]         # generate (default: ./verify-tree)
#   ./script/generate_verify_tree.sh --build [OUT_DIR] # generate, then build and
#                                                      # check the wasm size + sha256
#
# The emitted tree is a build artifact (gitignored). Publish it as the dedicated
# public verification repo, run the throwaway managed deploy + `cargo stylus
# verify` from it, then redeploy production from the same tree.
set -euo pipefail

# Expected raw wasm from building THIS tree. The size matches a plain repo build
# of the engine, but the sha256 differs on purpose: promoting the engine to the
# workspace root changes Rust's crate-metadata hashes, so the tree has its own
# deterministic, path-independent hash. This is the artifact to DEPLOY, so that
# `cargo stylus verify` (which rebuilds this published tree) matches the chain.
EXPECT_SIZE=264273
EXPECT_SHA256=2e5f8069d8d8f95792cd57c63803942f924aa7acf317d1e95e91855d542d9906

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DO_BUILD=0
OUT_DIR=""
for arg in "$@"; do
    case "$arg" in
    --build) DO_BUILD=1 ;;
    -h | --help)
        sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "unknown option: $arg (use --build or --help)" >&2
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

# 3) Curve crate: copy ONLY Cargo.toml + CurveMath.rs. The rest of src/rust/ holds
#    a script-driven parity fixture (curve_math_parity.inc) that must stay in the
#    main repo but out of the hashed tree. Strip the inline `#[cfg(test)] mod
#    parity` block (to EOF) from the copied CurveMath.rs.
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
