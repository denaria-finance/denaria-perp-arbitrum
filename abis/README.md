# ABIs

JSON ABIs for the Denaria hybrid Stylus/Solidity stack on Arbitrum Sepolia. Address
metadata and ABI-file mapping are in [addresses.json](addresses.json).

Network: Arbitrum Sepolia (`421614`).

## Latest Address Map

| Contract | ABI file | Address | Notes |
| --- | --- | --- | --- |
| `PerpEngine` | `PerpEngine.json` | [`0x656a276db415d3ac5ecc7926c183795f65ea1352`](https://sepolia.arbiscan.io/address/0x656a276db415d3ac5ecc7926c183795f65ea1352) | Stylus WASM engine ABI of the **deployed** engine at this address (reproducible artifact hash `1f2e01bc...`), **not** the current `perp-engine` source — it is intentionally pinned to the live contract and is regenerated only on redeploy; not fully Arbiscan source-verified via managed Stylus flow |
| `CallBatcher` | `CallBatcher.json` | [`0x2c74f281E1324EAcDd9583e13d8BdA1b7680B38c`](https://sepolia.arbiscan.io/address/0x2c74f281E1324EAcDd9583e13d8BdA1b7680B38c) | Solidity read batcher, Arbiscan-verified; **stateless** — reusable as-is with the current engine (pass it as the `perpPairAddress` argument); reads collateral from the Vault, not the removed `PerpEngine.getCollateral` |
| `StylusPerpMultiCalls` | `StylusPerpMultiCalls.json` | [`0x59052fC631d925f8083435434f7fAE5D9937ae93`](https://sepolia.arbiscan.io/address/0x59052fC631d925f8083435434f7fAE5D9937ae93) | Solidity manager / trusted forwarder; source-verified |
| `Vault` | `Vault.json` | [`0x8B7110857980De47996ADe2A85ce389D43dC8532`](https://sepolia.arbiscan.io/address/0x8B7110857980De47996ADe2A85ce389D43dC8532) | Solidity collateral custody; source-verified |
| `LostAndFound` | `LostAndFound.json` | [`0xfBb1AAc8949e9748b4498457871aCBA26D256735`](https://sepolia.arbiscan.io/address/0xfBb1AAc8949e9748b4498457871aCBA26D256735) | Solidity recovery contract; source-verified |
| `CurveMath` | `CurveMath.json` | [`0x7be5f452fd90b6b708134e086b42a82fd1f6d80c`](https://sepolia.arbiscan.io/address/0x7be5f452fd90b6b708134e086b42a82fd1f6d80c) | Solidity library used by front-end quote paths; source-verified |
| `UtilMath` | `UtilMath.json` | [`0xb5b086a0d3da94e5e9f83e02c8f93104e7ce47cd`](https://sepolia.arbiscan.io/address/0xb5b086a0d3da94e5e9f83e02c8f93104e7ce47cd) | Solidity library used by front-end quotes and Vault margin checks; source-verified |
| `Oracle` | `Oracle.json` | [`0x17aB8Ada1A2EA89A7E28fb4Ba8E5D0A65A6c5D8a`](https://sepolia.arbiscan.io/address/0x17aB8Ada1A2EA89A7E28fb4Ba8E5D0A65A6c5D8a) | `TWAPOracleMiddleware`; source-verified; carries the empty-report short-circuit fix; expects the Arbitrum Sepolia **testnet** BTC/USD Data Streams feed — a mainnet report will not verify on Sepolia |
| `Stablecoin` | `ERC20.json` | [`0xad78f7E737288e4a8CdF27d8e9c59B15399936EA`](https://sepolia.arbiscan.io/address/0xad78f7E737288e4a8CdF27d8e9c59B15399936EA) | Reused USDC.e-style test token, 6 decimals |

## ABI lanes: deployed vs candidate

Two explicit lanes are kept (per the tooling audit):

- **Deployed ABI** — [`PerpEngine.json`](PerpEngine.json): pinned to the LIVE engine
  (`0x656a…1352`, reproducible opt hash `1f2e01bc…`), regenerated only on redeploy. Off-chain
  consumers decoding calls to the *current on-chain* engine use this.
- **Candidate ABI** — [`PerpEngine.candidate.abi.sol`](PerpEngine.candidate.abi.sol): the
  macro-authoritative interface generated from the *current* `perp-engine` source
  (`cargo run -p denaria-perp-engine-stylus --features export-abi`). CI runs
  `script/candidate_abi.sh`, which regenerates it, fails on drift, and prints the
  deployed-vs-candidate function delta — the selectors a redeploy will add
  (`updateLpSnapshot`, `getLpLiquidityEpoch`, `marginCheckData`, `oracle`, `batchLiquidateFor`,
  `autoCloseUsersData`) or remove (`ReadFundingParameters`, `ReadInsuranceFund`, `fundingRate*`,
  `totalTraderExposure*`, `initializeProduction`).

On redeploy, regenerate `PerpEngine.json` from this same source (runbook §11) so the two lanes
converge.

## Engine ABI Notes

- `PerpEngine.json` is generated from the Stylus engine export ABI plus the event
  declarations in `perp-engine/src/lib.rs`.
- The engine exposes direct EOA entrypoints (`trade`, `closeAndWithdraw`,
  `addLiquidity`, etc.) and explicit-sender forwarded variants consumed by
  `StylusPerpMultiCalls`.
- Event topic parity with the Solidity reference engine is checked in
  `test/config/EventSelectorGoldenVector.t.sol`.
- The front-end should use `Vault.getUserTotalCollateral(address)` for real collateral
  reads; the engine does not own ERC20 collateral.
- Batched collateral reads should use `CallBatcher.batchCollateral`; the batcher resolves
  the Vault through `PerpEngine.ReadParameters()[0]` and does not call the removed
  `PerpEngine.getCollateral(address)` selector. Stateless and reusable as-is — pass the live engine (`0x656a…1352`) as `perpPairAddress`; the batcher is not bound to any engine (verified on-chain 2026-07-17).
- Every price-dependent write should attach a fresh signed Chainlink Data Streams v3
  report so `TWAPOracleMiddleware.getPrice()` remains fresh.

## Regeneration

Regenerate ABIs after any deployed ABI change:

```bash
cargo run -p denaria-perp-engine-stylus --features export-abi
forge inspect src/manager/callBatcher.sol:CallBatcher abi
forge inspect src/Vault.sol:Vault abi
forge inspect src/manager/StylusPerpMultiCalls.sol:StylusPerpMultiCalls abi
forge inspect src/LostAndFound.sol:LostAndFound abi
forge inspect src/util/CurveMath.sol:CurveMath abi
forge inspect src/util/UtilMath.sol:UtilMath abi
```

Keep [addresses.json](addresses.json) in sync with the deployment that the front-end
should target.
