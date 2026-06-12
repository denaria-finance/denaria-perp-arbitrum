#!/usr/bin/env python3
"""Generate the UPDATED Denaria on-chain architecture diagram after the Stylus port
(SVG; PNG too if cairosvg is available). Same visual language as
`gen_denaria_architecture.py` (the Solidity baseline). Shows the post-port topology:

  - PerpEngine = a single Arbitrum Stylus (Rust -> WASM) contract: one #[entrypoint]
    + one #[public] impl (the ABI surface), with the implementation split into
    per-domain Rust modules; the cubic-solver math is the embedded
    denaria-curve-math-stylus crate.
  - StylusPerpMultiCalls (Solidity) = the meta-call manager / trusted forwarder that
    calls the engine's explicit-sender `*For` entrypoints (replacing ERC2771
    same-selector + calldata-suffix forwarding).
  - Vault + TWAP oracle stay Solidity; the Vault <-> engine cross-calls cross the
    WASM boundary.

Reproducible: edit and re-run.
"""
import html

W, H = 2300, 1480
FONT = "DejaVu Sans, Arial, Helvetica, sans-serif"
INK, SUB, PANEL_TX, WHITE = "#0b2545", "#5b6b82", "#1e293b", "#ffffff"
GROUPS = {
    "entry":  ("#2563eb", "#eef4ff"),
    "mgr":    ("#7c3aed", "#f3eefe"),   # Solidity meta-call manager
    "rust":   ("#b91c1c", "#fdeeee"),   # Rust / WASM (Stylus)
    "vault":  ("#0d9488", "#ecfbf7"),
    "oracle": ("#d97706", "#fff7ec"),
    "libs":   ("#475569", "#f1f5f9"),
}
SEAM, EXT, ARROW_DARK = "#db2777", "#94a3b8", "#334155"

S = []
def add(x): S.append(x)
def esc(t): return html.escape(str(t), quote=True)

