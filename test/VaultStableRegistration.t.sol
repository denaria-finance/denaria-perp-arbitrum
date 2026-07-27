// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";
import { FiatTokenV2 } from "../src/token/USDCe.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A token whose `decimals()` reverts: the scale check must bubble that up instead of
///      registering a coin whose scale can never be validated.
contract NoDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert("NO_DECIMALS");
    }
}

/// @title Stablecoin registration guards (AS2/AS3)
/// @notice Vault collateral accounting keys ratio state by token address and converts amounts
///         through the registered `stableDecimals` scale. A duplicate registration aliases another
///         coin's ratio state, and a scale that is not exactly `10 ** token.decimals()` misvalues
///         every deposit and withdrawal for that coin (or bricks conversions when it is 0). Both
///         constructor and timelocked registration must reject those inputs.
///         The timelocked zero-address call is NOT a no-op: it deliberately skips registration
///         while still updating the add-stablecoin timelock duration — the only path that changes
///         that duration without registering a coin.
contract VaultStableRegistrationTest is Test {
    uint256 internal constant RATIO_DECIMALS = 1e8;

    address internal masterMinter = makeAddr("masterMinter");
    address internal pauser = makeAddr("pauser");
    address internal blacklister = makeAddr("blacklister");
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");

    FiatTokenV2 internal coin18;
    FiatTokenV2 internal coin6;

    event AddingStableCoin(
        uint256 lockTime,
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    );

    function setUp() public {
        coin18 = _newToken(18);
        coin6 = _newToken(6);
    }

    // --- constructor -------------------------------------------------------------------

    function testConstructorRejectsZeroAddressStable() public {
        vm.expectRevert(bytes("AS2"));
        _deployVault(_addrs(address(0)), _amounts(1e18));
    }

    function testConstructorRejectsDuplicateStable() public {
        address[] memory coins = new address[](2);
        coins[0] = address(coin18);
        coins[1] = address(coin18);
        uint256[] memory scales = new uint256[](2);
        scales[0] = 1e18;
        scales[1] = 1e18;

        vm.expectRevert(bytes("AS3"));
        _deployVault(coins, scales);
    }

    function testConstructorRejectsScaleBelowDecimals() public {
        vm.expectRevert(bytes("AS2"));
        _deployVault(_addrs(address(coin18)), _amounts(1e17));
    }

    function testConstructorRejectsScaleAboveDecimals() public {
        vm.expectRevert(bytes("AS2"));
        _deployVault(_addrs(address(coin18)), _amounts(1e19));
    }

    function testConstructorRejectsZeroScale() public {
        vm.expectRevert(bytes("AS2"));
        _deployVault(_addrs(address(coin6)), _amounts(0));
    }

    function testConstructorRejectsTokenWithoutDecimals() public {
        NoDecimalsToken broken = new NoDecimalsToken();
        vm.expectRevert(bytes("NO_DECIMALS"));
        _deployVault(_addrs(address(broken)), _amounts(1e18));
    }

    function testConstructorAcceptsMatchingScales() public {
        address[] memory coins = new address[](2);
        coins[0] = address(coin6);
        coins[1] = address(coin18);
        uint256[] memory scales = new uint256[](2);
        scales[0] = 1e6;
        scales[1] = 1e18;

        Vault vault = _deployVault(coins, scales);

        (ERC20 registered,,, uint256 scale) = vault.stableCoins(0);
        assertEq(address(registered), address(coin6));
        assertEq(scale, 1e6);
        (registered,,, scale) = vault.stableCoins(1);
        assertEq(address(registered), address(coin18));
        assertEq(scale, 1e18);
    }

    // --- timelocked addStableCoin -------------------------------------------------------

    function testTimelockedAdditionRejectsDuplicateStable() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));
        _prepareAddStableCoin(vault, address(coin18), 1e18, 1 days);

        vm.expectRevert(bytes("AS3"));
        vault.addStableCoin(address(coin18), 0, 0, 1e18, 1 days);
    }

    function testTimelockedAdditionRejectsWrongScale() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));
        _prepareAddStableCoin(vault, address(coin6), 1e18, 1 days);

        vm.expectRevert(bytes("AS2"));
        vault.addStableCoin(address(coin6), 0, 0, 1e18, 1 days);
    }

    /// @dev The timelocked path carries its own copy of the AS2 expression, so it needs the same
    ///      boundary coverage as the constructor: a divergent edit to one must not go unnoticed.
    function testTimelockedAdditionRejectsScaleBelowDecimals() public {
        Vault vault = _deployVault(_addrs(address(coin6)), _amounts(1e6));
        _prepareAddStableCoin(vault, address(coin18), 1e17, 1 days);

        vm.expectRevert(bytes("AS2"));
        vault.addStableCoin(address(coin18), 0, 0, 1e17, 1 days);
    }

    function testTimelockedAdditionRejectsZeroScale() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));
        _prepareAddStableCoin(vault, address(coin6), 0, 1 days);

        vm.expectRevert(bytes("AS2"));
        vault.addStableCoin(address(coin6), 0, 0, 0, 1 days);
    }

    function testTimelockedAdditionRejectsTokenWithoutDecimals() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));
        NoDecimalsToken broken = new NoDecimalsToken();
        _prepareAddStableCoin(vault, address(broken), 1e18, 1 days);

        vm.expectRevert(bytes("NO_DECIMALS"));
        vault.addStableCoin(address(broken), 0, 0, 1e18, 1 days);
    }

    function testTimelockedAdditionAcceptsMatchingScale() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));

        _addStableCoin(vault, address(coin6), 1e6, 1 days);

        (ERC20 registered,,, uint256 scale) = vault.stableCoins(1);
        assertEq(address(registered), address(coin6));
        assertEq(scale, 1e6);
    }

    /// @dev The zero-address path is not a full no-op: registration is skipped, but the timelock
    ///      duration is still updated and the event still emitted. Turning it into an early return
    ///      would silently remove the only way to change that duration.
    function testTimelockedZeroAddressUpdatesDurationWithoutRegistering() public {
        Vault vault = _deployVault(_addrs(address(coin18)), _amounts(1e18));
        uint256 newDuration = 3 days;
        _prepareAddStableCoin(vault, address(0), 0, newDuration);

        vm.expectEmit(true, true, true, true, address(vault));
        emit AddingStableCoin(0, address(0), 0, 0, 0, newDuration);
        vault.addStableCoin(address(0), 0, 0, 0, newDuration);

        assertEq(vault.addStableTimeLockDuration(), newDuration);
        vm.expectRevert();
        vault.stableCoins(1);
    }

    // --- helpers ------------------------------------------------------------------------

    function _newToken(uint8 tokenDecimals) private returns (FiatTokenV2 token) {
        token = new FiatTokenV2();
        token.initialize("USDCe", "USDC.e", "USD", tokenDecimals, masterMinter, pauser, blacklister, owner);
        token.initializeV2("USDCe");
    }

    function _addrs(address coin) private pure returns (address[] memory coins) {
        coins = new address[](1);
        coins[0] = coin;
    }

    function _amounts(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _deployVault(address[] memory coins, uint256[] memory scales) private returns (Vault vault) {
        uint256[] memory thresholds = new uint256[](coins.length);
        for (uint256 i; i < coins.length; i++) {
            thresholds[i] = RATIO_DECIMALS;
        }
        vault = new Vault(manager, 100, coins, thresholds, thresholds, scales);
    }

    function _prepareAddStableCoin(Vault vault, address coin, uint256 scale, uint256 newDuration) private {
        vault.grantRole(vault.MOD_ROLE(), address(this));
        vault.prepareAddStableCoin(coin, 0, 0, scale, newDuration);
        skip(vault.addStableTimeLockDuration() + 1);
    }

    function _addStableCoin(Vault vault, address coin, uint256 scale, uint256 newDuration) private {
        _prepareAddStableCoin(vault, coin, scale, newDuration);
        vault.addStableCoin(coin, 0, 0, scale, newDuration);
    }
}
