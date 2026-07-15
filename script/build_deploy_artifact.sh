#!/usr/bin/env bash
# Canonical deploy-artifact pipeline (H1): build the reproducible verify-tree wasm, apply the
# pinned wasm-opt post-pass, structurally validate it, and emit a size/fragment/provenance
# report. The optimized `engine.Oz.wasm` this produces is THE artifact to deploy.
#
# Usage:
#   bash script/build_deploy_artifact.sh            # build + wasm-opt + validate + report
#   RPC=https://sepolia-rollup.arbitrum.io/rpc bash script/build_deploy_artifact.sh  # + activation check
#
# Requires: the pinned Rust toolchain (rust-toolchain.toml), cargo-stylus 0.10.7, curl/tar.
# wasm-tools and wasm-opt are auto-fetched if missing.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

BINARYEN_VERSION="version_119"
CAP=282900            # empirical raw-wasm activation cap (~282.9 KB); keep headroom below it
OUT="$REPO/engine.Oz.wasm"
REPORT="$REPO/deploy-artifact-report.txt"
WORK="${WORK:-$(mktemp -d)}"

echo "== [1/5] generate + build the verify-tree wasm =="
./script/generate_verify_tree.sh >/dev/null
( cd verify-tree && CARGO_TARGET_DIR="$WORK/vt" cargo stylus build >/dev/null )
RAW="$(find "$WORK/vt" -name '*.wasm' -path '*release*' -size +100k | sort | tail -1)"
[ -n "$RAW" ] || { echo "FATAL: no verify-tree wasm produced"; exit 1; }
RAW_SIZE=$(stat -c%s "$RAW")
RAW_SHA=$(sha256sum "$RAW" | cut -d' ' -f1)

echo "== [2/5] wasm-opt -Oz (binaryen $BINARYEN_VERSION, pinned) =="
WOPT="$(command -v wasm-opt || true)"
if [ -z "$WOPT" ]; then
  TAR="$WORK/binaryen.tar.gz"
  curl -sL -o "$TAR" "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz"
  tar xzf "$TAR" -C "$WORK"
  WOPT="$WORK/binaryen-${BINARYEN_VERSION}/bin/wasm-opt"
fi
"$WOPT" -Oz \
  --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
  --enable-nontrapping-float-to-int --enable-reference-types \
  "$RAW" -o "$OUT"
OPT_SIZE=$(stat -c%s "$OUT")
OPT_SHA=$(sha256sum "$OUT" | cut -d' ' -f1)

echo "== [3/5] structural validation (wasm-tools validate) =="
WTOOLS="$(command -v wasm-tools || true)"
if [ -z "$WTOOLS" ]; then cargo install wasm-tools --locked >/dev/null 2>&1 || true; WTOOLS="$(command -v wasm-tools || true)"; fi
if [ -n "$WTOOLS" ]; then
  "$WTOOLS" validate "$OUT" && echo "  wasm-tools validate: OK"
  EXPORTS=$("$WTOOLS" print "$OUT" 2>/dev/null | grep -cE "^\s*\(export ") || true
  IMPORTS=$("$WTOOLS" print "$OUT" 2>/dev/null | grep -cE "\(import ") || true
  HAS_ENTRY=$("$WTOOLS" print "$OUT" 2>/dev/null | grep -c "user_entrypoint" || true)
else
  echo "  wasm-tools not available — skipping structural validation"
  EXPORTS="?"; IMPORTS="?"; HAS_ENTRY="?"
fi

echo "== [4/5] size / headroom / fragments =="
HEADROOM=$(( CAP - OPT_SIZE ))
BROTLI="?"
command -v brotli >/dev/null 2>&1 && BROTLI=$(brotli -c "$OUT" | wc -c)

{
  echo "Denaria deploy-artifact report"
  echo "commit:            $(git rev-parse HEAD 2>/dev/null || echo '?')"
  echo "raw wasm size:     $RAW_SIZE B"
  echo "raw wasm sha256:   $RAW_SHA"
  echo "optimized size:    $OPT_SIZE B   (wasm-opt -Oz, binaryen $BINARYEN_VERSION)"
  echo "optimized sha256:  $OPT_SHA"
  echo "brotli size:       $BROTLI B"
  echo "activation cap:    ~$CAP B (raw); headroom: $HEADROOM B"
  echo "exports:           $EXPORTS"
  echo "imports (hostio):  $IMPORTS"
  echo "user_entrypoint:   $([ "$HAS_ENTRY" != "0" ] && echo present || echo MISSING)"
} | tee "$REPORT"

if [ "$OPT_SIZE" -ge "$CAP" ]; then
  echo "FATAL: optimized artifact ($OPT_SIZE B) is at/over the activation cap (~$CAP B)"; exit 1
fi
[ "$HAS_ENTRY" = "0" ] && { echo "FATAL: user_entrypoint export missing"; exit 1; }

echo "== [5/5] activation check =="
if [ -n "${RPC:-}" ]; then
  cargo stylus check --wasm-file "$OUT" -e "$RPC" 2>&1 | grep -iE "contract size|data fee|reverted" || true
  echo "  (a priced 'wasm data fee' = activation SUCCESS; 'execution reverted' = FAIL)"
else
  echo "  RPC not set — skipping the on-chain activation check."
  echo "  Run: cargo stylus check --wasm-file $OUT -e <RPC>"
fi

echo ""
echo "DONE. Deploy artifact: $OUT  ($OPT_SIZE B, sha256 $OPT_SHA)"
echo "Report: $REPORT"
