//! Close path (closeAndWithdraw) + realizePnL body + position clears. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Solidity `perpTrade._closeAndWithdraw`: repay all LP + asset + stable
    /// debt, realize PnL to collateral. `is_self_close` carries Solidity's
    /// `_msgSender() == user` (true for the public entrypoint; the liquidation
    /// path passes false). `collateral` = `getCollateral(user)` (read once; the
    /// vault is not mutated until the final `addPnlToCollateral`). Returns the
    /// realized `(pnl, pnlSign)` so the public wrapper can forward it to the vault.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn close_and_withdraw_inner(
        &mut self,
        max_slippage: U256,
        max_liq_fee: U256,
        frontend_address: Address,
        user: Address,
        price: U256,
        collateral: U256,
        is_self_close: bool,
    ) -> Result<(U256, bool), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let dust = U256::from(10_000_000_000u64); // 1e10
        let bps = U256::from(100_000u64); // 1e5

        let (lp_stable_balance, lp_asset_balance) = self.get_lp_liquidity_balance(user);

        let lp_debt_asset_init = self.liquidity_position.getter(user).debt_asset.get();
        let lp_debt_stable_init = self.liquidity_position.getter(user).debt_stable.get();
        if (lp_stable_balance | lp_asset_balance | lp_debt_asset_init | lp_debt_stable_init) != U256::ZERO {
            self.remove_liquidity(lp_stable_balance, lp_asset_balance, user, price, max_liq_fee)?;
            let asset_debt_lp = self.liquidity_position.getter(user).debt_asset.get();
            let stable_debt_lp = self.liquidity_position.getter(user).debt_stable.get();
            {
                let mut pos = self.user_virtual_trader_position.setter(user);
                let cur_da = pos.debt_asset.get();
                pos.debt_asset.set(cur_da + asset_debt_lp);
                let cur_ds = pos.debt_stable.get();
                pos.debt_stable.set(cur_ds + stable_debt_lp);
            }
            if asset_debt_lp > U256::ZERO {
                if !self.total_trader_exposure_sign.get() {
                    self.total_trader_exposure.set(self.total_trader_exposure.get() + asset_debt_lp);
                } else {
                    let tte = self.total_trader_exposure.get();
                    self.total_trader_exposure_sign.set(tte > asset_debt_lp);
                    self.total_trader_exposure.set(cm::util_diff_abs(tte, asset_debt_lp));
                }
            }
        }
        self.clear_liquidity_position(user);

        let ba = self.user_virtual_trader_position.getter(user).balance_asset.get();
        let da = self.user_virtual_trader_position.getter(user).debt_asset.get();
        if cm::md(cm::util_diff_abs(ba, da), price, oracle_dec) < dust {
            self.user_virtual_trader_position.setter(user).balance_asset.set(da);
        } else {
            if ba > da {
                {
                    let mut pos = self.user_virtual_trader_position.setter(user);
                    pos.balance_asset.set(ba - da);
                    pos.debt_asset.set(U256::ZERO);
                }
                let input_size = ba - da;
                let min_trade_return = cm::md(cm::md(input_size, price, oracle_dec), bps - max_slippage, bps);
                let init_guess = self.global_liquidity_stable.get();
                let tr = self.execute_trade(false, input_size, min_trade_return, init_guess, frontend_address, user, price)?;
                self.emit(ExecutedTrade {
                    user, direction: false, tradeSize: input_size, tradeReturn: tr, currentPrice: price, leverage: U256::ZERO,
                });
            } else {
                let mut pos = self.user_virtual_trader_position.setter(user);
                pos.debt_asset.set(da - ba);
                pos.balance_asset.set(U256::ZERO);
            }

            let da2 = self.user_virtual_trader_position.getter(user).debt_asset.get();
            if da2 > U256::ZERO {
                let block_ts = self.vm().block_timestamp();
                if U256::from(block_ts)
                    > U256::from(self.last_curve_update.get()) + U256::from(self.curve_update_interval.get())
                    || self.last_trade_direction.get() != true
                    || self.last_validated_price.get() != price
                {
                    self.last_curve_update.set(U64::from(block_ts));
                    self.last_trade_direction.set(true);
                    self.last_validated_price.set(price);
                    self.dy0.set(U256::ZERO);
                    self.dx0.set(U256::ZERO);
                }
                let dx0 = self.dx0.get();
                let dy0 = self.dy0.get();
                let gs = self.global_liquidity_stable.get();
                let ga = self.global_liquidity_asset.get();
                let long_a = U256::from(100_000_000u64);
                let long_b = U256::from(10_000_000u64);
                let flat_fee = self.flat_trading_fee.get();
                let trading_fee = self.trading_fee.get();
                let trading_fee_dec = U256::from(1_000_000_000_000_000_000u64);
                let exact_in = self.compute_exact_amount_in_long(da2 + dx0, price, oracle_dec, gs, gs, ga, long_a, long_b);
                let exact_amount_in = exact_in - dy0;
                let fee_frontend = U256::from(self.fee_frontend.get());
                let input_needed = if frontend_address == Address::ZERO && fee_frontend > U256::ZERO {
                    // Zero-frontend close: the forward trade rebates the frontend-fee share, so the
                    // buy-back gross-up must not charge it. Mirrors the Solidity two-term mulDiv-ceil.
                    let ratio_dec = self.fee_fractions_decimals.get();
                    let fee_charged_fraction = ratio_dec - fee_frontend;
                    let fee_denominator = trading_fee_dec * ratio_dec - trading_fee * fee_charged_fraction;
                    cm::md_ceil(exact_amount_in, trading_fee_dec * ratio_dec, fee_denominator)
                        + cm::md_ceil(flat_fee * fee_charged_fraction, trading_fee_dec, fee_denominator)
                } else {
                    cm::md(exact_amount_in + flat_fee, trading_fee_dec, trading_fee_dec - trading_fee)
                };
                let min_trade_return = cm::md(cm::md(input_needed, oracle_dec, price), bps - max_slippage, bps);
                let tr = self.execute_trade(true, input_needed, min_trade_return, ga, frontend_address, user, price)?;
                self.emit(ExecutedTrade {
                    user, direction: true, tradeSize: input_needed, tradeReturn: tr, currentPrice: price, leverage: U256::ZERO,
                });

                let ba3 = self.user_virtual_trader_position.getter(user).balance_asset.get();
                let da3 = self.user_virtual_trader_position.getter(user).debt_asset.get();
                // Bit-exact mirror of perpTrade.sol "C0": max(1e10 floor,
                // globalLiquidityStable / 1e10) — the inversion residual envelope scales
                // with pool depth. global_liquidity_stable is read AFTER the buy-back
                // trade, like the Solidity storage read inside the require.
                let dust_bound = dust.max(self.global_liquidity_stable.get() / dust);
                if !(cm::md(cm::util_diff_abs(ba3, da3), price, oracle_dec) < dust_bound) {
                    return Err(err(b"C0"));
                }
            }
        }

        // Realize PnL (curve path), then reset the position.
        let (pnl, pnl_sign) = self.calc_pnl_user(user, price)?;

        if is_self_close && !pnl_sign && !(pnl < collateral) {
            return Err(err(b"C1"));
        }

        self.clear_virtual_trader_position(user);
        self.clear_auto_close_data(user, U256::ZERO);

        if collateral < pnl && !pnl_sign {
            let (ins, ins_s) = cm::signed_sum(
                self.insurance_fund.get(), self.insurance_fund_sign.get(), pnl - collateral, false,
            );
            self.insurance_fund.set(ins);
            self.insurance_fund_sign.set(ins_s);
        }
        self.emit(ClosedPosition { user, pnl, pnlSign: pnl_sign });
        Ok((pnl, pnl_sign))
    }

    /// Shared `closeAndWithdraw` body (EOA + forwarded) parameterized by `user`:
    /// guard + verify + getPrice + getCollateral + `close_and_withdraw_inner` +
    /// `addPnlToCollateral`. External calls gated behind `stub_boundary`.
    pub(crate) fn close_and_withdraw_outer(
        &mut self,
        user: Address,
        max_slippage: U256,
        max_liq_fee: U256,
        frontend_address: Address,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        if self.entered.get() {
            return Err(err(b"R"));
        }
        self.entered.set(true);

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
        let price = U256::from(300_000_000_000u64); // 3000 * 1e8

        // getCollateral(user) — read once (vault unchanged until addPnlToCollateral).
        let collateral: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral = vault.user_collateral(self.vm(), Call::new(), user)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral = U256::from(1_000u64) * U256::from(WAD_U64); // mock vault default 1000e18
        }

        let (pnl, pnl_sign) =
            self.close_and_withdraw_inner(max_slippage, max_liq_fee, frontend_address, user, price, collateral, true)?;

        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            let cfg = Call::new_mutating(self);
            vault.add_pnl_to_collateral(self.vm(), cfg, user, pnl, pnl_sign)?;
        }
        #[cfg(feature = "stub_boundary")]
        let _ = (pnl, pnl_sign);

        self.entered.set(false);
        Ok(())
    }

    /// `delete userVirtualTraderPosition[user]` — zero the whole position.
    pub(crate) fn clear_virtual_trader_position(&mut self, user: Address) {
        let mut pos = self.user_virtual_trader_position.setter(user);
        pos.balance_stable.set(U256::ZERO);
        pos.balance_asset.set(U256::ZERO);
        pos.debt_stable.set(U256::ZERO);
        pos.debt_asset.set(U256::ZERO);
        pos.funding_fee.set(U256::ZERO);
        pos.funding_fee_sign.set(false);
        pos.initial_funding_rate.set(U256::ZERO);
        pos.initial_funding_rate_sign.set(false);
    }

    /// Shared `realizePnL` body (EOA + forwarded) parameterized by `user`.
    pub(crate) fn realize_pnl_outer(&mut self, user: Address, unverified_report: Bytes) -> Result<(U256, bool), Vec<u8>> {
        if self.entered.get() {
            return Err(err(b"R"));
        }
        self.entered.set(true);

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

        let (pnl, pnl_sign) = self.calc_pnl_user(user, price)?;

        let collateral: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral = vault.user_collateral(self.vm(), Call::new(), user)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral = U256::from(1_000u64) * U256::from(WAD_U64);
        }
        if !(pnl_sign || pnl < collateral) {
            return Err(err(b"R1"));
        }

        if !pnl_sign {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let ds = pos.debt_stable.get();
            if pnl < ds {
                pos.debt_stable.set(ds - pnl);
            } else {
                let bs = pos.balance_stable.get();
                pos.balance_stable.set(bs + (pnl - ds));
                pos.debt_stable.set(U256::ZERO);
            }
        } else {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let bs = pos.balance_stable.get();
            if pnl < bs {
                pos.balance_stable.set(bs - pnl);
            } else {
                let ds = pos.debt_stable.get();
                pos.debt_stable.set(ds + (pnl - bs));
                pos.balance_stable.set(U256::ZERO);
            }
        }

        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            let cfg = Call::new_mutating(self);
            vault.add_pnl_to_collateral(self.vm(), cfg, user, pnl, pnl_sign)?;
        }
        self.emit(RealizedPnL { user, pnl, pnlSign: pnl_sign });
        self.entered.set(false);
        Ok((pnl, pnl_sign))
    }
}
