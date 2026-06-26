// SPDX-License-Identifier: BUSL-1.1

//! # Denaria PerpPair engine — Arbitrum Stylus (Rust/WASM) port
//!
//! Storage layout: a fresh, side-by-side layout (not byte-for-byte compatible
//! with the Solidity `PerpStorage`),
//! so fields are packed: the flags, the leverage/fraction `uint8`s, the
//! oracle/EMA/timestamp/interval values (`uint64`), and the small fee fractions
//! (`uint32`) share slots, while WAD-scale and accumulating quantities stay
//! `uint256`/`int256`. Narrowed fields are only those whose protocol range
//! provably fits the narrower type (see the inline ranges); narrowing the storage
//! TYPE does not change the stored VALUE, so parity is preserved as long as the
//! value fits.
//!
//! The Solidity `int256[2][2]` matrix `M` and `int256[2]` row `G` are flattened
//! into scalar fields (m00..m11, g0/g1) — functionally identical, simpler to pack
//! and access.
//!
//! Source of truth for the field set: `src/storage/PerpStorage.sol`.
//!
//! This file defines the storage, the `#[public]` ABI surface and the events;
//! the state-transition logic lives in the per-domain modules (trade, close,
//! liquidity, liquidation, funding, auto_close, config, access_control,
//! internal_logic).

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![allow(clippy::too_many_arguments)]
extern crate alloc;

use alloc::vec::Vec;

use stylus_sdk::{
    abi::Bytes,
    alloy_primitives::{keccak256, Address, B256, I256, U8, U32, U64, U256},
    prelude::*,
};
// `alloy-sol-types` is a direct dep (extern crate) so the `sol!` event macro's
// generated `alloy_sol_types::...` paths resolve; same 1.6.0 instance stylus-sdk
// re-exports, so the SolEvent trait identity matches.
use alloy_sol_types::{sol, SolEvent};

// Events — ABI/topic-parity with the Solidity perp modules. The `sol!`-derived
// SIGNATURE_HASH (topic0) is computed from the canonical type signature, so it
// matches Solidity as long as the parameter type lists match (verified in 9b).
sol! {
    #[derive(Debug)]
    struct ClampParameters { uint256 minFR; uint256 maxFR; uint256 offset; }

    event ExecutedTrade(address indexed user, bool direction, uint256 tradeSize, uint256 tradeReturn, uint256 currentPrice, uint256 leverage);
    event ClosedPosition(address indexed user, uint256 pnl, bool pnlSign);
    event LiquidityMoved(address indexed user, uint256 liquidityStable, uint256 liquidityAsset, uint256 fee, bool added);
    event LiquidatedUser(address indexed user, address liquidator, uint256 fraction, uint256 liquidationFee, uint256 positionSize, uint256 currentPrice, int256 deltaPnl, bool liquidationDirection);
    event EnabledAutoClose(address indexed user, uint256 profitTh, uint256 lossTh);
    event RealizedPnL(address indexed user, uint256 pnl, bool pnlSign);
    event ParametersUpdated(address _oracle, uint256 _feeFrontend, address _feeProtocolAddr, uint256 _insuranceFundCap, uint256 _maxLeverage, uint256 _liquidationDiscount);
    event LockedParameterUpdate(uint256 paramLockedUntil, uint256 _MMR, uint256 _tradingFee, uint256 _flatTradingFee, uint256 _feeLP, uint256 _liquidityMinFee, uint256 _liquidityMaxFee, uint256 _liquidityFeeK, uint256 _fundingC, ClampParameters _clampParams, uint256 _paramTimeLock, uint256 _minimumTradeSize);
    // Stylus-specific: the explicit-sender `*For` topology has a SETTABLE trusted forwarder
    // (OZ ERC2771's forwarder is immutable, so there is no Solidity counterpart). The
    // forwarder is a critical privileged address — every `*For` entrypoint trusts it — so
    // changes are made observable.
    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
}

// Shared pure math (curve solver, MatrixMath, UtilMath helpers). Depended on
// with default-features=false so its standalone #[entrypoint] is not linked.
use denaria_curve_math_stylus as cm;

