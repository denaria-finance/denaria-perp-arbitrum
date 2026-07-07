// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { Script, console2 } from "forge-std/Script.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { StylusPerpMultiCalls } from "../src/manager/StylusPerpMultiCalls.sol";
import { TestPriceProvider } from "../src/test_support/TestPriceProvider.sol";
import "../src/token/USDCe.sol";

/// @title Local Nitro dev-node deployer — SOLIDITY side + offline mock oracle + test USDC.
/// @notice Prototype for the Tier-3 offline CI money-path substrate. Mirrors
///         `ArbitrumSepoliaProdDeploy.s.sol` but, instead of reusing the live
///         Chainlink Data Streams oracle + USDC.e, it deploys:
///           - `TestPriceProvider` (signature-free mock oracle, `setPrice()`),
///           - a fresh mintable `FiatTokenV2` (test USDC.e),
///         so a full open/close trade can be driven entirely offline against the
///         pre-deployed-and-activated Stylus `PERP_ENGINE` WASM program.
///
///         Foundry cannot EXECUTE the Stylus (WASM) engine, so — exactly as in the
///         prod script — this only does Solidity deploys + storage-setter wiring
///         (`manager.initializeAddresses`, `vault.initializeParameters`). The engine's
///         `initializeProduction(...)` is run separately via `cast` (see the orchestrator).
contract LocalNitroDeploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address engine = vm.envAddress("PERP_ENGINE");
        require(engine != address(0) && engine.code.length > 0, "PERP_ENGINE not deployed/activated");
        address taker = vm.envAddress("TAKER");

        // Oracle price already scaled to oracle decimals (1e8): e.g. 100000e8 for $100k BTC.
        uint256 oraclePrice = vm.envOr("ORACLE_PRICE", uint256(100000) * 1e8);
        // Vault params (factors, not exponents — see the F4 stableUnit lesson).
        uint256 minCollateralMovement = vm.envOr("MIN_COLLATERAL_MOVEMENT", uint256(1e17));
        uint256 stableDecimalsFactor = vm.envOr("STABLE_DECIMALS", uint256(1e6));
        uint256 depositThreshold = vm.envOr("DEPOSIT_THRESHOLD", uint256(1e11));
        uint256 withdrawalThreshold = vm.envOr("WITHDRAWAL_THRESHOLD", uint256(1e11));
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(6)));
        // Mint 1,000,000 USDC.e (raw = 1e6 * 10^decimals) to the taker by default.
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000) * (10 ** tokenDecimals));

        vm.startBroadcast(deployerPk);

        // 1. Test USDC.e — mintable FiatTokenV2. Deployer is masterMinter so it can
        //    configureMinter(itself) then mint to the taker. initializeV2 wires the
        //    EIP-2612 permit domain the EOA `addCollateralOpenTrade` flow signs against.
        FiatTokenV2 usdc = new FiatTokenV2();
        usdc.initialize("USDCe", "USDC.e", "USD", tokenDecimals, deployer, deployer, deployer, deployer);
        usdc.initializeV2("USDCe");
        usdc.configureMinter(deployer, type(uint256).max);
        usdc.mint(taker, mintAmount);

        // 2. Offline mock oracle — accepts any (empty) report bytes, returns setPrice().
        TestPriceProvider oracle = new TestPriceProvider();
        oracle.setPrice(oraclePrice);

        // 3. Manager FIRST (immutable ERC2771 forwarder for the Vault + engine forwarder).
        StylusPerpMultiCalls manager = new StylusPerpMultiCalls();

        // 4. Real Vault, single-stablecoin config, manager as forwarder, oracle wired.
        address[] memory stableCoins = new address[](1);
        uint256[] memory depositThresholds = new uint256[](1);
        uint256[] memory withdrawalThresholds = new uint256[](1);
        uint256[] memory stableDecimalsArr = new uint256[](1);
        stableCoins[0] = address(usdc);
        depositThresholds[0] = depositThreshold;
        withdrawalThresholds[0] = withdrawalThreshold;
        stableDecimalsArr[0] = stableDecimalsFactor;
        Vault vault = new Vault(
            address(manager),
            address(oracle),
            minCollateralMovement,
            stableCoins,
            depositThresholds,
            withdrawalThresholds,
            stableDecimalsArr
        );

        // 5. LostAndFound (recovery flow the Vault links to).
        LostAndFound lostAndFound = new LostAndFound();

        // 6. Solidity-side wiring (pure storage setters — no engine call).
        manager.initializeAddresses(engine, address(vault));
        vault.initializeParameters(engine, address(lostAndFound));

        vm.stopBroadcast();

        require(manager.perpPair() == engine, "manager.perpPair != engine");
        require(manager.vault() == address(vault), "manager.vault != vault");

        // Machine-parseable address block for the orchestrator (grep ADDR:).
        console2.log("ADDR:PERP_ENGINE", engine);
        console2.log("ADDR:MANAGER", address(manager));
        console2.log("ADDR:VAULT", address(vault));
        console2.log("ADDR:ORACLE", address(oracle));
        console2.log("ADDR:STABLECOIN", address(usdc));
        console2.log("ADDR:LOSTANDFOUND", address(lostAndFound));
        console2.log("ADDR:DEPLOYER", deployer);
        console2.log("ADDR:TAKER", taker);
    }
}
