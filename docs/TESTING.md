# Testing

The suite covers Solidity reference behavior, Rust engine parity, cross-contract selector
compatibility, and configuration vectors.

## Solidity

Run the full Foundry suite:

```bash
forge test
```

Focused suites:

```bash
forge test --match-path test/PerpPair.t.sol
forge test --match-path test/Vault.t.sol
forge test --match-path test/Oracle.t.sol
forge test --match-path test/MultiCallTest.t.sol
forge test --match-path test/differential/*.t.sol
forge test --match-path test/config/*.t.sol
```

The Solidity `PerpPair` is a reference implementation for tests and vectors. Production
deployment uses the Stylus `PerpEngine`.

`test/differential/VaultSeamDifferential.t.sol` drives the current `Vault` and a frozen
pre-optimization copy (`VaultLegacy.sol`) through identical operation sequences — scripted and
fuzzed — on two full stacks and asserts their observable state stays bit-identical. It proves
the collateral-path read-reduction changes are behaviour-preserving.

## Rust

Run native engine tests:

```bash
cargo test
cargo test -p denaria-perp-engine-stylus --features stub_boundary
```

Build the WASM artifacts:

```bash
cargo build --release --target wasm32-unknown-unknown -p denaria-curve-math-stylus
cargo build --release --target wasm32-unknown-unknown -p denaria-perp-engine-stylus
```

## Golden Vectors

Golden vectors live under `test/fixtures/` and are generated from the Solidity reference.
They lock:

- curve math outputs;
- funding math;
- liquidity transitions;
- trade/funding behavior;
- close/PnL behavior;
- liquidation behavior;
- event selectors;
- parameter hashes.

Run the standalone CurveMath parity helper:

```bash
script/test-curve-math-parity.sh
```

## Dust-Bound Envelope Harness

`test/c0_envelope/C0EnvelopeSweep.t.sol` is a 240-cell regression harness for the
pool-relative close dust bound (`max(1e10, globalLiquidityStable / 1e10)` on the
post-buy-back residual). The curve inversion residual grows with pool depth, not
position size; every cell asserts both prediction/outcome consistency and zero `C0`
reverts. If this harness fails after a curve or solver change, the bound envelope
analysis must be redone before deploying.

`test/bench/DemoScenarioGasBench.t.sol` is the local pure-Solidity gas reference for
the live-deployment comparison in [GAS_BENCHMARKS.md](GAS_BENCHMARKS.md) (not part of
any regression gate; numbers are logged, nothing asserted).

## Selector Compatibility

The Solidity periphery uses typed callbacks into the Stylus engine. The selector audit
guards against deploying a WASM engine that omits a selector required by `Vault`,
`UtilMath`, or `StylusPerpMultiCalls`.

```bash
python3 script/selector_dependency_audit.py
python3 script/selector_manifest.py
```

Run these before deploying a new engine artifact and after changing any Solidity callback
interface.

## Post-Deploy Smoke

After a deployment, run:

```bash
ENGINE=<engine> UTILMATH=<utilmath> VAULT=<vault> RPC=<rpc> \
  bash script/post_deploy_read_smoke.sh
```

This test calls the front-end-shaped read paths through the deployed contracts and flags
empty `0x` reverts as selector/router failures.
