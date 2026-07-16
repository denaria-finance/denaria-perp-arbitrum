#!/usr/bin/env python3
"""Machine-checked ABI/selector manifest: Solidity PerpPair vs the Stylus PerpEngine.

Extracts the authoritative Solidity selector set from the compiled `PerpPair`
(`forge inspect`), extracts the Stylus engine's selectors from its `#[public] impl`
source (`#[selector(name=…)]` / default-camelCase + Rust arg types → ABI signature →
`cast sig`), then classifies every Solidity selector and every Stylus selector and
ASSERTS the classification holds. Exits non-zero on any unclassified selector, an
accidental gap, or a selector mismatch on a shared signature — so adding/removing an
entrypoint fails CI until this manifest is updated.

Run from the repo root:  python3 script/selector_manifest.py
"""
import json, re, subprocess, sys

LIB = "perp-engine/src/lib.rs"

RUST_TO_ABI = {
    "Address": "address", "bool": "bool", "U256": "uint256", "U8": "uint8",
    "U32": "uint32", "U64": "uint64", "B256": "bytes32", "Bytes": "bytes",
    "I256": "int256", "u8": "uint8", "u32": "uint32", "u64": "uint64",
}


def camel(s):
    p = s.split("_")
    return p[0] + "".join(w[:1].upper() + w[1:] for w in p[1:])


def cast_sig(sig):
    out = subprocess.run(["cast", "sig", sig], capture_output=True, text=True).stdout.strip()
    return out[2:] if out.startswith("0x") else out


def find_public_impl(lines):
    """Locate the single `#[public] impl PerpEngine` block by scanning the source,
    so the extractor cannot silently drift when lib.rs line numbers shift. Returns
    0-based [start, end] inclusive indices spanning the `impl ... {` line to its
    matching closing brace, found by BRACE-DEPTH COUNTING — the impl's own closing
    brace is indented, so a `startswith("}")` heuristic ran PAST it and
    absorbed whatever followed (the
    `#[cfg(any(test, feature = "benchmark"))] impl`, whose initialize_benchmark/
    seed_benchmark_state would then appear as PHANTOM members of the public
    surface)."""
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == "#[public]":
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            if j < len(lines) and lines[j].strip().startswith("impl PerpEngine"):
                start = j
                break
    if start is None:
        sys.exit("could not locate `#[public] impl PerpEngine` in " + LIB)
    depth = 0
    for k in range(start, len(lines)):
        # strip line comments (incl. /// docs, which may QUOTE braces) before
        # counting; code in this impl has no string literals containing braces
        code = lines[k].split("//", 1)[0]
        depth += code.count("{") - code.count("}")
        if depth < 0:
            sys.exit("unbalanced braces scanning `#[public] impl PerpEngine` in " + LIB)
        if depth == 0 and k > start:
            return start, k
    sys.exit("could not locate end of `#[public] impl PerpEngine` in " + LIB)


