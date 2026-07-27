// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { TWAPOracleMiddleware } from "../src/CL_oracle_middleware/TWAPOracleMiddleware.sol";
import { TWAPOracleMiddleware as TWAPOracleMiddlewareMirror } from "../src/test_support/TWAPOracleMiddlewareTest.sol";
import { MockLinkToken, MockRewardManager, MockFeeManager, MockVerifierProxy } from "./OracleMiddlewareReport.t.sol";

/// @title Oracle parameter-guard regressions (OM8)
/// @notice `maxTimeDelta` is the freshness half-window: at 0 a report is accepted only when
///         `validFrom == block.timestamp` exactly, so the oracle stops serving prices and every
///         price-consuming path (trade, close, liquidation, collateral removal) stalls.
///         `updateIndex` addresses the price history: moving it backwards replays already-consumed
///         datapoints and moving it to 0 underflows the `updateIndex - 1` history reads.
///         Both the production middleware and its test-support mirror must reject those inputs at
///         construction and in `setParameters`, while still allowing an unchanged index.
contract OracleParameterGuardsTest is Test {
    bytes32 constant FEED_ID = bytes32(uint256(3) << 240);

    TWAPOracleMiddleware internal oracle;
    MockVerifierProxy internal verifier;

    function setUp() public {
        MockLinkToken link = new MockLinkToken();
        MockRewardManager rewardManager = new MockRewardManager();
        MockFeeManager feeManager = new MockFeeManager(address(rewardManager), address(link));
        verifier = new MockVerifierProxy(address(feeManager));
        oracle = new TWAPOracleMiddleware(address(verifier), FEED_ID, 600, "BTC test oracle", int192(1e10));
    }

    function testConstructorRejectsZeroMaxTimeDelta() public {
        vm.expectRevert(bytes("OM8"));
        new TWAPOracleMiddleware(address(verifier), FEED_ID, 0, "BTC test oracle", int192(1e10));
    }

    function testConstructorAcceptsSmallestNonZeroMaxTimeDelta() public {
        TWAPOracleMiddleware fresh =
            new TWAPOracleMiddleware(address(verifier), FEED_ID, 1, "BTC test oracle", int192(1e10));
        assertEq(fresh.maxTimeDelta(), 1);
    }

    function testSetParametersRejectsZeroMaxTimeDelta() public {
        uint256 current = oracle.updateIndex();
        vm.expectRevert(bytes("OM8"));
        oracle.setParameters(0, current, 300, 5000, "BTC test oracle");
    }

    function testSetParametersRejectsUpdateIndexRollback() public {
        oracle.setParameters(600, 5, 300, 5000, "BTC test oracle");

        vm.expectRevert(bytes("OM8"));
        oracle.setParameters(600, 4, 300, 5000, "BTC test oracle");
    }

    function testSetParametersRejectsZeroUpdateIndex() public {
        vm.expectRevert(bytes("OM8"));
        oracle.setParameters(600, 0, 300, 5000, "BTC test oracle");
    }

    function testSetParametersAllowsEqualUpdateIndex() public {
        uint256 current = oracle.updateIndex();
        oracle.setParameters(600, current, 300, 5000, "BTC test oracle");
        assertEq(oracle.updateIndex(), current);
    }

    function testSetParametersAllowsForwardUpdateIndex() public {
        uint256 next = oracle.updateIndex() + 1;
        oracle.setParameters(600, next, 300, 5000, "BTC test oracle");
        assertEq(oracle.updateIndex(), next);
    }

    // --- test-support mirror: same guards, so oracle-behaviour tests cannot drift from production

    function testMirrorConstructorRejectsZeroMaxTimeDelta() public {
        vm.expectRevert(bytes("OM8"));
        new TWAPOracleMiddlewareMirror(0, "oracle", 10_000_000_000);
    }

    function testMirrorSetParametersEnforcesGuards() public {
        TWAPOracleMiddlewareMirror mirror = new TWAPOracleMiddlewareMirror(5, "oracle", 10_000_000_000);
        uint256 current = mirror.updateIndex();

        vm.expectRevert(bytes("OM8"));
        mirror.setParameters(0, current, 300, 5000, "oracle");

        mirror.setParameters(5, 7, 300, 5000, "oracle");
        vm.expectRevert(bytes("OM8"));
        mirror.setParameters(5, 6, 300, 5000, "oracle");

        mirror.setParameters(5, 7, 300, 5000, "oracle");
        assertEq(mirror.updateIndex(), 7);
    }
}
