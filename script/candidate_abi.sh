#!/usr/bin/env bash
# Candidate-ABI assurance (H3): regenerate the MACRO-AUTHORITATIVE engine ABI from
# the CURRENT source with `cargo … --features export-abi` (the official Stylus ABI
# export, not regex text-parsing) and diff it against the committed candidate
# snapshot. Two explicit lanes, per the tooling audit:
#
#   - DEPLOYED ABI  : abis/PerpEngine.json — pinned to the LIVE engine (0x656a…1352),
#                     regenerated only on redeploy. NOT the current source.
#   - CANDIDATE ABI : abis/PerpEngine.candidate.abi.sol — generated from the
#                     current source tree; THIS script keeps it in sync in CI.
#
# The regex checks (script/selector_manifest.py, selector_dependency_audit.py) stay
# as fast diagnostics; this generated interface is the source of truth.
#
# Exit 0 = candidate snapshot matches the current source; 1 = drift (regen+commit).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
SNAPSHOT="abis/PerpEngine.candidate.abi.sol"
DEPLOYED="abis/PerpEngine.json"
GEN="$(mktemp)"
trap 'rm -f "$GEN"' EXIT

echo "== candidate ABI check =="
cargo run --locked -q -p denaria-perp-engine-stylus --features export-abi >"$GEN"

if ! diff -u "$SNAPSHOT" "$GEN" >/tmp/candidate_abi.diff 2>&1; then
    echo "  [FAIL] CANDIDATE ABI DRIFT — the generated engine interface differs from the snapshot:"
    sed 's/^/    /' /tmp/candidate_abi.diff
    echo "  Regenerate + commit:"
    echo "    cargo run -q -p denaria-perp-engine-stylus --features export-abi > $SNAPSHOT"
    exit 1
fi
NFUNCS=$(grep -cE '^\s*function ' "$SNAPSHOT")
echo "  [OK] candidate snapshot matches the current source ($NFUNCS functions)."

# INFO (non-failing): make the DEPLOYED-vs-CANDIDATE gap explicit rather than silent.
# The deployed ABI is intentionally pinned to the older live engine; names that differ
# are exactly what a redeploy + `abis/PerpEngine.json` regen (runbook §11) will close.
if [ -f "$DEPLOYED" ] && command -v python3 >/dev/null 2>&1; then
    echo "  deployed-vs-candidate function-name delta (informational):"
    python3 - "$SNAPSHOT" "$DEPLOYED" <<'PY' | sed 's/^/    /'
import json, re, sys
cand = set(re.findall(r'^\s*function (\w+)\(', open(sys.argv[1]).read(), re.M))
dep = {f.get("name") for f in json.load(open(sys.argv[2])) if f.get("type") == "function"}
only_cand = sorted(cand - dep)
only_dep = sorted(dep - cand)
print(f"candidate-only (land on redeploy): {', '.join(only_cand) or '(none)'}")
print(f"deployed-only  (removed in source): {', '.join(only_dep) or '(none)'}")
print(f"shared: {len(cand & dep)}  candidate: {len(cand)}  deployed: {len(dep)}")
PY
fi
