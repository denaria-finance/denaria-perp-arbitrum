#!/usr/bin/env python3
"""Cross-contract selector-DEPENDENCY audit for the hybrid Stylus/Solidity stack.

Motivation (2026-06-10 debugging): the F-07 selector manifest compares the engine's
OWN ABI against the legacy PerpPair, but never checked who CONSUMES those selectors.
`UtilMath.calcMR`/`returnTradeInfo`/`_calcPnL` make typed `IPerpPair(...)` callbacks
into the engine, and `Vault._checkMR -> UtilMath.calcMR` (delegatecalled library)
inherits them transitively — so the 2026-06-08 deploy shipped with every UtilMath
read path (and Vault.removeCollateral) reverting on selectors the Stylus engine no
longer exposes. This audit closes that class of bug, in BOTH directions:

  A. Solidity stack -> engine    : every typed engine callback in the deployed
     Solidity sources must exist on the Stylus engine surface (extracted from
     perp-engine/src/lib.rs — the source of truth for the NEXT deploy — or, with
     --deployed-abi, from a deployed ABI JSON for ops checks).
  B. Solidity stack -> Vault     : typed IVault calls vs the Vault ABI.
  C. Engine (Rust) -> Vault/oracle: the engine's `sol_interface!` declarations vs
     the Vault/oracle ABIs (same bug class, reverse direction).
  D. Return-shape drift          : for matched selectors, the CALLER-side declared
     outputs must equal the target ABI outputs. (A selector only hashes the inputs,
     so a stale interface decodes garbage silently — e.g. the 6-field
     IPerpPair.ReadParameters vs the real 8-field tuple, already worked around
     point-wise in StylusPerpMultiCalls and now in UtilMath.)

Raw `abi.encodeWithSignature("...")` probes are also checked; probes in
OPTIONAL_PROBES (tolerant staticcalls with a graceful fallback, e.g. UtilMath's
curveMathAdapter) are reported but not fatal.

Run from the repo root:  python3 script/selector_dependency_audit.py
Exits non-zero on any violation — wire it next to selector_manifest.py in CI.
"""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --- the deployed-stack Solidity sources whose outbound calls are audited ---
CALLER_SOURCES = [
    "src/util/UtilMath.sol",
    "src/Vault.sol",
    "src/manager/callBatcher.sol",
    "src/manager/StylusPerpMultiCalls.sol",
    "src/manager/FeeManager.sol",
    "src/LostAndFound.sol",
    "src/util/CurveMath.sol",
]

# interface/contract name -> (forge inspect target, logical target surface)
IFACE_BINDINGS = {
    "IPerpPair":           ("src/interfaces/IPerpPair.sol:IPerpPair", "engine"),
    "PerpPair":            ("src/PerpPair.sol:PerpPair", "engine"),
    "IPerpPairBatcherParameters": ("src/manager/callBatcher.sol:IPerpPairBatcherParameters", "engine"),
    "IStylusPerpEngine":   ("src/manager/StylusPerpMultiCalls.sol:IStylusPerpEngine", "engine"),
    "IPerpPairParameters": ("src/util/UtilMath.sol:IPerpPairParameters", "engine"),
    "IVault":              ("src/interfaces/IVault.sol:IVault", "vault"),
    "IOracleMiddleware":   ("src/CL_oracle_middleware/interfaces/IOracleMiddleware.sol:IOracleMiddleware", "oracle"),
    # No deployed adapter exists (the engine exposes no curveMathAdapter getter, so the
    # tolerant probe always falls back to the linked CurveMath) — bound here so its call
    # sites surface as infos instead of being invisible (never-skip-silently principle).
    "ICurveMathAdapter":   ("src/interfaces/ICurveMathAdapter.sol:ICurveMathAdapter", "unaudited"),
}

ENGINE_LIB = "perp-engine/src/lib.rs"
VAULT_ABI = "abis/Vault.json"
ORACLE_ABI = "abis/Oracle.json"

# Tolerant raw probes: looked up via success-checked staticcall with a graceful
# fallback, so a miss is NOT a revert. Reported as info, never fatal.
OPTIONAL_PROBES = {"curveMathAdapter()"}

