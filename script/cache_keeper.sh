#!/usr/bin/env bash
# Stylus CacheManager keeper for the PerpEngine.
#
# PROTOCOL MODEL (corrected): the Arbitrum Stylus wasm cache is a MINIMUM-BID
# PRIORITY QUEUE (a heap), not an LRU. Entries carry a bid that DECAYS globally
# over time; when the cache is full a new bid evicts the current lowest bid.
# Program EXECUTION does NOT refresh or renew an entry — running the contract
# changes nothing about its cache standing. And an entry that is already cached
# CANNOT be topped up: `CacheManager.placeBid` reverts `AlreadyCached`. So the
# only actionable state for a keeper is EVICTION: once the engine drops out of
# cache, every call pays the full uncached WASM pedestal (~50k more L2 gas, ~10%
# per trade) until someone re-bids. This keeper detects that and (optionally)
# re-bids AFTER eviction — it never tries to "refresh" a live entry.
#
# It reads on-chain state with `cast` (no brittle CLI-output parsing) and places
# a bid only through `cargo stylus cache bid`. Cached-status + manager discovery
# come from the ArbWasmCache precompile (chain-stable); bid economics + occupancy
# from the CacheManager.
#
# READ-ONLY BY DEFAULT. It never sends a transaction unless you pass --execute,
# and even then only when the engine is NOT cached.
#
# Usage (monitor / dry-run — safe, no funds moved):
#   PERP_ENGINE=0x… RPC=https://sepolia-rollup.arbitrum.io/rpc \
#     ./script/cache_keeper.sh
#
# Usage (re-bid after eviction — SPENDS FUNDS; requires an explicit bid policy):
#   PERP_ENGINE=0x… RPC=… PRIVATE_KEY=0x… CACHE_MAX_BID=<wei> \
#     ./script/cache_keeper.sh --execute
#
# Exit codes: 0 = engine cached (or a needed re-bid succeeded AND the post-state
#                 re-read confirms it is cached again);
#             1 = engine NOT cached / eviction risk / cannot afford / bid failed.
# Suitable for cron: a non-zero exit is your alert signal.
#
# Config (env):
#   PERP_ENGINE     (required) engine contract address
#   RPC             Arbitrum RPC endpoint (default: public Sepolia)
#   CACHE_MANAGER   CacheManager address (default: discovered via
#                   ArbWasmCache.allCacheManagers(); override to pin one)
#   CACHE_BID       bid to place, in wei (default: the current on-chain minimum bid)
#   CACHE_MAX_BID   refuse to bid above this many wei. REQUIRED with --execute:
#                   bidding is an explicit-policy action, not an open-ended spend.
#   RISK_THRESHOLD  occupancy %% at/above which a still-cached engine is flagged
#                   as at eviction risk (default: 90)
#   PRIVATE_KEY     signer key, only needed with --execute (or PRIVATE_KEY_PATH)
#   PRIVATE_KEY_PATH  file with a hex private key (alternative to PRIVATE_KEY)
# Flags:
#   --execute       actually place the bid when the engine is evicted (default: dry-run)
#
# Note: there is deliberately no "--refresh" — re-bidding a LIVE entry reverts
# `AlreadyCached`, so a cached entry cannot be defended by topping up. The only
# lever is to bid a higher amount at (re-)insertion time so the entry sits above
# the eviction line for longer; set CACHE_BID accordingly.
#
# Tip: `cargo stylus cache suggest-bid <PERP_ENGINE> --endpoint <RPC>` prints a
# human-readable minimum bid; this keeper reads the same value via getMinBid.
set -u

# Parse flags before touching required config so --help works without any env.
EXECUTE=0
for arg in "$@"; do
    case "$arg" in
    --execute) EXECUTE=1 ;;
    -h | --help)
        sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $arg (use --execute or --help)" >&2
        exit 2
        ;;
    esac
done

RPC="${RPC:-https://sepolia-rollup.arbitrum.io/rpc}"
PERP_ENGINE="${PERP_ENGINE:?set PERP_ENGINE=<PerpEngine address>}"
# ArbWasmCache precompile is the same address on every Arbitrum chain.
ARB_WASM_CACHE="0x0000000000000000000000000000000000000072"
RISK_THRESHOLD="${RISK_THRESHOLD:-90}"

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

# 2) Discover the active CacheManager(s) from the ArbWasmCache precompile, rather
#    than trusting a hardcoded address that may be wrong for this chain. If the
#    user pinned CACHE_MANAGER, verify it is actually registered.
MANAGERS=$(read_call "allCacheManagers" "$ARB_WASM_CACHE" "allCacheManagers()(address[])")
# cast prints an address[] as e.g. [0xabc..., 0xdef...]; normalize to lowercase words.
MANAGERS=$(printf '%s' "$MANAGERS" | tr 'A-Z' 'a-z' | tr -d '[]" ' | tr ',' '\n' | grep -E '^0x[0-9a-f]{40}$' || true)
if [ -z "$MANAGERS" ]; then
    echo "  [FAIL] ArbWasmCache reports no registered CacheManager on this chain."
    exit 1
fi
if [ -n "${CACHE_MANAGER:-}" ]; then
    want=$(printf '%s' "$CACHE_MANAGER" | tr 'A-Z' 'a-z')
    if ! printf '%s\n' "$MANAGERS" | grep -qx "$want"; then
        echo "  [FAIL] pinned CACHE_MANAGER=$CACHE_MANAGER is NOT in allCacheManagers()."
        echo "         registered: $(printf '%s' "$MANAGERS" | tr '\n' ' ')"
        exit 1
    fi
else
    # The active manager is the last entry (managers are appended; earlier ones
    # may be decommissioned). Verify below via a getMinBid probe.
    CACHE_MANAGER=$(printf '%s\n' "$MANAGERS" | tail -1)
