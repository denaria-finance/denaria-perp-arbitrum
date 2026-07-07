#!/usr/bin/env bash
# Offline Nitro dev-node → full Denaria stack deploy orchestrator (Tier-3 money-path substrate).
#
# Brings up the REAL production contracts on a local, offline, Stylus-capable chain so a
# trade open/close journey can be driven in CI with zero live-Sepolia / creds / funds.
#
# THE KEY STEP most people miss: the nitro-devnode boots at ArbOS 59, one version below the
# ArbOS 60 that added Stylus contract *fragments* (merge-on-activate, MaxWasmSize 256KB).
# The 46KB PerpEngine REQUIRES fragments, so on ArbOS 59 activation reverts empty. We upgrade
# the running chain to ArbOS 60 (the dev key is chain owner) before deploying the engine.
#
# Prereqs already satisfied on this box (see docs/foundations-fix-progress.md Tier-3):
#   - Nitro dev-node running WITH CORS (the browser E2E talks to the RPC cross-origin):
#     `NITRO_NODE_VERSION=v3.11.1-8512b8c run-dev-node.sh --contract-size 128000` where the
#     node args include `--http.corsdomain='*' --http.vhosts='*'` (patched run-dev-node.sh)
#   - rustup nightly + wasm32 + cargo-stylus 0.10.7 (STOCK — no patch needed post-ArbOS-60)
#   - engine WASM built: cargo build --release --target wasm32-unknown-unknown -p denaria-perp-engine-stylus
#   - RUN THIS FROM THE REPO ROOT (denaria-perp-arbitrum): `cargo stylus deploy` needs the
#     repo as cwd — from elsewhere step 2 fails after step 1 already consumed dev nonces,
#     breaking clean-boot address determinism.
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8547}"
# nitro-devnode's well-known pre-funded dev key (public; chain owner). LOCAL ONLY.
DEVKEY="${DEVKEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
DEV="${DEV:-0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E}"
TAKER="${TAKER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"   # anvil acct #0 = injectEoaProvider default
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WASM="${WASM:-$REPO/target/wasm32-unknown-unknown/release/denaria_perp_engine_stylus.wasm}"
OUT="${OUT:-$REPO/nitro-addresses.json}"

ARBOWNER=0x0000000000000000000000000000000000000070
ARBSYS=0x0000000000000000000000000000000000000064
ARBOWNERPUB=0x000000000000000000000000000000000000006b

echo "==> [1/5] Upgrade chain to ArbOS 60 (fragment support for the 46KB engine)"
cur=$(cast call $ARBSYS "arbOSVersion()(uint64)" -r "$RPC")   # returns 55+version
if [ "$cur" -lt 115 ]; then
  cast send $ARBOWNER "scheduleArbOSUpgrade(uint64,uint64)" 60 0 --private-key "$DEVKEY" -r "$RPC" >/dev/null
  cast send $TAKER --value 0 --private-key "$DEVKEY" -r "$RPC" >/dev/null   # mine a block
fi
echo "    arbOSVersion=$(cast call $ARBSYS 'arbOSVersion()(uint64)' -r "$RPC") (115 = ArbOS 60)"
echo "    maxStylusContractFragments=$(cast call $ARBOWNERPUB 'getMaxStylusContractFragments()(uint8)' -r "$RPC")"

echo "==> [2/5] Deploy + activate the PerpEngine WASM (stock cargo-stylus, fragments)"
DEPLOY_OUT=$(cargo stylus deploy --wasm-file "$WASM" --no-verify --private-key "$DEVKEY" -e "$RPC" 2>&1)
echo "$DEPLOY_OUT" | grep -iE 'deployed code at|activated'
ENGINE=$(echo "$DEPLOY_OUT" | grep -oiE 'deployed code at address: .*(0x[0-9a-f]{40})' | grep -oiE '0x[0-9a-f]{40}' | head -1)
[ -n "$ENGINE" ] || { echo "FATAL: could not parse engine address"; exit 1; }
echo "    PERP_ENGINE=$ENGINE"

echo "==> [3/5] Fund taker + deploy Solidity periphery (Vault, manager, mock oracle, USDCe)"
cast send "$TAKER" --value 10ether --private-key "$DEVKEY" -r "$RPC" >/dev/null
export PRIVATE_KEY="$DEVKEY" PERP_ENGINE="$ENGINE" TAKER="$TAKER"
( cd "$REPO" && forge script script/LocalNitroDeploy.s.sol:LocalNitroDeploy \
    --rpc-url "$RPC" --broadcast --skip-simulation >/tmp/localnitro.deploy.log 2>&1 )
ADDR() { grep "ADDR:$1 " /tmp/localnitro.deploy.log | awk '{print $NF}'; }
MANAGER=$(ADDR MANAGER); VAULT=$(ADDR VAULT); ORACLE=$(ADDR ORACLE); STABLE=$(ADDR STABLECOIN); LNF=$(ADDR LOSTANDFOUND)
# libraries forge auto-deployed (needed by the read smoke)
BC="$REPO/broadcast/LocalNitroDeploy.s.sol/412346/run-latest.json"
UTILMATH=$(python3 -c "import json;print(next(t['contractAddress'] for t in json.load(open('$BC'))['transactions'] if t.get('contractName')=='UtilMath'))")
CURVEMATH=$(python3 -c "import json;print(next(t['contractAddress'] for t in json.load(open('$BC'))['transactions'] if t.get('contractName')=='CurveMath'))")
echo "    MANAGER=$MANAGER VAULT=$VAULT ORACLE=$ORACLE STABLE=$STABLE"

echo "==> [4/5] engine.initializeProduction(...) [params from example.env]"
set -a; source "$REPO/example.env"; set +a
cast send "$ENGINE" \
  "initializeProduction(address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)" \
  "$ORACLE" "$VAULT" "$MANAGER" "$MMR" "$TICKER_ASSET_CURRENCY" "$FEE_FRONTEND" "$FEE_LP" \
  "$FEE_PROTOCOL_ADDR" "$TRADING_FEE" "$FLAT_TRADING_FEE" "$EMA_PARAM" \
  --private-key "$DEVKEY" -r "$RPC" | grep -E 'status|transactionHash'

echo "==> [5/5] Read-surface smoke + write addresses"
ENGINE="$ENGINE" UTILMATH="$UTILMATH" VAULT="$VAULT" RPC="$RPC" PRICE=10000000000000 \
  bash "$REPO/script/post_deploy_read_smoke.sh" | tail -3

cat > "$OUT" <<JSON
{
  "chainId": 412346, "rpcUrl": "$RPC", "arbOsVersion": 60,
  "perpEngine": "$ENGINE", "manager": "$MANAGER", "vault": "$VAULT",
  "oracle": "$ORACLE", "stableCoin": "$STABLE", "lostAndFound": "$LNF",
  "curveMath": "$CURVEMATH", "utilMath": "$UTILMATH",
  "deployer": "$DEV", "taker": "$TAKER"
}
JSON
echo "==> DONE. Addresses → $OUT"
