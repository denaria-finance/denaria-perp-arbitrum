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
        LiquidityEpoch storage e = liquidityEpochs[currentLiquidityEpoch];
        e.liquidityM[0][0] = a;
        e.liquidityM[0][1] = b;
        e.liquidityM[1][0] = c;
        e.liquidityM[1][1] = d_;
    }

    function setGlobals(uint256 gs, uint256 ga) external {
        globalLiquidityStable = gs;
        globalLiquidityAsset = ga;
    }

    function setLp(address u, int256 i00, int256 i01, int256 i10, int256 i11, uint256 s, uint256 a) external {
        LiquidityPosition storage p = liquidityPosition[u];
        p.snapshotM[0][0] = i00;
        p.snapshotM[0][1] = i01;
        p.snapshotM[1][0] = i10;
        p.snapshotM[1][1] = i11;
        p.initialStableBalance = s;
        p.initialAssetBalance = a;
        // Pin the LP to the current accounting epoch so getLpLiquidityBalance recovers against the matrix set via setM.
        liquidityPositionEpoch[u] = currentLiquidityEpoch;
    }

    /// Pre-clamp signed recovery legs — the reference the production clamp is applied to. Uses the
    /// same adjugate recovery from the RAW forward snapshot M(t0) that `getLpLiquidityBalance` runs.
    function rawLegs(address u) external view returns (int256 rawS, int256 rawA) {
        LiquidityPosition storage p = liquidityPosition[u];
        (rawS, rawA) = MatrixMath.recoverLpBalanceFromSnapshot(
            liquidityEpochs[currentLiquidityEpoch].liquidityM,
            p.snapshotM,
            p.initialStableBalance,
            p.initialAssetBalance,
            decimals.liquidityMDecimals
        );
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
    /// wrapping/reverting. Magnitudes are scaled around `liquidityMDecimals` (2^80) so the
    /// adjugate recovery leaves non-trivial (and frequently negative) legs.
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
        // snapshotM[0][0] must be non-zero, else getLpLiquidityBalance early-returns (0,0).
        if (i00 == 0) i00 = 1;
        // The current epoch matrix M[0][0] must be non-zero too, else the epoch-liveness guard
        // early-returns (0,0) before recovery, which rawLegs (a direct recovery) would not model.
        if (m00 == 0) m00 = 1;
        // The adjugate recovery reverts MDET on det(snapshotM) <= 0; focus the clamp fuzz on the
        // valid (det > 0) domain, where a recovered leg can still go negative and must clamp to 0.
        vm.assume(i00 * i11 - i10 * i01 > 0);
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

    /// A real LP whose stored snapshot has det <= 0 (a corrupted matrix) reverts MDET on
    /// getLpLiquidityBalance — the adjugate recovery guard — instead of returning a wrong balance.
    function test_getLpLiquidityBalance_revertsMDET() public {
        int256 s = int256(1) << 80;
        harness.setM(s, 0, 0, s); // valid current matrix
        // det(snapshot) == 0: snapshotM00 != 0 (bypasses the empty-position sentinel), snapshotM11 = 0.
        harness.setLp(LP, s, 0, 0, 0, 1000e18, 10e18);
        vm.expectRevert(bytes("MDET"));
        harness.getLpLiquidityBalance(LP);
        // det(snapshot) < 0.
        harness.setLp(LP, s, 0, 0, -s, 1000e18, 10e18);
        vm.expectRevert(bytes("MDET"));
        harness.getLpLiquidityBalance(LP);
    }
}

import { console } from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import { FiatTokenV2 } from "../src/token/USDCe.sol";
import { TestPriceProvider } from "../src/test_support/TestPriceProvider.sol";
import { PerpMultiCalls } from "../src/manager/multiCallManager.sol";
import { PerpPairTestDeploymentHelper } from "./helpers/PerpPairTestDeploymentHelper.sol";

