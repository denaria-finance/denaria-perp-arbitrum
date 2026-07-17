// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { Script, console2 } from "forge-std/Script.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { StylusPerpMultiCalls } from "../src/manager/StylusPerpMultiCalls.sol";

/// @title Arbitrum Sepolia production-topology deployer — SOLIDITY side.
/// @notice Deploys + wires the Solidity side of the manager→engine WASM topology:
///         `StylusPerpMultiCalls` (manager / trusted forwarder) + the real `Vault` +
///         `LostAndFound`, pointed at the already-deployed-and-activated Stylus
///         `perp-engine` WASM program supplied via `PERP_ENGINE`.
///
///         IMPORTANT: Foundry's EVM cannot EXECUTE Stylus (WASM) contracts — a call to the
///         engine reverts `OpcodeNotFound` in `forge script` simulation. So this script deploys
///         the Solidity periphery FIRST; the engine (the wasm-opt'd artifact) is deployed and
///         activated AFTERWARDS via `cargo stylus deploy --wasm-file`, which does a raw create and
///         does NOT run a Stylus `#[constructor]`, so the engine is initialized post-activation
///         with a one-shot admin-guarded `initializeProduction(...)` call. The Solidity-side wiring
///         (`manager.initializeAddresses` / `vault.initializeParameters`, which merely store the
///         engine address) is then done via `cast` per the runbook. All engine reads and role
///         handoff also go via `cast`.
///
///         All parameters are read from the environment unchanged; see docs/DEPLOYMENT.md.
contract ArbitrumSepoliaProdDeploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        // PERP_ENGINE is OPTIONAL: the engine is deployed AFTER the periphery and initialized
        // post-activation via `initializeProduction` (the `--wasm-file` deploy path does not run a
        // Stylus `#[constructor]`). Leave PERP_ENGINE unset for that periphery-first flow (this
        // script then logs the next steps). If PERP_ENGINE IS set (a pre-existing engine), the
        // Solidity-side wiring is done inline as before.
        address engine = vm.envOr("PERP_ENGINE", address(0));
        address oracle = vm.envAddress("EXISTING_ORACLE");
        require(oracle != address(0), "EXISTING_ORACLE not set");
        address stableCoin = vm.envAddress("STABLECOIN");
        require(stableCoin != address(0), "STABLECOIN not set");

        // Vault constructor parameters (referenced from env, unchanged).
        uint256 minCollateralMovement = vm.envUint("MIN_COLLATERAL_MOVEMENT");
        uint256 stableDecimals = vm.envUint("STABLE_DECIMALS");
        uint256 depositThreshold = vm.envUint("DEPOSIT_THRESHOLD");
        uint256 withdrawalThreshold = vm.envUint("WITHDRAWAL_THRESHOLD");

        vm.startBroadcast(deployerPk);

        // 1. Manager FIRST — its address is the Vault's immutable ERC2771 forwarder and the
        //    engine's trustedForwarder (passed to the engine constructor below).
        StylusPerpMultiCalls manager = new StylusPerpMultiCalls();

        // 2. Real Vault, with the manager as its (immutable) ERC2771 forwarder.
        address[] memory stableCoins = new address[](1);
        uint256[] memory depositThresholds = new uint256[](1);
        uint256[] memory withdrawalThresholds = new uint256[](1);
        uint256[] memory stableDecimalsArr = new uint256[](1);
        stableCoins[0] = stableCoin;
        depositThresholds[0] = depositThreshold;
        withdrawalThresholds[0] = withdrawalThreshold;
        stableDecimalsArr[0] = stableDecimals;
        Vault vault = new Vault(
            address(manager),
            minCollateralMovement,
            stableCoins,
            depositThresholds,
            withdrawalThresholds,
            stableDecimalsArr
        );

        // 3. LostAndFound (recovery flow the Vault links to).
        LostAndFound lostAndFound = new LostAndFound();
        // The Vault needs VAULT_ROLE to route unclaimable transfers into recovery; without it the
        // lost-and-found path reverts.
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));

        // 4. Solidity-side wiring (pure storage setters — no engine call). Only possible once the
        //    engine exists; in the periphery-first constructor flow it is done via cast afterwards.
        bool haveEngine = engine != address(0) && engine.code.length > 0;
        if (haveEngine) {
            manager.initializeAddresses(engine, address(vault));
            vault.initializeParameters(engine, address(lostAndFound));
        }

        vm.stopBroadcast();

        // Solidity-only post-deploy assertions (the engine-side checks run via cast).
        require(
            lostAndFound.hasRole(lostAndFound.VAULT_ROLE(), address(vault)),
            "vault missing LostAndFound VAULT_ROLE"
        );
        if (haveEngine) {
            require(manager.perpPair() == engine, "manager.perpPair != engine");
            require(manager.vault() == address(vault), "manager.vault != vault");
        }

        console2.log("Deployer", deployer);
        console2.log("StylusPerpMultiCalls (manager)", address(manager));
        console2.log("Vault", address(vault));
        console2.log("LostAndFound", address(lostAndFound));
        console2.log("Oracle (existing)", oracle);
        console2.log("Stablecoin", stableCoin);
        if (haveEngine) {
            console2.log("PerpEngine (pre-existing, wired)", engine);
        } else {
            // Periphery-first flow: deploy the engine next, then wire it (cast).
            console2.log("NEXT (1/3): deploy + activate the engine (wasm-opt'd artifact):");
            console2.log("  cargo stylus deploy --wasm-file engine.Oz.wasm --private-key $PK --endpoint $RPC");
            console2.log("NEXT (2/3): initialize the engine (selector 0xa0d9afc0; caller receives admin+mod roles):");
            console2.log("  oracle=", oracle);
            console2.log("  vault=", address(vault));
            console2.log("  multiCallManager=", address(manager));
            console2.log("  (+ mmr, ticker, feeFrontend, feeLP, feeProtocolAddr, tradingFee, flatTradingFee, emaParam)");
            console2.log("  cast send <engine> 'initializeProduction(address,address,address,uint256,bytes32,uint32,uint32,address,uint256,uint256,uint256)' <oracle> <vault> <manager> ...");
            console2.log("NEXT (3/3, cast, after the engine is up):");
            console2.log("  manager.initializeAddresses(<engine>, vault); vault.initializeParameters(<engine>, lostAndFound); then cargo stylus cache bid <engine> <BID>");
        }
    }
}
