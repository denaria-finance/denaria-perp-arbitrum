// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { TWAPOracleMiddleware } from "../src/test_support/TWAPOracleMiddlewareTest.sol";

import "../src/util/UtilMath.sol";

contract OracleTest is Test {
    TWAPOracleMiddleware public oracle;

    function setUp() public {
        oracle = new TWAPOracleMiddleware(5, "oracle", 10_000_000_000);
        skip(100_000);
    }

    ///@dev tests verifying a price and checks it is returned
    function testAddPrice(int192 price) public {
        price = int192(bound(price, 1e12, 1e40));
        oracle.verifyReportIfNecessary(price, uint32(block.timestamp));
        int192 returnPrice = oracle.getPrice();
        assert(returnPrice == price / 1e10);
    }

    ///@dev tests verifying multiple prices in sequence
    function testAddMultiplePrices(int192 price1, int192 price2, int192 price3) public {
        price1 = int192(bound(price1, 1e12, 1e40));
        price2 = int192(bound(price2, price1 * 90 / 100, price1 * 110 / 100));
        price3 = int192(bound(price3, price2 * 90 / 100, price2 * 110 / 100));

        oracle.verifyReportIfNecessary(price1, uint32(block.timestamp));
        int192 returnPrice = oracle.getPrice();
        assertTrue(returnPrice == price1 / 1e10, "1");
        console.log(oracle.lastPrices(1));

        skip(3602);
        oracle.verifyReportIfNecessary(price2, uint32(block.timestamp));
        console.log(oracle.lastPrices(2));
        returnPrice = oracle.getPrice();
        assertTrue(returnPrice == price2 / 1e10, "2");

        skip(3604);
        oracle.verifyReportIfNecessary(price2, uint32(block.timestamp));
        console.log(oracle.lastPrices(2));
        returnPrice = oracle.getPrice();
        assertTrue(returnPrice == price2 / 1e10, "3");

        skip(3604);
        oracle.verifyReportIfNecessary(price3, uint32(block.timestamp));
        console.log(oracle.lastPrices(2));
        returnPrice = oracle.getPrice();
        assertTrue(returnPrice == price3 / 1e10, "4");
    }

    ///@dev tests that the twap mechanism for rejecting/accepting the prices works correctly
    function testTWAP(uint256 price1) public {
        price1 = bound(price1, 1e12, 1e40);
        uint256 price2 = price1 * 90 / 100;
        uint256 price3 = price2 * 108 / 100;
        uint256 price4 = price3 * 106 / 100;
        uint256 price5 = price4 * 92 / 100;
        uint256 price6 = price5 * 105 / 100;
        uint256 price7 = price6 * 95 / 100;
        uint256 price8 = price7 * 102 / 100;
        uint256 price9 = price8 * 9000 / 100;

        int192 returnPrice;

        vm.recordLogs();

        oracle.verifyReportIfNecessary(int192(uint192(price1)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price1 / 1e10, "price1");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0);

        skip(600);
        oracle.verifyReportIfNecessary(int192(uint192(price2)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price2 / 1e10, "price2");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        skip(1200);
        oracle.verifyReportIfNecessary(int192(uint192(price3)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price3 / 1e10, "price3");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        skip(300);
        oracle.verifyReportIfNecessary(int192(uint192(price4)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price4 / 1e10, "price4");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        skip(1500);
        oracle.verifyReportIfNecessary(int192(uint192(price5)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price5 / 1e10, "price5");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        skip(1200);
        oracle.verifyReportIfNecessary(int192(uint192(price6)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price6 / 1e10, "price6");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertTrue(
            inConfidenceInterval(
                uint256(uint192(abi.decode(entries[0].data, (int192)))),
                (price2 * 6 + price3 * 3 + price4 * 15 + price5 * 12) / 36,
                1_000_000
            ),
            "twap1"
        );

        skip(600);
        oracle.verifyReportIfNecessary(int192(uint192(price7)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price7 / 1e10, "price7");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertTrue(
            inConfidenceInterval(
                uint256(uint192(abi.decode(entries[0].data, (int192)))),
                (price3 * 3 + price4 * 15 + price5 * 12 + price6 * 6) / 36,
                1_000_000
            ),
            "twap2"
        );

        skip(200);
        oracle.verifyReportIfNecessary(int192(uint192(price8)), uint32(block.timestamp));
        returnPrice = oracle.getPrice();
        assertTrue(uint256(uint192(returnPrice)) == price8 / 1e10, "price8");

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertTrue(
            inConfidenceInterval(
                uint256(uint192(abi.decode(entries[0].data, (int192)))),
                (price3 + price4 * 15 + price5 * 12 + price6 * 6 + price7 * 2) / 36,
                1_000_000
            ),
            "twap3"
        );

        skip(1000);
        assertFalse(
            oracle.checkLastPriceVolatility(int192(uint192(price9)), uint32(block.timestamp)), "price9 should fail twap"
        );
        int192 acceptedPriceBeforeSpike = oracle.lastDecodedPrice();
        uint256 updateIndexBeforeSpike = oracle.updateIndex();
        oracle.verifyReportIfNecessary(int192(uint192(price9)), uint32(block.timestamp));
        assertEq(oracle.lastDecodedPrice(), acceptedPriceBeforeSpike, "price9 should not be exposed");
        assertEq(oracle.updateIndex(), updateIndexBeforeSpike + 1, "price9 should still feed twap history");
        vm.expectRevert(bytes("OM2"));
        returnPrice = oracle.getPrice();

        entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertTrue(
            inConfidenceInterval(
                uint256(uint192(abi.decode(entries[0].data, (int192)))),
                (price4 * 6 + price5 * 12 + price6 * 6 + price7 * 2 + price8 * 10) / 36,
                1_000_000
            ),
            "twap4"
        );
    }

    /// @dev tests that computeTWAP() correctly returns the time-weighted average over a lookback window
    function testGetTWAP() public {
        // Setup: push sequential prices spaced by time intervals
        uint256 lookback = 3600; // 1 hour
        uint256 basePrice = 1e18;

        // Simulate 4 price updates, spaced 15 minutes apart
        oracle.verifyReportIfNecessary(int192(int256(basePrice)), uint32(vm.getBlockTimestamp())); // t0
        skip(100);
        oracle.verifyReportIfNecessary(int192(int256(basePrice * 110 / 100)), uint32(vm.getBlockTimestamp())); // t1
        skip(100);
        oracle.verifyReportIfNecessary(int192(int256(basePrice * 90 / 100)), uint32(vm.getBlockTimestamp())); // t2
        skip(200);
        oracle.verifyReportIfNecessary(int192(int256(basePrice * 120 / 100)), uint32(vm.getBlockTimestamp())); // t3
        skip(100);

        uint256 expectedTwap = basePrice * 102 / 100; // 1.05 * basePrice

        // Call TWAP function
        uint256 computedTwap = oracle.getTWAP();

        // Allow small tolerance for rounding differences
        assertTrue(inConfidenceInterval(computedTwap, expectedTwap, 1_000_000), "TWAP computation incorrect");
    }

    /// @dev a stored price older than the full lookback window still carries into the TWAP, so a
    /// tail-only spike is rejected and does not become the exposed price (but still feeds history).
    function testSparseHistoryCarriesPriceAcrossFullTwapWindow() public {
        oracle = new TWAPOracleMiddleware(300, "oracle", 1);

        vm.warp(12 hours);
        oracle.verifyReportIfNecessary(100, uint32(vm.getBlockTimestamp()));

        vm.warp(13 hours + 59 minutes);
        oracle.verifyReportIfNecessary(60, uint32(vm.getBlockTimestamp()));

        vm.warp(14 hours);
        assertEq(oracle.getTWAP(), 99, "full-window twap should carry pre-window price");
        assertFalse(
            oracle.checkLastPriceVolatility(31, uint32(vm.getBlockTimestamp())), "tail-only twap accepted bad price"
        );

        oracle.verifyReportIfNecessary(31, uint32(vm.getBlockTimestamp()));
        assertEq(oracle.lastDecodedPrice(), 60, "twap-invalid price should not be exposed");
        assertEq(oracle.lastPrices(3), 31, "twap-invalid price should still feed history");
    }

    /// @dev a TWAP-invalid report is appended to history but does not overwrite the cached (exposed) price.
    function testTwapInvalidReportDoesNotPoisonStoredPrice() public {
        int192 basePrice = 100 * 1e10;
        int192 invalidPrice = 1000 * 1e10;

        oracle.verifyReportIfNecessary(basePrice, uint32(vm.getBlockTimestamp()));
        assertEq(oracle.lastDecodedPrice(), basePrice, "initial price not stored");

        uint32 firstTimestamp = uint32(vm.getBlockTimestamp());
        skip(1);
        oracle.verifyReportIfNecessary(invalidPrice, uint32(vm.getBlockTimestamp()));

        assertEq(oracle.lastDecodedPrice(), basePrice, "invalid report poisoned cached price");
        assertEq(oracle.lastDecodedValidFromTimestamp(), firstTimestamp, "invalid report poisoned timestamp");
        assertEq(oracle.updateIndex(), 3, "invalid report was not appended to history");
        assertEq(oracle.lastPrices(2), uint192(invalidPrice), "invalid report did not feed twap history");
        assertEq(oracle.getPrice(), basePrice / 1e10, "cached price should remain readable");
    }

    /// @dev repeated volatile reports eventually pull the TWAP into the new regime and get exposed.
    function testVolatileMarketCanConvergeToNewPriceRegime() public {
        oracle = new TWAPOracleMiddleware(300, "oracle", 1);

        vm.warp(12 hours);
        oracle.verifyReportIfNecessary(100, uint32(vm.getBlockTimestamp()));

        vm.warp(13 hours);
        oracle.verifyReportIfNecessary(400, uint32(vm.getBlockTimestamp()));
        assertEq(oracle.lastDecodedPrice(), 100, "first spike should not be exposed");

        vm.warp(13 hours + 30 minutes);
        oracle.verifyReportIfNecessary(400, uint32(vm.getBlockTimestamp()));
        assertEq(oracle.lastDecodedPrice(), 100, "twap should not have converged yet");

        vm.warp(14 hours);
        oracle.verifyReportIfNecessary(400, uint32(vm.getBlockTimestamp()));
        assertEq(oracle.lastDecodedPrice(), 400, "repeated volatile reports should converge twap");
        assertEq(oracle.getPrice(), 400, "new accepted regime should be exposed");
    }

    //support functions
    //returns if value is inside confidence interval of target
    function inConfidenceInterval(uint256 value, uint256 target, uint256 tolerance) public pure returns (bool) {
        uint256 diff = UtilMath.diffAbs(value, target);
        return diff <= value / tolerance;
    }
}