def extract_stylus():
    all_lines = open(LIB).read().split("\n")
    start, end = find_public_impl(all_lines)
    lines = all_lines[start: end + 1]
    sel = None
    out = {}
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = re.search(r'#\[selector\(name\s*=\s*"([^"]+)"\)\]', ln)
        if m:
            sel = m.group(1)
            i += 1
            continue
        fm = re.search(r"pub fn (\w+)\s*\(", ln)
        if fm:
            acc = ln[ln.index("pub fn"):]
            while acc.count("(") > acc.count(")"):
                i += 1
                acc += " " + lines[i].strip()
            start = acc.index("(")
            depth, end = 0, None
            for j, c in enumerate(acc[start:], start):
                depth += 1 if c == "(" else (-1 if c == ")" else 0)
                if depth == 0:
                    end = j
                    break
            name = fm.group(1)
            selname = sel if sel else camel(name)
            if selname == "constructor":  # a Stylus #[constructor] is deploy-time init, not a runtime ABI selector
                sel = None
                i += 1
                continue
            abis = []
            for a in (x.strip() for x in acc[start + 1:end].split(",") if x.strip()):
                if a.startswith("&self") or a.startswith("&mut self") or ":" not in a:
                    continue
                ty = a.split(":", 1)[1].strip().rstrip(",").replace("mut ", "").strip()
                base = ty.split("<")[0].strip()
                if base == "FixedBytes":  # FixedBytes<N> → bytesN (e.g. supportsInterface bytes4)
                    n = ty.split("<", 1)[1].split(">", 1)[0].strip()
                    abis.append(f"bytes{n}")
                    continue
                if base == "Vec":  # Vec<T> → T[] (e.g. batchLiquidateFor: Vec<Address> → address[])
                    inner = ty.split("<", 1)[1].rsplit(">", 1)[0].strip().split("<")[0].strip()
                    if inner not in RUST_TO_ABI:
                        sys.exit(f"UNMAPPED Vec inner type {inner!r} in {name}")
                    abis.append(f"{RUST_TO_ABI[inner]}[]")
                    continue
                if base not in RUST_TO_ABI:
                    sys.exit(f"UNMAPPED Rust type {base!r} in {name}")
                abis.append(RUST_TO_ABI[base])
            sig = f"{selname}({','.join(abis)})"
            out[sig] = cast_sig(sig)
            sel = None
        i += 1
    return out


def extract_solidity():
    raw = subprocess.run(
        ["forge", "inspect", "src/PerpPair.sol:PerpPair", "methodIdentifiers", "--json"],
        capture_output=True, text=True,
    ).stdout
    return json.loads(raw)


# --- Classification (the manifest). Every Solidity selector must be in exactly one bucket. ---

# Same canonical signature on both engines → identical 4-byte selector (full parity).
# (Derived as sol_sigs ∩ stylus_sigs; listed here so a drift fails the check.)

# Same function, DIVERGENT selector: previously the Stylus governance setters flattened the
# Solidity `ClampParameters` struct into inline uint256 args. The funding-clamp removal deleted
# `ClampParameters` from BOTH sides, so `prepareTimeLockedParameters`/`setTimeLockedParameters`
# now share an identical signature again (they fall in `supported`). No divergent selectors remain.
DIVERGENT = {}

# Intentionally NOT exposed on the Stylus engine (documented gaps), grouped by reason.
#
# Read parity: the binding limit is the cargo-stylus 0.10.7
# activation-simulation cap (~57.8-58.0 KB brotli in the stable build measurements),
# NOT a 24 KB wall (24,576 B is the per-fragment chunk size). Exposed on the engine:
# curveParameters,
# totalTraderExposureSign, computeFundingRate, _computeFundingFee (required by the UtilMath
# read paths and Vault.removeCollateral).
# Still unsupported below; full parity for those needs real headroom
# (panic_immediate_abort nightly profile, or the PerpReader facet).
UNSUPPORTED = {
    # Redundant funding alias dropped to fit under the activation cap: the FE and UtilMath
    # use _computeFundingFee; nothing calls the no-arg-rate convenience variant.
    "computeFundingFee(address)",
    # Standalone getters CONSOLIDATED into ReadFees/ReadParameters on the engine (the getter
    # consolidation) — the Solidity reference still declares them individually.
    "ReadFundingParameters()", "ReadInsuranceFund()", "fundingRate()", "fundingRateSign()",
    "totalTraderExposure()", "totalTraderExposureSign()",
    # Storage views still dropped (not needed on-chain: UtilMath probes curveMathAdapter
    # via a TOLERANT staticcall with a graceful linked-CurveMath fallback).
    "trustedForwarder()", "curveMathAdapter()",
    # Collateral now lives in the Vault; FE reads Vault.getUserTotalCollateral and UtilMath
    # resolves the Vault via ReadParameters()[0].
    "getCollateral(address)",
    # OZ AccessControl introspection — dropped to stay under the activation cap.
    "DEFAULT_ADMIN_ROLE()", "getRoleAdmin(bytes32)", "supportsInterface(bytes4)",
}