sol_storage! {
    #[entrypoint]
    pub struct PerpEngine {
        // --- packed: vault + flags + leverage/fraction u8 (20 + 4 + 4 = 28 B) ---
        address vault;
        bool insurance_fund_sign;
        bool funding_rate_sign;
        bool total_trader_exposure_sign;
        bool last_trade_direction;
        bool entered;                // reentrancy guard
        bool initialized;            // one-shot init guard
        uint8 max_leverage;          // <= 255 (15)
        uint8 max_lp_leverage;       // <= 255 (15)
        uint8 ins_fund_fraction;     // <= 255 (6)
        uint8 slip_liquidation_th;   // <= 255 (10)

        // --- packed: address + u64 each ---
        address oracle;
        uint64 oracle_decimals;      // 1e8 < 2^64
        address fee_protocol_addr;
        uint64 ema_param;            // ~9e7 < 2^64
        address curve_math_adapter;
        uint64 last_operation_timestamp; // unix ts < 2^64

        // --- packed: timestamps/intervals (4 x u64 = 32 B) ---
        uint64 last_curve_update;
        uint64 curve_update_interval;
        uint64 funding_interval;
        uint64 param_locked_until;

        // --- packed: u64 + small fee fractions u32 (8 + 5*4 = 28 B) ---
        uint64 param_time_lock;
        uint32 mmr;                  // 4e4 < 2^32
        uint32 fee_frontend;         // 3e5 < 2^32
        uint32 fee_lp;               // 5e5 < 2^32
        uint32 liquidation_discount; // 7500 < 2^32
        uint32 funding_c;            // 1e6 < 2^32

        // --- full-width scalars (WAD-scale / accumulating) ---
        uint256 minimum_trade_size;
        uint256 minimum_liquidity_movement;
        uint256 trading_fee;
        uint256 flat_trading_fee;
        uint256 auto_close_fee;
        uint256 insurance_fund;
        uint256 insurance_fund_cap;
        uint256 global_liquidity_stable;
        uint256 global_liquidity_asset;
        uint256 liquidity_min_fee;
        uint256 liquidity_max_fee;
        uint256 liquidity_fee_k;
        uint256 funding_rate;
        uint256 total_trader_exposure;
        uint256 dx0;
        uint256 dy0;
        uint256 avg_slippage_l;
        uint256 avg_slippage_s;
        uint256 last_validated_price;
        uint256 short_curve_parameter_a;
        uint256 short_curve_parameter_b;
        uint256 long_curve_parameter_a;
        uint256 long_curve_parameter_b;

        // --- liquidity matrix M (flattened 2x2) + funding row G (flattened) ---
        int256 liquidity_m00;
        int256 liquidity_m01;
        int256 liquidity_m10;
        int256 liquidity_m11;
        int256 matrix_row_g0;
        int256 matrix_row_g1;

        // --- Decimals (config) ---
        uint256 mmr_decimals;
        uint256 liquidation_decimals;
        uint256 fee_fractions_decimals;
        uint256 liquidity_fee_decimals;
        uint256 funding_rate_decimals;
        uint256 funding_c_decimals;
        int256  liquidity_m_decimals;
        uint256 trading_fee_decimals;
        uint256 liquidity_g_decimals;

        // --- ClampParameters (funding clamp config) ---
        uint256 clamp_min_fr;
        uint256 clamp_max_fr;
        uint256 clamp_offset;

        // --- roles / misc ---
        bytes32 mod_role;
        bytes32 param_hash;
        bytes32 ticker_asset_currency;

        // --- positions / per-user data ---
        mapping(address => VirtualTraderPosition) user_virtual_trader_position;
        mapping(address => LiquidityPosition) liquidity_position;
        mapping(address => AutoCloseData) auto_close_users_data;

        // --- AccessControl role membership (OZ-style): role => account => member ---
        mapping(bytes32 => mapping(address => bool)) role_members;

        // --- ERC2771-style trusted forwarder (explicit-sender forwarded entrypoints) ---
        address trusted_forwarder;
    }

    pub struct VirtualTraderPosition {
        uint256 balance_stable;
        uint256 balance_asset;
        uint256 debt_stable;
        uint256 debt_asset;
        uint256 funding_fee;
        bool funding_fee_sign;
        uint256 initial_funding_rate;
        bool initial_funding_rate_sign;
    }

    pub struct LiquidityPosition {
        uint256 initial_stable_balance;
        uint256 initial_asset_balance;
        uint256 debt_stable;
        uint256 debt_asset;
        int256 inverse_snapshot_m00;
        int256 inverse_snapshot_m01;
        int256 inverse_snapshot_m10;
        int256 inverse_snapshot_m11;
        int256 snapshot_g0;
        int256 snapshot_g1;
    }

    pub struct AutoCloseData {
        bool authorized;
        uint256 profit_th;
        uint256 loss_th;
        uint256 max_slippage;
        uint256 max_liq_fee;
    }
}

sol_interface! {
    interface IOracleMiddleware {
        function verifyReportIfNecessary(bytes unverified_report) external;
        function getPrice() external view returns (int256);
    }
    interface IVault {
        function userCollateral(address user) external view returns (uint256);
        function addPnlToCollateral(address user, uint256 pnl, bool pnl_sign) external;
        function removeAllCollateralForUser(address user) external;
    }
}

#[public]
impl PerpEngine {
    /// **Production initializer** — parity with the Solidity `PerpPair` constructor: takes
    /// the full configurable parameter set and applies the constructor's `SET*` validation
    /// (SET2 oracle≠0, SET3 vault≠0, SET1 fee-sum < feeFractionsDecimals, SET5 tradingFee
    /// range, SET6 flat-fee bound, SET7 feeProtocol≠0; SET4 `_MMR ≥ 0` is vacuous → replaced
    /// by the engine's u32 range narrowing, reverting `C`). The non-configurable protocol
    /// constants (decimals, curve, clamp, identity liquidity matrix, funding/liquidation
    /// defaults) are fixed exactly as the constructor hardcodes them. `multi_call_manager`
    /// is the ERC2771 trusted forwarder.
    #[selector(name = "initializeProduction")]
    #[allow(clippy::too_many_arguments)]
    pub fn initialize_production(
        &mut self,
        oracle: Address,
        vault: Address,
        multi_call_manager: Address,
        mmr: U256,
        ticker_asset_currency: B256,
        fee_frontend: U32,
        fee_lp: U32,
        fee_protocol_addr: Address,
        trading_fee: U256,
        flat_trading_fee: U256,
        ema_param: U256,
    ) -> Result<(), Vec<u8>> {
        if self.initialized.get() {
            return Err(err(b"INIT"));
        }
        // Fixed protocol constants first, so the SET checks read the same
        // `feeFractionsDecimals`/`tradingFeeDecimals`/`minimumTradeSize` storage the
        // Solidity constructor reads.
        self.init_protocol_constants();
        let wad = U256::from(WAD_U64);
        let fee_frac_dec = self.fee_fractions_decimals.get(); // 1e6
        let trading_fee_dec = self.trading_fee_decimals.get(); // 1e18
        let min_trade = self.minimum_trade_size.get(); // 48e18
        if oracle == Address::ZERO {
            return Err(err(b"SET2"));
        }
        if vault == Address::ZERO {
            return Err(err(b"SET3"));
        }
        // SET1: feeFrontend + feeLP < feeFractionsDecimals (widen to U256 — no u32 overflow).
        if !(U256::from(fee_frontend) + U256::from(fee_lp) < fee_frac_dec) {
            return Err(err(b"SET1"));
        }
        // SET5: tradingFee < tradingFeeDecimals (the `_tradingFee >= 0` clause is vacuous).
        if !(trading_fee < trading_fee_dec) {
            return Err(err(b"SET5"));
        }
        // SET6: flatTradingFee*1e18 < (tradingFeeDecimals - tradingFee)*minimumTradeSize.
        if !(flat_trading_fee * wad < (trading_fee_dec - trading_fee) * min_trade) {
            return Err(err(b"SET6"));
        }
        if fee_protocol_addr == Address::ZERO {
            return Err(err(b"SET7"));
        }
        // SET4 (`_MMR >= 0`) is vacuous for an unsigned value; the engine narrows MMR to
        // u32, so an out-of-range MMR reverts `C` (the engine's narrowing convention).
        self.mmr.set(U32::from(u32::try_from(mmr).map_err(|_| err(b"C"))?));
        self.oracle.set(oracle);
        self.vault.set(vault);
        self.trusted_forwarder.set(multi_call_manager);
        self.ticker_asset_currency.set(ticker_asset_currency);
        self.fee_frontend.set(fee_frontend);
        self.fee_lp.set(fee_lp);
        self.fee_protocol_addr.set(fee_protocol_addr);
        self.trading_fee.set(trading_fee);
        self.flat_trading_fee.set(flat_trading_fee);
        // emaParam is uint256 in Solidity but stored narrowed to u64 here → range-revert `C`.
        self.ema_param.set(U64::from(u64::try_from(ema_param).map_err(|_| err(b"C"))?));
        self.finalize_init();
        Ok(())
    }

