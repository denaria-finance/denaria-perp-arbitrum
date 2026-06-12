// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { TWAPOracleMiddleware } from "../src/CL_oracle_middleware/TWAPOracleMiddleware.sol";

/// Regression tests for the REAL Data-Streams middleware's report intake
/// (`verifyReportIfNecessary`), in particular the empty-report path: the original code
/// abi-decoded the report (peekValidFromV3) BEFORE the `length != 0` short-circuit
/// guard, so the legitimate "no report supplied" call shape (`0x`) reverted with EMPTY
/// revert data through every report-consuming caller (engine trade/close, Vault
/// removeCollateral, manager) — indistinguishable from a missing-selector failure.
/// Found during pre-deploy readiness verification and locked here as a regression.
contract MockLinkToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockRewardManager { }

contract MockFeeManager {
    address public i_rewardManager;
    address public i_linkAddress;

    constructor(address rewardManager_, address link_) {
        i_rewardManager = rewardManager_;
        i_linkAddress = link_;
    }
}

contract MockVerifierProxy {
    address public s_feeManager;
    bytes internal verifiedReportData;

    constructor(address feeManager_) {
        s_feeManager = feeManager_;
    }

    function setVerifiedReport(bytes memory data) external {
        verifiedReportData = data;
    }

    function verify(bytes calldata, bytes calldata) external payable returns (bytes memory) {
        return verifiedReportData;
    }
}

contract OracleMiddlewareReportTest is Test {
    // v3 schema = first two bytes of the feedId word inside reportData.
    bytes32 constant FEED_ID = bytes32(uint256(3) << 240);

    TWAPOracleMiddleware public oracle;
    MockVerifierProxy public verifier;

    function setUp() public {
        MockLinkToken link = new MockLinkToken();
        MockRewardManager rewardManager = new MockRewardManager();
        MockFeeManager feeManager = new MockFeeManager(address(rewardManager), address(link));
        verifier = new MockVerifierProxy(address(feeManager));
        oracle = new TWAPOracleMiddleware(address(verifier), FEED_ID, 600, "BTC test oracle", int192(1e10));
        skip(100_000);
    }

    /// @dev THE regression: an empty report must short-circuit to a no-op, not revert.
    ///      Before the operand-order fix this call reverted with empty (0x) data inside
    ///      peekValidFromV3's abi.decode.
    function testEmptyReportIsNoOp() public {
        oracle.verifyReportIfNecessary("");
        assertEq(oracle.updateIndex(), 1, "state must be untouched");
        assertEq(oracle.lastDecodedPrice(), int192(0), "no price must be stored");
    }

    /// @dev The demo/front-end stub convention: a well-formed v3 blob whose validFrom (0)
    ///      is not newer than the stored one is a safe no-op, before and after a real
    ///      report has been verified.
    function testStaleStubReportIsNoOp() public {
        bytes memory stub = _wrapReport(FEED_ID, 0);

        oracle.verifyReportIfNecessary(stub); // lastDecodedValidFromTimestamp == 0: 0 > 0 is false
        assertEq(oracle.updateIndex(), 1, "stub must not verify on fresh deploy");

        _verifyFreshReport(62_613e18, uint32(block.timestamp));
        uint256 idx = oracle.updateIndex();
        oracle.verifyReportIfNecessary(stub); // still strictly older than the stored report
        assertEq(oracle.updateIndex(), idx, "stub must not verify after a real report");
    }

    /// @dev The guard reorder must not break the verify branch: a fresh report still
    ///      routes through the verifier and lands in storage + getPrice().
    function testFreshReportVerifiesAndPriceFlows() public {
        _verifyFreshReport(62_613e18, uint32(block.timestamp));
        assertEq(oracle.updateIndex(), 2, "datapoint must be stored");
        assertEq(oracle.lastDecodedPrice(), int192(62_613e18), "price must be stored");
        assertEq(oracle.getPrice(), int192(62_613e8), "getPrice = price / stepdown(1e10)");
    }

    /// @dev Garbage that is non-empty must keep reverting DECODABLY (Error(string)),
    ///      never with empty data.
    function testNonV3ReportRevertsDecodably() public {
        bytes32 wrongSchema = bytes32(uint256(4) << 240);
        vm.expectRevert(bytes("not v3"));
        oracle.verifyReportIfNecessary(_wrapReport(wrongSchema, block.timestamp));
    }

    function testShortReportDataRevertsDecodably() public {
        bytes32[3] memory ctx;
        bytes memory shortData = abi.encodePacked(FEED_ID); // 32 bytes < required 64
        vm.expectRevert(bytes("reportData too short"));
        oracle.verifyReportIfNecessary(abi.encode(ctx, shortData));
    }

    // -------------------------------------------------------------------------------

    /// @dev Unverified-report blob as peekValidFromV3 expects it:
    ///      abi.encode(reportContext, reportData) with reportData = feedId word (schema
    ///      in the first 2 bytes) followed by the validFrom word.
    function _wrapReport(bytes32 feedIdWord, uint256 validFrom) internal pure returns (bytes memory) {
        bytes32[3] memory ctx;
        bytes memory reportData = abi.encodePacked(feedIdWord, bytes32(validFrom));
        return abi.encode(ctx, reportData);
    }

    function _verifyFreshReport(int192 price, uint32 validFrom) internal {
        TWAPOracleMiddleware.ReportV3 memory r = TWAPOracleMiddleware.ReportV3({
            feedId: FEED_ID,
            validFromTimestamp: validFrom,
            observationsTimestamp: validFrom,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: validFrom + 86_400,
            price: price,
            bid: price,
            ask: price
        });
        verifier.setVerifiedReport(abi.encode(r));
        oracle.verifyReportIfNecessary(_wrapReport(FEED_ID, validFrom));
    }
}
