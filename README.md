# Denaria Protocol Contracts

Denaria is an on-chain perpetual trading protocol built around a dynamic-curve AMM and
stablecoin collateral. The current implementation uses a hybrid Arbitrum topology:

- a Rust/Arbitrum Stylus `PerpEngine` for the stateful perp engine and write paths;
- Solidity periphery for collateral custody, meta-transaction bundling, Chainlink Data
  Streams verification, recovery flows, and deployed math libraries used by the Vault and
  front-end quotes;
- a legacy Solidity `PerpPair` implementation retained as a reference engine for
  regression, fuzz, invariant, and differential tests. It is not the current deployment
  target.

The latest Arbitrum Sepolia deployment has all Solidity contracts source-verified on
Arbiscan. The Stylus engine is reproducibly buildable from this repository, but full
Arbiscan Stylus source verification is still gated by cargo-stylus managed-build
constraints. See [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Repository Layout

```text
src/
  PerpPair.sol                    Solidity reference engine used by tests
  Vault.sol                       Stablecoin collateral accounting
  LostAndFound.sol                Recovery contract for undeliverable transfers
  CL_oracle_middleware/           Chainlink Data Streams TWAP middleware
  manager/StylusPerpMultiCalls.sol
                                  EIP-712 / ERC2771-style bundler for the Stylus engine
  perpModules/                    Solidity reference-engine modules
  storage/PerpStorage.sol         Shared Solidity reference storage
  util/                           Solidity CurveMath, MatrixMath, UtilMath, FeeManager
  rust/CurveMath.rs               Rust CurveMath crate source

perp-engine/
  src/                            Rust Stylus perp engine modules

test/
  differential/                   Solidity-vs-Stylus behavior vectors
  fixtures/                       Golden vectors generated from Solidity
  parity/                         Read-surface and selector parity tests

abis/                             Front-end ABIs and latest address map
docs/                             Stable architecture, deployment, verification, and test docs
script/                           Deploy, smoke, audit, and parity helper scripts
```

## Prerequisites

- Foundry / Forge
- Rust with the pinned toolchain in `rust-toolchain.toml`
- `cargo-stylus` 0.10.7 for Stylus build/deploy work
- Git submodules

Initialize dependencies after cloning:

```bash
git submodule update --init --recursive
```

## Build

Compile Solidity contracts:

```bash
forge build
```

Build the Stylus perp engine:

```bash
cargo build --release --target wasm32-unknown-unknown -p denaria-perp-engine-stylus
```

Build the standalone CurveMath Stylus crate:

```bash
cargo build --release --target wasm32-unknown-unknown -p denaria-curve-math-stylus
```

## Test

Run the Solidity suite:

```bash
forge test
```

Run selector/return-shape compatibility checks between the Solidity periphery and the
Stylus engine ABI:

```bash
python3 script/selector_dependency_audit.py
python3 script/selector_manifest.py
```

Run Rust tests:

```bash
cargo test
cargo test -p denaria-perp-engine-stylus --features stub_boundary
```

Run the standalone CurveMath parity harness:

```bash
script/test-curve-math-parity.sh
```

More detail is in [docs/TESTING.md](docs/TESTING.md).

## Deployment

The production-topology deploy is split intentionally:

1. Set the Solidity periphery parameters in `.env`, then run
   `script/ArbitrumSepoliaProdDeploy.s.sol` (with `PERP_ENGINE` unset) to deploy
   `StylusPerpMultiCalls`, `Vault`, and `LostAndFound`.
2. Build the Stylus `perp-engine` WASM program and deploy it via its `#[constructor]`,
   passing the periphery addresses as constructor args — this activates and initializes the
   engine atomically (no separate initializer call).
3. Wire the periphery to the engine (`manager.initializeAddresses`,
   `vault.initializeParameters`) and cache the program.
4. Run the post-deploy read-surface smoke test before pointing any front-end at the stack.

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Gas benchmarks](docs/GAS_BENCHMARKS.md) — the Stylus engine is ~11% cheaper in L2 gas than the Solidity baseline at production topology, bit-exact in output
- [Deployment](docs/DEPLOYMENT.md)
- [Verification](docs/VERIFICATION.md)
- [Testing](docs/TESTING.md)
- [ABIs and latest addresses](abis/README.md)

## License

Business Source License 1.1. See [LICENSE](LICENSE).
