# Deployment

This document describes the current Arbitrum Sepolia production topology:

1. deploy and activate the Rust/Arbitrum Stylus `PerpEngine`;
2. deploy the Solidity periphery (`StylusPerpMultiCalls`, `Vault`, `LostAndFound`);
3. initialize and smoke-test the wired stack.

The repository intentionally does not contain private keys, broadcast logs, or historical
deployment artifacts.

## Latest Arbitrum Sepolia Deployment

| Component | Address | Notes |
| --- | --- | --- |
| `PerpEngine` | `0xC46E6F46B24177Cc0B3A0D14f005b8AB24B9A600` | Stylus WASM, reproducible nightly artifact |
| `CallBatcher` | `0x2c74f281E1324EAcDd9583e13d8BdA1b7680B38c` | Solidity read batcher, source-verified; redeployed 2026-06-19 for Stylus collateral-read compatibility |
| `StylusPerpMultiCalls` | `0xF52Ea4c86501a9428ddC5CbD1637831C997f3986` | Solidity manager / trusted forwarder |
| `Vault` | `0xCBcb733D0c6D550026F50e9d7F7F0470105eC2Ac` | Solidity collateral custody |
| `LostAndFound` | `0x1988D0974f180A6847679c9C8E83d41D1E25128c` | Solidity recovery contract |
| `CurveMath` | `0xd2Ed1798BC3a1FED685c3DB2eb5846F8A13Cf510` | Solidity library |
| `UtilMath` | `0x1A32b61A29B07251D01Df5BA84E7d88b6c19beC3` | Solidity library |
| `TWAPOracleMiddleware` | `0x539937f3A18604E89f3AaafB13F6e417342c4b90` | Solidity oracle middleware |
| Stablecoin | `0xad78f7E737288e4a8CdF27d8e9c59B15399936EA` | Reused USDC.e test token |

The ABI map is maintained in [../abis/addresses.json](../abis/addresses.json).

`CallBatcher` is stateless and is not registered by the protocol contracts. Front ends
and backend jobs should point their batch-read calls at the latest address above and pass
the live `PerpEngine` address as the `perpPairAddress` argument.

## Environment

Copy `example.env` to `.env` and set:

- `PRIVATE_KEY`
- `ARBITRUM_SEPOLIA_RPC_URL`
- `ETHERSCAN_API_KEY`
- `PERP_ENGINE` after the Stylus engine has been deployed and activated
- `EXISTING_ORACLE` when reusing an already deployed oracle

Keep `.env` out of Git.

## Stylus Engine

Build the engine artifact:

```bash
cargo build --release --target wasm32-unknown-unknown -p denaria-perp-engine-stylus
```

Deploy and activate it with cargo-stylus. The deployed artifact must be produced from the
pinned toolchain and `.cargo/config.toml`; changing either changes the WASM hash and may
affect activation size.

After activation, cache the program:

```bash
cargo stylus cache bid <PERP_ENGINE>
```

## Solidity Periphery

Run the current deploy script after `PERP_ENGINE` is known:

```bash
set -a
source .env
set +a

forge script script/ArbitrumSepoliaProdDeploy.s.sol:ArbitrumSepoliaProdDeploy \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" \
  --chain 421614 \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Foundry cannot execute Stylus WASM in local script simulation, so this script only deploys
and wires the Solidity contracts. Initialize the engine separately with `cast`:

```bash
cast send "$PERP_ENGINE" \
  "initializeProduction(address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)" \
  "$EXISTING_ORACLE" \
  "$VAULT" \
  "$STYLUS_PERP_MULTICALLS" \
  "$MMR" \
  "$TICKER_ASSET_CURRENCY" \
  "$FEE_FRONTEND" \
  "$FEE_LP" \
  "$FEE_PROTOCOL_ADDR" \
  "$TRADING_FEE" \
  "$FLAT_TRADING_FEE" \
  "$EMA_PARAM" \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

## Post-Deploy Gate

Run the read-surface smoke test before pointing a front-end at a new deployment:

```bash
ENGINE="$PERP_ENGINE" \
UTILMATH="$UTILMATH" \
VAULT="$VAULT" \
RPC="$ARBITRUM_SEPOLIA_RPC_URL" \
bash script/post_deploy_read_smoke.sh
```

An empty `0x` revert is treated as a hard failure because it usually means a missing
Stylus selector or router miss. A decoded `Error(string)` can be a functional warning,
for example `OM2` before the oracle has a fresh signed report.

## Front-End Report Convention

For the latest oracle instance, empty report bytes no longer trigger an empty decoder
revert, but the market price is still only fresh when a recent signed Chainlink Data
Streams v3 report has been submitted. Production writes should attach a fresh report
within the configured freshness window.
