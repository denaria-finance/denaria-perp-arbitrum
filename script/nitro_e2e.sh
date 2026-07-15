#!/usr/bin/env bash
# Nitro mixed-VM end-to-end money-path (H2). Brings up a local, offline, Stylus-capable Nitro
# dev node (ArbOS 60), deploys the Solidity periphery + the engine, and drives a full open->close
# trade journey — exercising the real Stylus<->EVM boundary (sol_interface! calls, ABI decode,
# revert propagation, storage-cache) that native `stylus-test` cannot.
#
# INITIALIZATION: the engine initializes atomically via its Stylus `#[constructor]`, routed through
# the canonical `StylusDeployer`. A bare dev node does NOT ship that contract, so provide one:
#   STYLUS_DEPLOYER=0x...   (an address with the StylusDeployer code on this chain)
# On Arbitrum Sepolia the canonical deployer (0xcEcba2F1DC234f70Dd89F2041029807F8D03A990) is present,
# so this lane runs end-to-end there. On a bare dev node without a deployer the constructor does not
# run (the engine activates but stays uninitialized); the script detects this and stops with a clear
# message rather than a false pass. (The money-path logic itself was validated on Nitro during the
# wasm-opt differential; this lane codifies the production constructor deploy path.)
#
# Requires: docker, the pinned Rust toolchain + wasm32 target, cargo-stylus 0.10.7, foundry, binaryen.
# Heavy: pulls a ~3.5 GB Nitro image on first run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
RPC="${RPC:-http://127.0.0.1:8547}"
NITRO_IMAGE="${NITRO_IMAGE:-offchainlabs/nitro-node:v3.11.1-8512b8c}"
DEVKEY=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
ADMIN="${ADMIN:-0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E}"
TAKER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TAKERKEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
FRONTEND=0x1acA719546988cffe97265575c2C7F0D0aA488D8
ARBOWNER=0x0000000000000000000000000000000000000070
ARBSYS=0x0000000000000000000000000000000000000064
STYLUS_DEPLOYER="${STYLUS_DEPLOYER:-}"
DEMO_PRICE=6261365913505
WAD=1000000000000000000
MAXFEE=1000000000000000000000000000000
SIZE=$(python3 -c "print(100*10**18)")
LIQSTABLE=$(python3 -c "print(30000*10**18)")
LIQASSET=$(python3 -c "print(30000*10**18*10**8//$DEMO_PRICE)")
REPORT=0x
# Engine constructor config (matches example.env / the benchmark configuration).
MMR=40000
TICKER=0x3078353535333434326434323534343300000000000000000000000000000000
FEE_FRONTEND=300000; FEE_LP=500000; FEE_PROTOCOL=0x1acA719546988cffe97265575c2C7F0D0aA488D8
TRADING_FEE=0; FLAT_TRADING_FEE=120000000000000000; EMA_PARAM=90000000

MANAGE_NODE=1; [ -n "${RPC_EXTERNAL:-}" ] && MANAGE_NODE=0
cleanup() { [ "$MANAGE_NODE" = "1" ] && docker rm -f nitro-e2e >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "E2E FAIL: $1"; exit 1; }
oksend() { cast send "$@" -r "$RPC" >/dev/null 2>&1 || fail "tx failed: $*"; }

if [ "$MANAGE_NODE" = "1" ]; then
  echo "== [1/7] start Nitro dev node ($NITRO_IMAGE) + upgrade to ArbOS 60 =="
  docker rm -f nitro-e2e >/dev/null 2>&1 || true
  docker run -d --rm --name nitro-e2e --network host "$NITRO_IMAGE" \
    --dev --http.addr 127.0.0.1 --http.port 8547 --http.api=net,web3,eth,debug,arb \
    --http.corsdomain='*' --http.vhosts='*' >/dev/null
  for i in $(seq 1 60); do curl -s -m 3 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC" 2>/dev/null | grep -q result && break; sleep 1; done
  cast send 0x00000000000000000000000000000000000000FF "becomeChainOwner()" --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1
  cast send $ARBOWNER "scheduleArbOSUpgrade(uint64,uint64)" 60 0 --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1
  cast send $TAKER --value 0 --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1
  cast send $ARBOWNER "setWasmMaxSize(uint32)" 524288 --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1
  cast send $ARBOWNER 'setL1PricePerUnit(uint256)' 0 --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1
  [ "$(cast call $ARBSYS 'arbOSVersion()(uint64)' -r "$RPC" 2>/dev/null | head -1)" = "115" ] || fail "ArbOS 60 not reached"
else
  echo "== [1/7] using external node at $RPC =="
fi

echo "== [2/7] build the deploy artifact (verify-tree + wasm-opt) =="
WORK="${WORK:-$(mktemp -d)}" bash script/build_deploy_artifact.sh >/dev/null || fail "artifact build failed"
[ -f engine.Oz.wasm ] || fail "no engine.Oz.wasm"

