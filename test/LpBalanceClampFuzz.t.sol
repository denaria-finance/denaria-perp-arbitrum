// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { MatrixMath } from "../src/util/MatrixMath.sol";

contract MockOracleC {
    function verifyReportIfNecessary(bytes calldata) external { }

    function getPrice() external pure returns (int256) {
        return 300_000_000_000;
    }
}

contract MockVaultC {
    function userCollateral(address) external pure returns (uint256) {
        return 1000e18;
    }
}

/// @dev PerpPair subclass exposing setters for the LP-balance recovery inputs so the fuzzer
///      can drive the real `getLpLiquidityBalance` clamp over arbitrary (incl. negative) legs.
contract LpClampHarness is PerpPair {
    constructor(
        address o,
        address v,
        address f
    )
        PerpPair(
            o, v, address(1), (40 * 1e6) / 1000, bytes32("CLAMP"), uint32(300_000), uint32(500_000), f, 0, 12e16, 9e7
        )
    { }

    function setM(int256 a, int256 b, int256 c, int256 d_) external {
        liquidityM[0][0] = a;
        liquidityM[0][1] = b;
        liquidityM[1][0] = c;
        liquidityM[1][1] = d_;
    }

    function setGlobals(uint256 gs, uint256 ga) external {
        globalLiquidityStable = gs;
        globalLiquidityAsset = ga;
    }

    function setLp(address u, int256 i00, int256 i01, int256 i10, int256 i11, uint256 s, uint256 a) external {
        LiquidityPosition storage p = liquidityPosition[u];
        p.inverseSnapshotM[0][0] = i00;
        p.inverseSnapshotM[0][1] = i01;
        p.inverseSnapshotM[1][0] = i10;
        p.inverseSnapshotM[1][1] = i11;
        p.initialStableBalance = s;
        p.initialAssetBalance = a;
    }

    /// Pre-clamp signed recovery legs — the reference the production clamp is applied to.
    function rawLegs(address u) external view returns (int256 rawS, int256 rawA) {
        LiquidityPosition storage p = liquidityPosition[u];
        int256[2][2] memory am = MatrixMath.matMulTwoByTwo(liquidityM, p.inverseSnapshotM, decimals.liquidityMDecimals);
        int256 s = int256(p.initialStableBalance);
        int256 a = int256(p.initialAssetBalance);
        int256 d = decimals.liquidityMDecimals;
        rawS = (s * am[0][0] + a * am[0][1]) / d;
        rawA = (s * am[1][0] + a * am[1][1]) / d;
    }
}

contract LpBalanceClampFuzzTest is Test {
    LpClampHarness internal harness;
    address internal constant LP = address(0xABCD);

    function setUp() public {
        MockOracleC o = new MockOracleC();
        MockVaultC v = new MockVaultC();
        harness = new LpClampHarness(address(o), address(v), makeAddr("frontend"));
    }

    function _boundI(int256 x, int256 lim) internal pure returns (int256) {
        return int256(bound(uint256(x), 0, uint256(lim * 2))) - lim;
    }

    /// Fuzz the real `getLpLiquidityBalance`: over arbitrary matrices, snapshots and balances
    /// it must never revert, stay within the pool caps, and equal `clamp(rawLeg, 0, cap)` for
    /// both legs — i.e. a negative recovered leg yields 0 (the negative-balance clamp) instead of
    /// wrapping/reverting. Magnitudes are scaled to `liquidityMDecimals` (1e22) so the double
    /// normalization leaves non-trivial (and frequently negative) legs.
    function testFuzz_getLpLiquidityBalance_clampsAndBounds(
        int256 m00,
        int256 m01,
        int256 m10,
        int256 m11,
        int256 i00,
        int256 i01,
        int256 i10,
        int256 i11,
        uint256 initStable,
        uint256 initAsset,
        uint256 gs,
        uint256 ga
    )
        public
    {
        int256 lim = 1e23;
        m00 = _boundI(m00, lim);
        m01 = _boundI(m01, lim);
        m10 = _boundI(m10, lim);
        m11 = _boundI(m11, lim);
        i00 = _boundI(i00, lim);
        i01 = _boundI(i01, lim);
        i10 = _boundI(i10, lim);
        i11 = _boundI(i11, lim);
        // inverseSnapshotM[0][0] must be non-zero, else getLpLiquidityBalance early-returns (0,0).
        if (i00 == 0) i00 = 1;
        initStable = bound(initStable, 0, 1e24);
        initAsset = bound(initAsset, 0, 1e24);
        gs = bound(gs, 0, type(uint128).max);
        ga = bound(ga, 0, type(uint128).max);

        harness.setM(m00, m01, m10, m11);
        harness.setGlobals(gs, ga);
        harness.setLp(LP, i00, i01, i10, i11, initStable, initAsset);

        (uint256 lpS, uint256 lpA) = harness.getLpLiquidityBalance(LP);

        // Bounded by the pool.
        assertLe(lpS, gs, "stable leg exceeds pool cap");
        assertLe(lpA, ga, "asset leg exceeds pool cap");

        // Equals clamp(raw, 0, cap) on both legs — the negative-leg fix in one assertion.
        (int256 rawS, int256 rawA) = harness.rawLegs(LP);
        uint256 expS = rawS > 0 ? uint256(rawS) : 0;
        if (expS > gs) expS = gs;
        uint256 expA = rawA > 0 ? uint256(rawA) : 0;
        if (expA > ga) expA = ga;
        assertEq(lpS, expS, "stable leg != clamp(raw,0,cap)");
        assertEq(lpA, expA, "asset leg != clamp(raw,0,cap)");
    }
}
