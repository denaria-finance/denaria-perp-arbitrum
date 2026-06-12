# ABIs

JSON ABIs for the Denaria hybrid Stylus/Solidity stack on Arbitrum Sepolia. Address
metadata and ABI-file mapping are in [addresses.json](addresses.json).

Network: Arbitrum Sepolia (`421614`).

## Latest Address Map

| Contract | ABI file | Address | Notes |
| --- | --- | --- | --- |
| `PerpEngine` | `PerpEngine.json` | `0xC46E6F46B24177Cc0B3A0D14f005b8AB24B9A600` | Stylus WASM engine ABI generated from `perp-engine`; reproducible artifact hash `957e7cd6...`; not fully Arbiscan source-verified via managed Stylus flow |
| `StylusPerpMultiCalls` | `StylusPerpMultiCalls.json` | `0xF52Ea4c86501a9428ddC5CbD1637831C997f3986` | Solidity manager / trusted forwarder; source-verified |
| `Vault` | `Vault.json` | `0xCBcb733D0c6D550026F50e9d7F7F0470105eC2Ac` | Solidity collateral custody; source-verified |
| `LostAndFound` | `LostAndFound.json` | `0x1988D0974f180A6847679c9C8E83d41D1E25128c` | Solidity recovery contract; source-verified |
| `CurveMath` | `CurveMath.json` | `0xd2Ed1798BC3a1FED685c3DB2eb5846F8A13Cf510` | Solidity library used by front-end quote paths; source-verified |
| `UtilMath` | `UtilMath.json` | `0x1A32b61A29B07251D01Df5BA84E7d88b6c19beC3` | Solidity library used by front-end quotes and Vault margin checks; source-verified |
| `Oracle` | `Oracle.json` | `0x539937f3A18604E89f3AaafB13F6e417342c4b90` | `TWAPOracleMiddleware`; source-verified; carries the empty-report short-circuit fix |
| `Stablecoin` | `ERC20.json` | `0xad78f7E737288e4a8CdF27d8e9c59B15399936EA` | Reused USDC.e-style test token, 6 decimals |

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
- Every price-dependent write should attach a fresh signed Chainlink Data Streams v3
  report so `TWAPOracleMiddleware.getPrice()` remains fresh.

## Regeneration

Regenerate ABIs after any deployed ABI change:

```bash
cargo run -p denaria-perp-engine-stylus --features export-abi
forge inspect src/Vault.sol:Vault abi
forge inspect src/manager/StylusPerpMultiCalls.sol:StylusPerpMultiCalls abi
forge inspect src/LostAndFound.sol:LostAndFound abi
forge inspect src/util/CurveMath.sol:CurveMath abi
forge inspect src/util/UtilMath.sol:UtilMath abi
```

Keep [addresses.json](addresses.json) in sync with the deployment that the front-end
should target.
