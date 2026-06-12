// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TestPriceProvider is IOracleMiddleware {
    string private description;
    uint256 private oraclePrice;
    uint32 public lastDecodedObservationsTimestamp;
    uint256 public maxTimeDelta;
    bytes public lastReport;

    //Temporary get price before oracle is set up
    function getPrice() external view returns (int192) {
        return SafeCast.toInt192(SafeCast.toInt256(oraclePrice));
    }

    function verifyReport(bytes memory unverifiedReport) private {
        lastReport = unverifiedReport;
        lastDecodedObservationsTimestamp = SafeCast.toUint32(block.timestamp);
    }

    function verifyReportIfNecessary(bytes memory unverifiedReport) external override {
        verifyReport(unverifiedReport);
    }

    ///Fake implementation to not trigger warnings
    function checkLastPriceVolatility(
        int192 priceToCheck,
        uint192 priceValidFromTimestamp
    )
        external
        view
        override
        returns (bool acceptable)
    {
        priceToCheck = 1;
        priceValidFromTimestamp = 1;
        return oraclePrice >= 0 && priceToCheck >= 0;
    }

    function setPrice(uint256 price) public {
        oraclePrice = price;
    }

    ///Fake implementation to not trigger warnings
    function inConfidenceInterval(
        uint256 value,
        uint256 target,
        uint256 tolerance
    )
        external
        pure
        override
        returns (bool)
    {
        value = target;
        tolerance = value;
        return tolerance >= 0;
    }
}
