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
| `PerpEngine` | [`0x656a276db415d3ac5ecc7926c183795f65ea1352`](https://sepolia.arbiscan.io/address/0x656a276db415d3ac5ecc7926c183795f65ea1352) | Stylus WASM, reproducible nightly artifact |
| `CallBatcher` | [`0x2c74f281E1324EAcDd9583e13d8BdA1b7680B38c`](https://sepolia.arbiscan.io/address/0x2c74f281E1324EAcDd9583e13d8BdA1b7680B38c) | Solidity read batcher, source-verified; redeployed 2026-06-19 for Stylus collateral-read compatibility. STALE for this stack — still bound to the old engine 0xC46E…A600; redeploy/repoint before use |
| `StylusPerpMultiCalls` | [`0x59052fC631d925f8083435434f7fAE5D9937ae93`](https://sepolia.arbiscan.io/address/0x59052fC631d925f8083435434f7fAE5D9937ae93) | Solidity manager / trusted forwarder |
| `Vault` | [`0x8B7110857980De47996ADe2A85ce389D43dC8532`](https://sepolia.arbiscan.io/address/0x8B7110857980De47996ADe2A85ce389D43dC8532) | Solidity collateral custody |
| `LostAndFound` | [`0xfBb1AAc8949e9748b4498457871aCBA26D256735`](https://sepolia.arbiscan.io/address/0xfBb1AAc8949e9748b4498457871aCBA26D256735) | Solidity recovery contract |
| `CurveMath` | [`0x7be5f452fd90b6b708134e086b42a82fd1f6d80c`](https://sepolia.arbiscan.io/address/0x7be5f452fd90b6b708134e086b42a82fd1f6d80c) | Solidity library |
| `UtilMath` | [`0xb5b086a0d3da94e5e9f83e02c8f93104e7ce47cd`](https://sepolia.arbiscan.io/address/0xb5b086a0d3da94e5e9f83e02c8f93104e7ce47cd) | Solidity library |
| `TWAPOracleMiddleware` | [`0x17aB8Ada1A2EA89A7E28fb4Ba8E5D0A65A6c5D8a`](https://sepolia.arbiscan.io/address/0x17aB8Ada1A2EA89A7E28fb4Ba8E5D0A65A6c5D8a) | Solidity oracle middleware |
| Stablecoin | [`0xad78f7E737288e4a8CdF27d8e9c59B15399936EA`](https://sepolia.arbiscan.io/address/0xad78f7E737288e4a8CdF27d8e9c59B15399936EA) | Reused USDC.e test token |

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

The cache is an LRU with time-decay: access does not auto-cache, and an entry can be
evicted, after which every call pays the full WASM re-activation cost (~10% more L2 gas)
until it is re-bid. Monitor the engine and re-bid when needed with the keeper (read-only
by default; `--execute` places a bid):

```bash
PERP_ENGINE=<address> RPC="$ARBITRUM_SEPOLIA_RPC_URL" ./script/cache_keeper.sh
```

Run it on a schedule (e.g. cron); a non-zero exit means the engine is not cached or is at
eviction risk.

## Solidity Periphery + engine initialization

Foundry's EVM cannot execute Stylus (WASM) contracts, so the Solidity periphery is deployed
FIRST and the engine is deployed and initialized separately, in that order.

The deployed engine is the `wasm-opt -Oz` artifact — the only build that fits the Stylus
activation size cap. cargo-stylus deploys a pre-built artifact through its `--wasm-file` path,
which performs a raw contract creation + activation and does **not** run a Stylus
`#[constructor]` (the `--constructor-signature` flag is currently ignored on that path). The
engine is therefore initialized with a one-shot, admin-guarded `initializeProduction(...)` call
after activation.

> Target flow: an atomic deploy + activate + initialize via a real `#[constructor]`
> (StylusDeployer) once cargo-stylus routes a constructor through `--wasm-file`, or once the
> un-optimized build fits under the activation cap and the native `cargo stylus deploy` path can
> be used. Until then `initializeProduction` is the supported path; a hardcoded-admin caller
> check makes the two-step deploy front-run-proof.

Order:

**1. Deploy the periphery first** (leave `PERP_ENGINE` unset so the script skips engine wiring):

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

Record the printed `manager`, `Vault`, and `LostAndFound` addresses.

**2. Deploy + activate the engine**, then initialize it with `initializeProduction` (the caller
receives DEFAULT_ADMIN + MOD roles, so run it from the governance/admin key):

```bash
# deploy + activate the wasm-opt'd artifact (raw create; no constructor on this path)
cargo stylus deploy --wasm-file engine.Oz.wasm \
  --private-key "$PRIVATE_KEY" --endpoint "$ARBITRUM_SEPOLIA_RPC_URL"

# one-shot init — set PERP_ENGINE to the address printed above (selector 0xa0d9afc0)
cast send "$PERP_ENGINE" \
  "initializeProduction(address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)" \
  "$EXISTING_ORACLE" "$VAULT" "$STYLUS_PERP_MULTICALLS" "$MMR" "$TICKER_ASSET_CURRENCY" \
  "$FEE_FRONTEND" "$FEE_LP" "$FEE_PROTOCOL_ADDR" "$TRADING_FEE" "$FLAT_TRADING_FEE" "$EMA_PARAM" \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
# Confirm: `cast call $PERP_ENGINE 'MMR()(uint256)'` returns the configured value; the caller holds the roles.
```

**3. Wire the periphery to the engine** with `cast` (stores the engine address), then cache it:

```bash
cast send "$STYLUS_PERP_MULTICALLS" "initializeAddresses(address,address)" "$PERP_ENGINE" "$VAULT" \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$VAULT" "initializeParameters(address,address)" "$PERP_ENGINE" "$LOST_AND_FOUND" \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
cargo stylus cache bid "$PERP_ENGINE" "$BID" --endpoint "$ARBITRUM_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
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
