//! Liquidation orchestration + per-side helpers + collateral transfers. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Shared `liquidate` body (EOA + forwarded) parameterized by the `liquidator`.
    /// Port of `perpLiquidation.liquidate`.
    pub(crate) fn liquidate_impl(
        &mut self,
        liquidator: Address,
        user: Address,
        liquidated_position_size: U256,
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
        let price = U256::from(300_000_000_000u64);

        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        self.update_fg(price, last_op_ts)?;

        let collateral_user: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral_user = vault.user_collateral(self.vm(), Call::new(), user)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral_user = U256::from(1_000u64) * U256::from(WAD_U64);
        }

        let margin_ratio = self.calc_mr(user, price, collateral_user, last_op_ts)?;

        // PnL snapshot for the LiquidatedUser event (deltaPnl = pnlBefore - pnlAfter).
        let (pnl_before, pnl_before_sign) = self.calc_pnl_user(user, price)?;

        // Funding fee for the liquidator, then the user.
        let (lff, lffs) = self.compute_funding_fee(liquidator);
        {
            let mut lqp = self.user_virtual_trader_position.setter(liquidator);
            let (nff, nffs) =
                cm::signed_sum(lqp.funding_fee.get(), lqp.funding_fee_sign.get(), lff, lffs);
            lqp.funding_fee.set(nff);
            lqp.funding_fee_sign.set(nffs);
        }
        let (uff, uffs) = self.compute_funding_fee(user);
        {
            let mut up = self.user_virtual_trader_position.setter(user);
            let (nff, nffs) =
                cm::signed_sum(up.funding_fee.get(), up.funding_fee_sign.get(), uff, uffs);
            up.funding_fee.set(nff);
            up.funding_fee_sign.set(nffs);
        }

        let block_ts = self.vm().block_timestamp();
        self.last_operation_timestamp.set(U64::from(block_ts));

        let (stable_liq, asset_liq) = self.get_lp_liquidity_balance(user);
        let lp_debt_asset = self.liquidity_position.getter(user).debt_asset.get();
        let liq_dec = self.liquidation_decimals.get();
        let up_balance_asset = self.user_virtual_trader_position.getter(user).balance_asset.get();
        let up_debt_asset = self.user_virtual_trader_position.getter(user).debt_asset.get();
        let denom = cm::util_diff_abs(asset_liq + up_balance_asset, up_debt_asset + lp_debt_asset);
        let fraction = liquidated_position_size * liq_dec / denom;
        let exposition_side = (asset_liq + up_balance_asset) > (up_debt_asset + lp_debt_asset);
        if stable_liq != U256::ZERO || asset_liq != U256::ZERO {
            self.remove_liquidity(
                stable_liq * fraction / liq_dec, asset_liq * fraction / liq_dec, user, price, U256::ZERO,
            )?;
        }

        let mmr = U256::from(self.mmr.get());
        if margin_ratio <= mmr / U256::from(2u64) {
            if !(fraction <= liq_dec) {
                return Err(err(b"LQ1"));
            }
        } else if margin_ratio <= mmr {
            if !(fraction <= liq_dec / U256::from(2u64)) {
                return Err(err(b"LQ1"));
            }
        } else {
            return Err(err(b"LQ1"));
        }

        let discount = self.compute_liquidation_discount(margin_ratio);
        self.liquidate_position(liquidated_position_size, user, discount, exposition_side, liquidator, price, collateral_user)?;

        // Snapshots for user and liquidator.
        let fr = self.funding_rate.get();
        let frs = self.funding_rate_sign.get();
        {
            let mut up = self.user_virtual_trader_position.setter(user);
            up.initial_funding_rate.set(fr);
            up.initial_funding_rate_sign.set(frs);
        }
        {
            let mut lqp = self.user_virtual_trader_position.setter(liquidator);
            lqp.initial_funding_rate.set(fr);
            lqp.initial_funding_rate_sign.set(frs);
        }

        // LQ2: the liquidator must remain healthy.
        let collateral_liquidator: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral_liquidator = vault.user_collateral(self.vm(), Call::new(), liquidator)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral_liquidator = U256::from(1_000u64) * U256::from(WAD_U64);
        }
        if !(self.calc_mr(liquidator, price, collateral_liquidator, U256::from(self.last_operation_timestamp.get()))? > mmr) {
            return Err(err(b"LQ2"));
        }

        // deltaPnl = signedSumToInt(pnlBefore, !pnlBeforeSign, pnlAfter, pnlAfterSign).
        let (pnl_after, pnl_after_sign) = self.calc_pnl_user(user, price)?;
        let liquidation_pnl = cm::signed_sum_to_int(pnl_before, !pnl_before_sign, pnl_after, pnl_after_sign);

        // Full liquidation: close the user out and sweep their collateral.
        if fraction == liq_dec {
            let (cpnl, cpnl_sign) = self.close_and_withdraw_inner(
                U256::from(100_000u64), U256::from(10_000_000_000u64), liquidator, user, price, collateral_user, false,
            )?;
            #[cfg(not(feature = "stub_boundary"))]
            {
                let vault = IVault::new(self.vault.get());
                let cfg = Call::new_mutating(self);
                vault.add_pnl_to_collateral(self.vm(), cfg, user, cpnl, cpnl_sign)?;
                let vault2 = IVault::new(self.vault.get());
                let cfg2 = Call::new_mutating(self);
                vault2.remove_all_collateral_for_user(self.vm(), cfg2, user)?;
            }
            #[cfg(feature = "stub_boundary")]
            let _ = (cpnl, cpnl_sign);
        }

        let oracle_dec = U256::from(self.oracle_decimals.get());
        let position_size = liquidated_position_size * price / oracle_dec;
        self.emit(LiquidatedUser {
            user,
            liquidator,
            fraction,
            liquidationFee: position_size * discount / liq_dec,
            positionSize: position_size,
            currentPrice: price,
            deltaPnl: liquidation_pnl,
            liquidationDirection: exposition_side,
        });
        self.entered.set(false);
        Ok(())
    }

    /// Solidity `perpLiquidation._computeLiquidationDiscount`: piecewise discount that
    /// grows as the margin ratio falls below MMR (steeper below MMR/2).
    pub(crate) fn compute_liquidation_discount(&self, margin_ratio: U256) -> U256 {
        let step1 = U256::from(self.mmr.get());
        let step0 = step1 / U256::from(2u64);
        let e10 = U256::from(10_000_000_000u64); // 1e10
        let liq_disc = U256::from(self.liquidation_discount.get());
        if margin_ratio <= step0 {
            liq_disc * (e10 + (step0 - margin_ratio) * e10 / step0) / e10
        } else {
            liq_disc / U256::from(2u64) * (e10 + (step1 - margin_ratio) * e10 / (step1 - step0)) / e10
        }
    }

    /// Solidity `perpLiquidation._liquidatePosition`: transfer `d_amount` of the
    /// liquidated position to the liquidator at a discount, routing the discount's
    /// insurance fraction through `assign_protocol_fee_filling_insurance`. `collateral`
    /// = `getCollateral(user)` (bad-debt check in the short branch; vault unchanged
    /// since `liquidate` read it). NOTE: the short branch uses the SHORT curve
    /// parameters in `_computeExactAmountInLong` — faithful to the Solidity source.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn liquidate_position(
        &mut self,
        d_amount: U256,
        user: Address,
        discount: U256,
        direction: bool,
        liquidator: Address,
        price: U256,
        collateral: U256,
    ) -> Result<(), Vec<u8>> {
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let liq_dec = self.liquidation_decimals.get();
        let ins_fund_fraction = U256::from(self.ins_fund_fraction.get());
        let slip_liq_th = U256::from(self.slip_liquidation_th.get());
        let curve_dec = U256::from(100_000_000u64); // 1e8

        if direction {
            let gs = self.global_liquidity_stable.get();
            let ga = self.global_liquidity_asset.get();
            let short_a = self.short_curve_parameter_a.get();
            let short_b = self.short_curve_parameter_b.get();
            let mut dy_prime = self.compute_short_return(d_amount, price, oracle_dec, gs, gs, ga, short_a, short_b);
            let slip = cm::calc_slip(dy_prime * oracle_dec / d_amount, price, curve_dec);
            if slip > slip_liq_th * self.avg_slippage_s.get() {
                dy_prime = d_amount * price / oracle_dec;
            }
            let dy = (liq_dec - discount) * dy_prime / liq_dec;
            let insurance_fraction = discount / ins_fund_fraction * dy_prime / liq_dec;
            {
                let mut up = self.user_virtual_trader_position.setter(user);
                let ba = up.balance_asset.get();
                up.balance_asset.set(ba - d_amount);
            }
            {
                let mut lqp = self.user_virtual_trader_position.setter(liquidator);
                let ba = lqp.balance_asset.get();
                lqp.balance_asset.set(ba + d_amount);
            }
            self.debit_stable(liquidator, dy);
            self.credit_stable_via_debt(user, dy);
            self.debit_stable(liquidator, insurance_fraction);
            self.assign_protocol_fee_filling_insurance(insurance_fraction, liquidator);
        } else {
            let dy_prime: U256;
            if d_amount > self.global_liquidity_asset.get() {
                dy_prime = d_amount * price / oracle_dec;
            } else {
                let gs = self.global_liquidity_stable.get();
                let ga = self.global_liquidity_asset.get();
                let short_a = self.short_curve_parameter_a.get();
                let short_b = self.short_curve_parameter_b.get();
                let exact_in = self.compute_exact_amount_in_long(d_amount, price, oracle_dec, gs, gs, ga, short_a, short_b);
                let (pnl0, pnl0_sign) = self.calc_pnl_user(user, price)?;
                let (pnl, pnl_sign) =
                    cm::signed_sum(pnl0, pnl0_sign, exact_in - d_amount * price / oracle_dec, false);
                let slip = cm::calc_slip(exact_in * oracle_dec / d_amount, price, curve_dec);
                if (pnl > collateral && !pnl_sign) || slip > slip_liq_th * self.avg_slippage_l.get() {
                    dy_prime = d_amount * price / oracle_dec;
                } else {
                    dy_prime = exact_in;
                }
            }
            let dy_second = (liq_dec + discount) * dy_prime / liq_dec;
            let insurance_fraction = discount / ins_fund_fraction * dy_prime / liq_dec;
            self.debit_stable(user, dy_second);
            {
                let mut lqp = self.user_virtual_trader_position.setter(liquidator);
                let bs = lqp.balance_stable.get();
                lqp.balance_stable.set(bs + dy_second);
            }
            self.debit_asset(liquidator, d_amount);
            self.credit_asset_via_debt(user, d_amount);
            self.debit_stable(liquidator, insurance_fraction);
            self.assign_protocol_fee_filling_insurance(insurance_fraction, liquidator);
        }
        Ok(())
    }

    /// `if balanceStable >= amount { balanceStable -= amount } else { debtStable +=
    /// amount - balanceStable; balanceStable = 0 }` — pay stable, overflow into debt.
    pub(crate) fn debit_stable(&mut self, user: Address, amount: U256) {
        let mut pos = self.user_virtual_trader_position.setter(user);
        let bs = pos.balance_stable.get();
        if bs >= amount {
            pos.balance_stable.set(bs - amount);
        } else {
            let ds = pos.debt_stable.get();
            pos.debt_stable.set(ds + (amount - bs));
            pos.balance_stable.set(U256::ZERO);
        }
    }

    /// `if debtStable >= amount { debtStable -= amount } else { balanceStable +=
    /// amount - debtStable; debtStable = 0 }` — receive stable, repay debt first.
    pub(crate) fn credit_stable_via_debt(&mut self, user: Address, amount: U256) {
        let mut pos = self.user_virtual_trader_position.setter(user);
        let ds = pos.debt_stable.get();
        if ds >= amount {
            pos.debt_stable.set(ds - amount);
        } else {
            let bs = pos.balance_stable.get();
            pos.balance_stable.set(bs + (amount - ds));
            pos.debt_stable.set(U256::ZERO);
        }
    }

    /// Asset analogue of `debit_stable`.
    pub(crate) fn debit_asset(&mut self, user: Address, amount: U256) {
        let mut pos = self.user_virtual_trader_position.setter(user);
        let ba = pos.balance_asset.get();
        if ba >= amount {
            pos.balance_asset.set(ba - amount);
        } else {
            let da = pos.debt_asset.get();
            pos.debt_asset.set(da + (amount - ba));
            pos.balance_asset.set(U256::ZERO);
        }
    }

    /// Asset analogue of `credit_stable_via_debt`.
    pub(crate) fn credit_asset_via_debt(&mut self, user: Address, amount: U256) {
        let mut pos = self.user_virtual_trader_position.setter(user);
        let da = pos.debt_asset.get();
        if da >= amount {
            pos.debt_asset.set(da - amount);
        } else {
            let ba = pos.balance_asset.get();
            pos.balance_asset.set(ba + (amount - da));
            pos.debt_asset.set(U256::ZERO);
        }
    }
}
