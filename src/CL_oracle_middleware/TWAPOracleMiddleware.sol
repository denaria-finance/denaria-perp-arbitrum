// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IVerifierProxy.sol";
import "./interfaces/IFeeManager.sol";
import "./interfaces/IOracleMiddleware.sol";

using SafeERC20 for IERC20;

/**
 *     In the contract several error codes are present, here is a table of these errors' descriptions.
 *     | Error Code | Description                                                              |
 *     |------------|--------------------------------------------------------------------------|
 *     | OM1        | Error on onlyOwner: msg.sender is not the owner"                         |
 *     | OM2        | Error on getPrice: reverted because of unacceptable price parameters     |
 *     | OM3        | Last verified price does not follow time weighted avg price threshold!   |
 *     | OM4        | InvalidReportVersion                                                     |
 *     | OM5        | Error on verifyReport: IncorrectFeedId                                   |
 *     | OM6        | Error on verifyReport: UnacceptablePriceParameters                       |
 *     | OM7        | Error on withdrawToken: NothingToWithdraw                                |
 */

/**
 * @title A price oracle middleware based on Chainlink Data Streams verification services, integrating a time weighted average price check.
 * @notice This contract implements a middleware between Chainlink Data Streams and other services requiring a verified on-chain price for a crypto asset.
 * @dev Chainlink Reports V3 (gathered trough Streams Direct API or WebSocket connection) are submitted to the IVerifierProxy for verification and saved locally to this smart contract.
 * When the getPrice function is called, the middlware returns the last verified price if it is sufficiently fresh and it is in line with the time weighted average price of the last period.
 */
