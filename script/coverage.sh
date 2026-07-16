#!/usr/bin/env bash
# Rust coverage baseline (H8) via cargo-llvm-cov over the deployed logic (the Rust
# engine, run under `stub_boundary` so the oracle-path tests actually execute).
#
# Purpose: establish a REALISTIC baseline before enforcing any coverage threshold —
# the tooling audit's guidance is to measure first, not gate on an unmeasured number.
# Read-only; produces a report, changes no source.
#
# Usage:
#   ./script/coverage.sh            # summary table (engine + curve-math)
#   ./script/coverage.sh --html     # + HTML report under target/llvm-cov/html
#   ./script/coverage.sh --lcov     # + lcov.info (CI upload / diff-cover)
#
# Complementary fuzzing (post-baseline, per the audit — run these once a threshold
# is set, as they are heavier and some need their own harness crate):
#   - proptest shrinking properties on the pure math live in the curve-math tests
#     (cargo test -p denaria-curve-math-stylus);
#   - cargo-fuzz / libFuzzer targets for the pure curve, matrix, and signed-arith
#     functions belong in a separate `fuzz/` crate (nightly + libfuzzer-sys); native
#     fuzzing complements but does NOT replace the Nitro lane (no ArbOS HostIO/Ink/traps).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

EXTRA=()
for a in "$@"; do case "$a" in
    --html) EXTRA+=(--html) ;;
    --lcov) EXTRA+=(--lcov --output-path lcov.info) ;;
    -h | --help)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown arg: $a (use --html, --lcov, or --help)" >&2
        exit 2
        ;;
esac; done

if ! cargo llvm-cov --version >/dev/null 2>&1; then
    echo "cargo-llvm-cov not installed. Install with:"
    echo "  rustup component add llvm-tools-preview"
    echo "  cargo install cargo-llvm-cov --locked"
    exit 127
fi

# Merge both deploy-tree crates into one report. --no-report accumulates raw profdata;
# the final `report` renders the combined result. curve-math runs on its default target;
# the engine needs `stub_boundary` so trade/close/liquidation/funding tests execute.
cargo llvm-cov clean --workspace
cargo llvm-cov --locked --no-report -p denaria-curve-math-stylus
cargo llvm-cov --locked --no-report -p denaria-perp-engine-stylus --features stub_boundary
cargo llvm-cov report "${EXTRA[@]}"