# Engine surface intentionally NOT consumed by any deployed Solidity contract
# (FE/eth_call-only or future use). Listed so the audit is explicit, not silent.
RUST_TO_ABI = {
    "Address": "address", "bool": "bool", "U256": "uint256", "U8": "uint8",
    "U32": "uint32", "U64": "uint64", "B256": "bytes32", "Bytes": "bytes",
    "I256": "int256", "u8": "uint8", "u32": "uint32", "u64": "uint64",
}


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stderr}")
    return r.stdout


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def abi_type(t):
    """Canonical ABI type, expanding struct `tuple` types into their component
    lists (completeness-review finding: the raw 'tuple' label made struct-taking
    signatures non-canonical, so selector math would silently diverge)."""
    typ = t["type"]
    if typ.startswith("tuple"):
        inner = "(" + ",".join(abi_type(c) for c in t.get("components", [])) + ")"
        return inner + typ[len("tuple"):]  # preserves array suffixes (tuple[] etc.)
    return typ


def abi_inputs(entry):
    return ",".join(abi_type(i) for i in entry.get("inputs", []))


def abi_outputs(entry):
    return ",".join(abi_type(o) for o in entry.get("outputs", []))


def abi_sig(entry):
    return f"{entry['name']}({abi_inputs(entry)})"


def load_abi_functions(path):
    abi = json.loads((ROOT / path).read_text())
    return {abi_sig(e): e for e in abi if e.get("type") == "function"}


def narrowed_uint_only(caller_outs, target_outs):
    """True when the only differences are SAME-SIGN-CLASS, SAME-DIRECTION width
    changes on 32-byte words (uintN/uintM or intN/intM). Caller-wider is always
    decode-safe; caller-narrower is decode-safe while the value fits the protocol
    range. MIXED directions are rejected (completeness-review finding: a per-field
    width check alone would wave through a FIELD SWAP like caller
    (uint64,uint256) vs target (uint256,uint64) — semantically reversed outputs).
    Any sign-class mix or structural difference stays a hard violation."""
    def bits(t, cls):
        m = re.fullmatch(cls + r"(\d*)", t)
        return int(m.group(1) or 256) if m else None

    a, b = caller_outs.split(","), target_outs.split(",")
    if len(a) != len(b):
        return False
    direction = None
    for ca, tb in zip(a, b):
        if ca == tb:
            continue
        for cls in ("uint", "int"):
            ca_b, tb_b = bits(ca, cls), bits(tb, cls)
            if ca_b is not None and tb_b is not None:
                d = "narrowed" if ca_b < tb_b else "widened"
                if direction is not None and d != direction:
                    return False  # mixed directions = potential field swap
                direction = d
                break
        else:
            return False
    return True


