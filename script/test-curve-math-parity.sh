#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/tests"

cat >"$tmp_dir/Cargo.toml" <<EOF
[package]
name = "denaria-curve-math-parity-tests"
version = "0.1.0"
edition = "2021"
license = "BUSL-1.1"
publish = false

[dependencies]
serde_json = "1"
stylus-sdk = "0.10.7"

[features]
default = []
export-abi = ["stylus-sdk/export-abi"]
contract-client-gen = []
standalone-abi = []

[[test]]
name = "curve_math_parity"
path = "tests/curve_math_parity.rs"

[workspace]
EOF

cat >"$tmp_dir/tests/curve_math_parity.rs" <<EOF
#![allow(dead_code)]

#[path = "$repo_root/src/rust/CurveMath.rs"]
mod curve_math;

mod tests {
    use super::curve_math::*;

    include!("$repo_root/src/rust/curve_math_parity.inc");
}
EOF

if [[ "${1:-}" == "--clippy" ]]; then
  shift
  DENARIA_PERP_ROOT="$repo_root" cargo clippy --offline --manifest-path "$tmp_dir/Cargo.toml" --all-targets -- "$@"
else
  DENARIA_PERP_ROOT="$repo_root" cargo test --offline --manifest-path "$tmp_dir/Cargo.toml" "$@"
fi
