#!/usr/bin/env bash
# WASM size/structure diagnostics (H9). NOT a gate — a report-only tool for investigating what
# drives the engine's binary size (e.g. after a toolchain/optimizer change). Complements the
# canonical pipeline in build_deploy_artifact.sh.
#
# Usage:
#   bash script/wasm_diagnostics.sh [path/to/engine.wasm]
#
# Tools (fetched with `cargo install` if missing): twiggy (retained-size / dominators),
# wasm-tools (validate / sections / imports / exports). twiggy was archived upstream in 2026 —
# it is pinned as a diagnostic here, not a maintained security gate.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WASM="${1:-$REPO/engine.Oz.wasm}"
[ -f "$WASM" ] || { echo "no wasm at $WASM — build one first (script/build_deploy_artifact.sh)"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
have twiggy   || cargo install twiggy --locked >/dev/null 2>&1 || true
have wasm-tools || cargo install wasm-tools --locked >/dev/null 2>&1 || true

echo "==================================================================="
echo " WASM diagnostics: $WASM  ($(stat -c%s "$WASM") B)"
echo "==================================================================="

if have wasm-tools; then
  echo; echo "== validate =="; wasm-tools validate "$WASM" && echo "OK"
  echo; echo "== exports =="; wasm-tools print "$WASM" 2>/dev/null | grep -E "^\s*\(export " | head
  echo; echo "== imports (hostio) =="
  wasm-tools print "$WASM" 2>/dev/null | grep -E "\(import " | sed -E 's/.*\(import "([^"]+)" "([^"]+)".*/\1::\2/' | sort -u
fi

if have twiggy; then
  echo; echo "== twiggy top (retained size, top 25) =="
  twiggy top -n 25 "$WASM" 2>/dev/null || echo "(twiggy top failed — needs name section; build unstripped for detail)"
  echo; echo "== twiggy dominators (top) =="
  twiggy dominators "$WASM" 2>/dev/null | head -25 || true
else
  echo; echo "(twiggy unavailable — skipping retained-size analysis)"
fi