    /// Main trade entrypoint (EOA path) — Port of `perpTrade.trade(...)`. The acting
    /// user is the direct caller. Delegates to `trade_impl`.
    pub fn trade(
        &mut self,
        direction: bool,
        size: U256,
        min_trade_return: U256,
        initial_guess: U256,
        frontend_address: Address,
        leverage: u8,
        unverified_report: Bytes,
    ) -> Result<U256, Vec<u8>> {
        let user = self.vm().msg_sender();
        self.trade_impl(user, direction, size, min_trade_return, initial_guess, frontend_address, leverage, unverified_report)
    }

    /// Forwarded trade: callable ONLY by the trusted forwarder, which passes
    /// the real `user` explicitly. Same logic as `trade` via `trade_impl`. This is the
    /// Stylus-feasible production-topology entrypoint (the manager forwards to it).
    #[selector(name = "tradeFor")]
    #[allow(clippy::too_many_arguments)]
    pub fn trade_for(
        &mut self,
        user: Address,
        direction: bool,
        size: U256,
        min_trade_return: U256,
        initial_guess: U256,
        frontend_address: Address,
        leverage: u8,
        unverified_report: Bytes,
    ) -> Result<U256, Vec<u8>> {
        let user = self.require_forwarder(user)?;
        self.trade_impl(user, direction, size, min_trade_return, initial_guess, frontend_address, leverage, unverified_report)
    }

    /// Public `closeAndWithdraw` (EOA) — Solidity `perpTrade.closeAndWithdraw`. The
    /// acting user is the direct caller. Delegates to `close_and_withdraw_outer`.
    #[selector(name = "closeAndWithdraw")]
    pub fn close_and_withdraw(
        &mut self,
        max_slippage: U256,
        max_liq_fee: U256,
        frontend_address: Address,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let user = self.vm().msg_sender();
        self.close_and_withdraw_outer(user, max_slippage, max_liq_fee, frontend_address, unverified_report)
    }

    /// Forwarded `closeAndWithdraw`: trusted-forwarder-only, explicit `user`.
    #[selector(name = "closeAndWithdrawFor")]
    pub fn close_and_withdraw_for(
        &mut self,
        user: Address,
        max_slippage: U256,
        max_liq_fee: U256,
        frontend_address: Address,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let user = self.require_forwarder(user)?;
        self.close_and_withdraw_outer(user, max_slippage, max_liq_fee, frontend_address, unverified_report)
    }

    /// Public `addLiquidity` (EOA) — Solidity `perpLiquidity.addLiquidity`. The acting
    /// LP is the direct caller. Delegates to `add_liquidity_outer`.
    #[selector(name = "addLiquidity")]
    pub fn add_liquidity_public(
        &mut self,
        liquidity_stable: U256,
        liquidity_asset: U256,
        max_fee_value: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        self.add_liquidity_outer(sender, liquidity_stable, liquidity_asset, max_fee_value, unverified_report)
    }

    /// Forwarded `addLiquidity`: trusted-forwarder-only, explicit LP `user`.
    #[selector(name = "addLiquidityFor")]
    pub fn add_liquidity_for(
        &mut self,
        user: Address,
        liquidity_stable: U256,
        liquidity_asset: U256,
        max_fee_value: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let sender = self.require_forwarder(user)?;
        self.add_liquidity_outer(sender, liquidity_stable, liquidity_asset, max_fee_value, unverified_report)
    }

    /// Public `removeLiquidity` (EOA) — Solidity `perpLiquidity.removeLiquidity`. The
    /// acting LP is the direct caller. Delegates to `remove_liquidity_outer`.
    #[selector(name = "removeLiquidity")]
    pub fn remove_liquidity_public(
        &mut self,
        liquidity_stable_to_remove: U256,
        liquidity_asset_to_remove: U256,
        max_fee_value: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        self.remove_liquidity_outer(sender, liquidity_stable_to_remove, liquidity_asset_to_remove, max_fee_value, unverified_report)
    }

    /// Forwarded `removeLiquidity`: trusted-forwarder-only, explicit LP `user`.
    #[selector(name = "removeLiquidityFor")]
    pub fn remove_liquidity_for(
        &mut self,
        user: Address,
        liquidity_stable_to_remove: U256,
        liquidity_asset_to_remove: U256,
        max_fee_value: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let sender = self.require_forwarder(user)?;
        self.remove_liquidity_outer(sender, liquidity_stable_to_remove, liquidity_asset_to_remove, max_fee_value, unverified_report)
    }

    /// Total stable liquidity in the pool.
    #[selector(name = "globalLiquidityStable")]
    pub fn global_liquidity_stable(&self) -> Result<U256, Vec<u8>> {
        Ok(self.global_liquidity_stable.get())
    }

    /// Total asset liquidity in the pool.
    #[selector(name = "globalLiquidityAsset")]
    pub fn global_liquidity_asset(&self) -> Result<U256, Vec<u8>> {
        Ok(self.global_liquidity_asset.get())
    }

    /// Cumulative funding rate.
    #[selector(name = "fundingRate")]
    pub fn funding_rate(&self) -> Result<U256, Vec<u8>> {
        Ok(self.funding_rate.get())
    }

