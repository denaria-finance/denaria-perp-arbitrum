// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

/// @notice Raised by the mocks' fallback when a caller hits a selector the mocked
/// engine surface does not expose. The REAL Stylus engine reverts with EMPTY data
/// (`0x`) on a router miss; the named error here is test-side diagnosis sugar —
/// semantically both are "the call reverts", which is the bug class under test.
error MissingSelector(bytes4 selector);

/// @title Engine20260608SurfaceMock
/// @notice Mocks the read surface class of the 2026-06-08 Stylus deploy (0x56F6…7C23) for the
/// negative-path regression: the getters `curveParameters` / `computeFundingRate` /
/// `_computeFundingFee` / `getCollateral` / `curveMathAdapter` are intentionally ABSENT — any
/// call lands in the fallback and reverts, reproducing the 2026-06-10 diagnosis that every
/// UtilMath read path (and, transitively, `Vault._checkMR`) reverted against that deploy.
/// `ReadFees` (11-field) and `ReadParameters` (16-field) track the CURRENT engine surface after
/// the getter consolidation, not the historical 7/8-field shapes, so the mock stays a faithful
/// stand-in for the UtilMath read paths under test.
///
/// Dummy values mirror the production/benchmark configuration so the linked
/// CurveMath solver runs on known-good magnitudes (stable 1.8e25 / asset 6e21,
/// curve a/b = 1e8/1e7 — the seeded benchmark pool).
contract Engine20260608SurfaceMock {
    address public immutable vaultAddr;

    // per-user position state, settable by tests
    struct Pos {
        uint256 balanceStable;
        uint256 balanceAsset;
        uint256 debtStable;
        uint256 debtAsset;
        uint256 fundingFee;
        bool fundingFeeSign;
    }

    mapping(address => Pos) internal positions;
    uint256 internal stableLiq = 18_000_000e18;
    uint256 internal assetLiq = 6000e18;

    constructor(address vault_) {
        vaultAddr = vault_;
    }

    function setPosition(address user, Pos calldata p) external {
        positions[user] = p;
    }

    function setLiquidity(uint256 stable_, uint256 asset_) external {
        stableLiq = stable_;
        assetLiq = asset_;
    }

    // ---- the read surface shared by BOTH the 2026-06-08 deploy and the
    // ---- read-parity build (signatures must mirror the engine ABI exactly) ----

    function getLpLiquidityBalance(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function userVirtualTraderPosition(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, bool, uint256, bool)
    {
        Pos memory p = positions[user];
        return (p.balanceStable, p.balanceAsset, p.debtStable, p.debtAsset, p.fundingFee, p.fundingFeeSign, 0, true);
    }

    function liquidityPosition(address) external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    /// 11-field ReadFees — the trailing four fields fold in the former standalone
    /// fundingC / fundingInterval / fundingRate / fundingRateSign getters. UtilMath now
    /// sources fundingRate ([9]) and fundingRateSign ([10]) from here.
    function ReadFees()
        external
        view
        virtual
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (1e15, 1e17, 0, 0, 0, 0, 0, 0, 0, 0, true);
    }

    function globalLiquidityStable() external view returns (uint256) {
        return stableLiq;
    }

    function globalLiquidityAsset() external view returns (uint256) {
        return assetLiq;
    }

    function lastOperationTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function MMR() external pure returns (uint256) {
        return 40_000;
    }

    function maxLpLeverage() external pure returns (uint256) {
        return 15;
    }

    function calcPnL(address, uint256) external pure returns (uint256, bool) {
        return (0, true);
    }

    /// 16-field tuple, bit-exact field order of the engine's ReadParameters. The trailing
    /// eight fields fold in the former insurance-fund / curve-A/B / total-trader-exposure reads.
    function ReadParameters()
        external
        view
        returns (
            address,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bytes32,
            uint256,
            bool,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool
        )
    {
        return (
            vaultAddr,
            address(0xBEEF),
            48e18,
            1e16,
            300_000,
            500_000,
            500e18,
            bytes32("BTCUSDC"),
            0,
            true,
            1e8,
            1e7,
            1e8,
            1e7,
            0,
            true
        );
    }

    /// Any selector outside the mocked surface = the Stylus router-miss bug class.
    fallback() external {
        revert MissingSelector(msg.sig);
    }
}

/// @title ReadParityEngineSurfaceMock
/// @notice The 2026-06-08 surface PLUS the read-parity getters restored in
/// the engine source (commit 9fc7830a lineage, pending redeploy):
/// `curveParameters`, `computeFundingRate`, `_computeFundingFee`.
/// `getCollateral` and `curveMathAdapter` stay absent BY
/// DESIGN (collateral lives in the Vault; the adapter probe is tolerant) — so the
/// positive tests also prove UtilMath no longer needs either on the engine.
contract ReadParityEngineSurfaceMock is Engine20260608SurfaceMock {
    constructor(address vault_) Engine20260608SurfaceMock(vault_) { }

    /// Immutable protocol constants (config.rs:32-35) + dynamic curve-update fields.
    function curveParameters()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256)
    {
        return (1e8, 1e7, 1e8, 1e7, block.timestamp, 6, true, 0);
    }

    function computeFundingRate(uint256, uint256) external pure returns (uint256, bool) {
        return (0, true);
    }

    function _computeFundingFee(address, uint256, bool) external pure virtual returns (uint256, bool) {
        return (0, true);
    }
}

/// @title FundingIndexProbeMock
/// @notice Regression guard for the funding-rate read path: UtilMath sources the funding
/// rate from ReadFees()[9] (the folded field, formerly a standalone getter). Here [7]/[8] hold
/// FIXED non-zero distinct values and [9] is settable, and `_computeFundingFee` ECHOES its
/// rate argument, so calcMR's fundingFee — and therefore the margin ratio — moves iff
/// getFundingRate reads index [9]. A destructure that mis-reads [7] or [8] (identical across
/// the two probe calls) would leave the margin ratio unchanged and fail the guard.
contract FundingIndexProbeMock is ReadParityEngineSurfaceMock {
    uint256 public rate9;

    constructor(address vault_) ReadParityEngineSurfaceMock(vault_) { }

    function setRate9(uint256 r) external {
        rate9 = r;
    }

    function ReadFees()
        external
        view
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, bool)
    {
        // [7]=777, [8]=888 fixed & distinct; only [9]=rate9 varies; [10]=true.
        return (1e15, 1e17, 0, 0, 0, 0, 0, 777, 888, rate9, true);
    }

    function _computeFundingFee(address, uint256 rate, bool sign) external pure override returns (uint256, bool) {
        return (rate, sign); // echo so ReadFees[9] flows into calcMR's fundingFee
    }
}

/// @notice Minimal Vault read surface for the patched UtilMath `getCollateral`
/// path (`ReadParameters()[0]` -> `IVault(vault).userCollateral(user)`).
contract VaultReadSurfaceMock {
    mapping(address => uint256) public userCollateral;

    function setCollateral(address user, uint256 amount) external {
        userCollateral[user] = amount;
    }

    fallback() external {
        revert MissingSelector(msg.sig);
    }
}
