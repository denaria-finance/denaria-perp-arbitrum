// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A permit token whose `permit` succeeds but establishes a SMALLER allowance than the
///         caller asked for. EIP-2612 does not oblige an implementation to set exactly `value`,
///         and fee-on-transfer / upgradeable / non-standard stablecoins can deviate. It is the
///         shape the bundlers' post-permit allowance check exists for: without it the bundle
///         proceeds to `transferFrom` and fails late (or partially), instead of reverting up front.
contract ShortPermitToken is ERC20 {
    constructor() ERC20("Short permit token", "SHORT") { }

    function nonces(address) external pure returns (uint256) {
        return 0;
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        _approve(owner, spender, value == 0 ? 0 : value - 1);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
