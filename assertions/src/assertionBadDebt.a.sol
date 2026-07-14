// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPerpPair} from "./IPerpPair.sol";
import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";


/// @title BadDebtAssertion
/// @notice Checks that bad debt is not happening in the transaction for the sender.
///
/// @dev INVARIANT #1: check bad debt generation

contract BadDebtAssertion is Assertion {
    
    bytes32 constant EXECUTED_TRADE_TOPIC0 = keccak256("ExecutedTrade(address,bool,uint256,uint256,uint256,uint256)");
    bytes32 constant CLOSED_POSITION_TOPIC0 = keccak256("ClosedPosition(address,uint256,bool)");
    bytes32 constant TOGGLED_AUTO_TOPIC0 = keccak256("ToggledAutoClose(address,uint256,uint256,uint256,uint256)");
    bytes32 constant LIQUIDATED_USER_TOPIC0 = keccak256("LiquidatedUser(address,address,uint256,uint256,uint256,uint256,int256,bool)");
    bytes32 constant LIQUIDITY_MOVED_TOPIC0 = keccak256("LiquidityMoved(address,uint256,uint256,uint256,bool)");
    bytes32 constant REALIZED_PNL_TOPIC0 = keccak256("RealizedPnL(address,uint256,bool)");

    mapping(bytes32 => uint8) public eventIds;

    constructor(){
        eventIds[EXECUTED_TRADE_TOPIC0] = 1;
        eventIds[CLOSED_POSITION_TOPIC0] = 1;
        eventIds[TOGGLED_AUTO_TOPIC0] = 1;
        eventIds[LIQUIDITY_MOVED_TOPIC0] = 1;
        eventIds[REALIZED_PNL_TOPIC0] = 1;
    }

    /// @notice Registers assertion triggers on vault functions that modify epochs
    function triggers() external view override {
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.trade.selector);
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.closeAndWithdraw.selector);
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.addLiquidity.selector);
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.removeLiquidity.selector);
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.liquidate.selector);
        registerCallTrigger(this.assertionBadDebt.selector, IPerpPair.enableAutoClose.selector);
        //TODO: add all calls that can trigger this
    }

    
    /// @dev 
    function assertionBadDebt() external {

        address perpAddress = ph.getAssertionAdopter();
        ph.forkPostTx();

        //Recover user from logs. This only works for functions which emit events with user inside. If a transaction has no such calls should skip the assertion.
        PhEvm.Log[] memory logs = ph.getLogs();
        address user;
        for (uint256 i = 0; i < logs.length; i++) {

            if (logs[i].topics.length == 0) continue; 

            bytes32 sig = logs[i].topics[0];

            if (sig == LIQUIDATED_USER_TOPIC0) {
                (address liquidator,,,,,,) = abi.decode(
                    logs[i].data,
                    (address, uint256, uint256, uint256, uint256, int256, bool)
                );
                user = liquidator;
                break;
            }

            uint8 usrIdx = eventIds[sig];
            if (usrIdx != 0) {
                user = address(uint160(uint256(logs[i].topics[usrIdx])));
                break;
            }
        }
        if (user == address(0)) return;
        
        uint256 collateral = IPerpPair(perpAddress).getCollateral(user);
        (uint256 pnl, bool pnlSign) = IPerpPair(perpAddress).calcPnL(user, IPerpPair(perpAddress).getPrice());
        
        require(pnl<=collateral || pnlSign, "C1"); 
        
    }

    

    
}