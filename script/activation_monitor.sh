#!/usr/bin/env bash
# Stylus activation-lifecycle monitor for the PerpEngine (READ-ONLY).
#
# Stylus programs expire and must be RE-ACTIVATED periodically, and a network
# Stylus-version bump can also force reactivation. If the engine's activation
# lapses or its version falls behind the network, calls revert until it is
# re-activated. Nothing in the repo watched this lifecycle; this script does.
#
# It reads the ArbWasm precompile (0x…71) only — it NEVER sends a transaction.
# The actual reactivation is a FUNDED transaction (`cargo stylus activate` /
# `codehash-keepalive` with a non-zero value — a zero-value call reverts
# `ProgramInsufficientValue`), which is an operator/deploy-gated action; this
# monitor just tells you WHEN to do it and prints the command.
#
# Checks (per the activation lifecycle docs):
#   - remaining program time  → warn at WARN_DAYS, page at CRIT_DAYS;
#   - program version vs network stylusVersion → page on mismatch;
#   - codehash version vs network stylusVersion → page on mismatch.
#
# Usage:
#   PERP_ENGINE=0x… RPC=https://sepolia-rollup.arbitrum.io/rpc \
#     ./script/activation_monitor.sh
#
# Exit codes (cron: any non-zero == attention):
#   0 = healthy (time left >= WARN_DAYS and versions match);
#   2 = WARNING  (WARN_DAYS > time left >= CRIT_DAYS);
#   1 = CRITICAL (time left < CRIT_DAYS, or a version mismatch → reactivate now).
#
# Config (env):
#   PERP_ENGINE   (required) engine contract address
#   RPC           Arbitrum RPC endpoint (default: public Sepolia)
#   WARN_DAYS     remaining-time warning threshold in days (default: 60)
#   CRIT_DAYS     remaining-time critical threshold in days (default: 30)
set -u

case "${1:-}" in
-h | --help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
"") ;;
*)
    echo "unknown argument: $1 (use --help)" >&2
    exit 2
    ;;
esac

RPC="${RPC:-https://sepolia-rollup.arbitrum.io/rpc}"
PERP_ENGINE="${PERP_ENGINE:?set PERP_ENGINE=<PerpEngine address>}"
WARN_DAYS="${WARN_DAYS:-60}"
CRIT_DAYS="${CRIT_DAYS:-30}"
# ArbWasm precompile: same address on every Arbitrum chain.
ARB_WASM="0x0000000000000000000000000000000000000071"

read_call() {
    local label="$1" sig="$2"
    shift 2
    local out
    if ! out=$(cast call "$ARB_WASM" "$sig" "$@" --rpc-url "$RPC" 2>&1); then
        echo "  [FAIL] $label — read reverted: $(printf '%s' "$out" | head -1)"
        exit 1
    fi
    printf '%s' "$out" | awk 'NR==1{print $1}'
}

echo "== Stylus activation monitor =="
echo "  engine : $PERP_ENGINE"
echo "  rpc    : $RPC"

CODE=$(cast code "$PERP_ENGINE" --rpc-url "$RPC" 2>&1) || {
    echo "  [FAIL] cannot read code at PERP_ENGINE: $(printf '%s' "$CODE" | head -1)"
    exit 1
}
if [ "$CODE" = "0x" ] || [ -z "$CODE" ]; then
    echo "  [FAIL] no contract code at $PERP_ENGINE — wrong address or wrong chain."
    exit 1
fi
CODEHASH=$(cast keccak "$CODE")

NET_VER=$(read_call "stylusVersion" "stylusVersion()(uint16)")
PROG_VER=$(read_call "programVersion" "programVersion(address)(uint16)" "$PERP_ENGINE")
CODE_VER=$(read_call "codehashVersion" "codehashVersion(bytes32)(uint16)" "$CODEHASH")
SECS_LEFT=$(read_call "programTimeLeft" "programTimeLeft(address)(uint64)" "$PERP_ENGINE")

DAYS_LEFT=$(( SECS_LEFT / 86400 ))
echo "  codehash        : $CODEHASH"
echo "  network version : $NET_VER"
echo "  program version : $PROG_VER"
echo "  codehash version: $CODE_VER"
echo "  time left       : ${DAYS_LEFT} days (${SECS_LEFT}s)"

STATUS=0 # 0 ok, 2 warn, 1 crit; keep the most severe

if [ "$PROG_VER" != "$NET_VER" ] || [ "$CODE_VER" != "$NET_VER" ]; then
    echo
    echo "  [CRIT] Stylus VERSION MISMATCH — engine activated at v${PROG_VER}/codehash v${CODE_VER},"
    echo "         network is at v${NET_VER}. The engine must be RE-ACTIVATED to track the network."
    STATUS=1
fi

if [ "$DAYS_LEFT" -lt "$CRIT_DAYS" ]; then
    echo
    echo "  [CRIT] only ${DAYS_LEFT} days of activation left (< ${CRIT_DAYS}) — REACTIVATE NOW."
    STATUS=1
elif [ "$DAYS_LEFT" -lt "$WARN_DAYS" ]; then
    echo
    echo "  [WARN] ${DAYS_LEFT} days of activation left (< ${WARN_DAYS}) — schedule reactivation."
    [ "$STATUS" -eq 0 ] && STATUS=2
fi

if [ "$STATUS" -ne 0 ]; then
    echo
    echo "  Reactivation is a FUNDED transaction (send it from an operator key, with value):"
    echo "    cargo stylus activate --address $PERP_ENGINE --endpoint $RPC --private-key <KEY>"
    echo "  (a zero-value keepalive reverts ProgramInsufficientValue — attach the simulated fee"
    echo "   plus a margin; then re-run this monitor to confirm the version/time reset.)"
    exit "$STATUS"
fi

echo
echo "  [OK] activation healthy: ${DAYS_LEFT} days left, versions aligned at v${NET_VER}."
exit 0
