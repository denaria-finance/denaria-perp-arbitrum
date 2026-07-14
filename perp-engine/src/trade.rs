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

        if block_ts > U256::from(self.last_curve_update.get()) + U256::from(self.curve_update_interval.get())
            || self.last_trade_direction.get() != direction
            || self.last_validated_price.get() != spot_price
        {
            self.last_curve_update.set(U64::from(block_ts_u64));
            self.last_trade_direction.set(direction);
            self.last_validated_price.set(spot_price);
            self.dy0.set(zero);
            self.dx0.set(zero);
        }

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
            short_total_trade_return = self
                .compute_short_return(size + dx0, spot_price, oracle_dec, initial_guess + dy0, stable_liq + dy0, asset_liq - dx0, short_a, short_b)
                - dy0;
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
            self.dy0.set(dy0 + short_total_trade_return);

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
        let g0 = self.matrix_row_g0.get();
        let g1 = self.matrix_row_g1.get();

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

        {
            let mut lp = self.liquidity_position.setter(user);
            lp.snapshot_g0.set(g0);
            lp.snapshot_g1.set(g1);
        }
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
            let m10 = self.liquidity_m10.get();
            let m11 = self.liquidity_m11.get();
            self.liquidity_m00.set(self.liquidity_m00.get() + a_y * m10 / liq_m_dec);
            self.liquidity_m01.set(self.liquidity_m01.get() + a_y * m11 / liq_m_dec);
            self.liquidity_m10.set(m10 - cm::div_ceil(a_x * m10, liq_m_dec));
            self.liquidity_m11.set(m11 - cm::div_ceil(a_x * m11, liq_m_dec));
            self.global_liquidity_stable.set(self.global_liquidity_stable.get() + adj_size);
            self.global_liquidity_asset.set(self.global_liquidity_asset.get() - trade_return);
        } else {
            let net_return = short_total_trade_return - fee_lp_share;
            let a_x = cm::i(cm::md(size, liq_m_dec_u, stable_liq));
            let a_y = cm::i(cm::md(net_return, liq_m_dec_u, stable_liq));
            let m00 = self.liquidity_m00.get();
            let m01 = self.liquidity_m01.get();
            self.liquidity_m10.set(self.liquidity_m10.get() + a_x * m00 / liq_m_dec);
            self.liquidity_m11.set(self.liquidity_m11.get() + a_x * m01 / liq_m_dec);
            self.liquidity_m00.set(m00 - cm::div_ceil(a_y * m00, liq_m_dec));
            self.liquidity_m01.set(m01 - cm::div_ceil(a_y * m01, liq_m_dec));
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
