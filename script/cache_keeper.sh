#!/usr/bin/env bash
# Stylus CacheManager keeper for the PerpEngine.
#
# Motivation: the Arbitrum Stylus wasm cache is an LRU with time-decay. Access
# does NOT auto-cache, and an existing entry can be evicted (by decay, or by
# other programs outbidding). If the engine falls out of cache, EVERY user call
# silently reverts to the uncached path and pays the full WASM re-activation
# pedestal (~50k more L2 gas, ~10% per trade) indefinitely, until someone
# re-bids. Today the only safeguard is a one-time `cargo stylus cache bid`
# reminder printed by the deploy script. This keeper closes that gap: run it on
# a schedule to detect an evicted or at-risk engine and (optionally) re-bid.
#
# It reads on-chain state with `cast` (no brittle CLI-output parsing) and only
# places a bid through `cargo stylus cache bid`. Cached-status is read from the
# ArbWasmCache precompile (chain-stable); bid economics from the CacheManager.
#
# READ-ONLY BY DEFAULT. It never sends a transaction unless you pass --execute,
# and even then only when the engine is not cached (or --refresh is given).
#
# Usage (monitor / dry-run — safe, no funds moved):
#   PERP_ENGINE=0x… RPC=https://sepolia-rollup.arbitrum.io/rpc \
#     ./script/cache_keeper.sh
#
# Usage (re-bid when needed — SPENDS FUNDS):
#   PERP_ENGINE=0x… RPC=… PRIVATE_KEY=0x… \
#     ./script/cache_keeper.sh --execute
#
# Exit codes: 0 = engine cached and within budget (or a needed bid succeeded);
#             1 = engine NOT cached / eviction risk / cannot afford / bid failed.
# Suitable for cron: a non-zero exit is your alert signal.
#
# Config (env):
#   PERP_ENGINE     (required) engine contract address
#   RPC             Arbitrum RPC endpoint (default: public Sepolia)
#   CACHE_MANAGER   CacheManager address (default: Arbitrum Sepolia; override per chain)
#   CACHE_BID       bid to place, in wei (default: the current on-chain minimum bid)
#   CACHE_MAX_BID   refuse to bid above this many wei (default: unset = no ceiling)
#   PRIVATE_KEY     signer key, only needed with --execute (or use PRIVATE_KEY_PATH)
#   PRIVATE_KEY_PATH  file with a hex private key (alternative to PRIVATE_KEY)
# Flags:
#   --execute       actually place the bid when one is needed (default: dry-run)
#   --refresh       re-bid even if already cached (defend a contended cache)
#
# Tip: `cargo stylus cache suggest-bid <PERP_ENGINE> --endpoint <RPC>` prints a
# human-readable minimum bid; this keeper reads the same value via getMinBid.
set -u

# Parse flags before touching required config so --help works without any env.
EXECUTE=0
REFRESH=0
for arg in "$@"; do
    case "$arg" in
    --execute) EXECUTE=1 ;;
    --refresh) REFRESH=1 ;;
    -h | --help)
        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $arg (use --execute, --refresh, or --help)" >&2
        exit 2
        ;;
    esac
done

RPC="${RPC:-https://sepolia-rollup.arbitrum.io/rpc}"
PERP_ENGINE="${PERP_ENGINE:?set PERP_ENGINE=<PerpEngine address>}"
# Stylus CacheManager. Default is the Arbitrum Sepolia instance; override
# CACHE_MANAGER for other chains (e.g. Arbitrum One).
CACHE_MANAGER="${CACHE_MANAGER:-0x0c9043d042ab52cfa8d0207459260040cca54253}"
# ArbWasmCache precompile is the same address on every Arbitrum chain.
ARB_WASM_CACHE="0x0000000000000000000000000000000000000072"

# ge_dec A B -> exit 0 iff A >= B, for non-negative decimal integers of
# arbitrary size (wei values overflow 64-bit shell arithmetic, so compare by
# normalized length then lexicographically).
ge_dec() {
    local a b
    a=$(printf '%s' "$1" | sed 's/^0*//')
    b=$(printf '%s' "$2" | sed 's/^0*//')
    a=${a:-0}
    b=${b:-0}
    if [ "${#a}" -ne "${#b}" ]; then
        [ "${#a}" -gt "${#b}" ]
        return
    fi
    [[ "$a" > "$b" || "$a" == "$b" ]]
}

# read <label> <address> <sig> [args...] -> echoes the first output field, or
# exits the keeper on an RPC/read failure (a read we cannot trust is fatal).
read_call() {
    local label="$1" addr="$2" sig="$3"
    shift 3
    local out
    if ! out=$(cast call "$addr" "$sig" "$@" --rpc-url "$RPC" 2>&1); then
        echo "  [FAIL] $label — read reverted: $(printf '%s' "$out" | head -1)"
        exit 1
    fi
    printf '%s' "$out" | awk 'NR==1{print $1}'
}