def box(x, y, w, h, *, fill=WHITE, stroke="#334155", sw=1.6, rx=10, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" ry="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

def txt(x, y, t, *, size=15, weight="normal", fill=PANEL_TX, anchor="start", italic=False, mono=False):
    st = ' font-style="italic"' if italic else ""
    fam = "DejaVu Sans Mono, monospace" if mono else FONT
    add(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" '
        f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{st}>{esc(t)}</text>')

def panel(x, y, w, h, key, title, subtitle=None):
    stroke, fill = GROUPS[key]
    box(x, y, w, h, fill=fill, stroke=stroke, sw=2.2, rx=14)
    add(f'<rect x="{x}" y="{y}" width="{w}" height="36" rx="14" ry="14" fill="{stroke}"/>')
    add(f'<rect x="{x}" y="{y+18}" width="{w}" height="18" fill="{stroke}"/>')
    txt(x+18, y+24, title, size=16, weight="bold", fill=WHITE)
    if subtitle:
        txt(x+w-16, y+24, subtitle, size=12.5, fill="#e6e9f5", anchor="end", italic=True)

def node(x, y, w, h, title, lines, *, stroke="#334155", tag=None, fill=WHITE, accent=None, tsize=15):
    box(x, y, w, h, fill=fill, stroke=stroke, sw=1.8, rx=9)
    if accent:
        add(f'<rect x="{x}" y="{y}" width="6" height="{h}" rx="3" fill="{accent}"/>')
    pad = 16 + (6 if accent else 0)
    txt(x+pad, y+24, title, size=tsize, weight="bold", fill=PANEL_TX)
    if tag:
        txt(x+w-12, y+22, tag, size=11.5, fill=SUB, anchor="end", italic=True)
    cy = y + 44
    for ln in lines:
        txt(x+pad, cy, ln, size=12.5, fill=SUB)
        cy += 18

def marker(idn, color):
    return (f'<marker id="{idn}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
            f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')

def arrow(points, *, color=ARROW_DARK, dash=None, label=None, lt=0.5, width=2.4, head="end", lside=None):
    mk = {ARROW_DARK: "ad", SEAM: "av", EXT: "ag"}[color]
    pts = " ".join(f"{x},{y}" for x, y in points)
    d = f' stroke-dasharray="{dash}"' if dash else ""
    me = f' marker-end="url(#{mk})"' if head in ("end", "both") else ""
    ms = f' marker-start="url(#{mk})"' if head == "both" else ""
    add(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}"{d}{me}{ms} stroke-linejoin="round"/>')
    if label:
        k = max(range(len(points)-1), key=lambda j: abs(points[j+1][0]-points[j][0]) + abs(points[j+1][1]-points[j][1]))
        (x1, y1), (x2, y2) = points[k], points[k+1]
        mx, my = x1 + (x2-x1)*lt, y1 + (y2-y1)*lt
        side = lside or ("up" if abs(x2-x1) >= abs(y2-y1) else "right")
        tw = len(label) * 6.7
        if side == "up":     lx, ly, anc = mx, my-12, "middle"
        elif side == "down": lx, ly, anc = mx, my+20, "middle"
        elif side == "left": lx, ly, anc = mx-12, my+4, "end"
        else:                lx, ly, anc = mx+12, my+4, "start"
        bx = lx - (tw/2 if anc == "middle" else (tw if anc == "end" else 0)) - 6
        add(f'<rect x="{bx}" y="{ly-13}" width="{tw+12}" height="19" rx="6" fill="#ffffff" fill-opacity="0.88"/>')
        txt(lx, ly+1, label, size=11.5, fill=color, anchor=anc, weight="bold")

# ============================ build ============================
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{FONT}">')
add(f'<defs>{marker("ad", ARROW_DARK)}{marker("av", SEAM)}{marker("ag", EXT)}</defs>')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
txt(48, 56, "Denaria PerpPair — on-chain architecture after the Arbitrum Stylus port", size=30, weight="bold", fill=INK)
txt(48, 90, "Engine ported to Rust/WASM (Stylus); manager/Vault/oracle AND the math/preview libraries stay Solidity. Bit-exact (differential harness + golden vectors).",
    size=16, fill=SUB, italic=True)

# ---- entry (left) ----
node(48, 150, 250, 92, "User / EOA", ["direct entrypoints:", "trade · close · addLiquidity …"], stroke=GROUPS["entry"][0], accent=GROUPS["entry"][0], tag="caller")
node(48, 270, 250, 92, "Relayer", ["EIP-712 meta-tx", "(gasless, signed)"], stroke=GROUPS["entry"][0], accent=GROUPS["entry"][0], tag="caller")
node(48, 390, 250, 92, "PWA front-end (reads)", ["quotes & dashboards (eth_call):", "returnTradeInfo · calcMR · PnL"], stroke=GROUPS["entry"][0], accent=GROUPS["entry"][0], tag="caller")

# ---- Solidity meta-call manager ----
panel(360, 150, 330, 300, "mgr", "StylusPerpMultiCalls", "Solidity")
node(380, 196, 290, 110, "Meta-call bundlers", [
    "addCollateralOpenTrade · …AddLiquidity",
    "closeAndRemoveAllCollateral",
    "modify/take-profit · batchLiquidate"], stroke=GROUPS["mgr"][0])
node(380, 320, 290, 112, "= the engine's trustedForwarder", [
    "EIP-712 relayer + nonces (ECDSA)",
    "calls engine *For(user, …)  [typed]",
    "vault calls keep ERC2771 suffix"], stroke=GROUPS["mgr"][0], accent=SEAM)

# ---- Rust/WASM boundary (engine + curve crate) ----
box(728, 130, 868, 1180, fill="none", stroke=GROUPS["rust"][0], sw=2.2, rx=20, dash="10 8")
add(f'<rect x="752" y="116" width="300" height="30" rx="15" fill="{GROUPS["rust"][0]}"/>')
txt(760, 137, "Rust / WASM  —  Arbitrum Stylus", size=15, weight="bold", fill=WHITE)

# ---- engine panel ----
panel(760, 168, 804, 800, "rust", "PerpEngine", "single #[entrypoint] · one #[public] impl")
# ABI surface
node(782, 214, 760, 96, "ABI surface  (lib.rs — the only #[public] impl)", [
    "EOA entrypoints + 9 explicit-sender *For (trade/close/add+removeLiquidity/realizePnL/liquidate/autoClose ×2)",
    "views: getPrice · calcPnL · getLpLiquidityBalance · ReadParameters/Fees · Vault getters · read-parity getters (curveParameters · funding) · governance"],
    stroke=GROUPS["rust"][0], accent=GROUPS["rust"][0], tsize=14.5)
# storage
node(782, 322, 760, 60, "#[entrypoint] sol_storage!  (fresh PACKED layout)", [
    "u8/u32/u64/bool packed · WAD/accumulators full-width · M (2×2) + row G flattened to scalars"],
    stroke=GROUPS["rust"][0], tsize=14)
# domain modules grid (3 x 3)
txt(782, 416, "implementation — per-domain Rust modules:", size=13.5, weight="bold", fill=PANEL_TX)
mods = [
    ("trade.rs", "_trade · curve solve · fees"),
    ("funding.rs", "updateFG · funding rate/fee"),
    ("internal_logic.rs", "LP balance · calcPnL · calcMR"),
    ("liquidity.rs", "add/remove · M·M⁻¹ · LP debt"),
    ("close.rs", "closeAndWithdraw · realizePnL"),
    ("liquidation.rs", "liquidate · discount · transfers"),
    ("auto_close.rs", "enable/exec auto-close"),
    ("config.rs", "init · time-locked params"),
    ("access_control.rs", "roles · emit · forwarder gate"),
]
gx, gy, gw, gh, gpx, gpy = 782, 432, 244, 70, 14, 14
for i, (t, sub) in enumerate(mods):
    r, c = divmod(i, 3)
    x = gx + c*(gw+gpx); y = gy + r*(gh+gpy)
    node(x, y, gw, gh, t, [sub], stroke=GROUPS["rust"][0], fill="#ffffff", tsize=13.5)
# tests
node(782, 690, 760, 58, "tests.rs  —  native + golden-vector + DIFFERENTIAL harness", [
    "trade+funding · liquidity · close+PnL · liquidation+auto-close replayed bit-exact vs real PerpPair · invariants + fuzz"],
    stroke=GROUPS["libs"][0], tsize=13.5)

# ---- shared curve-math crate (inside the WASM boundary) ----
panel(760, 990, 804, 250, "rust", "denaria-curve-math-stylus", "Rust crate · embedded (no #[entrypoint] when linked)")
node(782, 1036, 376, 96, "Cubic curve solver", [
    "255-iter Newton (8 branches)",
    "exact-amount-in long/short",
    "truncation-toward-zero parity"], stroke=GROUPS["rust"][0])
node(1182, 1036, 360, 96, "MatrixMath + UtilMath", [
    "2×2 matMul/inverse · clamp",
    "signedSum · calcEMA · divCeil · _calcPnL",
    "73 golden vectors — bit-exact"], stroke=GROUPS["rust"][0])
txt(782, 1170, "Same math as the deployed Solidity libraries (right) — golden-vector-locked, so quotes and execution agree bit-exactly.",
    size=13, fill=SUB, italic=True)
txt(782, 1196, "Engine ↔ crate: a normal in-WASM call (the standalone crate also deploys on its own with its own #[entrypoint]).",
    size=13, fill=SUB, italic=True)

# ---- Solidity right column: Vault + oracle + Chainlink ----
panel(1640, 168, 610, 360, "vault", "Vault", "Solidity · ERC2771 · real ERC20 collateral")
node(1662, 214, 566, 132, "Collateral accounting", [
    "addCollateral (ERC20 safeTransferFrom) · removeCollateral",
    "userCollateral · ratio snapshots · LostAndFound",
    "_msgSender() = trustedForwarder (the manager)"], stroke=GROUPS["vault"][0])
node(1662, 360, 566, 146, "reads the engine (F-10 cross-calls):", [
    "lastOperationTimestamp · calcPnL · updateFG",
    "MMR · maxLpLeverage · user/liquidityPosition",
    "→ each crosses the WASM boundary (≈+24k pedestal)"], stroke=GROUPS["vault"][0], accent=SEAM)

panel(1640, 568, 610, 168, "oracle", "TWAP Oracle Middleware", "Solidity")
node(1662, 612, 566, 104, "Chainlink Data Streams (Reports V3)", [
    "getPrice() = SafeCast.toUint256(verified price)",
    "verifyReportIfNecessary(report)"], stroke=GROUPS["oracle"][0])

node(1640, 776, 610, 84, "Chainlink VerifierProxy / Data Streams", [
    "external · signed price reports (Reports V3)"], stroke=EXT, fill="#f8fafc", accent=EXT, tag="off-chain feed")

# ---- Solidity math libraries (deployed, linked) ----
panel(1640, 900, 610, 290, "libs", "Solidity math libraries", "deployed + linked · EVM bytecode")
node(1662, 946, 566, 110, "FE quoting layer — UtilMath · CurveMath", [
    "returnTradeInfo · calcMR · calcHypotheticalMR · _calcPnL  (eth_call)",
    "reads engine state via the read-parity getters",
    "same ABI as the legacy system — FE migration = address swap"], stroke=GROUPS["libs"][0])
node(1662, 1066, 566, 104, "Vault-linked — UtilMath (+ MatrixMath · FeeManager)", [
    "DELEGATECALL: calcMR inside removeCollateral's margin guard",
    "EVM linked-library mechanism — not available to a Stylus program",
    "bit-exact twins of the engine's embedded Rust crate"], stroke=GROUPS["libs"][0], accent=GROUPS["libs"][0])

# ============================ arrows ============================
# user / relayer -> manager
arrow([(298, 196), (360, 200)], label="bundle", lside="up")
arrow([(298, 316), (360, 360)], color=ARROW_DARK, label="EIP-712 meta-tx", lside="down")
# user -> engine direct (EOA path): route BELOW the manager panel to avoid crossing it
arrow([(298, 242), (330, 242), (330, 500), (740, 500), (740, 320), (760, 320)], color=ARROW_DARK,
      dash="6 5", label="direct EOA path", lt=0.5, lside="down")
# manager -> engine *For
arrow([(690, 360), (724, 360), (724, 290), (760, 290)], color=SEAM, width=2.8, label="*For(user,…)  explicit-sender", lt=0.5, lside="up")
# manager -> vault (addCollateral, ERC2771 suffix) — exit the manager's top edge, over the top
arrow([(525, 150), (525, 108), (1935, 108), (1935, 168)], color=ARROW_DARK, label="addCollateral  (ERC2771 suffix)", lt=0.62, lside="down")
# engine -> vault (userCollateral / addPnl)
arrow([(1564, 300), (1640, 300)], color=ARROW_DARK, label="userCollateral · addPnl", lside="up")
# vault -> engine (getters cross-call)
arrow([(1640, 430), (1600, 430), (1600, 470), (1564, 470)], color=SEAM, label="getters (cross-call)", lt=0.5, lside="down")
# engine -> oracle
arrow([(1564, 640), (1640, 640)], color=ARROW_DARK, label="getPrice · verifyReport", lside="up")
# oracle -> chainlink
arrow([(1945, 736), (1945, 776)], color=EXT, label="reports", lside="right")
# vault -> libs (delegatecall, linked)
arrow([(2250, 430), (2284, 430), (2284, 1040), (2250, 1040)], color=ARROW_DARK, label="delegatecall (linked)", lt=0.5, lside="left")
# libs -> engine (state reads, crossing the WASM seam)
arrow([(1640, 990), (1604, 990), (1604, 935), (1564, 935)], color=SEAM, label="read-parity getters", lt=0.4, lside="down")
# FE -> libs (previews)
arrow([(48, 436), (24, 436), (24, 1380), (1945, 1380), (1945, 1190)], color=ARROW_DARK, dash="6 5", label="previews (eth_call)", lt=0.55, lside="up")
# engine -> curve crate (embedded math)
arrow([(1162, 968), (1162, 990)], color=ARROW_DARK, width=2.6, label="embedded math", lside="right")

# ============================ legend ============================
lx, ly = 48, 980
box(lx, ly, 640, 330, fill="#ffffff", stroke="#cbd5e1", sw=1.4, rx=12)
txt(lx+18, ly+30, "Legend  /  what changed vs the Solidity baseline", size=16, weight="bold", fill=INK)
def leg(yy, color, t, *, dash=None, fillb=None):
    if fillb:
        box(lx+18, yy-13, 26, 18, fill=fillb, stroke=color, sw=2)
    else:
        d = f' stroke-dasharray="{dash}"' if dash else ""
        add(f'<line x1="{lx+18}" y1="{yy-4}" x2="{lx+52}" y2="{yy-4}" stroke="{color}" stroke-width="3"{d}/>')
    txt(lx+62, yy, t, size=13.5, fill=PANEL_TX)
leg(ly+62,  GROUPS["rust"][0],  "Rust / WASM (Stylus): PerpEngine + curve-math crate", fillb=GROUPS["rust"][1])
leg(ly+90,  GROUPS["mgr"][0],   "Solidity meta-call manager (trustedForwarder)", fillb=GROUPS["mgr"][1])
leg(ly+118, GROUPS["vault"][0], "Solidity Vault (real ERC20 collateral)", fillb=GROUPS["vault"][1])
leg(ly+146, GROUPS["oracle"][0],"Solidity TWAP oracle ← off-chain Chainlink", fillb=GROUPS["oracle"][1])
leg(ly+174, GROUPS["libs"][0], "Solidity math libraries (FE quotes + Vault-linked, bit-exact twins)", fillb=GROUPS["libs"][1])
leg(ly+202, SEAM, "explicit-sender *For  REPLACES  ERC2771 same-selector + calldata-suffix")
leg(ly+230, ARROW_DARK, "typed call · view / cross-call")
leg(ly+258, EXT, "external / off-chain", dash="6 5")
txt(lx+18, ly+288, "Baseline: a monolithic Solidity PerpPair inheritance chain (perpModules/ + storage/).",
    size=12.5, fill=SUB, italic=True)
txt(lx+18, ly+310, "Now: one Stylus WASM contract (1 #[entrypoint]/1 #[public] impl) + 9 internal Rust modules; storage repacked.",
    size=12.5, fill=SUB, italic=True)

add("</svg>")
svg = "\n".join(S)
open("docs/assets/denaria_stylus_architecture.svg", "w").write(svg)
print("wrote docs/assets/denaria_stylus_architecture.svg")
try:
    import cairosvg
    cairosvg.svg2png(bytestring=svg.encode(), write_to="docs/assets/denaria_stylus_architecture.png", output_width=W, output_height=H, background_color="white")
    print("wrote docs/assets/denaria_stylus_architecture.png")
except Exception as e:
    print(f"(PNG skipped — cairosvg unavailable: {e}; SVG is the canonical form, re-run with cairosvg for PNG)")
