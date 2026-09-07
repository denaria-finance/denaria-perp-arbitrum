#!/usr/bin/env bash
# Canonical deploy-artifact pipeline (H1): build the reproducible verify-tree wasm, apply the
# pinned wasm-opt post-pass, structurally validate it, and emit a size/fragment/provenance
# report. The optimized `engine.Oz.wasm` this produces is THE artifact to deploy.
#
# Usage:
#   bash script/build_deploy_artifact.sh            # build + wasm-opt + validate + report
#   RPC=https://sepolia-rollup.arbitrum.io/rpc bash script/build_deploy_artifact.sh  # + activation check
#
# Requires: the pinned Rust toolchain (rust-toolchain.toml), cargo-stylus 0.10.8, curl/tar.
# wasm-tools and wasm-opt are auto-fetched if missing.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# shellcheck source=script/wasm_opt_recipe.sh
. "$REPO/script/wasm_opt_recipe.sh"

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

echo "== [2/5] wasm-opt (binaryen $BINARYEN_VERSION, pinned recipe) =="
WOPT="$(resolve_wasm_opt "$WORK")" || { echo "FATAL: could not resolve wasm-opt $BINARYEN_VERSION"; exit 1; }
"$WOPT" "${WASM_OPT_FLAGS[@]}" "$RAW" -o "$OUT"
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

# Activation also rejects a module with too many opcodes in ONE function body, independently of
# the module's total size. wasm-opt's inlining is what pushes a body over, so this is checked on
# the OPTIMISED artifact; script/wasm_max_body.py explains the proxy it measures.
read -r FUNCS MAX_BODY < <(python3 "$REPO/script/wasm_max_body.py" "$OUT")
# An unmeasured budget must fail the build, not skip the check: a non-numeric value would make
# the comparison below error out and be read as "not over the limit".
case "${MAX_BODY:-}" in '' | *[!0-9]*) echo "FATAL: could not measure the largest function body"; exit 1 ;; esac
echo "  functions: $FUNCS, largest body: $MAX_BODY B (opcode limit $STYLUS_MAX_FUNC_OPCODES)"

echo "== [4/5] size / headroom / fragments =="
# The chain measures the module cargo-stylus submits, not the file on disk.
SUBMITTED=$(( OPT_SIZE + DEPLOY_SECTION_OVERHEAD ))
HEADROOM=$(( STYLUS_MAX_WASM_SIZE - SUBMITTED ))
BROTLI="?"
command -v brotli >/dev/null 2>&1 && BROTLI=$(brotli -c "$OUT" | wc -c)

{
  echo "Denaria deploy-artifact report"
  echo "commit:            $(git rev-parse HEAD 2>/dev/null || echo '?')"
  echo "raw wasm size:     $RAW_SIZE B"
  echo "raw wasm sha256:   $RAW_SHA"
  echo "optimized size:    $OPT_SIZE B   (binaryen $BINARYEN_VERSION, ${WASM_OPT_FLAGS[*]})"
  echo "optimized sha256:  $OPT_SHA"
  echo "brotli size:       $BROTLI B"
  echo "submitted size:    $SUBMITTED B (artifact + project_hash section)"
  echo "size budget:       $STYLUS_MAX_WASM_SIZE B decompressed; headroom: $HEADROOM B"
  echo "largest body:      $MAX_BODY B of $FUNCS functions (opcode limit $STYLUS_MAX_FUNC_OPCODES)"
  echo "exports:           $EXPORTS"
  echo "imports (hostio):  $IMPORTS"
  echo "user_entrypoint:   $([ "$HAS_ENTRY" != "0" ] && echo present || echo MISSING)"
} | tee "$REPORT"

if [ "$OPT_SIZE" -gt "$OPT_SIZE_LIMIT" ]; then
  echo "FATAL: optimized artifact ($OPT_SIZE B) is over the size budget ($OPT_SIZE_LIMIT B ="
  echo "       $STYLUS_MAX_WASM_SIZE decompressed, less the deploy overhead and safety margin)"; exit 1
fi
if [ "$MAX_BODY" -ge "$STYLUS_MAX_FUNC_OPCODES" ]; then
  echo "FATAL: largest function body ($MAX_BODY B) may exceed the Stylus per-function opcode"
  echo "       limit ($STYLUS_MAX_FUNC_OPCODES) — the artifact would fail activation"; exit 1
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