echo "== Stylus cache keeper =="
echo "  engine        : $PERP_ENGINE"
echo "  cache manager : $CACHE_MANAGER"
echo "  rpc           : $RPC"

# 1) Confirm there is actually a contract at PERP_ENGINE.
CODE=$(cast code "$PERP_ENGINE" --rpc-url "$RPC" 2>&1) || {
    echo "  [FAIL] cannot read code at PERP_ENGINE: $(printf '%s' "$CODE" | head -1)"
    exit 1
}
if [ "$CODE" = "0x" ] || [ -z "$CODE" ]; then
    echo "  [FAIL] no contract code at $PERP_ENGINE — wrong address or wrong chain."
    exit 1
fi

# 2) Authoritative cached check via the ArbWasmCache precompile: the cache key
#    is the account codehash (keccak256 of the deployed code).
CODEHASH=$(cast keccak "$CODE")
CACHED=$(read_call "codehashIsCached" "$ARB_WASM_CACHE" "codehashIsCached(bytes32)(bool)" "$CODEHASH")
echo "  codehash      : $CODEHASH"
echo "  is cached     : $CACHED"

# 3) Bid economics from the CacheManager.
PAUSED=$(read_call "isPaused" "$CACHE_MANAGER" "isPaused()(bool)")
CACHE_SIZE=$(read_call "cacheSize" "$CACHE_MANAGER" "cacheSize()(uint64)")
QUEUE_SIZE=$(read_call "queueSize" "$CACHE_MANAGER" "queueSize()(uint64)")
MIN_BID=$(read_call "getMinBid" "$CACHE_MANAGER" "getMinBid(address)(uint192)" "$PERP_ENGINE")
echo "  paused        : $PAUSED"
echo "  cache/queue   : $CACHE_SIZE / $QUEUE_SIZE bytes used"
echo "  min bid (wei) : $MIN_BID"

# 4) Decide the bid to place: explicit CACHE_BID, else the current minimum.
BID="${CACHE_BID:-$MIN_BID}"
if [ -n "${CACHE_MAX_BID:-}" ] && ! ge_dec "$CACHE_MAX_BID" "$BID"; then
    echo
    echo "  [FAIL] required bid ($BID wei) exceeds CACHE_MAX_BID ($CACHE_MAX_BID wei)."
    echo "         The engine cannot be (re-)cached within budget — raise CACHE_MAX_BID"
    echo "         or accept the uncached ~10% gas penalty. NOT bidding."
    exit 1
fi

# 5) Do we need to act?
NEED_BID=0
if [ "$CACHED" != "true" ]; then
    echo
    echo "  [ALERT] engine is NOT cached — every call pays the uncached WASM pedestal (~10%)."
    NEED_BID=1
elif [ "$REFRESH" = "1" ]; then
    echo
    echo "  [INFO] engine is cached; --refresh requested — re-bidding to defend the entry."
    NEED_BID=1
else
    echo
    echo "  [OK] engine is cached and within budget. No action needed."
    exit 0
fi

if [ "$PAUSED" = "true" ]; then
    echo "  [FAIL] CacheManager is paused — cannot place a bid right now. Retry later."
    exit 1
fi

# 6) Act. Dry-run prints the exact command; --execute runs it (spends funds).
KEY_ARGS=()
if [ -n "${PRIVATE_KEY:-}" ]; then
    KEY_ARGS=(--private-key "$PRIVATE_KEY")
elif [ -n "${PRIVATE_KEY_PATH:-}" ]; then
    KEY_ARGS=(--private-key-path "$PRIVATE_KEY_PATH")
fi

if [ "$EXECUTE" != "1" ]; then
    echo
    echo "  DRY-RUN (no transaction sent). To place this bid, re-run with --execute:"
    echo "    cargo stylus cache bid $PERP_ENGINE $BID --endpoint $RPC --private-key <KEY>"
    # Non-cached in dry-run is still an alert-worthy state for cron.
    [ "$CACHED" != "true" ] && exit 1
    exit 0
fi

if [ "${#KEY_ARGS[@]}" -eq 0 ]; then
    echo "  [FAIL] --execute requires PRIVATE_KEY or PRIVATE_KEY_PATH to sign the bid."
    exit 1
fi

echo
echo "  >>> SENDING BID: $BID wei on $PERP_ENGINE (this spends funds) <<<"
if cargo stylus cache bid "$PERP_ENGINE" "$BID" --endpoint "$RPC" "${KEY_ARGS[@]}"; then
    echo "  [OK] bid placed. Re-run without --execute to confirm the engine is now cached."
    exit 0
fi
echo "  [FAIL] cache bid transaction failed — see cargo stylus output above."
exit 1
