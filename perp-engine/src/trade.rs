//! Trade engine — bit-exact port of perpTrade.sol::_trade + the trade wrapper body. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    // --- Trade engine: bit-exact port of perpTrade.sol::_trade -------------
    // `_trade` hardcodes curveParameterDecimals = 1e8.
    pub(crate) fn compute_long_return(
        &self, size: U256, spot: U256, od: U256, guess: U256, stable: U256, asset: U256, a: U256, b: U256,
    ) -> U256 {
        cm::u(cm::compute_long_return_inner(
            cm::i(size), cm::i(spot), cm::i(od), cm::i(guess), cm::i(stable), cm::i(asset),
            cm::i(a), cm::i(b), cm::i(U256::from(100_000_000u64)),
        ))
    }

    pub(crate) fn compute_short_return(
        &self, size: U256, spot: U256, od: U256, guess: U256, stable: U256, asset: U256, a: U256, b: U256,
    ) -> U256 {
        cm::u(cm::compute_short_return_inner(
            cm::i(size), cm::i(spot), cm::i(od), cm::i(guess), cm::i(stable), cm::i(asset),
            cm::i(a), cm::i(b), cm::i(U256::from(100_000_000u64)),
        ))
    }

    /// Solidity `perpTrade._hasActiveCurveMemory`: is the curve window still open for this
    /// direction at this price? All four conditions must hold. The timestamp bound is non-strict
    /// on the active side, so a trade landing exactly on the interval boundary reuses the window.
    ///
    /// The fourth condition guards the base-frame reconstruction in `execute_trade` and the close
    /// path. Now that the 1/64 rule lets the accumulators survive an LP removal that shrinks the
    /// pool, a pool leg can fall under the accumulator it is netted against. In this release build
    /// `-` WRAPS, so `stable_liq - dy0` would silently yield an astronomically large pool leg and
    /// a catastrophically wrong price rather than reverting; this condition turns that state into
    /// a clean window reset. Note the pairing is the opposite of the naive one: a LONG nets against
    /// the STABLE leg, a SHORT against the ASSET leg.
    pub(crate) fn has_active_curve_memory(&self, direction: bool, price: U256) -> bool {
        let block_ts = U256::from(self.vm().block_timestamp());
        block_ts <= U256::from(self.last_curve_update.get()) + U256::from(self.curve_update_interval.get())
            && self.last_trade_direction.get() == direction
            && self.last_validated_price.get() == price
            && if direction {
                self.global_liquidity_stable.get() > self.dy0.get()
            } else {
                self.global_liquidity_asset.get() > self.dx0.get()
            }
    }

    /// Solidity `perpTrade.readCurveMemory`: the curve accumulators, but only while the window is
    /// genuinely open for `direction` at `price`; otherwise zero. A withdrawal preview has to quote
    /// against the same base pool frame a real close would see, and reading `dx0`/`dy0` raw would
    /// apply a stale window's accumulators to a fresh quote.
    ///
    /// Deliberately NOT on the `#[public]` surface: only the engine's own consolidated read
    /// consumes it, so a selector would cost ABI surface and WASM for nothing. The Solidity
    /// reference does expose it, for the differential harness.
    pub(crate) fn read_curve_memory(&self, direction: bool, price: U256) -> (U256, U256) {
        if self.has_active_curve_memory(direction, price) {
            (self.dx0.get(), self.dy0.get())
        } else {
            (U256::ZERO, U256::ZERO)
        }
    }

    /// Solidity `perpTrade._syncCurveMemory`: open a fresh curve window unless the current one is
    /// still active for this direction and price. The accumulators and the
    /// (update, direction, price) triple are only ever written together, here — the LP paths
    /// deliberately no longer touch the triple.
    pub(crate) fn sync_curve_memory(&mut self, direction: bool, price: U256) {
        if !self.has_active_curve_memory(direction, price) {
            self.last_curve_update.set(U64::from(self.vm().block_timestamp()));
            self.last_trade_direction.set(direction);
            self.last_validated_price.set(price);
            self.dy0.set(U256::ZERO);
            self.dx0.set(U256::ZERO);
        }
    }

    /// Solidity `_assignProtocolFeeFillingInsurance(fee, protocolAddr)`.
    pub(crate) fn assign_protocol_fee_filling_insurance(&mut self, fee: U256, protocol_addr: Address) {
        if self.insurance_fund_sign.get() {
            let current = self.insurance_fund.get();
            let cap = self.insurance_fund_cap.get();
            if current < cap {
                let cap_left = cap - current;
                if fee <= cap_left {
                    self.insurance_fund.set(current + fee);
                    return;
                }
                self.insurance_fund.set(cap);
                let mut pp = self.user_virtual_trader_position.setter(protocol_addr);
                let bal = pp.balance_stable.get();
                pp.balance_stable.set(bal + fee - cap_left);
                return;
            }
            let mut pp = self.user_virtual_trader_position.setter(protocol_addr);
            let bal = pp.balance_stable.get();
            pp.balance_stable.set(bal + fee);
            return;
        }
        let signed_capacity = self.insurance_fund_cap.get() + self.insurance_fund.get();
        if fee <= signed_capacity {
            let (v, s) = cm::signed_sum(self.insurance_fund.get(), self.insurance_fund_sign.get(), fee, true);
            self.insurance_fund.set(v);
            self.insurance_fund_sign.set(s);
            return;
        }
        let mut pp = self.user_virtual_trader_position.setter(protocol_addr);
        let bal = pp.balance_stable.get();
        pp.balance_stable.set(bal + fee - signed_capacity);
        self.insurance_fund.set(self.insurance_fund_cap.get());
        self.insurance_fund_sign.set(true);
    }

    /// Solidity `_trade(direction, size, minTradeReturn, initialGuess, frontendAddress, user, spotPrice)`.
    pub(crate) fn execute_trade(
        &mut self,
        direction: bool,
        size: U256,
        min_trade_return: U256,
        initial_guess: U256,
        frontend_address: Address,
        user: Address,
        spot_price: U256,
    ) -> Result<U256, Vec<u8>> {
        let zero = U256::ZERO;
        let stable_liq = self.global_liquidity_stable.get();
        let asset_liq = self.global_liquidity_asset.get();
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let fee_frontend = U256::from(self.fee_frontend.get());
        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        let block_ts_u64 = self.vm().block_timestamp();
        let block_ts = U256::from(block_ts_u64);

        let mut initial_guess = initial_guess;
        let mut trading_fee_amount: U256;
        let mut trade_return: U256;
        let mut short_total_trade_return = zero;

        let zero_slippage_return = if direction {
            cm::md(size, oracle_dec, spot_price)
        } else {
            cm::md(size, spot_price, oracle_dec)
        };

        self.sync_curve_memory(direction, spot_price);

        let trading_fee = self.trading_fee.get();
        let trading_fee_decimals = U256::from(1_000_000_000_000_000_000u64);
        let flat_trading_fee = self.flat_trading_fee.get();
        let fee_frac_dec = U256::from(1_000_000u64);
        let fee_lp = U256::from(self.fee_lp.get());
        let ema_param = U256::from(self.ema_param.get());

        if direction {
            if asset_liq <= zero_slippage_return {
                initial_guess = zero;
            } else if initial_guess > asset_liq || initial_guess < (asset_liq - zero_slippage_return) {
                initial_guess = asset_liq - zero_slippage_return;
            }

            trading_fee_amount = cm::md(size, trading_fee, trading_fee_decimals) + flat_trading_fee;
            if size > trading_fee_amount {
                let frontend_fee_part = cm::md(trading_fee_amount, fee_frontend, fee_frac_dec);
                let dy0 = self.dy0.get();
                let dx0 = self.dx0.get();
                let long_a = U256::from(100_000_000u64);
                let long_b = U256::from(10_000_000u64);
                if frontend_address == Address::ZERO {
                    let inp = size - (trading_fee_amount - frontend_fee_part) + dy0;
                    trade_return = self
                        .compute_long_return(inp, spot_price, oracle_dec, initial_guess, stable_liq - dy0, asset_liq + dx0, long_a, long_b)
                        - dx0;
                    self.dy0.set(dy0 + size - (trading_fee_amount - frontend_fee_part));
                } else {
                    let inp = size - trading_fee_amount + dy0;
                    trade_return = self
                        .compute_long_return(inp, spot_price, oracle_dec, initial_guess, stable_liq - dy0, asset_liq + dx0, long_a, long_b)
                        - dx0;
                    self.dy0.set(dy0 + size - trading_fee_amount);
                }
                if last_op_ts != block_ts {
                    let avg = self.avg_slippage_l.get();
                    self.avg_slippage_l.set(cm::calc_ema(
                        cm::md(size - trading_fee_amount, oracle_dec, trade_return),
                        spot_price,
                        oracle_dec,
                        avg,
                        ema_param,
                    ));
                }
                self.dx0.set(self.dx0.get() + trade_return);
            } else {
                trade_return = zero;
                trading_fee_amount = size;
            }
            if !(trade_return >= min_trade_return && trade_return <= zero_slippage_return) {
                return Err(err(b"T4"));
            }
        } else {
            if stable_liq <= zero_slippage_return {
                initial_guess = zero;
            } else if initial_guess > stable_liq || initial_guess < (stable_liq - zero_slippage_return) {
                initial_guess = stable_liq - cm::md(size, spot_price, oracle_dec);
            }

            let dx0 = self.dx0.get();
            let dy0 = self.dy0.get();
            let short_a = U256::from(100_000_000u64);
            let short_b = U256::from(10_000_000u64);
            // Priced as a SLICE against the window's base pool state, so splitting a short across
            // several transactions in one window cannot beat trading it whole. The helper nets the
            // already-consumed `dx0` internally, which is why the trailing `- dy0` is gone.
            short_total_trade_return = cm::compute_incremental_short_return(
                size,
                dx0,
                spot_price,
                oracle_dec,
                initial_guess + dy0,
                stable_liq + dy0,
                asset_liq - dx0,
                short_a,
                short_b,
                U256::from(100_000_000u64),
            )?;
            if last_op_ts != block_ts {
                let avg = self.avg_slippage_s.get();
                self.avg_slippage_s.set(cm::calc_ema(
                    cm::md(short_total_trade_return, oracle_dec, size),
                    spot_price,
                    oracle_dec,
                    avg,
                    ema_param,
                ));
            }
            self.dx0.set(dx0 + size);

            trading_fee_amount = cm::md(short_total_trade_return, trading_fee, trading_fee_decimals) + flat_trading_fee;
            if trading_fee_amount < short_total_trade_return {
                trade_return = short_total_trade_return - trading_fee_amount;
            } else {
                trading_fee_amount = short_total_trade_return;
                trade_return = zero;
            }
            if frontend_address == Address::ZERO {
                trade_return = trade_return + cm::md(trading_fee_amount, fee_frontend, fee_frac_dec);
            }
            if !(trade_return >= min_trade_return && trade_return <= zero_slippage_return) {
                return Err(err(b"T4"));
            }
        }

        if !(if direction { trade_return < asset_liq } else { trade_return < stable_liq }) {
            return Err(err(b"T5"));
        }

        self.update_fg(spot_price, last_op_ts)?;

        // Funding fee, snapshots, exposure and position update.
        let (local_ff, local_ff_sign) = self.compute_funding_fee(user)?;
        let cur_fr = self.funding_rate.get();
        let cur_fr_sign = self.funding_rate_sign.get();

        if direction {
            let (exp, exp_s) = cm::signed_sum(
                self.total_trader_exposure.get(), self.total_trader_exposure_sign.get(), trade_return, true,
            );
            self.total_trader_exposure.set(exp);
            self.total_trader_exposure_sign.set(exp_s);
        } else {
            let (exp, exp_s) = cm::signed_sum(
                self.total_trader_exposure.get(), self.total_trader_exposure_sign.get(), size, false,
            );
            self.total_trader_exposure.set(exp);
            self.total_trader_exposure_sign.set(exp_s);
        }

        // Re-baseline the LP funding snapshot against the user's own epoch (a no-op for a pure trader).
        self.refresh_lp_funding_snapshot(user);
        {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let (nff, nff_sign) =
                cm::signed_sum(pos.funding_fee.get(), pos.funding_fee_sign.get(), local_ff, local_ff_sign);
            pos.funding_fee.set(nff);
            pos.funding_fee_sign.set(nff_sign);
            pos.initial_funding_rate.set(cur_fr);
            pos.initial_funding_rate_sign.set(cur_fr_sign);
            if direction {
                let ba = pos.balance_asset.get();
                pos.balance_asset.set(ba + trade_return);
                let bs = pos.balance_stable.get();
                if size <= bs {
                    pos.balance_stable.set(bs - size);
                } else {
                    let ds = pos.debt_stable.get();
                    pos.debt_stable.set(ds + size - bs);
                    pos.balance_stable.set(zero);
                }
            } else {
                let bs = pos.balance_stable.get();
                pos.balance_stable.set(bs + trade_return);
                let ba = pos.balance_asset.get();
                if size <= ba {
                    pos.balance_asset.set(ba - size);
                } else {
                    let da = pos.debt_asset.get();
                    pos.debt_asset.set(da + size - ba);
                    pos.balance_asset.set(zero);
                }
            }
        }

        // Liquidity matrix M update.
        let liq_m_dec = self.liquidity_m_decimals.get();
        let liq_m_dec_u = cm::u(liq_m_dec);
        let fee_lp_share = cm::md(trading_fee_amount, fee_lp, fee_frac_dec);

        if direction {
            let mut adj_size = size - cm::md(trading_fee_amount, fee_frac_dec - fee_lp, fee_frac_dec);
            if frontend_address == Address::ZERO {
                adj_size = adj_size + cm::md(trading_fee_amount, fee_frontend, fee_frac_dec);
            }
            let a_y = cm::i(cm::md(adj_size, liq_m_dec_u, asset_liq));
            let a_x = cm::i(cm::md(trade_return, liq_m_dec_u, asset_liq));
            self.apply_liquidity_matrix_update(a_x, a_y, 0);
            self.global_liquidity_stable.set(self.global_liquidity_stable.get() + adj_size);
            self.global_liquidity_asset.set(self.global_liquidity_asset.get() - trade_return);
        } else {
            let net_return = short_total_trade_return - fee_lp_share;
            // Record the NET pool outflow, not the gross return: dy0 must be exactly the sum of the
            // `global_liquidity_stable` decrements over the window, so that `stable_liq + dy0`
            // reconstructs the window-start pool bit-exactly. Re-read from storage — the local
            // captured before the trade is stale by now.
            self.dy0.set(self.dy0.get() + net_return);
            let a_x = cm::i(cm::md(size, liq_m_dec_u, stable_liq));
            let a_y = cm::i(cm::md(net_return, liq_m_dec_u, stable_liq));
            self.apply_liquidity_matrix_update(a_x, a_y, 1);
            self.global_liquidity_stable.set(self.global_liquidity_stable.get() - net_return);
            self.global_liquidity_asset.set(self.global_liquidity_asset.get() + size);
        }

        let protocol_fee = cm::md(trading_fee_amount, fee_frac_dec - fee_lp - fee_frontend, fee_frac_dec);
        let protocol_addr = self.fee_protocol_addr.get();
        self.assign_protocol_fee_filling_insurance(protocol_fee, protocol_addr);
        if frontend_address != Address::ZERO {
            let mut fp = self.user_virtual_trader_position.setter(frontend_address);
            let bal = fp.balance_stable.get();
            fp.balance_stable.set(bal + cm::md(trading_fee_amount, fee_frontend, fee_frac_dec));
        }

        let wad = U256::from(WAD_U64);
        if !(self.global_liquidity_stable.get() >= wad
            && cm::md(self.global_liquidity_asset.get(), spot_price, U256::from(self.oracle_decimals.get())) >= wad)
        {
            return Err(err(b"T3"));
        }

        Ok(trade_return)
    }

    pub(crate) fn compute_exact_amount_in_long(
        &self, size: U256, spot: U256, od: U256, guess: U256, stable: U256, asset: U256, a: U256, b: U256,
    ) -> U256 {
        cm::u(cm::compute_exact_in_long_inner(
            cm::i(size), cm::i(spot), cm::i(od), cm::i(guess), cm::i(stable), cm::i(asset),
            cm::i(a), cm::i(b), cm::i(U256::from(100_000_000u64)),
        ))
    }

    /// Shared `trade` body (EOA + forwarded) parameterized by the acting `user`.
    /// Port of `perpTrade.trade`: verify -> leverage(T0) -> getPrice -> minTradeSize(T2)
    /// -> execute_trade -> T1 calcMR -> ExecutedTrade. External oracle/Vault calls gated
    /// behind `stub_boundary`.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn trade_impl(
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
        // Emergency breaker (H9c): while paused, block OPENING/INCREASING a position (new risk).
        // Close, liquidation, removeLiquidity, realizePnL, and auto-close bypass trade_impl (they
        // call execute_trade / close_and_withdraw_inner directly), so those de-risking and exit
        // paths stay LIVE — the granular control the audit asks for, not a blunt global pause.
        if self.trading_paused.get() {
            return Err(err(b"PAUSED"));
        }
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

        if U256::from(leverage) > U256::from(self.max_leverage.get()) {
            return Err(err(b"T0"));
        }

        #[cfg(not(feature = "stub_boundary"))]
        let spot_price_signed = {
            let oracle = IOracleMiddleware::new(self.oracle.get());
            oracle.get_price(self.vm(), Call::new())?
        };
        #[cfg(feature = "stub_boundary")]
        let spot_price_signed = cm::i(U256::from(300_000_000_000u64)); // 3000 * 1e8

        // SafeCast.toUint256 (reverts on negative; price 0 allowed but reverts downstream).
        let spot_price = cm::u(spot_price_signed);

        let size_ok = if direction {
            size >= self.minimum_trade_size.get()
        } else {
            cm::md(size, spot_price, U256::from(self.oracle_decimals.get())) >= self.minimum_trade_size.get()
        };
        if !size_ok {
            return Err(err(b"T2"));
        }

        let trade_return =
            self.execute_trade(direction, size, min_trade_return, initial_guess, frontend_address, user, spot_price)?;

        // T1: real calcMR(...) > MMR (collateral from the live Vault, stubbed in tests).
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
        if !(self.calc_mr(user, spot_price, collateral, U256::from(self.last_operation_timestamp.get()))?
            > U256::from(self.mmr.get()))
        {
            return Err(err(b"T1"));
        }

        self.emit(ExecutedTrade {
            user,
            direction,
            tradeSize: size,
            tradeReturn: trade_return,
            currentPrice: spot_price,
            leverage: U256::from(leverage),
        });
        self.entered.set(false);
        Ok(trade_return)
    }
}