/// @dev End-to-end counterpart to the clamp fuzz above: the fuzz drives the recovery through a
///      harness and compares against the same recovery, so it cannot show that the clamp is what
///      keeps the pool solvent. This suite reproduces the stable-only-LP drain on the real
///      contracts (real Vault, real curve, real trades) and asserts the ECONOMIC outcome.
contract LpNegativeLegDrainTest is Test, PerpPairTestDeploymentHelper {
    Vault internal vault;
    PerpPair internal perpPair;
    PerpMultiCalls internal multiCallManager;
    LostAndFound internal lostAndFound;
    TestPriceProvider internal oracle;
    FiatTokenV2 internal stable;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 internal constant MMR = 38 * 1e6 / 1000;
    uint32 internal constant FEE_FRONTEND = 5 * uint32(1e6) / 100;
    uint32 internal constant FEE_LP = 5 * uint32(1e6) / 10;
    uint256 internal constant TRADING_FEE = 1e18 / 1000;
    uint256 internal constant FLAT_TRADING_FEE = 1e17;
    uint256 internal constant MAX_USER_LIQUIDITY_FEE = 1e30;

    address internal feeProtocolAddr = makeAddr("denaria");
    address internal frontendAddress = makeAddr("frontend");
    address internal minter = makeAddr("minter");
    bytes internal fakeReport;

    address internal victimLp = makeAddr("alice");
    address internal attackerLp = makeAddr("bob");
    address internal attackerTrader = makeAddr("charlie");
    address internal churnLong = makeAddr("david");
    address internal churnShort = makeAddr("eve");

    function setUp() public {
        stable = new FiatTokenV2();
        stable.initialize("USDCe", "USDC.e", "USD", 18, minter, minter, minter, minter);
        vm.prank(minter);
        stable.configureMinter(minter, 1e40);

        address[] memory coins = new address[](1);
        coins[0] = address(stable);
        uint256[] memory depositThresholds = new uint256[](1);
        depositThresholds[0] = 1e8;
        uint256[] memory withdrawalThresholds = new uint256[](1);
        withdrawalThresholds[0] = 1e8;
        uint256[] memory stableDecimals = new uint256[](1);
        stableDecimals[0] = 1e18;

        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault =
            new Vault(address(multiCallManager), 100, coins, depositThresholds, withdrawalThresholds, stableDecimals);
        perpPair = _deployPerpPairForTest(
            address(oracle),
            address(vault),
            address(multiCallManager),
            MMR,
            bytes32("BTC"),
            FEE_FRONTEND,
            FEE_LP,
            feeProtocolAddr,
            TRADING_FEE,
            FLAT_TRADING_FEE,
            ORACLE_DECIMALS * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));
        lostAndFound = new LostAndFound();
        vault.initializeParameters(address(perpPair), address(lostAndFound));
        _restoreTestEraParameters(
            perpPair, address(oracle), FEE_FRONTEND, feeProtocolAddr, MMR, TRADING_FEE, FLAT_TRADING_FEE, FEE_LP
        );

        address[5] memory users = [victimLp, attackerLp, attackerTrader, churnLong, churnShort];
        uint256[] memory collateral = new uint256[](1);
        collateral[0] = 10_000_000 * 1e18;
        for (uint256 i; i < users.length; i++) {
            vm.prank(minter);
            stable.mint(users[i], 20_000_000 * 1e18);
            vm.prank(users[i]);
            stable.approve(address(vault), type(uint256).max);
            vm.prank(users[i]);
            vault.addCollateral(collateral);
        }
    }

    /// @dev A stable-only LP deposit into a worn-down pool, followed by a long that perturbs M(t),
    ///      drives the attacker's recovered ASSET leg negative. Without the clamp the unsafe
    ///      uint256 cast wraps it and the global cap hands the attacker the pool's whole asset
    ///      side, which realizePnL then mints into their vault collateral. The assertions here are
    ///      economic: LP claims must stay within pool inventory, and a stable-only LP must not be
    ///      able to walk away with more than it deposited.
    function testStableOnlyLpCannotDrainPoolEndToEnd() public {
        uint256 price = 6_689_150_000_000; // ~$66,891.50, 8 decimals
        oracle.setPrice(price);

        // 1. Victim LP seeds a balanced pool.
        uint256 victimStable = 1_000_000 * 1e18;
        vm.prank(victimLp);
        perpPair.addLiquidity(victimStable, victimStable * ORACLE_DECIMALS / price, MAX_USER_LIQUIDITY_FEE, fakeReport);

        // 2. Trade churn wears the liquidity matrix down into the ill-conditioned regime.
        for (uint256 i; i < 80; i++) {
            skip(120);
            // Reads are hoisted: an inline external call would consume the prank below.
            uint256 assetGuess = perpPair.globalLiquidityAsset();
            vm.prank(churnLong);
            try perpPair.trade(true, 20_000 * 1e18, 1, assetGuess, frontendAddress, 1, fakeReport) { } catch { }

            skip(120);
            uint256 stableGuess = perpPair.globalLiquidityStable();
            uint256 shortSize = (20_000 * 1e18 * ORACLE_DECIMALS) / price;
            vm.prank(churnShort);
            try perpPair.trade(false, shortSize, 1, stableGuess, frontendAddress, 1, fakeReport) { } catch { }
        }
        skip(120);

        // 3. Attacker joins as a STABLE-ONLY LP: zero asset leg at the snapshot.
        uint256 attackerDeposit = 19_980 * 1e18;
        vm.prank(attackerLp);
        perpPair.addLiquidity(attackerDeposit, 0, MAX_USER_LIQUIDITY_FEE, fakeReport);
        (, uint256 attackerAssetAtEntry) = perpPair.getLpLiquidityBalance(attackerLp);
        assertEq(attackerAssetAtEntry, 0, "stable-only deposit must start with a zero asset leg");
        uint256 attackerCollateralBefore = vault.userCollateral(attackerLp);

        // 4. Attacker's own long perturbs M(t) so the recovered asset leg goes negative.
        uint256 attackGuess = perpPair.globalLiquidityAsset();
        vm.prank(attackerTrader);
        perpPair.trade(true, 15_000 * 1e18, 1, attackGuess, frontendAddress, 1, fakeReport);

        // 5. Pool inventory must still cover the sum of the LP claims. Unclamped, the attacker's
        //    wrapped asset leg alone equals globalLiquidityAsset, so the two LPs together claim
        //    ~2x the asset side (measured: 29.518e18 claimed vs 14.759e18 in the pool).
        (uint256 victimStableLeg, uint256 victimAssetLeg) = perpPair.getLpLiquidityBalance(victimLp);
        (uint256 attackerStableLeg, uint256 attackerAssetLeg) = perpPair.getLpLiquidityBalance(attackerLp);
        console.log("attacker legs after attack:", attackerStableLeg, attackerAssetLeg);
        assertLe(
            victimAssetLeg + attackerAssetLeg,
            perpPair.globalLiquidityAsset(),
            "LP asset claims exceed pool asset inventory"
        );
        assertLe(
            victimStableLeg + attackerStableLeg,
            perpPair.globalLiquidityStable(),
            "LP stable claims exceed pool stable inventory"
        );

        // 6. Realize the claim into vault collateral: a stable-only LP that only paid the deposit
        //    fee cannot come out ahead. Measured on the fixed code the attacker LOSES the
        //    ~0.32e18 liquidity fee; unclamped they gain ~705,922e18 (35x their deposit, ~70% of
        //    the pool's asset-side value).
        vm.prank(attackerLp);
        perpPair.realizePnL(fakeReport);
        uint256 attackerCollateralAfter = vault.userCollateral(attackerLp);
        console.log("attacker collateral before/after:", attackerCollateralBefore, attackerCollateralAfter);
        assertLe(
            attackerCollateralAfter,
            attackerCollateralBefore + attackerDeposit / 100,
            "stable-only LP realized more collateral than it could ever be owed"
        );

        // 7. And the value the attacker can still walk out with (remaining LP claim) plus what it
        //    already realized stays at or below what it put in.
        (uint256 finalStableLeg, uint256 finalAssetLeg) = perpPair.getLpLiquidityBalance(attackerLp);
        uint256 realizedGain =
            attackerCollateralAfter > attackerCollateralBefore ? attackerCollateralAfter - attackerCollateralBefore : 0;
        uint256 realizedLoss =
            attackerCollateralBefore > attackerCollateralAfter ? attackerCollateralBefore - attackerCollateralAfter : 0;
        uint256 valueOut = finalStableLeg + (finalAssetLeg * price) / ORACLE_DECIMALS + realizedGain;
        uint256 valueIn = attackerDeposit + realizedLoss;
        console.log("attacker value out / in:", valueOut, valueIn);
        assertLe(valueOut, valueIn, "stable-only LP extracted more value than it deposited");
    }
}

