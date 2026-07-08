// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
contract TWAPOracleMiddleware {
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

    address private s_owner; // The owner of the contract.
    bytes32 public immutable feedId; // Identifier of the crypto asset price feed, as given by CL on https://docs.chain.link/data-streams/crypto-streams.
    string public description; // Description of the crypto asset price feed offered by this smart contract.
    uint256 public maxTimeDelta; // Maximum acceptable time difference that allows to guarantee data freshness.
    int192 public immutable oracleDecimalsStepdownFactor = 10 ** 10; //used in the division to bring down the price precision from 10^18 to 10^8 decimal positions

    // Data stored locally about the last verified price datapoint
    uint32 public lastDecodedValidFromTimestamp; // Stores the last decoded earliest timestamp for which price is applicable.
    int192 public lastDecodedPrice; // Stores the last decoded price from a verified report.

    // TWAP calculation parameters
    mapping(uint256 => uint192) public lastPrices; // Mapping of incremental index => price datapoints, saved locally after Chainlink Report verification.
    mapping(uint256 => uint32) public lastTimestamps; // Mapping of incremental index => timestamps at which the previous price datapoints are generated.
    uint256 public updateIndex = 1; // Index of the first free mapping position, after the last saved price datapoint and its timestamp. The zero index position is considered invalid.
    uint32 public lookbackPeriod = 3600; // Maximum timeframe considered by the TWAP calculation in seconds (price datapoint older than current timestamp - loockbackPeriod will not be used).
    uint32 public TWAPTolerance = 2; // Maximum acceptable tolerance value for the TWAP calculated for the last lookBackPeriod seconds; ex: 2% = 50, 4% = 25, 10% = 10, 20% = 5, 25% = 4, 50% = 2, 100% = 1.

    uint32 public constant minReadings = 5; // Minimum number of prices that need to be verified and saved locally before the TWAP check turns on.

    address public feeTokenAddress; // Must be set to LINK token address for paying fees; TODO: check if necessary to pass to verifyReport before mainnetDeploy

    event DecodedPrice(int192 price); // Event emitted when a report is successfully verified and decoded.
    event DebugEvent(uint256 twap); // for testing / debugging puroposes only

    /**
     * @param _maxTimeDelta Maximum acceptable time difference that allows to guarantee data freshness (expressed in seconds).
     * @param _description Description of the crypto asset price feed offered by this smart contract.
     * You can find the addresses on https://docs.chain.link/data-streams/crypto-streams.
     */
    constructor(uint256 _maxTimeDelta, string memory _description, int192 _oracleDecimalsStepdownFactor) {
        s_owner = msg.sender;
        maxTimeDelta = _maxTimeDelta;
        description = _description;
        oracleDecimalsStepdownFactor = _oracleDecimalsStepdownFactor;
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
    function getPrice() external returns (int192 price) {
        require(
            ((lastDecodedPrice != 0) && (lastDecodedValidFromTimestamp >= block.timestamp - maxTimeDelta)
                    && (lastDecodedValidFromTimestamp <= block.timestamp + maxTimeDelta)),
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
        returns (bool acceptable)
    {
        uint256 twap = _computeTWAP(priceValidFromTimestamp);
        if (twap == 0) {
            return true;
        }

        emit DebugEvent(twap);
        return inConfidenceInterval(uint256(int256(priceToCheck)), twap, TWAPTolerance);
    }

    function getTWAP() public view returns (uint256) {
        return _computeTWAP(block.timestamp);
    }

    function _computeTWAP(uint256 priceValidFromTimestamp) internal view returns (uint256) {
        if (updateIndex == 1) {
            return 0;
        }

        uint256 windowStart = priceValidFromTimestamp > lookbackPeriod ? priceValidFromTimestamp - lookbackPeriod : 0;
        uint256 weightedPriceSum = 0;
        uint256 totalTime = 0;
        uint256 i = updateIndex - 1;
        uint256 intervalEnd = priceValidFromTimestamp;

        while (i > 0 && lastTimestamps[i] >= priceValidFromTimestamp) {
            unchecked {
                --i;
            }
        }

        while (i > 0) {
            uint256 price = lastPrices[i];
            uint256 timestamp = lastTimestamps[i];

            if (timestamp < windowStart) {
                uint256 overlap = intervalEnd - windowStart;
                weightedPriceSum += price * overlap;
                totalTime += overlap;
                break;
            }

            if (intervalEnd > timestamp) {
                uint256 timeDelta = intervalEnd - timestamp;
                weightedPriceSum += price * timeDelta;
                totalTime += timeDelta;
            }

            intervalEnd = timestamp;
            unchecked {
                --i;
            }
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
     */
    function verifyReportIfNecessary(int192 price, uint32 validFromTimestamp) external {
        if (validFromTimestamp > _lastStoredTimestamp()) {
            verifyReport(price, validFromTimestamp);
        }
    }

    function _lastStoredTimestamp() internal view returns (uint32) {
        return updateIndex == 1 ? 0 : lastTimestamps[updateIndex - 1];
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
     * @custom:reverts InvalidReportVersion(uint8 version) Thrown when an unsupported report version is provided.
     */
    function verifyReport(int192 price, uint32 validFromTimestamp) private {
        // Thrown when the latest price report contains unacceptable parameters.
        require(
            (validFromTimestamp >= block.timestamp - maxTimeDelta) && (validFromTimestamp > _lastStoredTimestamp())
                && (price >= oracleDecimalsStepdownFactor),
            "Error on verifyReport: UnacceptablePriceParameters"
        );

        bool acceptedPrice = _checkLastPriceVolatility(price, validFromTimestamp);

        lastPrices[updateIndex] = uint192(price);
        lastTimestamps[updateIndex] = validFromTimestamp;
        updateIndex++;

        if (acceptedPrice) {
            // Store locally the data from the last accepted report returned by getPrice().
            lastDecodedValidFromTimestamp = validFromTimestamp;
            lastDecodedPrice = price;
        }
    }

    function _checkLastPriceVolatility(
        int192 priceToCheck,
        uint192 priceValidFromTimestamp
    )
        private
        view
        returns (bool)
    {
        uint256 twap = _computeTWAP(priceValidFromTimestamp);
        if (twap == 0) {
            return true;
        }
        return inConfidenceInterval(uint256(int256(priceToCheck)), twap, TWAPTolerance);
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
}
