// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// Periphery deploy for the local Nitro E2E (script/nitro_e2e.sh): a mock oracle, the manager
// (ERC2771 forwarder), the real Vault, USDC.e, and LostAndFound. The engine is deployed
// separately (a benchmark-feature WASM, initialized via cast). The Vault reads the oracle from
// the engine (`IPerpPair.oracle()`), so its constructor takes no oracle (6 args).
import { Script, console2 } from "forge-std/Script.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { StylusPerpMultiCalls } from "../src/manager/StylusPerpMultiCalls.sol";
import { TestPriceProvider } from "../src/test_support/TestPriceProvider.sol";
import "../src/token/USDCe.sol";

contract LocalNitroDeploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address taker = vm.envAddress("TAKER");

        uint256 oraclePrice = vm.envOr("ORACLE_PRICE", uint256(100000) * 1e8);
        uint256 minCollateralMovement = vm.envOr("MIN_COLLATERAL_MOVEMENT", uint256(1e17));
        uint256 stableDecimalsFactor = vm.envOr("STABLE_DECIMALS", uint256(1e6));
        uint256 depositThreshold = vm.envOr("DEPOSIT_THRESHOLD", uint256(1e11));
        uint256 withdrawalThreshold = vm.envOr("WITHDRAWAL_THRESHOLD", uint256(1e11));
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(6)));
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000) * (10 ** tokenDecimals));

        vm.startBroadcast(deployerPk);

        FiatTokenV2 usdc = new FiatTokenV2();
        usdc.initialize("USDCe", "USDC.e", "USD", tokenDecimals, deployer, deployer, deployer, deployer);
        usdc.initializeV2("USDCe");
        usdc.configureMinter(deployer, type(uint256).max);
        usdc.mint(taker, mintAmount);

        TestPriceProvider oracle = new TestPriceProvider();
        oracle.setPrice(oraclePrice);

        StylusPerpMultiCalls manager = new StylusPerpMultiCalls();

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
            minCollateralMovement,
            stableCoins,
            depositThresholds,
            withdrawalThresholds,
            stableDecimalsArr
        );

        LostAndFound lostAndFound = new LostAndFound();
        lostAndFound.grantRole(lostAndFound.VAULT_ROLE(), address(vault));

        vm.stopBroadcast();

        console2.log("ADDR:MANAGER", address(manager));
        console2.log("ADDR:VAULT", address(vault));
        console2.log("ADDR:ORACLE", address(oracle));
        console2.log("ADDR:STABLECOIN", address(usdc));
        console2.log("ADDR:LOSTANDFOUND", address(lostAndFound));
    }
}
