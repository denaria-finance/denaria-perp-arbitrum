// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {BadDebtAssertion} from "../src/assertionBadDebt.a.sol";

contract MyBacktestingTest is CredibleTestWithBacktesting {
    
    function testHistoricalTransactions() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: 0xD07822ee341C11a193869034d7e5f583c4a94872, // PerpPair on linea mainnet
                endBlock: 28144850, // Latest block to test  27625715
                blockRange: 2, // Number of blocks to test
                assertionCreationCode: type(BadDebtAssertion).creationCode,
                assertionSelector: BadDebtAssertion.assertionBadDebt.selector,
                rpcUrl: "https://linea-mainnet.g.alchemy.com/v2/mgTucu-ukIEKOmeTBpdOl",
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );

        // Check results
        assert(results.assertionFailures == 0);
    }
    
}