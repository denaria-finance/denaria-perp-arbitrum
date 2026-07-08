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
///         engine reverts `OpcodeNotFound` in `forge script` simulation. So the engine's
///         `initializeProduction(...)` (which sets trustedForwarder=manager and grants the
///         deployer DEFAULT_ADMIN+MOD on the engine), all engine reads, and any engine role
///         handoff are done via `cast` per the runbook — NOT here. This script only does the
///         Solidity deploys + the Solidity-side wiring (`manager.initializeAddresses`,
///         `vault.initializeParameters`, which merely store addresses) + Solidity asserts.
///
///         All parameters are read from the environment unchanged; see docs/DEPLOYMENT.md.
contract ArbitrumSepoliaProdDeploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address engine = vm.envAddress("PERP_ENGINE");
        require(engine != address(0) && engine.code.length > 0, "PERP_ENGINE not deployed/activated");
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
        //    engine's trustedForwarder (the latter set later via cast initializeProduction).
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
            oracle,
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

        // 4. Solidity-side wiring (pure storage setters — no engine call).
        manager.initializeAddresses(engine, address(vault));
        vault.initializeParameters(engine, address(lostAndFound));

        vm.stopBroadcast();

        // Solidity-only post-deploy assertions (the engine-side checks run via cast).
        require(manager.perpPair() == engine, "manager.perpPair != engine");
        require(manager.vault() == address(vault), "manager.vault != vault");
        require(
            lostAndFound.hasRole(lostAndFound.VAULT_ROLE(), address(vault)),
            "vault missing LostAndFound VAULT_ROLE"
        );

        console2.log("Deployer", deployer);
        console2.log("PerpEngine (wasm, pre-deployed)", engine);
        console2.log("StylusPerpMultiCalls (manager)", address(manager));
        console2.log("Vault", address(vault));
        console2.log("LostAndFound", address(lostAndFound));
        console2.log("Oracle (existing)", oracle);
        console2.log("Stablecoin", stableCoin);
        console2.log("NEXT (cast): engine.initializeProduction(oracle, vault, manager, MMR, ticker, feeFrontend, feeLP, feeProtocolAddr, tradingFee, flatTradingFee, emaParam)");
        console2.log("THEN: cargo stylus cache bid <PERP_ENGINE>");
    }
}