contract TWAPOracleMiddleware is IOracleMiddleware {
    /**
     * @dev Represents a data report from a Data Streams stream for v3 schema (crypto streams).
     * The `price`, `bid`, and `ask` values are carried to either 8 or 18 decimal places, depending on the stream.
     * For more information, see https://docs.chain.link/data-streams/crypto-streams and https://docs.chain.link/data-streams/reference/report-schema
     */
    struct ReportV3 {
        bytes32 feedId; // The stream ID the report has data for.
        uint32 validFromTimestamp; // Earliest timestamp for which price is applicable.
        uint32 observationsTimestamp; // Latest timestamp for which price is applicable.
        uint192 nativeFee; // Base cost to validate a transaction using the report, denominated in the chain’s native token (e.g., WETH/ETH).
        uint192 linkFee; // Base cost to validate a transaction using the report, denominated in LINK.
        uint32 expiresAt; // Latest timestamp where the report can be verified onchain.
        int192 price; // DON consensus median price (8 or 18 decimals).
        int192 bid; // Simulated price impact of a buy order up to the X% depth of liquidity utilisation (8 or 18 decimals).
        int192 ask; // Simulated price impact of a sell order up to the X% depth of liquidity utilisation (8 or 18 decimals).
    }

    IVerifierProxy public immutable s_verifierProxy; // The VerifierProxy contract used for report verification.

    address private s_owner; // The owner of the contract.
    bytes32 public immutable feedId; // Identifier of the crypto asset price feed, as given by CL on https://docs.chain.link/data-streams/crypto-streams.
    string public description; // Description of the crypto asset price feed offered by this smart contract.
    uint256 public maxTimeDelta; // Maximum acceptable time difference that allows to guarantee data freshness.
    int192 public immutable oracleDecimalsStepdownFactor = 10 ** 10; //used in the division to bring down the price precision from 10^18 to 10^8 decimal positions

    // Data stored locally about the last verified price datapoint
    uint32 public lastDecodedValidFromTimestamp; // Stores the last decoded earliest timestamp for which price is applicable.
    int192 public lastDecodedPrice; // Stores the last decoded price from a verified report.
    uint32 public lastDecodedExpiresAt; // Stores the last decoded expiration timestamp of a verified report.

    // TWAP calculation parameters
    mapping(uint256 => uint192) public lastPrices; // Mapping of incremental index => price datapoints, saved locally after Chainlink Report verification.
    mapping(uint256 => uint32) public lastTimestamps; // Mapping of incremental index => timestamps at which the previous price datapoints are generated.
    uint256 public updateIndex = 1; // Index of the first free mapping position, after the last saved price datapoint and its timestamp. The zero index position is considered invalid.
    uint32 public lookbackPeriod = 3600; // Maximum timeframe considered by the TWAP calculation in seconds (price datapoint older than current timestamp - loockbackPeriod will not be used).
    uint32 public TWAPTolerance = 2; // Maximum acceptable tolerance value for the TWAP calculated for the last lookBackPeriod seconds; ex: 2% = 50, 4% = 25, 10% = 10, 20% = 5, 25% = 4, 50% = 2, 100% = 1.

    address public feeTokenAddress; // LINK token address used to pay report-verification fees

    event DecodedPrice(int192 price); // Event emitted when a report is successfully verified and decoded.

    /**
     * @param _verifierProxy The address of the VerifierProxy contract.
     * @param _feedId Identifier of the crypto asset price feed.
     * @param _maxTimeDelta Maximum acceptable time difference that allows to guarantee data freshness (expressed in seconds).
     * @param _description Description of the crypto asset price feed offered by this smart contract.
     * You can find the addresses on https://docs.chain.link/data-streams/crypto-streams.
     */
    constructor(
        address _verifierProxy,
        bytes32 _feedId,
        uint256 _maxTimeDelta,
        string memory _description,
        int192 _oracleDecimalsStepdownFactor
    ) {
        s_owner = msg.sender;
        s_verifierProxy = IVerifierProxy(_verifierProxy);
        feedId = _feedId;
        maxTimeDelta = _maxTimeDelta;
        description = _description;
        oracleDecimalsStepdownFactor = _oracleDecimalsStepdownFactor;

        // Testnet-only block: per-report verification fees apply on testnets. Remove for
        // a mainnet deploy, where Chainlink Data Streams billing is subscription-based.

        // Retrieve fee manager and reward manager
        IFeeManager feeManager = IFeeManager(address(s_verifierProxy.s_feeManager()));

        address rewardManager = feeManager.i_rewardManager();

        // Set the fee token address (LINK in this case)
        feeTokenAddress = feeManager.i_linkAddress();

        // Approve rewardManager to spend this contract's balance in fees
        IERC20(feeTokenAddress).approve(rewardManager, type(uint256).max);
    }

    /**
     * @notice Updates the main middleware oracle parameters.
     * @param _maxTimeDelta Maximum acceptable time difference that allows to guarantee data freshness (expressed in seconds).
     * @param _description Description of the crypto asset price feed offered by this smart contract.
     * You can find the addresses on https://docs.chain.link/data-streams/crypto-streams.
     */
    function setParameters(
        uint256 _maxTimeDelta,
        uint256 _updateIndex,
        uint32 _lookbackPeriod,
        uint32 _TWAPTolerance,
        string memory _description
    )
        external
        onlyOwner
    {
        maxTimeDelta = _maxTimeDelta;
        updateIndex = _updateIndex;
        lookbackPeriod = _lookbackPeriod;
        TWAPTolerance = _TWAPTolerance;
        description = _description;
    }

    /**
     * @notice Updates the TWAP Oracle Middleware owner.
     * @param _newOwner address of the new owner.
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        s_owner = _newOwner;
    }

    /// @notice Checks if the caller is the owner of the contract.
    modifier onlyOwner() {
        // Thrown when a caller tries to execute a function that is restricted to the contract's owner.
        require(msg.sender == s_owner, "OM1");
        _;
    }

    /**
     * @notice returns the latest stored price if it follows the following criterias:
     *  - the price cannot be zero;
     *     - the price must have been generated in the last maxTimeDelta seconds;
     *     - the price must be compatible (considering a tolerance of TWAPTolerance) with the time weighted average value of all the prices of the report verified in the last lookbackPeriod seconds.
     *     The output price is casted to the desired decimal position precision by dividing for a stepdown factor.
     */
    function getPrice() external view returns (int192 price) {
        require(
            ((lastDecodedPrice != 0) && (lastDecodedValidFromTimestamp >= block.timestamp - maxTimeDelta)
                    && (lastDecodedValidFromTimestamp <= block.timestamp + maxTimeDelta) //+maxTimeDelta) && needed to fix chainlink responses as it seems they arrive with a ValidFromTimestamp slightly in the future.
                    && (lastDecodedExpiresAt > block.timestamp)),
            "OM2"
        );

        require(checkLastPriceVolatility(lastDecodedPrice, lastDecodedValidFromTimestamp), "OM3");

        return lastDecodedPrice / oracleDecimalsStepdownFactor;
    }

    /**
     * @notice returns a boolean representing wether the priceToCheck is acceptable according to time weighted average price threshold.
     * @param priceToCheck price value whose volatility needs to be checked against the previous trend of the prices stored locally.
     * @param priceValidFromTimestamp timestamp at which priceToCheck has been generated.
     */
    function checkLastPriceVolatility(
        int192 priceToCheck,
        uint192 priceValidFromTimestamp
    )
        public
        view
        returns (bool acceptable)
    {
        uint192 twap;
        uint256 i;

        if (updateIndex == 1) {
            return true;
        }

        uint256 startIndex = 1;
        uint256 endIndex = 1;
        uint32 usablePrices;

        // The following for cycle is used to determine how many verified prices have been saved in the period from priceValidFromTimestamp-loockbackPeriod to priceValidFromTimestamp,
        // in order to know if there are sufficient data point to base the TWAP calculation on.
        // Pay attention to the fact that the for loops back chronologically, so first we find endIndex, then startIndex, with startIndex <= endIndex (therefore lastTimestamp[startIndex]<=lastTimestamp[endIndex]).
        for (i = updateIndex - 1; i > 0; --i) {
            if (lastTimestamps[i] < priceValidFromTimestamp) {
                // The following if check is the exit condition from the for cycle, that happens if the currently considered lastTimestamp[i] is outside of the loockbackPeriod for the first time.
                if (lastTimestamps[i] < priceValidFromTimestamp - lookbackPeriod) {
                    // This could revert if priceValidFromTimestamp < lookbackPeriod, but it would mean that a timestamp in the early 1970s has been passed as an input.
                    // This is not a timestamp that can be passed by the rest of the perp system, so it is a non-issue.
                    startIndex = i + 1; // if we know we're exiting from the for cycle, the correct startIndex is the one analyzed in the previous iteration (i+1)
                    break;
                }

                if (endIndex == 1) {
                    // looking back chronologically, we set the endIndex if it has not been set yet.
                    endIndex = i;
                }

                usablePrices++; // for each cycle iteration where the lastTimestamps[i] is still in the lookback period, we increment the counter for the found usable prices datapoints.
            }
        }

        if (usablePrices == 0) {
            // if we do not have any usable prices in the lookbackPeriod before the input priceValidFromTimestamp, we cannot verify the TWAP and return true.
            return true;
        } else {
            // if we have at least one usable price in the lookbackPeriod before the input priceValidFromTimestamp, we can proceed with the TWAP calculation.

            for (
                i = startIndex; // this for loop cycles from the already found startIndex to endIndex (lastPrices[endIndex not yet considered]).
                i < endIndex;
                ++i
            ) {
                twap += lastPrices[i] * (lastTimestamps[i + 1] - lastTimestamps[i]);
            }

            twap += lastPrices[endIndex] * (priceValidFromTimestamp - lastTimestamps[endIndex]); // the last contribution from lastTimestamps[endIndex] to priceValidFromTimestamp is added to the twap.

            twap = twap / (priceValidFromTimestamp - lastTimestamps[startIndex]); // the twap is divided by the total time period between lastTimestamps[startIndex] and priceValidFromTimestamp.

            return inConfidenceInterval(uint256(int256(priceToCheck)), uint256(twap), TWAPTolerance); // the input priceToCheck is evaluated against the calculated twap.
        }
    }

    function getTWAP() public view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 windowStart = currentTime - lookbackPeriod;

        uint256 weightedPriceSum = 0;
        uint256 totalTime = 0;

        uint256 i = updateIndex - 1;

        while (i > 0) {
            uint256 price = lastPrices[i];
            uint256 timestamp;
            if (i == updateIndex - 1) {
                timestamp = currentTime;
            } else {
                timestamp = lastTimestamps[i + 1];
            }
            uint256 prevTimestamp = lastTimestamps[i];

            // use < not <= so we include the full interval when equal
            if (prevTimestamp < windowStart) {
                uint256 overlap = timestamp - windowStart;
                weightedPriceSum += price * overlap;
                totalTime += overlap;
                break;
            }

            uint256 timeDelta = timestamp - prevTimestamp;
            weightedPriceSum += price * timeDelta;
            totalTime += timeDelta;

            i--;
        }

        if (totalTime == 0) return 0;
        return weightedPriceSum / totalTime;
    }

    /// @notice returns if value is inside confidence interval of target when considering tolerance
    function inConfidenceInterval(uint256 value, uint256 target, uint256 tolerance) public pure returns (bool) {
        uint256 diff = diffAbs(value, target);
        return diff <= target / tolerance;
    }

    /// @notice returns the absolute value of the difference between x and y
    function diffAbs(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = x >= y ? x - y : y - x;
    }

    /**
     * @notice Verifies an unverified data report if at least maxTimeDelta seconds have passed since the last verified price.
     * @dev The length guard MUST short-circuit before peekValidFromV3: peeking abi-decodes
     * the report, and decoding empty bytes reverts with EMPTY revert data, which would
     * bubble undecodable through every report-consuming caller (engine trade/close,
     * Vault.removeCollateral, manager) for the legitimate "no report supplied" case.
     */
    function verifyReportIfNecessary(bytes memory unverifiedReport) external {
        if (unverifiedReport.length != 0 && peekValidFromV3(unverifiedReport) > lastDecodedValidFromTimestamp) {
            verifyReport(unverifiedReport);
        }
    }

    /**
     * @notice Verifies an unverified data report and processes its contents, supporting v3 report schemas.
     * @dev Performs the following steps:
     * - Decodes the unverified report to extract the report data.
     * - Extracts the report version by reading the first two bytes of the report data.
     *   - The first two bytes correspond to the schema version encoded in the stream ID.
     *   - Schema version `0x0003` corresponds to report version 3 (for Crypto assets).
     * - Validates that the report version is 3; reverts with `InvalidReportVersion` otherwise.
     * - Retrieves the fee manager and reward manager contracts.
     * - Calculates the fee required for report verification using the fee manager.
     * - Approves the reward manager to spend the calculated fee amount.
     * - Verifies the report via the VerifierProxy contract.
     * - Decodes the verified report data into the appropriate report struct (`ReportV3` or `ReportV4`) based on the report version.
     * - Emits a `DecodedPrice` event with the price extracted from the verified report.
     * - Updates the `lastDecodedPrice` state variable with the price from the verified report.
     * @param unverifiedReport The encoded report data to be verified, including the signed report and metadata.
     * @custom:reverts InvalidReportVersion(uint8 version) Thrown when an unsupported report version is provided.
     */
    function verifyReport(bytes memory unverifiedReport) private {
        // Decode unverified report to extract report data
        (, bytes memory reportData) = abi.decode(unverifiedReport, (bytes32[3], bytes));

        // Extract report version from reportData
        uint16 reportVersion = (uint16(uint8(reportData[0])) << 8) | uint16(uint8(reportData[1]));

        // Thrown when an unsupported report version is provided to verifyReport.
        require(reportVersion == 3, "OM4");

        // Verify the report through the VerifierProxy
        bytes memory verifiedReportData = s_verifierProxy.verify(unverifiedReport, abi.encode(feeTokenAddress));

        // Decode verified report data into the appropriate Report struct based on reportVersion 3
        // v3 report schema
        ReportV3 memory verifiedReport = abi.decode(verifiedReportData, (ReportV3));

        // Verify that the feedId is the one of the crypto asset saved locally
        // Thrown when a different crypto asset report v3 is provided to verifyReport.
        require(verifiedReport.feedId == feedId, "OM5");

        // Thrown when the latest price report contains unacceptable parameters.
        require(
            (verifiedReport.validFromTimestamp >= block.timestamp - maxTimeDelta)
                && (verifiedReport.validFromTimestamp <= block.timestamp + maxTimeDelta)
                && (verifiedReport.validFromTimestamp > lastDecodedValidFromTimestamp)
                && (verifiedReport.price >= oracleDecimalsStepdownFactor),
            "OM6"
        );

        // Log price from the verified report
        emit DecodedPrice(verifiedReport.price);

        // Store locally the data from the last report
        lastDecodedValidFromTimestamp = verifiedReport.validFromTimestamp;
        lastDecodedPrice = verifiedReport.price;
        lastDecodedExpiresAt = verifiedReport.expiresAt;

        lastPrices[updateIndex] = uint192(verifiedReport.price);
        lastTimestamps[updateIndex] = verifiedReport.validFromTimestamp;
        updateIndex++;
    }

    /**
     * @notice Withdraws all tokens of a specific ERC20 token type to a beneficiary address.
     * @dev Utilizes SafeERC20's safeTransfer for secure token transfer. Reverts if the contract's balance of the specified token is zero.
     * @param _beneficiary Address to which the tokens will be sent. Must not be the zero address.
     * @param _token Address of the ERC20 token to be withdrawn. Must be a valid ERC20 token contract.
     */
    function withdrawToken(address _beneficiary, address _token) public onlyOwner {
        // Retrieve the balance of this contract for the specified token
        uint256 amount = IERC20(_token).balanceOf(address(this));

        // Thrown when a withdrawal attempt is made but the contract holds no tokens of the specified type.
        require(amount != 0, "OM7");

        // Transfer the tokens to the beneficiary
        IERC20(_token).safeTransfer(_beneficiary, amount);
    }

    function peekValidFromV3(bytes memory unverifiedReport) internal pure returns (uint32 validFrom) {
        (, bytes memory reportData) = abi.decode(unverifiedReport, (bytes32[3], bytes));

        // schema version is the first 2 bytes of reportData (inside the feedId)
        uint16 schema = (uint16(uint8(reportData[0])) << 8) | uint16(uint8(reportData[1]));
        require(schema == 3, "not v3");

        // validFrom is the next 32-byte word after the 32-byte feedId => offset 32 in reportData
        require(reportData.length >= 64, "reportData too short");

        assembly {
            // reportData points to bytes header; data starts at reportData + 0x20
            // word at offset 32 in data => (reportData + 0x20 + 0x20) = reportData + 0x40
            validFrom := and(mload(add(reportData, 0x40)), 0xffffffff)
        }
    }
}