    /// Total trader exposure.
    #[selector(name = "totalTraderExposure")]
    pub fn total_trader_exposure(&self) -> Result<U256, Vec<u8>> {
        Ok(self.total_trader_exposure.get())
    }

    /// Public `liquidate` — Solidity `perpLiquidation.liquidate`. The caller
    /// (liquidator) liquidates a `liquidatedPositionSize` fraction of `user`'s
    /// unhealthy position at a discount. ERC2771-less `_msgSender` = the liquidator.
    #[selector(name = "liquidate")]
    pub fn liquidate(
        &mut self,
        user: Address,
        liquidated_position_size: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let liquidator = self.vm().msg_sender();
        self.liquidate_impl(liquidator, user, liquidated_position_size, unverified_report)
    }

    /// Forwarded `liquidate`: trusted-forwarder-only, explicit `liquidator`.
    #[selector(name = "liquidateFor")]
    pub fn liquidate_for(
        &mut self,
        liquidator: Address,
        user: Address,
        liquidated_position_size: U256,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let liquidator = self.require_forwarder(liquidator)?;
        self.liquidate_impl(liquidator, user, liquidated_position_size, unverified_report)
    }

    /// Public `realizePnL` (EOA) — Solidity `internalPerpLogic.realizePnL`. Settle the
    /// caller's PnL into collateral in place. Delegates to `realize_pnl_outer`.
    #[selector(name = "realizePnL")]
    pub fn realize_pnl(&mut self, unverified_report: Bytes) -> Result<(U256, bool), Vec<u8>> {
        let user = self.vm().msg_sender();
        self.realize_pnl_outer(user, unverified_report)
    }

    /// Forwarded `realizePnL`: trusted-forwarder-only, explicit `user`.
    #[selector(name = "realizePnLFor")]
    pub fn realize_pnl_for(&mut self, user: Address, unverified_report: Bytes) -> Result<(U256, bool), Vec<u8>> {
        let user = self.require_forwarder(user)?;
        self.realize_pnl_outer(user, unverified_report)
    }

    /// Public `enableAutoClose` — Solidity `perpAutoClose.enableAutoClose`. Authorize
    /// third parties to close the caller's position at a profit/loss threshold. Not
    /// reentrancy-guarded in Solidity (pure storage writes).
    #[selector(name = "enableAutoClose")]
    pub fn enable_auto_close(
        &mut self,
        profit_th: U256,
        loss_th: U256,
        max_slippage: U256,
        max_liq_fee: U256,
    ) -> Result<(), Vec<u8>> {
        let user = self.vm().msg_sender();
        self.enable_auto_close_impl(user, profit_th, loss_th, max_slippage, max_liq_fee)
    }

    /// Forwarded `enableAutoClose`: trusted-forwarder-only, explicit `user`
    /// (the position owner authorizing auto-close).
    #[selector(name = "enableAutoCloseFor")]
    pub fn enable_auto_close_for(
        &mut self,
        user: Address,
        profit_th: U256,
        loss_th: U256,
        max_slippage: U256,
        max_liq_fee: U256,
    ) -> Result<(), Vec<u8>> {
        let user = self.require_forwarder(user)?;
        self.enable_auto_close_impl(user, profit_th, loss_th, max_slippage, max_liq_fee)
    }

    /// Public `disableAutoClose` — Solidity `perpAutoClose.disableAutoClose`.
    #[selector(name = "disableAutoClose")]
    pub fn disable_auto_close(&mut self) -> Result<(), Vec<u8>> {
        let user = self.vm().msg_sender();
        self.clear_auto_close_data(user);
        Ok(())
    }

    /// Forwarded `disableAutoClose`: trusted-forwarder-only, explicit `user`.
    #[selector(name = "disableAutoCloseFor")]
    pub fn disable_auto_close_for(&mut self, user: Address) -> Result<(), Vec<u8>> {
        let user = self.require_forwarder(user)?;
        self.clear_auto_close_data(user);
        Ok(())
    }

    /// Public `autoCloseUserPosition` — Solidity `perpAutoClose.autoCloseUserPosition`.
    /// A third party closes `user`'s position once their authorized PnL threshold is
    /// met, collecting `autoCloseFee`.
    #[selector(name = "autoCloseUserPosition")]
    pub fn auto_close_user_position(
        &mut self,
        user: Address,
        frontend_address: Address,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();
        self.auto_close_user_position_impl(caller, user, frontend_address, unverified_report)
    }

    /// Forwarded `autoCloseUserPosition`: trusted-forwarder-only, explicit
    /// `caller` (the auto-close fee recipient).
    #[selector(name = "autoCloseUserPositionFor")]
    pub fn auto_close_user_position_for(
        &mut self,
        caller: Address,
        user: Address,
        frontend_address: Address,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        let caller = self.require_forwarder(caller)?;
        self.auto_close_user_position_impl(caller, user, frontend_address, unverified_report)
    }

    /// OZ `AccessControl.hasRole(role, account)`.
    #[selector(name = "hasRole")]
    pub fn has_role_public(&self, role: B256, account: Address) -> Result<bool, Vec<u8>> {
        Ok(self.has_role(role, account))
    }

    /// OZ `AccessControl.grantRole(role, account)` — caller must hold the role's admin,
    /// which defaults to `DEFAULT_ADMIN_ROLE` (0x0) for every role.
    #[selector(name = "grantRole")]
    pub fn grant_role(&mut self, role: B256, account: Address) -> Result<(), Vec<u8>> {
        self.only_role(B256::ZERO)?;
        self.grant_role_internal(role, account);
        Ok(())
    }

    /// OZ `AccessControl.revokeRole(role, account)` — caller must hold the role's admin
    /// (`DEFAULT_ADMIN_ROLE`). Lets governance drop a granted role (e.g. a compromised
    /// MOD_ROLE holder).
    #[selector(name = "revokeRole")]
    pub fn revoke_role(&mut self, role: B256, account: Address) -> Result<(), Vec<u8>> {
        self.only_role(B256::ZERO)?;
        self.revoke_role_internal(role, account);
        Ok(())
    }

