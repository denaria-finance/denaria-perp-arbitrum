// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/PerpPair.sol";

/// @title Liquidity stateful differential generator
/// @notice Drives the REAL Solidity `PerpPair` through an add/remove-liquidity sequence
///         (empty-pool bootstrap → general add → partial remove → full remove) and snapshots
///         the full liquidity state after each op into a JSON fixture. The Rust/Stylus
///         `PerpEngine` replays it under `stub_boundary` (perp-engine test
///         `liquidity_differential`) and asserts bit-exact. Fee-free (the default config's
///         liquidityMaxFee=0 waives fees); the fee math itself is separately golden-locked
///         Env mirrors the Stylus stub: oracle 3000e8, vault collateral 1000e18.
contract MockOracleL {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000;
    }
}

contract MockVaultL {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
}

contract PerpLiquidityRef is PerpPair {
    constructor(
        address o,
        address v,
        address f
    )
        PerpPair(
            o, v, address(1), (40 * 1e6) / 1000, bytes32("BENCH"), uint32(300_000), uint32(500_000), f, 0, 12e16, 9e7
        )
    { }

    function getM() external view returns (int256, int256, int256, int256) {
        return (liquidityM[0][0], liquidityM[0][1], liquidityM[1][0], liquidityM[1][1]);
    }

    function getG() external view returns (int256, int256) {
        return (matrixRowG[0], matrixRowG[1]);
    }

    function getInsurance() external view returns (uint256, bool) {
        return (insuranceFund, insuranceFundSign);
    }

    function getLPInv(address u) external view returns (int256, int256, int256, int256) {
        LiquidityPosition storage p = liquidityPosition[u];
        return (p.inverseSnapshotM[0][0], p.inverseSnapshotM[0][1], p.inverseSnapshotM[1][0], p.inverseSnapshotM[1][1]);
    }

    function getLPSnapG(address u) external view returns (int256, int256) {
        LiquidityPosition storage p = liquidityPosition[u];
        return (p.snapshotG[0], p.snapshotG[1]);
    }
}

contract LiquidityDifferentialTest is Test {
    string internal constant FIXTURE_PATH = "/test/fixtures/liquidity_differential.json";

    PerpLiquidityRef ref;
    address internal lp1 = address(0x1111);
    address internal lp2 = address(0x2222);

    function test_generate() external {
        ref = new PerpLiquidityRef(address(new MockOracleL()), address(new MockVaultL()), address(this));

        string memory ops = "";
        // op0: empty-pool bootstrap (deposit value 3000+1*3000 = 6000e18 < 15*1000e18 LP-leverage cap)
        ops = doAdd(lp1, 3000e18, 1e18, 1000);
        // op1: general add (M updated via matmul)
        ops = string.concat(ops, ",", doAdd(lp2, 1500e18, 0.5e18, 4600));
        // op2: lp1 removes half of its current balance
        (uint256 s1, uint256 a1) = ref.getLpLiquidityBalance(lp1);
        ops = string.concat(ops, ",", doRemove(lp1, s1 / 2, a1 / 2, 8200));
        // op3: lp2 removes its full balance
        (uint256 s2, uint256 a2) = ref.getLpLiquidityBalance(lp2);
        ops = string.concat(ops, ",", doRemove(lp2, s2, a2, 11_800));

        vm.writeFile(string.concat(vm.projectRoot(), FIXTURE_PATH), string.concat('{"ops":[', ops, "]}"));
    }

    function doAdd(address u, uint256 s, uint256 a, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        vm.prank(u);
        ref.addLiquidity(s, a, 0, "");
        return entry("add", u, s, a, ts);
    }

    function doRemove(address u, uint256 s, uint256 a, uint256 ts) internal returns (string memory) {
        vm.warp(ts);
        vm.prank(u);
        ref.removeLiquidity(s, a, 0, "");
        return entry("remove", u, s, a, ts);
    }

    function entry(
        string memory kind,
        address u,
        uint256 s,
        uint256 a,
        uint256 ts
    )
        internal
        view
        returns (string memory)
    {
        (int256 m00, int256 m01, int256 m10, int256 m11) = ref.getM();
        (int256 g0, int256 g1) = ref.getG();
        (uint256 ins, bool insSign) = ref.getInsurance();
        string memory head = string.concat(
            '{"kind":"',
            kind,
            '","user":"',
            vm.toString(u),
            '","stable":"',
            vm.toString(s),
            '","asset":"',
            vm.toString(a),
            '","blockTs":"',
            vm.toString(ts),
            '"'
        );
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
            ',"insurance":"',
            vm.toString(ins),
            '","insuranceSign":',
            insSign ? "true" : "false",
            ',"m00":"',
            vm.toString(m00),
            '","m01":"',
            vm.toString(m01),
            '","m10":"',
            vm.toString(m10),
            '","m11":"',
            vm.toString(m11),
            '","g0":"',
            vm.toString(g0),
            '","g1":"',
            vm.toString(g1),
            '"'
        );
        return string.concat(head, glob, lpJson(u), "}");
    }

    function lpJson(address u) internal view returns (string memory) {
        (uint256 initS, uint256 initA, uint256 lpDebtS, uint256 lpDebtA) = ref.liquidityPosition(u);
        (int256 im00, int256 im01, int256 im10, int256 im11) = ref.getLPInv(u);
        (int256 sg0, int256 sg1) = ref.getLPSnapG(u);
        (uint256 vBalS, uint256 vBalA, uint256 vDebtS, uint256 vDebtA,,,,) = ref.userVirtualTraderPosition(u);
        string memory lp = string.concat(
            ',"initS":"',
            vm.toString(initS),
            '","initA":"',
            vm.toString(initA),
            '","lpDebtS":"',
            vm.toString(lpDebtS),
            '","lpDebtA":"',
            vm.toString(lpDebtA),
            '","im00":"',
            vm.toString(im00),
            '","im01":"',
            vm.toString(im01),
            '","im10":"',
            vm.toString(im10),
            '","im11":"',
            vm.toString(im11),
            '","sg0":"',
            vm.toString(sg0),
            '","sg1":"',
            vm.toString(sg1),
            '"'
        );
        string memory v = string.concat(
            ',"vBalS":"',
            vm.toString(vBalS),
            '","vBalA":"',
            vm.toString(vBalA),
            '","vDebtS":"',
            vm.toString(vDebtS),
            '","vDebtA":"',
            vm.toString(vDebtA),
            '"'
        );
        return string.concat(lp, v);
    }
}
