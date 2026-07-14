#!/usr/bin/env bash
# Post-deploy READ-SURFACE smoke test for the hybrid Stylus/Solidity perp stack.
#
# Motivation: every UtilMath read path (calcMR / returnTradeInfo / _calcPnL /
# calcHypotheticalMR) and Vault.removeCollateral revert if UtilMath's typed
# callbacks hit selectors the Stylus engine does not expose. A post-deploy
# check that only cast-calls the engine's own getters misses this. This script
# is the gate: it drives the FULL front-end-shaped read surface end-to-end
# (engine direct + through UtilMath + Vault) and classifies every revert:
#
#   - empty revert data ("0x")        -> FAIL  (Stylus router miss = missing selector)
#   - Error(string) revert (0x08c379a0) -> WARN (functional revert, e.g. OM2 oracle)
#   - success                          -> OK
#
# Run after EVERY deploy, before re-pointing the front-end:
#   ENGINE=0x… UTILMATH=0x… VAULT=0x… BATCHER=0x… RPC=https://sepolia-rollup.arbitrum.io/rpc \
#     ./script/post_deploy_read_smoke.sh
#
# Optional: USER (default: zero-position probe address), PRICE (1e8-scale,
# default 3000e8 — only revert-classification matters, not the quoted values).
set -u

RPC="${RPC:-https://sepolia-rollup.arbitrum.io/rpc}"
ENGINE="${ENGINE:?set ENGINE=<PerpEngine address>}"
UTILMATH="${UTILMATH:?set UTILMATH=<UtilMath library address>}"
VAULT="${VAULT:?set VAULT=<Vault address>}"
BATCHER="${BATCHER:-}"
USER_ADDR="${USER_ADDR:-0x00000000000000000000000000000000000A11CE}"
PRICE="${PRICE:-300000000000}" # 3000e8

FAILS=0
WARNS=0

check() { # check <label> <expectation:must-pass|may-warn> <cast args...>
    local label="$1" expectation="$2"
    shift 2
    local out
    out=$(cast call "$@" --rpc-url "$RPC" 2>&1)
    if [ $? -eq 0 ]; then
        echo "  [OK]   $label"
        return
    fi
    if echo "$out" | grep -q 'data: "0x"'; then
        echo "  [FAIL] $label — EMPTY revert (0x): missing selector / router miss"
        FAILS=$((FAILS + 1))
    elif echo "$out" | grep -q 'data: "0x08c379a0'; then
        local reason
        reason=$(echo "$out" | grep -o 'data: "0x[0-9a-f]*"' | head -1)
        if [ "$expectation" = "may-warn" ]; then
            echo "  [WARN] $label — Error(string) revert (functional, e.g. OM2): $reason"
            WARNS=$((WARNS + 1))
        else
            echo "  [FAIL] $label — unexpected Error(string) revert: $reason"
            FAILS=$((FAILS + 1))
        fi
    else
        echo "  [FAIL] $label — unrecognized error: $(echo "$out" | head -1)"
        FAILS=$((FAILS + 1))
    fi
}

echo "== engine direct reads ($ENGINE) =="
check "MMR()" must-pass "$ENGINE" "MMR()(uint256)"
check "globalLiquidityStable()" must-pass "$ENGINE" "globalLiquidityStable()(uint256)"
check "globalLiquidityAsset()" must-pass "$ENGINE" "globalLiquidityAsset()(uint256)"
check "lastOperationTimestamp()" must-pass "$ENGINE" "lastOperationTimestamp()(uint256)"
check "ReadFees()" must-pass "$ENGINE" "ReadFees()(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
check "ReadParameters()" must-pass "$ENGINE" "ReadParameters()(address,address,uint256,uint256,uint256,uint256,uint256,bytes32,uint256,bool,uint256,uint256,uint256,uint256,uint256,bool)"
check "userVirtualTraderPosition(user)" must-pass "$ENGINE" "userVirtualTraderPosition(address)(uint256,uint256,uint256,uint256,uint256,bool,uint256,bool)" "$USER_ADDR"
check "liquidityPosition(user)" must-pass "$ENGINE" "liquidityPosition(address)(uint256,uint256,uint256,uint256)" "$USER_ADDR"
check "getLpLiquidityBalance(user)" must-pass "$ENGINE" "getLpLiquidityBalance(address)(uint256,uint256)" "$USER_ADDR"
check "getPrice() [OM2 expected until a signed report exists]" may-warn "$ENGINE" "getPrice()(uint256)"