echo "== [3/7] deploy the Solidity periphery =="
cast send $TAKER --value 10ether --private-key $DEVKEY -r "$RPC" >/dev/null 2>&1 || true
export PRIVATE_KEY=$DEVKEY TAKER=$TAKER
forge script script/LocalNitroDeploy.s.sol:LocalNitroDeploy --rpc-url "$RPC" --broadcast --skip-simulation >/tmp/e2e.deploy.log 2>&1 \
  || { tail -5 /tmp/e2e.deploy.log; fail "periphery deploy failed"; }
A() { grep "ADDR:$1 " /tmp/e2e.deploy.log | awk '{print $NF}'; }
MANAGER=$(A MANAGER); VAULT=$(A VAULT); ORACLE=$(A ORACLE); STABLE=$(A STABLECOIN); LNF=$(A LOSTANDFOUND)
echo "   MANAGER=$MANAGER VAULT=$VAULT ORACLE=$ORACLE"

echo "== [4/7] deploy the engine via its #[constructor] (atomic init through StylusDeployer) =="
DEPLOYER_ARG=(); [ -n "$STYLUS_DEPLOYER" ] && DEPLOYER_ARG=(--deployer-address "$STYLUS_DEPLOYER")
DEP=$(cargo stylus deploy --wasm-file engine.Oz.wasm --no-verify "${DEPLOYER_ARG[@]}" \
  --private-key $DEVKEY -e "$RPC" \
  --constructor-signature "constructor(address,address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)" \
  --constructor-args "$ADMIN" "$ORACLE" "$VAULT" "$MANAGER" $MMR "$TICKER" $FEE_FRONTEND $FEE_LP "$FEE_PROTOCOL" $TRADING_FEE $FLAT_TRADING_FEE $EMA_PARAM 2>&1)
ENGINE=$(echo "$DEP" | grep -oiE 'deployed code at address: .*(0x[0-9a-f]{40})' | grep -oiE '0x[0-9a-f]{40}' | head -1)
[ -n "$ENGINE" ] || { echo "$DEP" | tail -3; fail "engine deploy/parse failed"; }
echo "   ENGINE=$ENGINE"
if [ "$(cast call "$ENGINE" 'MMR()(uint256)' -r "$RPC" 2>/dev/null | head -1)" = "0" ]; then
  echo ""
  echo "  The engine ACTIVATED but its #[constructor] did not run (MMR=0), i.e. no working"
  echo "  StylusDeployer on this chain. Provide one via STYLUS_DEPLOYER=0x... (canonical on Sepolia:"
  echo "  0xcEcba2F1DC234f70Dd89F2041029807F8D03A990) and re-run, or run this lane against Sepolia."
  fail "engine not initialized — StylusDeployer required for the production constructor"
fi

echo "== [5/7] wire periphery + arm oracle + fund/seed =="
oksend "$MANAGER" "initializeAddresses(address,address)" "$ENGINE" "$VAULT" --private-key $DEVKEY
oksend "$VAULT" "initializeParameters(address,address)" "$ENGINE" "$LNF" --private-key $DEVKEY
oksend "$ORACLE" "setPrice(uint256)" $DEMO_PRICE --private-key $DEVKEY
oksend "$STABLE" "approve(address,uint256)" "$VAULT" "$(cast max-uint)" --private-key $TAKERKEY
oksend "$VAULT" "addCollateral(uint256[])" "[50000000000]" --private-key $TAKERKEY
oksend "$ENGINE" "addLiquidity(uint256,uint256,uint256,bytes)" $LIQSTABLE $LIQASSET $MAXFEE $REPORT --private-key $TAKERKEY
GLA=$(cast call "$ENGINE" 'globalLiquidityAsset()(uint256)' -r "$RPC" 2>/dev/null | awk '{print $1}')

echo "== [6/7] OPEN long 100 =="
oksend "$ENGINE" "trade(bool,uint256,uint256,uint256,address,uint8,bytes)" true $SIZE 0 "$GLA" "$FRONTEND" 1 $REPORT --private-key $TAKERKEY
POS=$(cast call "$ENGINE" 'userVirtualTraderPosition(address)(uint256,uint256,uint256,uint256,uint256,bool,uint256,bool)' $TAKER -r "$RPC" | tr '\n' ' ')
echo "   position: $POS"
echo "$POS" | grep -qE '100000000000000000000' || fail "position did not open (expected debt 100e18)"

echo "== [7/7] CLOSE =="
oksend "$ENGINE" "closeAndWithdraw(uint256,uint256,address,bytes)" $WAD $MAXFEE "$FRONTEND" $REPORT --private-key $TAKERKEY
POS=$(cast call "$ENGINE" 'userVirtualTraderPosition(address)(uint256,uint256,uint256,uint256,uint256,bool,uint256,bool)' $TAKER -r "$RPC" | tr '\n' ' ')
echo "   position: $POS"
echo "$POS" | grep -qE '^0 0 0 0 0 false 0 false' || fail "position not cleared after close"

echo ""
echo "E2E PASS: constructor deploy + open->close money-path complete on ArbOS-60 (engine $ENGINE)"
