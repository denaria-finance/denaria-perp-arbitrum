# Gas Benchmarks

All measurements are on Arbitrum Sepolia (chain 421614). The production engine is the Rust/Stylus WASM `PerpEngine` (`perp-engine/`); the legacy Solidity `PerpPair` serves as the differential reference. The benchmark twin used in the controlled comparisons **inherits the real `PerpPair`** (real `_trade`, funding, cubic `CurveMath` — zero transcription), so the comparison is engine-vs-engine on identical logic. On every controlled comparison both engines return a **bit-exact identical** `tradeReturn = 333304970286499533` for the reference long trade, confirming runtime equivalence.

## 1. Headline results (controlled same-state comparisons)

Identical state and inputs on both engines, pure L2 execution gas (L1 data fee removed via NodeInterface — see §7). Long: `size = 1000e18`, `leverage = 1`; short: `size = 0.033e18`, `leverage = 1`. Engine cached. Both sides run the full `calcMR > MMR` margin check.

| Path (L2 gas) | Stylus | Solidity | Δ (Sty − Sol) | % |
| --- | ---: | ---: | ---: | ---: |
| `trade` long, direct engine call | 445,930 | 502,458 | −56,528 | **−11.25%** |
| `trade` long, production topology (manager → engine) | 465,073 | 522,926 | −57,853 | **−11.06%** |
| `trade` short, production topology | 463,764 | 524,514 | −60,750 | **−11.58%** |

The production topology is the real user path: the meta-call manager bundles `vault.addCollateral` + the engine trade and forwards the real user as the acting account — `StylusPerpMultiCalls.addCollateralOpenTrade → engine.tradeFor(user, …)` (typed forwarded entrypoint, manager = `trustedForwarder`) on the Stylus side, vs `PerpMultiCalls.addCollateralOpenTrade → PerpPair.trade(...)` via the ERC2771 calldata-suffix path on the Solidity side. Both managers shared the same mock vault and oracle, so those legs cancel in the delta.

With a placeholder margin check (`collateral > 0`) instead of the real `calcMR`, the direct-call deltas were:

| Call (L2 gas) | Solidity twin | Stylus engine | Δ (Sty − Sol) | % |
| --- | ---: | ---: | ---: | ---: |
| `trade` long | 484,476 | 425,222 | −59,254 | −12.2% |
| `trade` short | 487,025 | 421,608 | −65,417 | −13.4% |
| getter "noop" | 23,816 | 47,712 | +23,896 | — |

**Bottom line: on the production meta-call path with the full margin check, the Stylus engine is ~11% (≈58–61k L2 gas) cheaper than the Solidity baseline, bit-exact in output.**

## 2. Structural findings

### 2.1 Fixed WASM entry pedestal (~22–25k gas per call)

Every call into the Stylus program pays a fixed EVM→WASM entry overhead, isolated by comparing trivial getters across engines (entry + 1 SLOAD):

| Entrypoint (L2 gas) | total | L1 portion | L2 (= total − L1) |
| --- | ---: | ---: | ---: |
| Stylus noop getter (`globalLiquidityStable()`) | 117,753 | 71,000 | 46,753 |
| EVM twin noop getter | 95,329 | 71,000 | 24,329 |
| Stylus math probe (full 8-iteration 256-bit Newton, zero storage) | 180,586 | 133,754 | 46,832 |

- Pedestal = 46,753 − 24,329 = **+22,424 gas** (constant-product micro-benchmark build); **≈ +23,400** on the real cubic engine (noop 47,712 vs the 24,329 EVM getter baseline); **24,915** measured per-frame on the live deployment's `Vault → engine.lastOperationTimestamp()` STATICCALL (vs ~3k for an equivalent Solidity getter). The pedestal is stable and engine-size-insensitive.
- It is largely per-call and ~irreducible; it shrinks only by doing more work per call (fewer Stylus calls, monolithic engine — the design adopted) and by keeping the program CacheManager-cached.
- The EVM baseline sanity-checks: 24,329 ≈ 21,000 intrinsic + ~2,100 SLOAD + dispatch.

