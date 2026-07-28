//! LP-balance reconstruction, calcPnL, and calcMR (internalPerpLogic). Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Solidity `InternalPerpLogic.getLpLiquidityBalance(user)`:
    /// current LP balance = M(t) · adj(M(t0))·v(t0) / det(M(t0)), clamped to the pool.
    /// Reverts `MDET` on a corrupted (det ≤ 0) snapshot matrix, matching the reference.
    pub(crate) fn get_lp_liquidity_balance(&self, user: Address) -> Result<(U256, U256), Vec<u8>> {
        let lp = self.liquidity_position.getter(user);
        if lp.snapshot_m00.get() == I256::ZERO {
            return Ok((U256::ZERO, U256::ZERO));
        }
        // Recover against the LP's OWN accounting epoch matrix M(t); a retired/empty epoch yields (0,0).
        let epoch_id = self.liquidity_position_epoch.getter(user).get();
        let epoch = self.liquidity_epochs.getter(epoch_id);
        if epoch.liquidity_m00.get() == I256::ZERO {
            return Ok((U256::ZERO, U256::ZERO));
        }
        // Recover the balance from the RAW forward snapshot M(t0) via the adjugate (no stored
        // inverse). `recover_lp_balance_from_snapshot` reverts MDET when det(M(t0)) ≤ 0.
        let (stable_signed, asset_signed) = cm::recover_lp_balance_from_snapshot(
            epoch.liquidity_m00.get(), epoch.liquidity_m01.get(), epoch.liquidity_m10.get(), epoch.liquidity_m11.get(),
            lp.snapshot_m00.get(), lp.snapshot_m01.get(), lp.snapshot_m10.get(), lp.snapshot_m11.get(),
            lp.initial_stable_balance.get(),
            lp.initial_asset_balance.get(),
            self.liquidity_m_decimals.get(),
        )
        .map_err(|e| err(&e))?;
        // Clamp each signed recovery leg to the pool floor (0) before the U256 cast and the
        // global cap: an ill-conditioned M(t) can drive a leg negative, and `cm::u` reverts on a
        // negative I256. Mirrors Solidity `result > 0 ? uint256(result) : 0`.
        let mut lp_stable = cm::u_or_zero(stable_signed);
        let mut lp_asset = cm::u_or_zero(asset_signed);
        let gs = self.global_liquidity_stable.get();
        let ga = self.global_liquidity_asset.get();
        if lp_stable > gs {
            lp_stable = gs;
        }
        if lp_asset > ga {
            lp_asset = ga;
        }
        Ok((lp_stable, lp_asset))
    }

    /// Solidity `internalPerpLogic._settleFundingAndUpdateSnapshots`: crystallize the user's accrued
    /// funding fee into their virtual position, then migrate their LP snapshot to the current epoch.
    pub(crate) fn settle_funding_and_update_snapshots(&mut self, user: Address) -> Result<(), Vec<u8>> {
        let (lp_stable_balance, lp_asset_balance) = self.get_lp_liquidity_balance(user)?;

        let (local_ff, local_ff_sign) = self.compute_funding_fee(user)?;
        {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let (nff, nffs) =
                cm::signed_sum(pos.funding_fee.get(), pos.funding_fee_sign.get(), local_ff, local_ff_sign);
            pos.funding_fee.set(nff);
            pos.funding_fee_sign.set(nffs);
        }

        self.update_snapshots(user, lp_stable_balance, lp_asset_balance)
    }

    /// Solidity `UtilMath._calcPnL(...)`. `use_spot_price=true` (the calcMR path)
    /// values the residual asset at spot; `false` (the close path) routes it
    /// through the curve (`computeShortReturn` / `computeExactAmountInLong`).
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn calc_pnl(
        &self,
        balance_stable: U256,
        balance_asset: U256,
        debt_stable: U256,
        debt_asset: U256,
        funding_fee: U256,
        funding_fee_sign: bool,
        price: U256,
        oracle_dec: U256,
        use_spot_price: bool,
    ) -> Result<(U256, bool), Vec<u8>> {
        let (diff_stable, diff_stable_sign) = cm::signed_sum(balance_stable, true, debt_stable, false);
        let (diff_stable, diff_stable_sign) =
            cm::signed_sum(diff_stable, diff_stable_sign, funding_fee, !funding_fee_sign);
        let (diff_asset, diff_asset_sign) = cm::signed_sum(balance_asset, true, debt_asset, false);

        let mut short_return = U256::ZERO;
        let threshold = cm::md(U256::from(10_000_000_000_000u64), oracle_dec, price);
        if diff_asset > threshold {
            if use_spot_price {
                short_return = cm::md(diff_asset, price, oracle_dec);
            } else if diff_asset_sign {
                let ts = self.global_liquidity_stable.get();
                let ta = self.global_liquidity_asset.get();
                short_return = self.compute_short_return(
                    diff_asset, price, oracle_dec, ts, ts, ta,
                    U256::from(100_000_000u64), U256::from(10_000_000u64),
                );
            } else {
                let ts = self.global_liquidity_stable.get();
                let ta = self.global_liquidity_asset.get();
                // No pool-size guard: the executable quote values an output at or beyond the asset
                // side at spot. A hard revert here bricked every read that touched an oversized
                // short — PnL, margin ratio, health checks, liquidation eligibility.
                short_return = cm::compute_executable_amount_in_long(
                    diff_asset,
                    price,
                    oracle_dec,
                    ts,
                    ts,
                    ta,
                    U256::from(100_000_000u64),
                    U256::from(10_000_000u64),
                    U256::from(100_000_000u64),
                )?;
            }
        }
        Ok(cm::signed_sum(diff_stable, diff_stable_sign, short_return, diff_asset_sign))
    }

    /// Solidity `UtilMath.calcHypotheticalMR(...)` (with oracleDecimals 1e8,
    /// MMRDecimals 1e6 as calcMR passes). Returns the margin ratio (0 = bad debt,
    /// MMRDecimals = empty position).
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn calc_hypothetical_mr(
        &self,
        balance_stable: U256,
        balance_asset: U256,
        debt_stable: U256,
        debt_asset: U256,
        funding_fee: U256,
        funding_fee_sign: bool,
        price: U256,
        collateral: U256,
    ) -> Result<U256, Vec<u8>> {
        let oracle_dec = U256::from(100_000_000u64);
        let mmr_decimals = U256::from(1_000_000u64);
        let (pnl, pnl_sign) = self.calc_pnl(
            balance_stable, balance_asset, debt_stable, debt_asset, funding_fee, funding_fee_sign, price, oracle_dec, true,
        )?;
        let position_value = cm::md(cm::util_diff_abs(balance_asset, debt_asset), price, oracle_dec);
        let (tot_coll, tot_coll_sign) = cm::signed_sum(collateral, true, pnl, pnl_sign);
        if !tot_coll_sign && tot_coll != U256::ZERO {
            return Ok(U256::ZERO); // bad debt
        }
        if position_value == U256::ZERO {
            return Ok(mmr_decimals);
        }
        Ok(cm::md(tot_coll, mmr_decimals, position_value))
    }

    /// `withdrawalCheckData(user, price, hypotheticalCollateral)` — the Vault's whole
    /// collateral-withdrawal safety read in ONE cross-contract call: the FEE-INCLUSIVE exit PnL and
    /// whether the position stays margin-safe once `hypotheticalCollateral` is all that backs it.
    ///
    /// The old check valued the position at its mark and ignored what leaving actually costs — the
    /// trade exit fee, the LP removal fee, and the slippage of the closing curve — so a position
    /// could pass and still be unable to exit without going into bad debt. Everything is computed
    /// here rather than in the Vault, which would otherwise pay a boundary call per input.
    pub(crate) fn withdrawal_check_data(
        &self,
        user: Address,
        price: U256,
        hypothetical_collateral: U256,
    ) -> Result<(U256, bool, bool), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let (pnl, pnl_sign, position_value, exit_fee) = self.withdrawal_exit_preview(user, price)?;

        let (total_equity, total_equity_sign) = cm::signed_sum(hypothetical_collateral, true, pnl, pnl_sign);
        if !total_equity_sign && total_equity != U256::ZERO {
            return Ok((pnl, pnl_sign, false));
        }
        let mmr_dec = self.mmr_decimals.get();
        let mut calculated_mmr =
            if position_value == U256::ZERO { mmr_dec } else { cm::md(total_equity, mmr_dec, position_value) };

        let (lp_stable_balance, lp_asset_balance) = self.get_lp_liquidity_balance(user)?;
        let (bs, ba, ds, da) = {
            let vp = self.user_virtual_trader_position.getter(user);
            (vp.balance_stable.get(), vp.balance_asset.get(), vp.debt_stable.get(), vp.debt_asset.get())
        };
        let (lp_debt_stable, lp_debt_asset) = {
            let lp = self.liquidity_position.getter(user);
            (lp.debt_stable.get(), lp.debt_asset.get())
        };
        let debt_stable = if ds > bs { ds - bs } else { U256::ZERO };
        let debt_asset = if da > ba { da - ba } else { U256::ZERO };
        if lp_stable_balance + lp_asset_balance != U256::ZERO {
            // The exit fee is money the LP will not have once it leaves, so the leverage cap has to
            // be applied to what actually remains.
            let fee_adjusted =
                if hypothetical_collateral > exit_fee { hypothetical_collateral - exit_fee } else { U256::ZERO };
            if fee_adjusted * U256::from(self.max_lp_leverage.get())
                < debt_stable + lp_debt_stable + cm::md(debt_asset + lp_debt_asset, price, oracle_dec)
            {
                calculated_mmr = U256::ZERO;
            }
        }
        Ok((pnl, pnl_sign, calculated_mmr >= U256::from(self.mmr.get())))
    }

    /// Solidity `_withdrawalExitPreview`: aggregate the trader and LP legs, fold in funding accrued
    /// to THIS block and the LP removal fee, then price the exit through the closing curve.
    pub(crate) fn withdrawal_exit_preview(&self, user: Address, price: U256) -> Result<(U256, bool, U256, U256), Vec<u8>> {
        let (lp_stable_balance, lp_asset_balance) = self.get_lp_liquidity_balance(user)?;
        let (bs, ba, ds, da, pos_ff, pos_ff_sign) = {
            let vp = self.user_virtual_trader_position.getter(user);
            (
                vp.balance_stable.get(),
                vp.balance_asset.get(),
                vp.debt_stable.get(),
                vp.debt_asset.get(),
                vp.funding_fee.get(),
                vp.funding_fee_sign.get(),
            )
        };
        let (lp_debt_stable, lp_debt_asset) = {
            let lp = self.liquidity_position.getter(user);
            (lp.debt_stable.get(), lp.debt_asset.get())
        };

        let (local_ff, local_ff_sign) = self.compute_funding_fee(user)?;
        let (mut funding_fee, mut funding_fee_sign) = cm::signed_sum(pos_ff, pos_ff_sign, local_ff, local_ff_sign);

        // The removal fee is charged like a funding debit, so it lands on the same side of the fold.
        let lp_removal_fee = self.lp_removal_fee(price, lp_stable_balance, lp_asset_balance);
        if lp_removal_fee != U256::ZERO {
            let (f, fs) = cm::signed_sum(funding_fee, funding_fee_sign, lp_removal_fee, true);
            funding_fee = f;
            funding_fee_sign = fs;
        }

        let (pnl, pnl_sign, position_value, close_fee) = self.fee_inclusive_pnl(
            bs + lp_stable_balance,
            ba + lp_asset_balance,
            ds + lp_debt_stable,
            da + lp_debt_asset,
            funding_fee,
            funding_fee_sign,
            price,
        )?;
        Ok((pnl, pnl_sign, position_value, close_fee + lp_removal_fee))
    }

    /// Solidity `_lpRemovalFee`: what unwinding this LP position would cost, at the current pool.
    fn lp_removal_fee(&self, price: U256, lp_stable_balance: U256, lp_asset_balance: U256) -> U256 {
        if (lp_stable_balance | lp_asset_balance) == U256::ZERO {
            return U256::ZERO;
        }
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let fee_dec = self.liquidity_fee_decimals.get();
        let fee = cm::compute_liquidity_removal_fee(
            lp_stable_balance,
            lp_asset_balance,
            self.global_liquidity_stable.get(),
            self.global_liquidity_asset.get(),
            price,
            oracle_dec,
            self.liquidity_max_fee.get(),
            self.liquidity_min_fee.get(),
            self.liquidity_fee_k.get(),
            fee_dec,
        );
        cm::md(lp_stable_balance + cm::md(lp_asset_balance, price, oracle_dec), fee, fee_dec)
    }

    /// Solidity `_feeInclusivePnl`: PnL that already carries the cost of closing.
    #[allow(clippy::too_many_arguments)]
    fn fee_inclusive_pnl(
        &self,
        balance_stable: U256,
        balance_asset: U256,
        debt_stable: U256,
        debt_asset: U256,
        funding_fee: U256,
        funding_fee_sign: bool,
        price: U256,
    ) -> Result<(U256, bool, U256, U256), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let (diff_stable, diff_stable_sign) = cm::signed_sum(balance_stable, true, debt_stable, false);
        let (diff_stable, diff_stable_sign) =
            cm::signed_sum(diff_stable, diff_stable_sign, funding_fee, !funding_fee_sign);
        let (diff_asset, diff_asset_sign) = cm::signed_sum(balance_asset, true, debt_asset, false);
        let position_value = cm::md(diff_asset, price, oracle_dec);

        let mut stable_trade_value = U256::ZERO;
        let mut close_fee = U256::ZERO;
        // Dust cutoff: below this the exit is not worth pricing, and charging the FLAT trading fee
        // on a dust leg would invent a cost far larger than the leg itself.
        if diff_asset > cm::md(U256::from(10_000_000_000_000u64), oracle_dec, price) {
            let (v, f) = if diff_asset_sign {
                self.long_close_value(diff_asset, price)?
            } else {
                self.short_close_cost(diff_asset, price)?
            };
            stable_trade_value = v;
            close_fee = f;
        }

        let (pnl, pnl_sign) = cm::signed_sum(diff_stable, diff_stable_sign, stable_trade_value, diff_asset_sign);
        Ok((pnl, pnl_sign, position_value, close_fee))
    }

    /// Solidity `_longCloseValue`: selling a net-long asset leg is a SHORT trade, quoted against the
    /// short window's base pool frame so the preview sees the curve a real close would.
    fn long_close_value(&self, asset_size: U256, price: U256) -> Result<(U256, U256), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let stable_liquidity = self.global_liquidity_stable.get();
        let asset_liquidity = self.global_liquidity_asset.get();
        let (curve_dx, curve_dy) = self.read_curve_memory(false, price);
        let gross_return = cm::compute_incremental_short_return(
            asset_size,
            curve_dx,
            price,
            oracle_dec,
            stable_liquidity + curve_dy,
            stable_liquidity + curve_dy,
            asset_liquidity - curve_dx,
            U256::from(100_000_000u64),
            U256::from(10_000_000u64),
            U256::from(100_000_000u64),
        )?;
        let trading_fee_dec = U256::from(1_000_000_000_000_000_000u64);
        let close_fee = cm::md(gross_return, self.trading_fee.get(), trading_fee_dec) + self.flat_trading_fee.get();
        if close_fee < gross_return {
            return Ok((gross_return - close_fee, close_fee));
        }
        Ok((U256::ZERO, gross_return))
    }

    /// Solidity `_shortCloseCost`: buying back a net-short asset leg is a LONG trade. Same two-term
    /// ceil gross-up the close path uses, so the preview cannot quote a cheaper exit than the real one.
    fn short_close_cost(&self, asset_size: U256, price: U256) -> Result<(U256, U256), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let stable_liquidity = self.global_liquidity_stable.get();
        let asset_liquidity = self.global_liquidity_asset.get();
        // The quote short-circuits to a plain spot value when the buy-back would empty the asset leg
        // or leave a sub-unit pool; on those branches the answer bears no relation to dy0, and since
        // a long window's dy0 exceeds the spot value of its dx0 by the slippage premium, `- dy0`
        // would go negative — and WRAP, because release builds have overflow-checks off. This is the
        // close path's own guard (close.rs) in the same positive form: outside it there is no window
        // to unwind against, so the leg is priced at spot with no memory.
        let (curve_dx, curve_dy) = if asset_size < asset_liquidity
            && cm::md(asset_liquidity - asset_size, price, oracle_dec) >= U256::from(1_000_000_000_000_000_000u64)
        {
            self.read_curve_memory(true, price)
        } else {
            (U256::ZERO, U256::ZERO)
        };
        let raw_amount_in = cm::compute_executable_amount_in_long(
            asset_size + curve_dx,
            price,
            oracle_dec,
            stable_liquidity,
            stable_liquidity - curve_dy,
            asset_liquidity + curve_dx,
            U256::from(100_000_000u64),
            U256::from(10_000_000u64),
            U256::from(100_000_000u64),
        )?;
        // The guard makes this saturation unreachable; it is belt-and-braces against the wrap, and
        // it must NOT stand alone — saturating without the guard would understate the buy-back and
        // let an oversized short withdraw.
        let exact_amount_in = if raw_amount_in > curve_dy { raw_amount_in - curve_dy } else { U256::ZERO };
        let trading_fee_dec = U256::from(1_000_000_000_000_000_000u64);
        let fee_denominator = trading_fee_dec - self.trading_fee.get();
        let cost = cm::md_ceil(exact_amount_in, trading_fee_dec, fee_denominator)
            + cm::md_ceil(self.flat_trading_fee.get(), trading_fee_dec, fee_denominator);
        let close_fee = if cost > exact_amount_in { cost - exact_amount_in } else { U256::ZERO };
        Ok((cost, close_fee))
    }

    /// Shared body of the margin check: reads the position/LP state ONCE and returns the
    /// margin ratio together with the raw fields a caller's bad-debt override needs
    /// (position balances/debts, LP debts, LP balances). `calc_mr` and the public
    /// `margin_check_data` getter both build on this so they stay bit-identical.
    #[allow(clippy::type_complexity)]
    pub(crate) fn margin_check_core(
        &self,
        user: Address,
        price: U256,
        collateral: U256,
        last_op_ts: U256,
    ) -> Result<(U256, U256, U256, U256, U256, U256, U256, U256, U256), Vec<u8>> {
        let (stable_lp, asset_lp) = self.get_lp_liquidity_balance(user)?;

        let vp = self.user_virtual_trader_position.getter(user);
        let balance_stable = vp.balance_stable.get();
        let balance_asset = vp.balance_asset.get();
        let debt_stable = vp.debt_stable.get();
        let debt_asset = vp.debt_asset.get();
        let pos_funding_fee = vp.funding_fee.get();
        let pos_funding_fee_sign = vp.funding_fee_sign.get();

        let lp = self.liquidity_position.getter(user);
        let lp_debt_stable = lp.debt_stable.get();
        let lp_debt_asset = lp.debt_asset.get();

        let mut funding_rate = self.funding_rate.get();
        let mut funding_rate_sign = self.funding_rate_sign.get();
        let block_ts = U256::from(self.vm().block_timestamp());
        if last_op_ts != block_ts {
            let (nfr, nfr_sign) = self.compute_funding_rate(price, last_op_ts)?;
            let (fr, frs) = cm::signed_sum(funding_rate, funding_rate_sign, nfr, nfr_sign);
            funding_rate = fr;
            funding_rate_sign = frs;
        }
        let (local_ff, local_ff_sign) = self.compute_funding_fee_with(user, funding_rate, funding_rate_sign)?;
        let (funding_fee, funding_fee_sign) =
            cm::signed_sum(pos_funding_fee, pos_funding_fee_sign, local_ff, local_ff_sign);

        let mr = self.calc_hypothetical_mr(
            stable_lp + balance_stable,
            asset_lp + balance_asset,
            debt_stable + lp_debt_stable,
            debt_asset + lp_debt_asset,
            funding_fee,
            funding_fee_sign,
            price,
            collateral,
        )?;
        Ok((mr, balance_stable, balance_asset, debt_stable, debt_asset, lp_debt_stable, lp_debt_asset, stable_lp, asset_lp))
    }

    /// Solidity `UtilMath.calcMR(user, price, perpPair, collateral, lastOperationTimestamp)`.
    pub(crate) fn calc_mr(&self, user: Address, price: U256, collateral: U256, last_op_ts: U256) -> Result<U256, Vec<u8>> {
        Ok(self.margin_check_core(user, price, collateral, last_op_ts)?.0)
    }

    /// Solidity `Vault._checkMR`'s margin read in ONE WASM frame: the margin ratio plus the raw
    /// position/LP fields and `maxLpLeverage`/`MMR` its bad-debt override needs, instead of the
    /// ~12 separate cross-contract reads the Vault used to make. Reads `lastOperationTimestamp`
    /// internally, exactly as the Vault passed it before.
    #[allow(clippy::type_complexity)]
    pub(crate) fn margin_check_data(
        &self,
        user: Address,
        price: U256,
        collateral: U256,
    ) -> Result<(U256, U256, U256, U256, U256, U256, U256, U256, U256, U256, U256), Vec<u8>> {
        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        let (mr, bs, ba, ds, da, lpds, lpda, slp, alp) = self.margin_check_core(user, price, collateral, last_op_ts)?;
        Ok((mr, bs, ba, ds, da, lpds, lpda, slp, alp, U256::from(self.max_lp_leverage.get()), U256::from(self.mmr.get())))
    }

    /// Solidity `internalPerpLogic.calcPnL(user, price)` — the close-path PnL
    /// (curve valuation, no oversized-short spot fallback). Always recomputes the funding
    /// rate to `price` (no `block.timestamp` gate, unlike `calcMR`).
    pub(crate) fn calc_pnl_user(&self, user: Address, price: U256) -> Result<(U256, bool), Vec<u8>> {
        self.calc_pnl_user_internal(user, price, false)
    }

    /// Liquidation-only PnL. When the user is net-short by more than the pool can buy back
    /// (`totalDebtAsset - totalBalanceAsset > globalLiquidityAsset`), the position is valued
    /// at spot instead of on the curve, so an oversized short cannot make its own liquidation
    /// revert on insufficient pool liquidity. Solidity `_calcPnLLiquidationSafe`. The close,
    /// realize and auto-close paths deliberately keep the curve valuation (`calc_pnl_user`).
    pub(crate) fn calc_pnl_user_liquidation_safe(&self, user: Address, price: U256) -> Result<(U256, bool), Vec<u8>> {
        self.calc_pnl_user_internal(user, price, true)
    }

    /// Solidity `_calcPnLInternal(user, price, allowOversizedShortSpotFallback)`.
    fn calc_pnl_user_internal(
        &self,
        user: Address,
        price: U256,
        allow_oversized_short_spot_fallback: bool,
    ) -> Result<(U256, bool), Vec<u8>> {
        let (stable_lp, asset_lp) = self.get_lp_liquidity_balance(user)?;
        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        let (nfr, nfr_sign) = self.compute_funding_rate(price, last_op_ts)?;
        let (fr, frs) =
            cm::signed_sum(self.funding_rate.get(), self.funding_rate_sign.get(), nfr, nfr_sign);
        let (local_ff, local_ff_sign) = self.compute_funding_fee_with(user, fr, frs)?;

        let vp = self.user_virtual_trader_position.getter(user);
        let (funding_fee, funding_fee_sign) =
            cm::signed_sum(vp.funding_fee.get(), vp.funding_fee_sign.get(), local_ff, local_ff_sign);
        let lp = self.liquidity_position.getter(user);
        let oracle_dec = U256::from(self.oracle_decimals.get());

        // Oversized-short spot fallback (liquidation only): a net-short position larger than
        // the pool's asset liquidity cannot be bought back on the curve, so value it at spot.
        let total_balance_asset = vp.balance_asset.get() + asset_lp;
        let total_debt_asset = vp.debt_asset.get() + lp.debt_asset.get();
        // The pool boundary itself falls back to spot (`>=`), matching the two other boundaries in
        // this cluster: the exact-in early return and the executable quote's own spot guard. All
        // three must agree at exact equality, which is the degenerate zero-output cubic. The middle
        // comparison stays strict — it also guards the subtraction.
        let use_spot_price = allow_oversized_short_spot_fallback
            && total_debt_asset > total_balance_asset
            && total_debt_asset - total_balance_asset >= self.global_liquidity_asset.get();

        self.calc_pnl(
            vp.balance_stable.get() + stable_lp,
            vp.balance_asset.get() + asset_lp,
            vp.debt_stable.get() + lp.debt_stable.get(),
            vp.debt_asset.get() + lp.debt_asset.get(),
            funding_fee,
            funding_fee_sign,
            price,
            oracle_dec,
            use_spot_price,
        )
    }
}