# Stylus-only entrypoints with no Solidity counterpart (intentional additions).
ADDITIONS = {
    # Explicit-sender forwarded variants (replace ERC2771 same-selector+suffix forwarding).
    "tradeFor(address,bool,uint256,uint256,uint256,address,uint8,bytes)",
    "closeAndWithdrawFor(address,uint256,uint256,address,bytes)",
    "addLiquidityFor(address,uint256,uint256,uint256,bytes)",
    "removeLiquidityFor(address,uint256,uint256,uint256,bytes)",
    "realizePnLFor(address,bytes)",
    "liquidateFor(address,address,uint256,bytes)",
    "autoCloseUserPositionFor(address,address,address,bytes)",
    "enableAutoCloseFor(address,uint256,uint256,uint256,uint256)",
    "disableAutoCloseFor(address)",
    # Post-deploy production initializer (Stylus stand-in for the Solidity constructor — the
    # wasm-opt'd multi-fragment artifact cannot route through the StylusDeployer #[constructor]).
    "initializeProduction(address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)",
    # Settable trusted forwarder (OZ's is immutable).
    "setTrustedForwarder(address)",
    # Batch liquidation (keeper convenience; no Solidity counterpart). The initializer is a
    # Stylus #[constructor] (deploy-time, not a selector) so it is excluded by the extractor;
    # the benchmark entrypoints (initializeBenchmark/seedBenchmarkState) live in a cfg-gated
    # NON-#[public] impl, so they are not additions either.
    "batchLiquidateFor(address,address[],uint256[],bytes)",
    # Batch auto-close keeper helper (best-effort; no Solidity counterpart).
    "batchAutoCloseUserPositionFor(address,address[],address[],bytes)",
    # Emergency breaker (granular pause of the OPEN-position path; no Solidity counterpart).
    "pauseTrading()",
    "unpauseTrading()",
    "tradingPaused()",
}


def main():
    sol = extract_solidity()
    sty = extract_stylus()
    sol_sigs, sty_sigs = set(sol), set(sty)
    supported = sol_sigs & sty_sigs
    errors = []

    # 1. shared signatures must share the selector
    for s in sorted(supported):
        if sol[s] != sty[s]:
            errors.append(f"selector mismatch on {s}: sol {sol[s]} != sty {sty[s]}")

    # 2. every Solidity selector classified exactly once
    for s in sorted(sol_sigs):
        buckets = [s in supported, s in DIVERGENT, s in UNSUPPORTED]
        if sum(buckets) != 1:
            errors.append(f"Solidity {s} ({sol[s]}) classified {sum(buckets)} times (expected 1) — UNCLASSIFIED GAP")

    # 3. DIVERGENT targets must exist on the Stylus side
    for sol_sig, sty_sig in DIVERGENT.items():
        if sty_sig not in sty_sigs:
            errors.append(f"DIVERGENT target missing on Stylus: {sty_sig}")

    # 4. every Stylus-only selector is a declared addition (or a DIVERGENT target)
    for s in sorted(sty_sigs - sol_sigs):
        if s not in ADDITIONS:
            errors.append(f"Stylus-only {s} ({sty[s]}) is not a declared addition — UNDOCUMENTED")

    print(f"Solidity selectors: {len(sol)} | Stylus selectors: {len(sty)}")
    print(f"  supported (identical selector): {len(supported)}")
    print(f"  divergent selector (clamp flattened): {len(DIVERGENT)}")
    print(f"  intentionally unsupported: {len(UNSUPPORTED)}")
    print(f"  stylus-only additions: {len(ADDITIONS) - len(DIVERGENT)}")
    if errors:
        print("\nFAILED:")
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print("\nOK: every selector classified; no accidental gaps; supported pairs share selectors.")


if __name__ == "__main__":
    main()
