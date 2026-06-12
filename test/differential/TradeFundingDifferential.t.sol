// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Trade + funding stateful differential generator (review finding F-04, scenario 1)
/// @notice Drives the REAL Solidity `PerpPair` engine through a multi-trade sequence with
///         time advancing between ops (so funding accrues), capturing a full state snapshot
///         after each op into a JSON fixture. The Rust/Stylus `PerpEngine` replays the same
///         sequence under `stub_boundary` and asserts each snapshot bit-exact
///         (`perp-engine` test `trade_funding_differential`). The environment mirrors the
///         Stylus stub_boundary exactly: oracle price 3000e8, vault collateral 1000e18.
contract MockOracleD {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000; // 3000 * 1e8
    }
}

contract MockVaultD {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
}

/// Harness: the real `PerpPair` with the benchmark config (matches the Stylus
/// `initializeBenchmark` constants) + reserve seeding + getters for the internal
/// state the differential compares.
contract PerpEngineRef is PerpPair {
    constructor(
        address _oracle,
        address _vault,
        address _feeProtocol
    )
        PerpPair(
            _oracle,
            _vault,
            address(1), // trustedForwarder (unused: traders call directly)
            (40 * 1e6) / 1000, // MMR
            bytes32("BENCH"),
            uint32(300_000),
            uint32(500_000),
            _feeProtocol,
            0, // tradingFee
            12e16, // flatTradingFee
            9e7 // emaParam
        )
    { }

    function seedReserves(uint256 s, uint256 a) external {
        globalLiquidityStable = s;
        globalLiquidityAsset = a;
    }

    function getG() external view returns (int256, int256) {
        return (matrixRowG[0], matrixRowG[1]);
    }

    function getInsurance() external view returns (uint256, bool) {
        return (insuranceFund, insuranceFundSign);
    }
}

contract TradeFundingDifferentialTest is Test {
    string internal constant FIXTURE_PATH = "/test/fixtures/trade_funding_differential.json";

    PerpEngineRef ref;

    // Op script (kept identical on the Rust side, which reads it back from the fixture).
    struct Op {
        address user;
        bool direction; // true=long
        uint256 size;
        uint8 leverage;
        uint256 blockTs;
    }

    function buildOps() internal pure returns (Op[] memory ops) {
        address a = address(0xA11CE);
        address b = address(0xB0B);
        ops = new Op[](5);
        // open A long; open B long (funding now accrues from A's exposure over time);
        // A second trade (nonzero funding fee on A); B short reduces exposure; A short.
        ops[0] = Op(a, true, 1000e18, 1, 1000);
        ops[1] = Op(b, true, 1000e18, 1, 4600); // +3600s
        ops[2] = Op(a, true, 200e18, 1, 8200); // +3600s, A trades again
        ops[3] = Op(b, false, 0.05e18, 1, 11_800); // +3600s, B short
        ops[4] = Op(a, false, 0.05e18, 1, 15_400); // +3600s, A short
    }

    function test_generate() external {
        MockOracleD oracle = new MockOracleD();
        MockVaultD vault = new MockVaultD();
        ref = new PerpEngineRef(address(oracle), address(vault), address(this));
        ref.seedReserves(18_000_000e18, 6000e18);

        Op[] memory ops = buildOps();
        string memory init = string.concat(
            '{"stable":"', vm.toString(uint256(18_000_000e18)), '","asset":"', vm.toString(uint256(6000e18)), '"}'
        );

        string memory opsJson = "";
        for (uint256 i = 0; i < ops.length; i++) {
            Op memory o = ops[i];
            vm.warp(o.blockTs);
            vm.prank(o.user);
            uint256 ret;
            bool reverted;
            try ref.trade(o.direction, o.size, 0, 0, address(0), o.leverage, "") returns (uint256 r) {
                ret = r;
            } catch {
                reverted = true;
            }
            require(!reverted, "differential op reverted; adjust the sequence to all-success");
            string memory entry = opEntry(o, ret);
            opsJson = i == 0 ? entry : string.concat(opsJson, ",", entry);
        }

        string memory fixture = string.concat('{"init":', init, ',"ops":[', opsJson, "]}");
        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), fixture);
    }

    function opEntry(Op memory o, uint256 ret) internal view returns (string memory) {
        (int256 g0, int256 g1) = ref.getG();
        (uint256 ins, bool insSign) = ref.getInsurance();
        (
            uint256 balS,
            uint256 balA,
            uint256 debtS,
            uint256 debtA,
            uint256 fee,
            bool feeSign,
            uint256 initFR,
            bool initFRSign
        ) = ref.userVirtualTraderPosition(o.user);

        // op header
        string memory head = string.concat(
            '{"user":"',
            vm.toString(o.user),
            '","direction":',
            o.direction ? "true" : "false",
            ',"size":"',
            vm.toString(o.size),
            '","leverage":',
            vm.toString(uint256(o.leverage)),
            ',"blockTs":"',
            vm.toString(o.blockTs),
            '","ret":"',
            vm.toString(ret),
            '"'
        );
        // global state
        string memory glob = string.concat(
            ',"gStable":"',
            vm.toString(ref.globalLiquidityStable()),
            '","gAsset":"',
            vm.toString(ref.globalLiquidityAsset()),
            '","fundingRate":"',
            vm.toString(ref.fundingRate()),
            '","fundingRateSign":',
            ref.fundingRateSign() ? "true" : "false",
            ',"exposure":"',
            vm.toString(ref.totalTraderExposure()),
            '","exposureSign":',
            ref.totalTraderExposureSign() ? "true" : "false",
            ',"lastOpTs":"',
            vm.toString(ref.lastOperationTimestamp()),
            '","g0":"',
            vm.toString(g0),
            '","g1":"',
            vm.toString(g1),
            '","insurance":"',
            vm.toString(ins),
            '","insuranceSign":',
            insSign ? "true" : "false"
        );
        // acting user's position
        string memory usr = string.concat(
            ',"uBalStable":"',
            vm.toString(balS),
            '","uBalAsset":"',
            vm.toString(balA),
            '","uDebtStable":"',
            vm.toString(debtS),
            '","uDebtAsset":"',
            vm.toString(debtA),
            '","uFee":"',
            vm.toString(fee),
            '","uFeeSign":',
            feeSign ? "true" : "false",
            ',"uInitFR":"',
            vm.toString(initFR),
            '","uInitFRSign":',
            initFRSign ? "true" : "false",
            "}"
        );
        return string.concat(head, glob, usr);
    }
}