    /// OZ `AccessControl.renounceRole(role, callerConfirmation)` — an account drops its own
    /// role; `callerConfirmation` must equal the caller (OZ's foot-gun guard).
    #[selector(name = "renounceRole")]
    pub fn renounce_role(&mut self, role: B256, caller_confirmation: Address) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();
        if caller_confirmation != caller {
            return Err(err(b"ACB")); // AccessControlBadConfirmation
        }
        self.revoke_role_internal(role, caller);
        Ok(())
    }

    /// MOD_ROLE-gated: set the trusted forwarder for the explicit-sender `*For` entrypoints.
    #[selector(name = "setTrustedForwarder")]
    pub fn set_trusted_forwarder(&mut self, forwarder: Address) -> Result<(), Vec<u8>> {
        self.only_role(self.mod_role.get())?;
        let old = self.trusted_forwarder.get();
        self.trusted_forwarder.set(forwarder);
        self.emit(TrustedForwarderUpdated { oldForwarder: old, newForwarder: forwarder });
        Ok(())
    }

    /// OZ `isTrustedForwarder(forwarder)`.
    #[selector(name = "isTrustedForwarder")]
    pub fn is_trusted_forwarder(&self, forwarder: Address) -> Result<bool, Vec<u8>> {
        Ok(forwarder == self.trusted_forwarder.get())
    }

    /// Keeper-callable `updateFG` — Solidity `perpFunding.updateFG`: advance the funding
    /// rate to the current block even with no trade/close activity.
    #[selector(name = "updateFG")]
    pub fn update_fg_keeper(&mut self, unverified_report: Bytes) -> Result<(), Vec<u8>> {
        #[cfg(not(feature = "stub_boundary"))]
        {
            let oracle = IOracleMiddleware::new(self.oracle.get());
            let cfg = Call::new_mutating(self);
            oracle.verify_report_if_necessary(self.vm(), cfg, unverified_report.into())?;
        }
        #[cfg(feature = "stub_boundary")]
        let _ = unverified_report;

        #[cfg(not(feature = "stub_boundary"))]
        let price = {
            let oracle = IOracleMiddleware::new(self.oracle.get());
            cm::u(oracle.get_price(self.vm(), Call::new())?)
        };
        #[cfg(feature = "stub_boundary")]
        let price = U256::from(300_000_000_000u64);

        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        self.update_fg(price, last_op_ts)?;
        let block_ts = self.vm().block_timestamp();
        self.last_operation_timestamp.set(U64::from(block_ts));
        Ok(())
    }

    /// `perpConfig.prepareTimeLockedParameters` — MOD_ROLE-gated. Validates and arms a
    /// time-locked parameter change (stores the commit hash + unlock time).
    #[selector(name = "prepareTimeLockedParameters")]
    #[allow(clippy::too_many_arguments)]
    pub fn prepare_time_locked_parameters(
        &mut self,
        mmr: U256,
        trading_fee: U256,
        flat_trading_fee: U256,
        fee_lp: U256,
        liquidity_min_fee: U256,
        liquidity_max_fee: U256,
        liquidity_fee_k: U256,
        funding_c: U256,
        clamp_min_fr: U256,
        clamp_max_fr: U256,
        clamp_offset: U256,
        param_time_lock: U256,
        minimum_trade_size: U256,
    ) -> Result<(), Vec<u8>> {
        self.only_role(self.mod_role.get())?;
        let fee_frac_dec = self.fee_fractions_decimals.get();
        let trading_fee_dec = self.trading_fee_decimals.get();
        let one_e6 = U256::from(1_000_000u64);
        let one_e10 = U256::from(10_000_000_000u64);
        let wad = U256::from(WAD_U64);
        if !(mmr < one_e6
            && clamp_min_fr <= clamp_max_fr
            && fee_lp <= fee_frac_dec - U256::from(self.fee_frontend.get())
            && trading_fee < trading_fee_dec
            && flat_trading_fee * wad < (trading_fee_dec - trading_fee) * minimum_trade_size
            && liquidity_min_fee <= liquidity_max_fee
            && liquidity_max_fee <= one_e10)
        {
            return Err(err(b"C"));
        }
        // Solidity uses the CURRENT storage paramTimeLock for the lock duration; the
        // `param_time_lock` ARGUMENT is only hashed and stored later by setTimeLocked.
        let unlock = U64::from(self.vm().block_timestamp()) + self.param_time_lock.get();
        self.param_locked_until.set(unlock);
        let hash = self.time_locked_param_hash(
            mmr, trading_fee, flat_trading_fee, fee_lp, liquidity_min_fee, liquidity_max_fee,
            liquidity_fee_k, funding_c, clamp_min_fr, clamp_max_fr, clamp_offset, param_time_lock, minimum_trade_size,
        );
        self.param_hash.set(hash);
        self.emit(LockedParameterUpdate {
            paramLockedUntil: U256::from(unlock),
            _MMR: mmr,
            _tradingFee: trading_fee,
            _flatTradingFee: flat_trading_fee,
            _feeLP: fee_lp,
            _liquidityMinFee: liquidity_min_fee,
            _liquidityMaxFee: liquidity_max_fee,
            _liquidityFeeK: liquidity_fee_k,
            _fundingC: funding_c,
            _clampParams: ClampParameters { minFR: clamp_min_fr, maxFR: clamp_max_fr, offset: clamp_offset },
            _paramTimeLock: param_time_lock,
            _minimumTradeSize: minimum_trade_size,
        });
        Ok(())
    }

    /// `perpConfig.setTimeLockedParameters` — MOD_ROLE-gated. Applies a previously-armed
    /// change once the timelock elapses and the param hash matches.
    #[selector(name = "setTimeLockedParameters")]
    #[allow(clippy::too_many_arguments)]
    pub fn set_time_locked_parameters(
        &mut self,
        mmr: U256,
        trading_fee: U256,
        flat_trading_fee: U256,
        fee_lp: U256,
        liquidity_min_fee: U256,
        liquidity_max_fee: U256,
        liquidity_fee_k: U256,
        funding_c: U256,
        clamp_min_fr: U256,
        clamp_max_fr: U256,
        clamp_offset: U256,
        param_time_lock: U256,
        minimum_trade_size: U256,
    ) -> Result<(), Vec<u8>> {
        self.only_role(self.mod_role.get())?;
        let new_hash = self.time_locked_param_hash(
            mmr, trading_fee, flat_trading_fee, fee_lp, liquidity_min_fee, liquidity_max_fee,
            liquidity_fee_k, funding_c, clamp_min_fr, clamp_max_fr, clamp_offset, param_time_lock, minimum_trade_size,
        );
        if !(U256::from(self.vm().block_timestamp()) >= U256::from(self.param_locked_until.get())
            && new_hash == self.param_hash.get())
        {
            return Err(err(b"C"));
        }
        // Narrowing to the engine's packed storage REVERTS ("C") on out-of-range rather
        // than silently saturating (the require bounds mmr/feeLP; funding_c/paramTimeLock
        // are otherwise unbounded — Solidity stores uint256, the engine narrows, so an
        // un-storable value reverts instead of being silently clamped).
        self.mmr.set(U32::from(u32::try_from(mmr).map_err(|_| err(b"C"))?));
        self.fee_lp.set(U32::from(u32::try_from(fee_lp).map_err(|_| err(b"C"))?));
        self.flat_trading_fee.set(flat_trading_fee);
        self.trading_fee.set(trading_fee);
        self.liquidity_min_fee.set(liquidity_min_fee);
        self.liquidity_max_fee.set(liquidity_max_fee);
        self.liquidity_fee_k.set(liquidity_fee_k);
        self.funding_c.set(U32::from(u32::try_from(funding_c).map_err(|_| err(b"C"))?));
        self.clamp_min_fr.set(clamp_min_fr);
        self.clamp_max_fr.set(clamp_max_fr);
        self.clamp_offset.set(clamp_offset);
        self.param_time_lock.set(U64::from(u64::try_from(param_time_lock).map_err(|_| err(b"C"))?));
        self.minimum_trade_size.set(minimum_trade_size);
        Ok(())
    }

    /// `perpConfig.setUnguardedParameters` — MOD_ROLE-gated. Sets the non-time-locked
    /// parameters directly.
    #[selector(name = "setUnguardedParameters")]
    #[allow(clippy::too_many_arguments)]
    pub fn set_unguarded_parameters(
        &mut self,
        oracle: Address,
        fee_frontend: U32,
        fee_protocol_addr: Address,
        insurance_fund_cap: U256,
        max_leverage: U8,
        liquidation_discount: U32,
        max_lp_leverage: U8,
        slip_liquidation_th: U8,
    ) -> Result<(), Vec<u8>> {
        self.only_role(self.mod_role.get())?;
        let fee_frac_dec = self.fee_fractions_decimals.get();
        if !(oracle != Address::ZERO
            && U256::from(fee_frontend) <= fee_frac_dec - U256::from(self.fee_lp.get())
            && U256::from(liquidation_discount) < U256::from(500_000u64) // 1e6/2
            && self.fee_protocol_addr.get() != Address::ZERO)
        {
            return Err(err(b"C"));
        }
        self.oracle.set(oracle);
        self.insurance_fund_cap.set(insurance_fund_cap);
        self.fee_frontend.set(fee_frontend);
        self.fee_protocol_addr.set(fee_protocol_addr);
        self.liquidation_discount.set(liquidation_discount);
        self.max_leverage.set(max_leverage);
        self.max_lp_leverage.set(max_lp_leverage);
        self.slip_liquidation_th.set(slip_liquidation_th);
        self.emit(ParametersUpdated {
            _oracle: oracle,
            _feeFrontend: U256::from(fee_frontend),
            _feeProtocolAddr: fee_protocol_addr,
            _insuranceFundCap: insurance_fund_cap,
            _maxLeverage: U256::from(max_leverage),
            _liquidationDiscount: U256::from(liquidation_discount),
        });
        Ok(())
    }

    // ----------------------------------------------------------------------
    // Public view getters — Solidity-surface parity for the off-chain/manager
    // read paths (`internalPerpLogic.getLpLiquidityBalance`/`calcPnL`,
    // `perpFunding.getPrice`, `PerpStorage.ReadParameters`). These were private
    // helpers; thin `#[public]` wrappers expose them so the production-topology
    // manager's `modifyLiquidityPosition`/`takeProfitRemoveCollateral` bundlers
    // can read engine state. Read-only (`&self`); no state change.
    // ----------------------------------------------------------------------

    /// `internalPerpLogic.getLpLiquidityBalance(user)` → (lpStable, lpAsset).
    #[selector(name = "getLpLiquidityBalance")]
    pub fn get_lp_liquidity_balance_public(&self, user: Address) -> Result<(U256, U256), Vec<u8>> {
        Ok(self.get_lp_liquidity_balance(user))
    }

    /// `perpFunding.getPrice()` → `SafeCast.toUint256(oracle.getPrice())`.
    #[selector(name = "getPrice")]
    pub fn get_price(&self) -> Result<U256, Vec<u8>> {
        #[cfg(not(feature = "stub_boundary"))]
        {
            let oracle = IOracleMiddleware::new(self.oracle.get());
            Ok(cm::u(oracle.get_price(self.vm(), Call::new())?))
        }
        #[cfg(feature = "stub_boundary")]
        Ok(U256::from(300_000_000_000u64))
    }

    /// `internalPerpLogic.calcPnL(user, price)` (close-path, `useSpotPrice=false`)
    /// → (pnl, pnlSign). `price` is the oracle price supplied by the caller.
    #[selector(name = "calcPnL")]
    pub fn calc_pnl_public(&self, user: Address, price: U256) -> Result<(U256, bool), Vec<u8>> {
        self.calc_pnl_user(user, price)
    }

    /// `PerpStorage.ReadParameters()` → the 8-field config tuple
    /// (vault, oracle, minimumTradeSize, minimumLiquidityMovement, feeFrontend,
    /// feeLP, insuranceFundCap, tickerAssetCurrency). Bit-exact field order.
    #[selector(name = "ReadParameters")]
    pub fn read_parameters(
        &self,
    ) -> Result<(Address, Address, U256, U256, U256, U256, U256, B256), Vec<u8>> {
        Ok((
            self.vault.get(),
            self.oracle.get(),
            self.minimum_trade_size.get(),
            self.minimum_liquidity_movement.get(),
            U256::from(self.fee_frontend.get()),
            U256::from(self.fee_lp.get()),
            self.insurance_fund_cap.get(),
            self.ticker_asset_currency.get(),
        ))
    }

    // ----------------------------------------------------------------------
    // Vault-integration getters. The Solidity `Vault` reads these from `perpPair`
    // in `updateSnapshot` (every add/removeCollateral) and in the collateral-removal
    // safety check. They match the Solidity public-storage auto-getter selectors, so
    // the engine is a drop-in for the Vault.
    // ----------------------------------------------------------------------

    /// `lastOperationTimestamp()` — read by `Vault.updateSnapshot` (and removeCollateral).
    #[selector(name = "lastOperationTimestamp")]
    pub fn last_operation_timestamp_public(&self) -> Result<U256, Vec<u8>> {
        Ok(U256::from(self.last_operation_timestamp.get()))
    }

    /// `MMR()` — the maintenance-margin ratio (Vault collateral-removal check).
    #[selector(name = "MMR")]
    pub fn mmr_public(&self) -> Result<U256, Vec<u8>> {
        Ok(U256::from(self.mmr.get()))
    }

    /// `maxLpLeverage()` — the LP leverage cap (Vault collateral-removal check).
    #[selector(name = "maxLpLeverage")]
    pub fn max_lp_leverage_public(&self) -> Result<U256, Vec<u8>> {
        Ok(U256::from(self.max_lp_leverage.get()))
    }

    /// `userVirtualTraderPosition(user)` — the 8-field struct auto-getter shape the Vault
    /// decodes: (balanceStable, balanceAsset, debtStable, debtAsset, fundingFee,
    /// fundingFeeSign, initialFundingRate, initialFundingRateSign).
    #[selector(name = "userVirtualTraderPosition")]
    pub fn user_virtual_trader_position_public(
        &self,
        user: Address,
    ) -> Result<(U256, U256, U256, U256, U256, bool, U256, bool), Vec<u8>> {
        let p = self.user_virtual_trader_position.getter(user);
        Ok((
            p.balance_stable.get(),
            p.balance_asset.get(),
            p.debt_stable.get(),
            p.debt_asset.get(),
            p.funding_fee.get(),
            p.funding_fee_sign.get(),
            p.initial_funding_rate.get(),
            p.initial_funding_rate_sign.get(),
        ))
    }

    /// `liquidityPosition(user)` — the value-type fields the Solidity auto-getter returns
    /// (the `int256[2][2]`/`int256[2]` arrays are omitted): (initialStableBalance,
    /// initialAssetBalance, debtStable, debtAsset).
    #[selector(name = "liquidityPosition")]
    pub fn liquidity_position_public(&self, user: Address) -> Result<(U256, U256, U256, U256), Vec<u8>> {
        let lp = self.liquidity_position.getter(user);
        Ok((
            lp.initial_stable_balance.get(),
            lp.initial_asset_balance.get(),
            lp.debt_stable.get(),
            lp.debt_asset.get(),
        ))
    }

    // ----------------------------------------------------------------------
    // Legacy read parity (front-end support). These views are public on the Solidity
    // `PerpPair` and are exposed here with their EXACT legacy signatures/selectors, so
    // front-ends only need the engine address. All are thin reads over existing
    // storage / internal funding helpers (no new logic); per-user collateral lives in
    // the Vault (`getUserTotalCollateral`).
    // ----------------------------------------------------------------------

    /// `ReadFees()` → (tradingFee, flatTradingFee, autoCloseFee, liquidityMinFee,
    /// liquidityMaxFee, liquidityFeeK, liquidationDiscount).
    #[selector(name = "ReadFees")]
    pub fn read_fees(&self) -> Result<(U256, U256, U256, U256, U256, U256, U256), Vec<u8>> {
        Ok((
            self.trading_fee.get(),
            self.flat_trading_fee.get(),
            self.auto_close_fee.get(),
            self.liquidity_min_fee.get(),
            self.liquidity_max_fee.get(),
            self.liquidity_fee_k.get(),
            U256::from(self.liquidation_discount.get()),
        ))
    }

    /// `ReadFundingParameters()` → (fundingC, fundingInterval).
    #[selector(name = "ReadFundingParameters")]
    pub fn read_funding_parameters(&self) -> Result<(U256, U256), Vec<u8>> {
        Ok((
            U256::from(self.funding_c.get()),
            U256::from(self.funding_interval.get()),
        ))
    }

    /// `ReadInsuranceFund()` → (insFund, insFundSign).
    #[selector(name = "ReadInsuranceFund")]
    pub fn read_insurance_fund(&self) -> Result<(U256, bool), Vec<u8>> {
        Ok((self.insurance_fund.get(), self.insurance_fund_sign.get()))
    }

    /// `fundingRateSign()` → the sign bit of the current funding rate (`fundingRate()` is
    /// already exposed).
    #[selector(name = "fundingRateSign")]
    pub fn funding_rate_sign_public(&self) -> Result<bool, Vec<u8>> {
        Ok(self.funding_rate_sign.get())
    }

    /// `curveParameters()` → the legacy `CurveParameters` struct tuple
    /// (shortCurveParameterA, shortCurveParameterB, longCurveParameterA,
    /// longCurveParameterB, lastCurveUpdate, curveUpdateInterval, lastTradeDirection,
    /// lastValidatedPrice). The a/b coefficients are immutable protocol constants
    /// (1e8/1e7, `init_protocol_constants`); fields [4..7] are the dynamic curve-update
    /// state mutated by trade/close. `lastCurveUpdate`/`curveUpdateInterval` are stored
    /// narrowed to u64 and widened to U256 here (value-identical). Read by the PWA/webapp
    /// close-position preview.
    #[selector(name = "curveParameters")]
    pub fn curve_parameters(
        &self,
    ) -> Result<(U256, U256, U256, U256, U256, U256, bool, U256), Vec<u8>> {
        Ok((
            self.short_curve_parameter_a.get(),
            self.short_curve_parameter_b.get(),
            self.long_curve_parameter_a.get(),
            self.long_curve_parameter_b.get(),
            U256::from(self.last_curve_update.get()),
            U256::from(self.curve_update_interval.get()),
            self.last_trade_direction.get(),
            self.last_validated_price.get(),
        ))
    }

    /// `totalTraderExposureSign()` → the sign bit of net trader exposure (`totalTraderExposure()`
    /// magnitude is already exposed). Dynamic state; not derivable off-chain. Read by the webapp.
    #[selector(name = "totalTraderExposureSign")]
    pub fn total_trader_exposure_sign_public(&self) -> Result<bool, Vec<u8>> {
        Ok(self.total_trader_exposure_sign.get())
    }

    /// `computeFundingRate(price, timestamp)` → (rate, rateSign). Thin view over the existing
    /// internal `compute_funding_rate` helper (no new logic). Read by the PWA/webapp funding UI.
    #[selector(name = "computeFundingRate")]
    pub fn compute_funding_rate_public(
        &self,
        price: U256,
        timestamp: U256,
    ) -> Result<(U256, bool), Vec<u8>> {
        self.compute_funding_rate(price, timestamp)
    }

    /// `_computeFundingFee(user, fundingRate, fundingRateSign)` → (fee, feeSign). Thin view over
    /// the existing internal `compute_funding_fee_with` helper. Read by the PWA/webapp.
    #[selector(name = "_computeFundingFee")]
    pub fn compute_funding_fee_with_public(
        &self,
        user: Address,
        funding_rate: U256,
        funding_rate_sign: bool,
    ) -> Result<(U256, bool), Vec<u8>> {
        Ok(self.compute_funding_fee_with(user, funding_rate, funding_rate_sign))
    }

    }