### 2.2 The body is cheaper; arithmetic is negligible in absolute terms

Decomposition of the constant-product micro-benchmark's trade deficit (pure L2):

| Quantity | Gas | Meaning |
| --- | ---: | --- |
| Δ_noop | +22,424 | Fixed per-call WASM entry overhead |
| math probe − noop | +79 | The full 8-iteration 256-bit Newton solver costs ≈ the one SLOAD the getter performs ⇒ **absolute Stylus arithmetic ≈ ~2,000 gas, negligible** |
| Δ_trade (long) | +12,757 | Net L2 trade deficit of the micro-benchmark |
| Δ_trade (short) | +12,653 | Stable across direction/size |
| Trade body = Δ_trade − Δ_noop | ≈ −9,700 | Stylus executes the trade body (≈40 storage ops + Newton + signed 2×2 matrix + fee splits + 3 external calls) **~9.7k cheaper** than the EVM twin |

`Net L2 trade deficit +12,757 = fixed WASM entry +22,424 − cheaper body 9,667`. The deficit is entirely the fixed pedestal; storage + arithmetic + external calls run cheaper in WASM.

### 2.3 More arithmetic compresses the gap (thesis, confirmed)

Because the body is net-cheaper and the entry pedestal is fixed, adding body work makes Stylus relatively *better*. Evidence:

- The constant-product micro-benchmark was **+12,757 L2 (~+3.5%, Stylus more expensive)**; the real engine (true cubic `CurveMath`, funding `_updateFG`/`computeFundingFee`, full fee/matrix path) flips it to **−59,254 L2 (−12.2%)** direct-call.
- The cubic + funding logic adds **+129,554 L2 on Solidity** vs **+57,543 L2 on Stylus** over the constant-product baseline → Stylus's marginal 256-bit arithmetic is **~2.25× cheaper**, outweighing the fixed entry pedestal.
- The real engine's trade body (work beyond the fixed entry) is ≈ 377,500 L2 (425,186 − 47,712 on the direct path).
- On the live deployment, the most arithmetic-heavy operations show the largest advantages (`addLiquidity` ≈ −17%, `closeAndWithdraw` ≈ −23% vs the Solidity reference, §6).
- A first trade has funding = 0; a multi-trade series with non-zero funding exercises more arithmetic, which favours Stylus further.

### 2.4 The meta-call hop is engine-agnostic

Routing through the manager adds **+19,143 L2 on Stylus** and **+20,468 L2 on Solidity** — essentially equal (manager dispatch + no-op `vault.addCollateral` + ERC2771-suffix vs typed-`tradeFor` dispatch). The percentage compresses slightly vs the direct call only because equal overhead is added to both denominators; the absolute Stylus advantage is preserved end-to-end.

## 3. Margin-check (`calcMR`) cost delta

Replacing the placeholder T1 (`collateral > 0`) with the real `calcMR > MMR` check costs:

- **+20,708 L2 on Stylus** (425,222 → 445,930, direct call)
- **+17,982 L2 on Solidity** (484,476 → 502,458)

calcMR's matrix + funding + PnL work is marginally *less* favourable to Stylus than the cubic solve, trimming the direct delta from −59,254 to −56,528 — the engine still wins comfortably (~−11%).

## 4. Cached vs uncached

| Stylus engine `trade` | total | L1 | L2 |
| --- | ---: | ---: | ---: |
| **uncached** | 523,705 | 30,458 | **493,247** |
| **cached** | 473,562 | 30,458 | **443,104** |

Cache benefit: **~50,143 L2 (≈10%)**. The cached figure is the production-relevant one; uncached carries the full per-call WASM re-activation pedestal. Caching the production contract (`cargo stylus cache bid`) is mandatory; access does **not** auto-cache (the CacheManager is an LRU with time-decay).

## 5. Real-Vault collateral path: the hybrid-seam premium

