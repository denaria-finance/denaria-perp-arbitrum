#!/usr/bin/env bash
# Drive ONE open→close trade journey against the offline Nitro stack (Tier-3 money-path gate).
# Prereq: script/deploy-local-nitro.sh has produced nitro-addresses.json and the stack is live.
#
# Mirrors the proven demo recipe (test/bench/DemoScenarioGasBench.t.sol) at CHAIN LEVEL via cast,
# one account (the taker) as both LP and trader, DIRECT engine/vault calls (no manager forwarder,
# no permit), mock oracle armed with setPrice + empty report bytes.
#
# KEY GOTCHA: closeAndWithdraw's max_slippage is a WAD budget (≤1e18). The Solidity bench's
# 100_000 is too tight for the Stylus engine and reverts empty — use 1e18 (100%) for a plain close.
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8547}"
DEVKEY="${DEVKEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
# taker = anvil acct #0 (injectEoaProvider default); has 1,000,000 USDCe minted by the deploy.
TAKERKEY="${TAKERKEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
TAKER="${TAKER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
J="${J:-$(cd "$(dirname "$0")/.." && pwd)/nitro-addresses.json}"

g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
ENGINE=$(g perpEngine); VAULT=$(g vault); ORACLE=$(g oracle); STABLE=$(g stableCoin)
FRONTEND=0x1acA719546988cffe97265575c2C7F0D0aA488D8
DEMO_PRICE=6261365913505                          # 62,613.66 BTC/USD, 1e8 scale
LIQSTABLE=$(python3 -c "print(30000*10**18)")
LIQASSET=$(python3 -c "print(30000*10**18*10**8//$DEMO_PRICE)")
SIZE=$(python3 -c "print(100*10**18)")
WAD=1000000000000000000
MAXFEE=1000000000000000000000000000000               # 1e30
REPORT=0x                                            # mock oracle no-ops empty report bytes
ok(){ echo "$1" | grep -qE 'status +1' && echo "  ✓ $2" || { echo "  ✗ $2"; echo "$1"|tail -3; exit 1; }; }
pos(){ cast call $ENGINE 'userVirtualTraderPosition(address)(uint256,uint256,uint256,uint256,uint256,bool,uint256,bool)' $TAKER -r $RPC | tr '\n' ' '; }

echo "== arm mock oracle @ DEMO_PRICE"
ok "$(cast send $ORACLE 'setPrice(uint256)' $DEMO_PRICE --private-key $DEVKEY -r $RPC 2>&1)" "setPrice"
echo "== taker: approve + deposit 50k collateral + seed 30k liquidity"
ok "$(cast send $STABLE 'approve(address,uint256)' $VAULT $(cast max-uint) --private-key $TAKERKEY -r $RPC 2>&1)" "approve"
ok "$(cast send $VAULT 'addCollateral(uint256[])' '[50000000000]' --private-key $TAKERKEY -r $RPC 2>&1)" "addCollateral 50k"
ok "$(cast send $ENGINE 'addLiquidity(uint256,uint256,uint256,bytes)' $LIQSTABLE $LIQASSET $MAXFEE $REPORT --private-key $TAKERKEY -r $RPC 2>&1)" "addLiquidity 30k"
GLA=$(cast call $ENGINE 'globalLiquidityAsset()(uint256)' -r $RPC | awk '{print $1}')

echo "== OPEN long 100 (leverage 1)"
ok "$(cast send $ENGINE 'trade(bool,uint256,uint256,uint256,address,uint8,bytes)' true $SIZE 0 $GLA $FRONTEND 1 $REPORT --private-key $TAKERKEY -r $RPC 2>&1)" "trade open"
echo "  position: $(pos)"

echo "== CLOSE (max_slippage=1e18)"
ok "$(cast send $ENGINE 'closeAndWithdraw(uint256,uint256,address,bytes)' $WAD $MAXFEE $FRONTEND $REPORT --private-key $TAKERKEY -r $RPC 2>&1)" "closeAndWithdraw"
P=$(pos); echo "  position: $P"
echo "$P" | grep -qE '^0 0 0 0 0 false 0 false' && echo "== ✅ open→close round-trip complete, position cleared" \
  || { echo "== ✗ position not cleared"; exit 1; }