// Benchmark/test scaffolding — DELIBERATELY OUTSIDE the `#[public]` impl so it emits NO router
// selectors in any build, which keeps the deployed wasm within the cargo-stylus activation size
// limit. Compiled only under `cfg(test)` (native tests call these as direct methods) or
// `--features benchmark`; `initializeBenchmark`/`seedBenchmarkState` are therefore not part of
// the on-chain selector surface (these helpers do not touch the trade path, so trade gas is
// unchanged).
#[cfg(any(test, feature = "benchmark"))]
impl PerpEngine {
    /// Benchmark/test initializer (no Stylus `#[constructor]`; called post-deploy). Sets the
    /// fixed benchmark configuration; for a production deploy use `initializeProduction`.
    pub fn initialize_benchmark(
        &mut self,
        oracle: Address,
        vault: Address,
        fee_protocol_addr: Address,
    ) -> Result<(), Vec<u8>> {
        if self.initialized.get() {
            return Err(err(b"INIT"));
        }
        self.oracle.set(oracle);
        self.vault.set(vault);
        self.fee_protocol_addr.set(fee_protocol_addr);
        // Benchmark-hardcoded configurable fields (the fixed benchmark configuration).
        self.mmr.set(U32::from(40_000u32)); // (40*1e6)/1000
        self.fee_frontend.set(U32::from(300_000u32));
        self.fee_lp.set(U32::from(500_000u32));
        self.trading_fee.set(U256::ZERO);
        self.flat_trading_fee.set(U256::from(120_000_000_000_000_000u64)); // 0.12e18
        self.ema_param.set(U64::from(90_000_000u64));
        self.init_protocol_constants();
        self.finalize_init();
        Ok(())
    }

