// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import "../../src/util/UtilMath.sol";
import "../../src/manager/callBatcher.sol";
import "./StylusEngineSurfaceMock.sol";

/// @title StylusReadSurfaceTest — cross-contract selector-dependency regression suite
/// @notice Locks the 2026-06-10 diagnosis: UtilMath's read paths (`calcMR`,
/// `returnTradeInfo`, `_calcPnL`, `calcHypotheticalMR`) make typed callbacks into
/// the engine, and the 2026-06-08 Stylus deploy did not expose those selectors, so
/// every one of them reverted (and `Vault.removeCollateral` with them, via
/// `Vault._checkMR -> UtilMath.calcMR` — the same library call this suite drives,
/// so that transitive leg is covered by equivalence; the static
/// `script/selector_dependency_audit.py` checks the full call graph).
///
/// Two mocked engine surfaces:
///  - `Engine20260608SurfaceMock`     = the surface actually deployed on 2026-06-08
///    (negative tests: every UtilMath read MUST revert exactly as observed on-chain);
///  - `ReadParityEngineSurfaceMock`   = + the 4 restored getters (positive tests:
///    every UtilMath read MUST succeed, with `getCollateral`/`curveMathAdapter`
///    still absent — proving the patched UtilMath no longer needs them).
contract StylusReadSurfaceTest is Test {
    VaultReadSurfaceMock vault;
    Engine20260608SurfaceMock legacyDeploy; // 2026-06-08 surface (bug regression)
    ReadParityEngineSurfaceMock readParity; // next-deploy surface
    CallBatcher batcher;

    address constant USER = address(0xA11CE);
    uint256 constant PRICE = 3000e8; // benchmark-pool magnitude (stable 1.8e25 / asset 6e21)

    function setUp() public {
        vault = new VaultReadSurfaceMock();
        legacyDeploy = new Engine20260608SurfaceMock(address(vault));
        readParity = new ReadParityEngineSurfaceMock(address(vault));
        batcher = new CallBatcher();
        vault.setCollateral(USER, 1000e18);
    }

    // ------------------------------------------------------------------
    // POSITIVE: the read-parity surface satisfies every UtilMath read path
    // ------------------------------------------------------------------

    function test_calcMR_succeeds_on_readParity_surface() public view {
        // stale lastOperationTimestamp forces the computeFundingRate callback too
        uint256 mr = UtilMath.calcMR(USER, PRICE, address(readParity), 1000e18, block.timestamp - 1);
        assertEq(mr, 1e6, "empty position => marginRatio == MMRDecimals");
    }

    function test_calcMR_with_position_succeeds_on_readParity_surface() public {
        readParity.setPosition(
            USER,
            Engine20260608SurfaceMock.Pos({
                balanceStable: 0,
                balanceAsset: 1e18,
                debtStable: 3000e18,
                debtAsset: 0,
                fundingFee: 0,
                fundingFeeSign: true
            })
        );
        // exercises the curve-exit branch of _calcPnL (computeShortReturn via the
        // LINKED CurveMath — the tolerant curveMathAdapter probe misses and falls back)
        uint256 mr = UtilMath.calcMR(USER, PRICE, address(readParity), 1000e18, block.timestamp);
        assertGt(mr, 0, "open position with collateral => nonzero margin ratio");
    }

    /// Regression guard: calcMR must source the funding rate from ReadFees()[9]
    /// (the folded field), not an adjacent index. The probe keeps [7]/[8] fixed non-zero and
    /// varies only [9]; with a fresh timestamp the rate flows straight through the echoing
    /// _computeFundingFee into the margin ratio, so mrWithRate must differ from mrZeroRate —
    /// a destructure that mis-read [7] or [8] would leave the ratio unchanged and fail here.
    function test_calcMR_sources_fundingRate_from_ReadFees_index_9() public {
        FundingIndexProbeMock probe = new FundingIndexProbeMock(address(vault));
        probe.setPosition(
            USER,
            Engine20260608SurfaceMock.Pos({
                balanceStable: 0,
                balanceAsset: 1e18,
                debtStable: 3000e18,
                debtAsset: 0,
                fundingFee: 0,
                fundingFeeSign: true
            })
        );
        probe.setRate9(0);
        uint256 mrZeroRate = UtilMath.calcMR(USER, PRICE, address(probe), 1000e18, block.timestamp);
        probe.setRate9(50e18);
        uint256 mrWithRate = UtilMath.calcMR(USER, PRICE, address(probe), 1000e18, block.timestamp);
        assertTrue(
            mrWithRate != mrZeroRate,
            "a non-zero ReadFees[9]=fundingRate must move the margin ratio (guards the funding index)"
        );
    }

    function test_returnTradeInfo_succeeds_on_readParity_surface() public view {
        (uint256 slippage, uint256 marginRatio, uint256 tradeReturn,,,,,, uint256 finalCollateral) =
            UtilMath.returnTradeInfo(USER, true, 3000e18, 0, PRICE, address(readParity));
        assertGt(tradeReturn, 0, "long quote must return a positive tradeReturn");
        assertGt(marginRatio, 0, "collateralized quote must have a margin ratio");
        assertEq(finalCollateral, 1000e18, "collateral must come from the Vault (patched getCollateral)");
        slippage; // silence unused-var
    }

    function test_calcPnL_succeeds_on_readParity_surface() public view {
        (uint256 pnl, bool pnlSign) = UtilMath._calcPnL(0, 1e18, 0, 0, 0, true, PRICE, 1e8, address(readParity), false);
        assertGt(pnl, 0, "1 asset long at 3000e8 must quote a positive exit value");
        assertTrue(pnlSign, "long with no debt => positive pnl");
    }

    function test_calcHypotheticalMR_succeeds_on_readParity_surface() public view {
        uint256 mr = UtilMath.calcHypotheticalMR(0, 0, 0, 0, 0, true, PRICE, 1e8, 1e18, 1e6, address(readParity));
        assertEq(mr, 1e6, "empty hypothetical position => MMRDecimals");
    }

    function test_batchCalcMR_reads_collateral_from_vault_on_readParity_surface() public view {
        address[] memory users = new address[](1);
        users[0] = USER;

        uint256[] memory mr = batcher.batchCalcMR(users, PRICE, address(readParity));

        assertEq(mr[0], 1e6, "empty position => marginRatio == MMRDecimals");
    }

    function test_batchCollateral_reads_collateral_from_vault_on_readParity_surface() public view {
        address[] memory users = new address[](1);
        users[0] = USER;

        uint256[] memory collaterals = batcher.batchCollateral(users, PRICE, address(readParity));

        assertEq(collaterals[0], 1000e18, "collateral must come from the Vault");
    }

    function test_batchCollateral_returns_empty_without_engine_callback() public view {
        address[] memory users = new address[](0);

        uint256[] memory collaterals = batcher.batchCollateral(users, PRICE, address(legacyDeploy));

        assertEq(collaterals.length, 0, "empty input must return an empty output");
    }

    function test_calcPnLNoExit_is_pure_and_engine_independent() public pure {
        // no perpPair argument at all — must work against ANY engine surface
        (uint256 pnl, bool sign) = UtilMath._calcPnLNoExit(1e18, 0, 0, 0, 0, true, PRICE, 1e8);
        assertEq(pnl, 1e18);
        assertTrue(sign);
    }

    // ------------------------------------------------------------------
    // NEGATIVE / regression: the 2026-06-08 surface reverts exactly where
    // the on-chain debugging found it (cast-reproduced empty-`0x` reverts)
    // ------------------------------------------------------------------

    function test_calcMR_reverts_on_20260608_surface_at_computeFundingRate() public {
        vm.expectRevert(
            abi.encodeWithSelector(MissingSelector.selector, bytes4(keccak256("computeFundingRate(uint256,uint256)")))
        );
        // stale timestamp => the FIRST missing callback hit is computeFundingRate (UtilMath.sol calcMR)
        UtilMath.calcMR(USER, PRICE, address(legacyDeploy), 1000e18, block.timestamp - 1);
    }

    function test_calcMR_reverts_on_20260608_surface_at_computeFundingFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MissingSelector.selector, bytes4(keccak256("_computeFundingFee(address,uint256,bool)"))
            )
        );
        // fresh timestamp skips computeFundingRate => the unconditional _computeFundingFee hits
        UtilMath.calcMR(USER, PRICE, address(legacyDeploy), 1000e18, block.timestamp);
    }

    function test_returnTradeInfo_reverts_on_20260608_surface_at_curveParameters() public {
        vm.expectRevert(abi.encodeWithSelector(MissingSelector.selector, bytes4(keccak256("curveParameters()"))));
        UtilMath.returnTradeInfo(USER, true, 3000e18, 0, PRICE, address(legacyDeploy));
    }

    function test_calcPnL_reverts_on_20260608_surface_even_for_empty_position() public {
        // curveParameters() is read UNCONDITIONALLY at the top of _calcPnL — this is
        // why even the empty-position close preview reverted on the deployed stack
        vm.expectRevert(abi.encodeWithSelector(MissingSelector.selector, bytes4(keccak256("curveParameters()"))));
        UtilMath._calcPnL(0, 0, 0, 0, 0, true, PRICE, 1e8, address(legacyDeploy), true);
    }

    function test_calcHypotheticalMR_reverts_on_20260608_surface() public {
        vm.expectRevert(abi.encodeWithSelector(MissingSelector.selector, bytes4(keccak256("curveParameters()"))));
        UtilMath.calcHypotheticalMR(0, 0, 0, 0, 0, true, PRICE, 1e8, 1e18, 1e6, address(legacyDeploy));
    }
}