| Path | total | L1 | L2 |
| --- | ---: | ---: | ---: |
| Real `Vault.addCollateral` (ERC20 `transferFrom` + ratio accounting + Stylus engine cross-call) | 257,278 | 27,508 | **229,770** |
| Mock no-op `addCollateral` | 46,866 | 24,443 | **22,423** |

- The real collateral deposit costs **~229,770 L2** vs the mock's 22,423 — a **+207k L2** realism gap (real ERC20 storage writes, the Vault's ratio-snapshot accounting, and the cross-call into the engine).
- `Vault.updateSnapshot` reads `perpPair.lastOperationTimestamp()` on every collateral op. Against the Stylus engine that read pays the **~24k WASM-entry pedestal** vs ~2–3k against a Solidity engine → a **Stylus premium of ~+22k L2 per Vault→engine read** on the collateral path. It is paid once per `addCollateral`/`removeCollateral`, **not on the hot trade path**.
- Net effect: the full real `addCollateralOpenTrade` advantage is **≈ −36k L2 (~−6–7%** of the larger real total**)** once the Vault's engine cross-call is included — smaller than the trade-only −11%, still a clear Stylus win.

## 6. Live-deployment per-operation gas (real Vault, real TWAP oracle, USDC.e)

Measured from on-chain receipts and `debug_traceTransaction` call traces of a real trader/LP flow (50k USDC.e collateral → 30,000e18 + 0.479e18 LP seed → 100e18 long → close) on a live Arbitrum Sepolia deployment of this hybrid stack. `L2 execution = gasUsed − gasUsedForL1` from the receipt.

| Op | total gas | L1 component | **L2 execution** | external frames (from traces) |
| --- | ---: | ---: | ---: | --- |
| `Vault.addCollateral` (50k USDC.e) | 240,521 | 12,282 | **228,239** | USDC.e `transferFrom` 43,427 + engine `lastOperationTimestamp` 24,915 |
| `engine.addLiquidity` (first seed) | 434,767 | 15,944 | **418,823** | oracle verify 4,379 + `getPrice` 12,858 + vault `userCollateral` 3,178 |
| `engine.trade` (open long 100e18) | 459,836 | 16,693 | **443,143** | oracle verify 4,379 + `getPrice` 19,466 + vault `userCollateral` 3,178 |
| `engine.closeAndWithdraw` | 270,575 | 16,436 | **254,139** | oracle 23,845 + vault `userCollateral` 3,178 + `addPnlToCollateral` 6,213 |
| `engine.addLiquidity` (re-seed) | 440,083 | 8,244 | **431,839** | same shape as first seed |

**Cross-validation:** the live cached `trade` L2 (443,143) is within 40 gas of the controlled-benchmark cached trade (443,104 L2) — the live deployment behaves exactly like the benchmarked build.

The traces also confirm the hybrid topology: every perp operation enters the WASM program directly and all AMM/margin/funding/fee math executes inside that single frame — no subcalls to `CurveMath`/`UtilMath` libraries or any Solidity engine; the only external frames are the deliberate periphery calls (oracle `verifyReportIfNecessary` + `getPrice`, Vault `userCollateral`/`addPnlToCollateral`).

### 6.1 Live ops vs a pure-Solidity reference, per call type

Only `trade` was ever benchmarked controlled on the Solidity side; the other operations are compared against a fresh local reference (`test/bench/DemoScenarioGasBench.t.sol`): the exact live scenario on the legacy Solidity `PerpPair` with the production parameters, `vm.cool()` before each step to emulate per-transaction cold access, call-only EVM gas (no 21k intrinsic, no calldata). To compare like with like, the live L2 execution is reduced to call-only gas by subtracting the 21k intrinsic and the calldata cost (~1.5–2.5k for these inputs; ±1k uncertainty).

| Op | Live Stylus, call-only L2 (est.) | Solidity reference, call-only | Δ | % |
| --- | ---: | ---: | ---: | ---: |
| `addLiquidity` (seed) | ≈ 395,800 | 474,562 | ≈ −78,800 | **≈ −17%** |
| `trade` (open long) | ≈ 420,100 | 420,420 | ≈ 0 | see note A |
| `closeAndWithdraw` | ≈ 231,100 | 298,537 | ≈ −67,400 | **≈ −23%** |
| `addCollateral` | ≈ 205,200 | 167,243 | ≈ +38,000 | see note B |