    /// Seeds the pool reserves for benchmarking (`PerpPair` has no such setter; reserves move
    /// only via `addLiquidity`). MOD_ROLE-gated so only governance can seed.
    pub fn seed_benchmark_state(
        &mut self,
        stable_liquidity: U256,
        asset_liquidity: U256,
    ) -> Result<(), Vec<u8>> {
        if !self.initialized.get() {
            return Err(err(b"S0"));
        }
        self.only_role(self.mod_role.get())?;
        self.global_liquidity_stable.set(stable_liquidity);
        self.global_liquidity_asset.set(asset_liquidity);
        Ok(())
    }
}

// -----------------------------------------------------------------------
// Funding — bit-exact port of src/perpModules/perpFunding.sol.
// Internal (engine-only) methods over the packed storage + shared UtilMath
// helpers. `cm::i` mirrors Solidity SafeCast.toInt256 (reverts >= 2^255).
// Narrowed config (oracle_decimals u64, funding_c u32, funding_interval u64)
// is widened to U256 before arithmetic, so results are value-identical.
// -----------------------------------------------------------------------
#[allow(dead_code)]
const WAD_U64: u64 = 1_000_000_000_000_000_000;

/// Encode a revert `code` as Solidity-standard `Error(string)` ABI revert data
/// (selector `0x08c379a0` + `abi.encode(string)`), so block explorers (Arbitrum Sepolia
/// scan) and industry tooling (ethers/viem/foundry) decode the revert reason — exactly as
/// a Solidity `require(false, "<code>")` would. The short codes
/// (T0/C0/L*/SET*/AC/F/…) are unchanged; only the on-chain encoding is standardized. All
/// codes are ≤ 32 bytes, so the string occupies a single ABI word.
fn err(code: &[u8]) -> Vec<u8> {
    debug_assert!(code.len() <= 32, "revert code must fit one ABI word");
    let mut out = Vec::with_capacity(4 + 32 * 3);
    out.extend_from_slice(&[0x08, 0xc3, 0x79, 0xa0]); // keccak256("Error(string)")[..4]
    let mut offset = [0u8; 32];
    offset[31] = 0x20; // string data offset = 32
    out.extend_from_slice(&offset);
    let mut len = [0u8; 32];
    len[24..32].copy_from_slice(&(code.len() as u64).to_be_bytes());
    out.extend_from_slice(&len);
    let mut data = [0u8; 32];
    data[..code.len()].copy_from_slice(code); // right-padded to 32
    out.extend_from_slice(&data);
    out
}


// Implementation helpers split per domain. Each is a `use super::*` +
// `impl PerpEngine` of `pub(crate)` methods; the single `#[public]` impl above + the
// `#[entrypoint]` storage stay here (Stylus requires one of each).
mod access_control;
mod auto_close;
mod close;
mod config;
mod funding;
mod internal_logic;
mod liquidation;
mod liquidity;
mod trade;

#[cfg(test)]
mod tests;