def forge_iface_abi(target):
    r = subprocess.run(["forge", "inspect", target, "abi", "--json"],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        # interface absent in this tree state (e.g. auditing an older revision)
        return {}, {}
    abi = json.loads(r.stdout)
    return {e["name"]: e for e in abi if e.get("type") == "function"}, \
           {abi_sig(e): e for e in abi if e.get("type") == "function"}


# --- engine surface from the Rust #[public] impl (source of truth for the next deploy) ---
def engine_surface_from_source():
    """Reuses the F-07 manifest's extraction idea: every #[selector(name=…)] /
    default-camelCase method in the single `#[public] impl PerpEngine` block, with
    Rust arg/return types mapped to ABI types."""
    lines = (ROOT / ENGINE_LIB).read_text().split("\n")
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == "#[public]":
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and lines[j].strip().startswith("impl PerpEngine"):
                start = j
                break
    if start is None:
        sys.exit(f"could not locate `#[public] impl PerpEngine` in {ENGINE_LIB}")
    # Brace-depth end detection (NOT a column-0 heuristic): the impl's own closing
    # brace is indented, and the next column-0 brace belongs to the cfg-gated
    # benchmark impl — the old heuristic absorbed it, presenting the retired
    # initializeBenchmark/seedBenchmarkState as PHANTOM surface members
    # (completeness-review real-miss). Line comments are stripped before counting
    # because doc comments quote braces.
    depth, end = 0, None
    for k in range(start, len(lines)):
        code = lines[k].split("//", 1)[0]
        depth += code.count("{") - code.count("}")
        if depth < 0:
            sys.exit(f"unbalanced braces scanning #[public] impl in {ENGINE_LIB}")
        if depth == 0 and k > start:
            end = k
            break
    if end is None:
        sys.exit(f"could not locate end of `#[public] impl PerpEngine` in {ENGINE_LIB}")

    body = "\n".join(lines[start:end])
    body = re.sub(r"//[^\n]*", "", body)
    fns = {}
    # `#[selector(name = "X")]` optionally precedes `pub fn y(...) -> Result<RET, Vec<u8>>`,
    # possibly with OTHER attributes in between (live pattern: #[allow(clippy::...)] sits
    # between #[selector] and `pub fn` on initialize_production — completeness-review
    # finding; without the inter-attribute tolerance the renamed selector would be lost).
    # The full `Result<T, Vec<u8>>` is captured non-greedily up to the `, Vec<u8>>` error
    # type, so tuple returns like `Result<(U256, bool), Vec<u8>>` parse whole.
    pat = re.compile(
        r'(?:#\[selector\(name\s*=\s*"(?P<sel>\w+)"\)\]\s*(?:#\[[^\]]*\]\s*)*)?'
        r"pub fn (?P<rust>\w+)\s*\(\s*&(?:mut\s+)?self,?(?P<args>[^)]*)\)"
        r"(?:\s*->\s*Result<(?P<ret>.*?),\s*Vec<u8>\s*>)?",
        re.S,
    )
    for m in pat.finditer(body):
        name = m.group("sel") or camel(m.group("rust"))
        args = []
        for a in m.group("args").split(","):
            a = a.strip()
            if not a:
                continue
            t = a.split(":", 1)[1].strip()
            args.append(RUST_TO_ABI.get(t, t))
        rets = []
        raw_ret = (m.group("ret") or "").strip()
        if raw_ret.startswith("(") and raw_ret.endswith(")"):
            raw_ret = raw_ret[1:-1]
        if raw_ret:
            for t in raw_ret.split(","):
                t = t.strip()
                if t:
                    rets.append(RUST_TO_ABI.get(t, t))
        fns[f"{name}({','.join(args)})"] = ",".join(rets)
    return fns


def camel(s):
    p = s.split("_")
    return p[0] + "".join(w[:1].upper() + w[1:] for w in p[1:])


# --- engine sol_interface! (engine -> Vault/oracle direction) ---
def engine_outbound_interfaces():
    src = (ROOT / ENGINE_LIB).read_text()
    m = re.search(r"sol_interface!\s*\{(.*?)\n\}", src, re.S)
    if not m:
        sys.exit("could not locate sol_interface! block in the engine")
    out = []  # (iface, signature, outputs)
    for im in re.finditer(r"interface\s+(\w+)\s*\{(.*?)\}", m.group(1), re.S):
        iface, body = im.group(1), im.group(2)
        for fm in re.finditer(
            r"function\s+(\w+)\(([^)]*)\)[^;]*?(?:returns\s*\(([^)]*)\))?\s*;", body
        ):
            name, raw_args, raw_rets = fm.group(1), fm.group(2), fm.group(3) or ""
            args = [a.strip().split()[0] for a in raw_args.split(",") if a.strip()]
            rets = [r.strip().split()[0] for r in raw_rets.split(",") if r.strip()]
            out.append((iface, f"{name}({','.join(args)})", ",".join(rets)))
    return out


def main():
    deployed_abi = None
    if "--deployed-abi" in sys.argv:
        deployed_abi = sys.argv[sys.argv.index("--deployed-abi") + 1]

    if deployed_abi:
        engine = {s: abi_outputs(e) for s, e in load_abi_functions(deployed_abi).items()}
        engine_label = deployed_abi
    else:
        engine = engine_surface_from_source()
        engine_label = f"{ENGINE_LIB} (#[public] surface — next deploy)"
    vault = {s: abi_outputs(e) for s, e in load_abi_functions(VAULT_ABI).items()}
    oracle = {s: abi_outputs(e) for s, e in load_abi_functions(ORACLE_ABI).items()}
    targets = {
        "engine": (engine, engine_label),
        "vault": (vault, VAULT_ABI),
        "oracle": (oracle, ORACLE_ABI),
    }

    violations, infos = [], []

    caller_srcs = {rel: strip_comments((ROOT / rel).read_text()) for rel in CALLER_SOURCES}

    iface_abis = {}
    for name, (inspect_target, _) in IFACE_BINDINGS.items():
        iface_abis[name] = forge_iface_abi(inspect_target)
        if not iface_abis[name][0]:
            # A broken binding must NEVER silently void its checks
            # (completeness-review real-miss: an empty interface ABI degraded every
            # dependent check to a non-fatal info and the audit false-PASSED).
            used_in = [rel for rel, s in caller_srcs.items() if re.search(rf"\b{name}\s*\(", s)]
            if used_in:
                violations.append(
                    f"BROKEN BINDING {name} -> {inspect_target}: forge inspect failed but the "
                    f"interface is used in {', '.join(used_in)} — its dependency checks would be voided"
                )
            else:
                infos.append(f"binding {name} unavailable ({inspect_target}) and unused — skipped")

    # --- directions A + B + D: typed calls in the Solidity stack ---
    # The cast argument allows ONE level of nested parens so forms like
    # `IOracleMiddleware(IVault(vault).oracle()).verifyReportIfNecessary(...)`
    # are extracted (completeness-critic finding: the flat pattern missed them).
    call_pat = re.compile(
        r"\b(" + "|".join(IFACE_BINDINGS) + r")\s*\((?:[^()]|\([^()]*\))*\)\s*\.\s*([A-Za-z_]\w*)"
    )
    for rel in CALLER_SOURCES:
        src = caller_srcs[rel]
        for m in call_pat.finditer(src):
            iface, fn = m.group(1), m.group(2)
            if fn == "selector":
                continue
            by_name, _ = iface_abis[iface]
            if fn not in by_name:
                # never skip silently — an unresolved member means the binding or
                # the extraction is incomplete, exactly how blind spots are born
                line = src[: m.start()].count("\n") + 1
                infos.append(f"unresolved member {rel}:~{line}: {iface}.{fn} not in the bound interface ABI")
                continue
            entry = by_name[fn]
            sig, outs = abi_sig(entry), abi_outputs(entry)
            tname = IFACE_BINDINGS[iface][1]
            line = src[: m.start()].count("\n") + 1
            if tname not in targets:
                infos.append(
                    f"unaudited target {rel}:~{line}: {iface}.{fn} — no deployed ABI to check against"
                )
                continue
            tabi, tlabel = targets[tname]
            where = f"{rel}:~{line} [{iface}.{fn} -> {tname}]"
            if sig not in tabi:
                # same name, different inputs? then the selector differs too
                near = [s for s in tabi if s.split("(")[0] == fn]
                if near:
                    violations.append(f"SELECTOR MISMATCH {where}: caller uses {sig}, target has {near}")
                else:
                    violations.append(f"MISSING SELECTOR {where}: {sig} not on {tlabel}")
            elif tabi[sig] != outs:
                if narrowed_uint_only(outs, tabi[sig]):
                    # The caller declares a narrower uintN than the target's uint256.
                    # ABI decoding succeeds while the value fits uintN (the strict
                    # decoder only checks the high bits are zero), and the engine
                    # range-bounds these fields by construction — benign, but worth
                    # surfacing so a future range change is re-evaluated.
                    infos.append(
                        f"narrowed decode {where}: caller declares ({outs}) for target ({tabi[sig]}) — value-safe while in range"
                    )
                else:
                    violations.append(
                        f"RETURN-SHAPE DRIFT {where}: caller declares ({outs}) but {tlabel} returns ({tabi[sig]})"
                    )

        # raw probes
        for pm in re.finditer(r'abi\.encodeWithSignature\(\s*"([^"]+)"', src):
            sig = pm.group(1)
            line = src[: pm.start()].count("\n") + 1
            if sig in OPTIONAL_PROBES:
                infos.append(f"optional probe {rel}:~{line}: {sig} (tolerant staticcall — ok if missing)")
                continue
            if sig not in engine and sig not in vault and sig not in oracle:
                violations.append(f"RAW PROBE MISS {rel}:~{line}: {sig} on no audited surface")

    # --- direction C: engine sol_interface! -> Vault/oracle ---
    # explicit routing — an UNKNOWN interface in sol_interface! must fail loudly,
    # not be checked against an arbitrary surface (completeness-review finding)
    sol_iface_targets = {"IVault": (vault, VAULT_ABI), "IOracleMiddleware": (oracle, ORACLE_ABI)}
    for iface, sig, rets in engine_outbound_interfaces():
        if iface not in sol_iface_targets:
            violations.append(
                f"UNKNOWN OUTBOUND INTERFACE {ENGINE_LIB} sol_interface!::{iface} — extend the audit's routing map"
            )
            continue
        tabi, tlabel = sol_iface_targets[iface]
        where = f"{ENGINE_LIB} sol_interface!::{iface}"
        if sig not in tabi:
            violations.append(f"MISSING SELECTOR {where}: {sig} not on {tlabel}")
        elif tabi[sig] != rets:
            if narrowed_uint_only(rets, tabi[sig]):
                infos.append(
                    f"width-only decode {where}: engine declares ({rets}) for target ({tabi[sig]}) — value-safe"
                )
            else:
                violations.append(
                    f"RETURN-SHAPE DRIFT {where}: engine declares ({rets}) but {tlabel} returns ({tabi[sig]})"
                )

    for i in infos:
        print(f"  [info] {i}")
    if violations:
        print(f"\nselector-dependency audit vs engine surface = {engine_label}")
        for v in violations:
            print(f"  [FAIL] {v}")
        sys.exit(1)
    print(f"\nselector-dependency audit PASSED vs engine surface = {engine_label}")


if __name__ == "__main__":
    main()