echo "== engine read-parity getters (REQUIRED by UtilMath) =="
check "curveParameters()" must-pass "$ENGINE" "curveParameters()(uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256)"
check "computeFundingRate(price,1)" must-pass "$ENGINE" "computeFundingRate(uint256,uint256)(uint256,bool)" "$PRICE" 1
check "_computeFundingFee(user,0,true)" must-pass "$ENGINE" "_computeFundingFee(address,uint256,bool)(uint256,bool)" "$USER_ADDR" 0 true

echo "== Vault reads ($VAULT) =="
check "userCollateral(user)" must-pass "$VAULT" "userCollateral(address)(uint256)" "$USER_ADDR"
check "getUserTotalCollateral(user)" must-pass "$VAULT" "getUserTotalCollateral(address)(uint256)" "$USER_ADDR"

echo "== deployment wiring (engine->Vault calls are onlyPerpPair-gated) =="
WIRED=$(cast call "$VAULT" "perpPair()(address)" --rpc-url "$RPC" 2>/dev/null | awk '{print tolower($1)}')
if [ "$WIRED" = "$(echo "$ENGINE" | tr 'A-Z' 'a-z')" ]; then
    echo "  [OK]   vault.perpPair() == ENGINE"
else
    echo "  [FAIL] vault.perpPair() == '$WIRED' != ENGINE '$ENGINE' — addPnlToCollateral/removeAllCollateralForUser would revert"
    FAILS=$((FAILS + 1))
fi

echo "== UtilMath end-to-end reads ($UTILMATH -> engine callbacks) =="
check "_calcPnLNoExit (pure)" must-pass "$UTILMATH" "_calcPnLNoExit(uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256)(uint256,bool)" 1000000000000000000 0 0 0 0 true "$PRICE" 100000000
check "calcMR(user,…)" must-pass "$UTILMATH" "calcMR(address,uint256,address,uint256,uint256)(uint256)" "$USER_ADDR" "$PRICE" "$ENGINE" 0 1
check "calcHypotheticalMR (empty position)" must-pass "$UTILMATH" "calcHypotheticalMR(uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256,address)(uint256)" 0 0 0 0 0 true "$PRICE" 100000000 1000000000000000000 1000000 "$ENGINE"
check "_calcPnL (empty position)" must-pass "$UTILMATH" "_calcPnL(uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,address,bool)(uint256,bool)" 0 0 0 0 0 true "$PRICE" 100000000 "$ENGINE" true
# the open-trade preview solves on the live pool: skipped automatically when the pool is empty
STABLE=$(cast call "$ENGINE" "globalLiquidityStable()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
if [ -n "$STABLE" ] && [ "$STABLE" != "0" ]; then
    check "returnTradeInfo (long quote on live pool)" must-pass "$UTILMATH" "returnTradeInfo(address,bool,uint256,uint256,uint256,address)" "$USER_ADDR" true 1000000000000000000 0 "$PRICE" "$ENGINE"
else
    echo "  [SKIP] returnTradeInfo — pool not seeded yet (globalLiquidityStable == 0)"
fi

if [ -n "$BATCHER" ]; then
    echo "== CallBatcher reads ($BATCHER -> $ENGINE) =="
    check "batchCollateral([])" must-pass "$BATCHER" "batchCollateral(address[],uint256,address)(uint256[])" "[]" "$PRICE" "$ENGINE"
    check "batchCollateral([user])" must-pass "$BATCHER" "batchCollateral(address[],uint256,address)(uint256[])" "[$USER_ADDR]" "$PRICE" "$ENGINE"
    check "batchCalcMR([user])" must-pass "$BATCHER" "batchCalcMR(address[],uint256,address)(uint256[])" "[$USER_ADDR]" "$PRICE" "$ENGINE"
    check "batchUserVirtualTraderPosition([user])" must-pass "$BATCHER" "batchUserVirtualTraderPosition(address[],address)((uint256,uint256,uint256,uint256,uint256,bool,uint256,bool)[])" "[$USER_ADDR]" "$ENGINE"
    check "batchLiquidityPosition([user])" must-pass "$BATCHER" "batchLiquidityPosition(address[],address)((uint256,uint256,uint256,uint256,uint256,uint256)[])" "[$USER_ADDR]" "$ENGINE"
else
    echo "== CallBatcher reads =="
    echo "  [SKIP] BATCHER not set"
fi

echo
if [ "$FAILS" -gt 0 ]; then
    echo "READ-SURFACE SMOKE: $FAILS FAILURE(S), $WARNS warning(s) — DO NOT re-point the front-end."
    exit 1
fi
echo "READ-SURFACE SMOKE: all checks passed ($WARNS warning(s))."
