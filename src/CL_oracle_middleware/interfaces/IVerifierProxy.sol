// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

interface IVerifierFeeManager { }

// Custom interfaces for IVerifierProxy and IFeeManager
interface IVerifierProxy {
    /**
     * @notice Verifies that the data encoded has been signed correctly by routing to the correct verifier, and bills the user if applicable.
     * @param payload The encoded data to be verified, including the signed report.
     * @param parameterPayload Fee metadata for billing. In the current implementation, this consists of the abi-encoded address of the ERC-20 token used for fees.
     * @return verifierResponse The encoded report from the verifier.
     */
    function verify(
        bytes calldata payload,
        bytes calldata parameterPayload
    )
        external
        payable
        returns (bytes memory verifierResponse);

    /**
     * @notice Verifies multiple reports in bulk, ensuring that each is signed correctly, routes them to the appropriate verifier, and handles billing for the verification process.
     * @param payloads An array of encoded data to be verified, where each entry includes the signed report.
     * @param parameterPayload Fee metadata for billing. In the current implementation, this consists of the abi-encoded address of the ERC-20 token used for fees.
     * @return verifiedReports An array of encoded reports returned from the verifier.
     */
    function verifyBulk(
        bytes[] calldata payloads,
        bytes calldata parameterPayload
    )
        external
        payable
        returns (bytes[] memory verifiedReports);

    /**
     * @notice Returns the price data from the last verified report if the freshness is acceptable.
     * @return price The price of the last verified report.
     */
    function getPrice() external view returns (int192 price);

    function s_feeManager() external view returns (IVerifierFeeManager);
}
