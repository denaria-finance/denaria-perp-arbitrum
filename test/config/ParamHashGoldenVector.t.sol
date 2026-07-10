// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import "../../src/util/UtilMath.sol";

/// @notice Generates golden vectors for the time-locked-parameters keccak hash, a
///         verbatim transcription of `perpConfig.prepareTimeLockedParameters`' formula
///         (lines 79-95). The Stylus engine's `time_locked_param_hash` must reproduce
///         these bit-exactly. Target: perp-engine/src/lib.rs `time_locked_param_hash`.
contract ParamHashGoldenVectorTest is Test {
    using Strings for uint256;

    string internal constant FIXTURE_PATH = "/test/fixtures/param_hash_vectors.json";

    struct Vec {
        uint256 mmr;
        uint256 tradingFee;
        uint256 flatTradingFee;
        uint256 feeLP;
        uint256 liquidityMinFee;
        uint256 liquidityMaxFee;
        uint256 liquidityFeeK;
        uint256 fundingC;
        uint256 paramTimeLock;
        uint256 minimumTradeSize;
    }

    /// Verbatim copy of the perpConfig param-hash formula.
    function paramHash(Vec memory v) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(v.mmr, v.tradingFee, v.flatTradingFee, v.feeLP)),
                v.liquidityMinFee,
                v.liquidityMaxFee,
                v.liquidityFeeK,
                v.fundingC,
                v.paramTimeLock,
                v.minimumTradeSize
            )
        );
    }

    function testWriteParamHashFixture() public {
        // Realistic config + a distinct-values vector (so a wrong field order would diverge).
        Vec memory a = Vec(40_000, 0, 12e16, 500_000, 0, 5e8, 1e10, 1e6, 10, 48e18);
        Vec memory b = Vec(1, 2, 3, 4, 5, 6, 7, 8, 12, 13);

        string memory json = string(
            abi.encodePacked(
                '{\n  "schema": "denaria.param_hash.parity.v1",\n  "vectors": [\n',
                vectorJson("realistic", a),
                ",\n",
                vectorJson("distinct-values", b),
                "\n  ]\n}\n"
            )
        );
        string memory dir = string.concat(vm.projectRoot(), "/test/fixtures");
        string memory path = string.concat(vm.projectRoot(), FIXTURE_PATH);
        vm.createDir(dir, true);
        vm.writeFile(path, json);
        assertEq(vm.readFile(path), json, "fixture write mismatch");
    }

    function vectorJson(string memory label, Vec memory v) internal pure returns (string memory) {
        string memory in1 = string(
            abi.encodePacked(
                '"mmr":"',
                v.mmr.toString(),
                '","tradingFee":"',
                v.tradingFee.toString(),
                '","flatTradingFee":"',
                v.flatTradingFee.toString(),
                '","feeLP":"',
                v.feeLP.toString(),
                '","liquidityMinFee":"',
                v.liquidityMinFee.toString(),
                '","liquidityMaxFee":"',
                v.liquidityMaxFee.toString(),
                '","liquidityFeeK":"',
                v.liquidityFeeK.toString()
            )
        );
        string memory in2 = string(
            abi.encodePacked(
                '","fundingC":"',
                v.fundingC.toString(),
                '","paramTimeLock":"',
                v.paramTimeLock.toString(),
                '","minimumTradeSize":"',
                v.minimumTradeSize.toString(),
                '"'
            )
        );
        return string(
            abi.encodePacked(
                '    {"label":"',
                label,
                '","inputs":{',
                in1,
                in2,
                '},"expected":"',
                Strings.toHexString(uint256(paramHash(v)), 32),
                '"}'
            )
        );
    }
}