fi
echo "  cache manager : $CACHE_MANAGER  ($(printf '%s' "$MANAGERS" | grep -c .) registered)"

# 3) Authoritative cached check via the ArbWasmCache precompile: the cache key
#    is the account codehash (keccak256 of the deployed code).
CODEHASH=$(cast keccak "$CODE")
CACHED=$(read_call "codehashIsCached" "$ARB_WASM_CACHE" "codehashIsCached(bytes32)(bool)" "$CODEHASH")
echo "  codehash      : $CODEHASH"
echo "  is cached     : $CACHED"

# 4) Bid economics + occupancy from the CacheManager.
PAUSED=$(read_call "isPaused" "$CACHE_MANAGER" "isPaused()(bool)")
CACHE_CAP=$(read_call "cacheSize" "$CACHE_MANAGER" "cacheSize()(uint64)")
QUEUE_USED=$(read_call "queueSize" "$CACHE_MANAGER" "queueSize()(uint64)")
MIN_BID=$(read_call "getMinBid" "$CACHE_MANAGER" "getMinBid(address)(uint192)" "$PERP_ENGINE")
# Occupancy in basis points, then percent (cap/used are byte counts that fit u64).
OCCUPANCY_BPS=0
if [ "$CACHE_CAP" != "0" ]; then
    OCCUPANCY_BPS=$(( QUEUE_USED * 10000 / CACHE_CAP ))
fi
OCC_PCT=$(( OCCUPANCY_BPS / 100 )).$(printf '%02d' $(( OCCUPANCY_BPS % 100 )))
echo "  paused        : $PAUSED"
echo "  occupancy     : $QUEUE_USED / $CACHE_CAP bytes  (${OCC_PCT}%)"
echo "  min bid (wei) : $MIN_BID"

# 5) Decide the bid to place: explicit CACHE_BID, else the current minimum.
BID="${CACHE_BID:-$MIN_BID}"

# 6) Classify state.
if [ "$CACHED" = "true" ]; then
    # Cached: cannot re-bid (AlreadyCached). Only report eviction risk from
    # occupancy so an operator can pre-fund a higher CACHE_BID for the NEXT
    # insertion, and page before an actual eviction.
    if [ "$OCCUPANCY_BPS" -ge $(( RISK_THRESHOLD * 100 )) ]; then
        echo
        echo "  [WARN] engine is cached but the cache is ${OCC_PCT}% full (>= ${RISK_THRESHOLD}%)."
        echo "         Bids decay globally; a low effective bid can be evicted. Pre-fund a"
        echo "         higher CACHE_BID for the next insertion. Cannot top up a live entry"
        echo "         (placeBid reverts AlreadyCached). Watch ArbWasmCache DeleteBid events"
        echo "         for this codehash:"
        echo "           cast logs --address $ARB_WASM_CACHE 'DeleteBid(bytes32,address,uint64)' --rpc-url $RPC"
        # Still cached ⇒ healthy for cron purposes; risk is a warning, not a failure.
    else
        echo
        echo "  [OK] engine is cached (${OCC_PCT}% occupancy, below the ${RISK_THRESHOLD}% risk line). No action."
    fi
    exit 0
fi

# Not cached: this is the only actionable (bid) state.
echo
echo "  [ALERT] engine is NOT cached — every call pays the uncached WASM pedestal (~10%)."

if [ "$PAUSED" = "true" ]; then
    echo "  [FAIL] CacheManager is paused — cannot place a bid right now. Retry later."
    exit 1
fi

# Explicit bid policy: a re-bid must be bounded. Require CACHE_MAX_BID and enforce it.
if [ -z "${CACHE_MAX_BID:-}" ]; then
    echo "  [FAIL] re-bidding requires an explicit CACHE_MAX_BID ceiling (bid policy)."
    echo "         Set CACHE_MAX_BID=<wei> (>= min bid $MIN_BID) to authorize a bounded re-bid."
    exit 1
fi
if ! ge_dec "$CACHE_MAX_BID" "$BID"; then
    echo "  [FAIL] required bid ($BID wei) exceeds CACHE_MAX_BID ($CACHE_MAX_BID wei)."
    echo "         Raise CACHE_MAX_BID or accept the uncached ~10% gas penalty. NOT bidding."
    exit 1
fi

# 7) Act. Dry-run prints the exact command; --execute runs it (spends funds).
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
    exit 1 # not cached ⇒ alert-worthy for cron
fi

if [ "${#KEY_ARGS[@]}" -eq 0 ]; then
    echo "  [FAIL] --execute requires PRIVATE_KEY or PRIVATE_KEY_PATH to sign the bid."
    exit 1
fi

echo
echo "  >>> SENDING BID: $BID wei on $PERP_ENGINE (this spends funds) <<<"
if ! cargo stylus cache bid "$PERP_ENGINE" "$BID" --endpoint "$RPC" "${KEY_ARGS[@]}"; then
    echo "  [FAIL] cache bid transaction failed — see cargo stylus output above."
    exit 1
fi

# 8) Verify the POST-STATE: re-read codehashIsCached rather than trusting the CLI
#    exit code alone. A bid can land yet lose a same-block race, so confirm.
CACHED_AFTER=$(read_call "codehashIsCached(after)" "$ARB_WASM_CACHE" "codehashIsCached(bytes32)(bool)" "$CODEHASH")
if [ "$CACHED_AFTER" = "true" ]; then
    echo "  [OK] bid placed and confirmed: engine codehash is cached again."
    exit 0
fi
echo "  [FAIL] bid transaction returned success but the engine is still NOT cached"
echo "         (out-bid or evicted in the same window). Raise CACHE_BID and retry."
exit 1