**Note A — why the raw live trade looks ~par while the controlled benchmark says −11%:** the two cells contain different oracle costs. The live tx pays the real `TWAPOracleMiddleware` (verify + getPrice = 23,845 gas of Solidity periphery, identical under any engine); the local reference pays a near-free mock price provider (~5k). Subtracting the measured externals from both sides (engine-body vs engine-body): ≈ 393k (Stylus) vs ≈ 415k (Solidity) → ≈ −5% on this state. The remaining distance to the controlled −11.25% comes from the imperfections of this normalization (cold-access emulation via `vm.cool`, intrinsic/calldata estimates, different pool magnitudes → a different mix of zero→nonzero storage writes). The §1 numbers stay authoritative for the engine-vs-engine claim; this table's value is confirming the live deployment is in the expected band per operation.

**Note B — `addCollateral` is the one op where the hybrid pays a premium:** it runs entirely in the Solidity Vault on both stacks; the difference is the Vault's one cross-contract read, `perpPair.lastOperationTimestamp()` — 24,915 gas against the Stylus engine (the fixed WASM-entry pedestal, §2.1) vs ~3k against a Solidity engine, plus live-token differences (proxied USDC.e). This is the §5 hybrid-seam premium: quantified, bounded, and off the hot trade path.

### 6.2 Calldata (L1) component caveat

The L1 component (~8–17k in the table above) is **engine-agnostic** and dominated by the oracle report blob in the calldata; it shrinks if the front-end passes the 196-byte report stub instead of a full signed Data Streams report.

## 7. Methodology notes

- **L2 isolation via NodeInterface.** `eth_estimateGas` on Arbitrum bundles a volatile, calldata-dependent L1 data fee into the estimate. All controlled comparisons use the NodeInterface precompile `0x00000000000000000000000000000000000000C8` `gasEstimateComponents(address,bool,bytes) → (total, l1Portion, baseFee, l1BaseFee)` and report **L2 = total − l1Portion**. Validation: getter L1 portions were identical (71,000) on both engines (the L1 fee cancels for identical calldata), while trade L1 portions differed slightly (e.g. 132,761 vs 130,323) — which is exactly why raw `eth_estimateGas` deltas are noisy (a raw trade delta of +15,195 vs the clean L2 +12,757 on the same day). Live-deployment figures instead use receipt `gasUsed − gasUsedForL1` plus `callTracer` per-frame gas.
- **Same-state twin.** The Solidity baseline inherits the real `PerpPair` (real `_trade`/funding/cubic `CurveMath`, zero transcription). Both engines were seeded identically (`globalLiquidityStable = 1.8e25`, `globalLiquidityAsset = 6000e18`, oracle price 3000 at 1e8 decimals) with the full `PerpPair`-matching config (MMR 40000, decimals/clamps/funding parameters), so `calcMR` and `trade` are bit-exact across engines — verified by the identical on-chain `tradeReturn`.
- **Shared periphery.** In the controlled benchmarks, both sides used the same mock vault (no-op `addCollateral`, fixed generous `userCollateral`) and the same constant-price mock oracle, so those legs cancel in the delta. The real Chainlink Data Streams verification path cannot be driven in a benchmark without Chainlink's report API; the oracle leg is engine-agnostic (both engines call the same oracle), so it does not bias the cross-engine delta — and the live-deployment numbers (§6) include the real `TWAPOracleMiddleware`.
- **Caching.** All headline Stylus figures are with the program CacheManager-cached (the production-relevant state); §4 quantifies the uncached penalty.
- **Topology.** Both direct-call (cleanest engine signal) and production manager→engine figures are reported; the headline is the production topology. The fixed WASM-entry pedestal is paid once per Stylus call regardless of topology.