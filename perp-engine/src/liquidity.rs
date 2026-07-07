//! Add/remove liquidity (perpLiquidity) + the forwarded *_outer bodies. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Solidity `internalPerpLogic._updateSnapshots`: stamp the position's
    /// initial funding rate and the LP's matrix-row G + initial shares.
    pub(crate) fn update_snapshots(&mut self, user: Address, new_initial_stable: U256, new_initial_asset: U256) {
        let fr = self.funding_rate.get();
        let frs = self.funding_rate_sign.get();
        let g0 = self.matrix_row_g0.get();
        let g1 = self.matrix_row_g1.get();
        {
            let mut pos = self.user_virtual_trader_position.setter(user);
            pos.initial_funding_rate.set(fr);
            pos.initial_funding_rate_sign.set(frs);
        }
        {
            let mut lp = self.liquidity_position.setter(user);
            lp.snapshot_g0.set(g0);
            lp.snapshot_g1.set(g1);
            lp.initial_stable_balance.set(new_initial_stable);
            lp.initial_asset_balance.set(new_initial_asset);
        }
    }

    /// Solidity `perpLiquidity._distributeLiquidityFee`: split the removal fee
    /// between stable/asset LPs by updating the liquidity matrix row 0 and
    /// crediting the fee to global stable liquidity.
    pub(crate) fn distribute_liquidity_fee(&mut self, fee_value: U256, spot_price: U256) {
        let gs = self.global_liquidity_stable.get();
        let ga = self.global_liquidity_asset.get();
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let total_liq_value = gs + cm::md(ga, spot_price, oracle_dec);
        if fee_value > U256::ZERO && ga != U256::ZERO && gs != U256::ZERO && total_liq_value > U256::ZERO {
            let liq_m_dec = self.liquidity_m_decimals.get();
            let liq_m_dec_u = cm::u(liq_m_dec);
            let fee_stable = cm::md(fee_value, gs, total_liq_value);
            let a_x = cm::i(cm::md(fee_stable, liq_m_dec_u, gs));
            let a_y = cm::i(cm::md(fee_value - fee_stable, liq_m_dec_u, ga));
            let m00 = self.liquidity_m00.get();
            let m01 = self.liquidity_m01.get();
            let m10 = self.liquidity_m10.get();
            let m11 = self.liquidity_m11.get();
            self.liquidity_m00.set(m00 + (a_y * m10 + a_x * m00) / liq_m_dec);
            self.liquidity_m01.set(m01 + (a_y * m11 + a_x * m01) / liq_m_dec);
            self.global_liquidity_stable.set(gs + fee_value);
        }
    }

    /// Solidity `perpLiquidity._removeLiquidity`: pull `stable_to_remove`/
    /// `asset_to_remove` from the user's LP position back into their virtual
    /// trader balances, applying funding, the removal fee, LP-debt repayment
    /// (`reduceValue`) and exposure/curve bookkeeping. Bit-exact.
    pub(crate) fn remove_liquidity(
        &mut self,
        mut stable_to_remove: U256,
        mut asset_to_remove: U256,
        user: Address,
        spot_price: U256,
        max_fee_value: U256,
    ) -> Result<(), Vec<u8>> {
        let (lp_stable_balance, lp_asset_balance) = self.get_lp_liquidity_balance(user);
        if !(lp_stable_balance >= stable_to_remove && lp_asset_balance >= asset_to_remove) {
            return Err(err(b"L5"));
        }

        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        self.update_fg(spot_price, last_op_ts)?;

        let (local_ff, local_ff_sign) = self.compute_funding_fee(user);
        {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let (nff, nffs) =
                cm::signed_sum(pos.funding_fee.get(), pos.funding_fee_sign.get(), local_ff, local_ff_sign);
            pos.funding_fee.set(nff);
            pos.funding_fee_sign.set(nffs);
        }

        self.update_snapshots(user, lp_stable_balance - stable_to_remove, lp_asset_balance - asset_to_remove);

        let liq_m_dec = self.liquidity_m_decimals.get();
        let (inv00, inv01, inv10, inv11) = cm::mat_inverse_2x2(
            self.liquidity_m00.get(), self.liquidity_m01.get(), self.liquidity_m10.get(), self.liquidity_m11.get(),
            liq_m_dec,
        )?;
        {
            let mut lp = self.liquidity_position.setter(user);
            lp.inverse_snapshot_m00.set(inv00);
            lp.inverse_snapshot_m01.set(inv01);
            lp.inverse_snapshot_m10.set(inv10);
            lp.inverse_snapshot_m11.set(inv11);
        }

        let gs = self.global_liquidity_stable.get();
        let ga = self.global_liquidity_asset.get();
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let fee_decimals = U256::from(10_000_000_000u64);
        let fee = cm::compute_liquidity_removal_fee(
            stable_to_remove, asset_to_remove, gs, ga, spot_price, oracle_dec,
            self.liquidity_max_fee.get(), self.liquidity_min_fee.get(), self.liquidity_fee_k.get(), fee_decimals,
        );
        let fee_value =
            cm::md(stable_to_remove + cm::md(asset_to_remove, spot_price, oracle_dec), fee, fee_decimals);
        if !(max_fee_value >= fee_value || max_fee_value == U256::ZERO) {
            return Err(err(b"L6"));
        }

        // Solidity `assert(...)` — must hold given the L5 check; revert if not.
        if !(gs >= stable_to_remove && ga >= asset_to_remove) {
            return Err(err(b"RLA"));
        }
        self.global_liquidity_stable.set(gs - stable_to_remove);
        self.global_liquidity_asset.set(ga - asset_to_remove);

        self.distribute_liquidity_fee(fee_value, spot_price);

        // Deduct fee from removed stable (overflow into trader stable debt).
        if stable_to_remove >= fee_value {
            stable_to_remove -= fee_value;
        } else {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let cur_ds = pos.debt_stable.get();
            pos.debt_stable.set(cur_ds + (fee_value - stable_to_remove));
            stable_to_remove = U256::ZERO;
        }

        // First repay LP debt, then credit trader balances.
        let lp_debt_stable = self.liquidity_position.getter(user).debt_stable.get();
        let (rs, new_lp_debt_stable) = cm::reduce_value(stable_to_remove, lp_debt_stable);
        stable_to_remove = rs;
        let lp_debt_asset = self.liquidity_position.getter(user).debt_asset.get();
        let (ra, new_lp_debt_asset) = cm::reduce_value(asset_to_remove, lp_debt_asset);
        asset_to_remove = ra;
        {
            let mut lp = self.liquidity_position.setter(user);
            lp.debt_stable.set(new_lp_debt_stable);
            lp.debt_asset.set(new_lp_debt_asset);
        }
        {
            let mut pos = self.user_virtual_trader_position.setter(user);
            let cur_bs = pos.balance_stable.get();
            pos.balance_stable.set(cur_bs + stable_to_remove);
            let cur_ba = pos.balance_asset.get();
            pos.balance_asset.set(cur_ba + asset_to_remove);
        }
        if asset_to_remove > U256::ZERO {
            if self.total_trader_exposure_sign.get() {
                self.total_trader_exposure.set(self.total_trader_exposure.get() + asset_to_remove);
            } else {
                let tte = self.total_trader_exposure.get();
                self.total_trader_exposure_sign.set(tte < asset_to_remove);
                self.total_trader_exposure.set(cm::util_diff_abs(tte, asset_to_remove));
            }
        }

        let block_ts = self.vm().block_timestamp();
        self.last_curve_update.set(U64::from(block_ts));
        self.last_validated_price.set(spot_price);
        self.dy0.set(U256::ZERO);
        self.dx0.set(U256::ZERO);
        self.last_operation_timestamp.set(U64::from(block_ts));
        self.emit(LiquidityMoved {
            user,
            liquidityStable: stable_to_remove,
            liquidityAsset: asset_to_remove,
            fee: fee_value,
            added: false,
        });
        Ok(())
    }

    /// Solidity `perpLiquidity._addLiquidity`: fold the deposit (and the LP's existing
    /// balance, re-added) into the pool, applying funding, the deposit fee, and a fresh
    /// `M⁻¹(t0)` snapshot. The empty-pool case BOOTSTRAPS `inverseSnapshotM` to
    /// identity·`liquidityMDecimals` (the only place M is seeded from a real deposit).
    /// `getPrice()` is deterministic within a tx, so the caller-computed `spot_price`
    /// stands in for the internal `getPrice()` calls. Bit-exact.
    pub(crate) fn add_liquidity(
        &mut self,
        mut liquidity_stable: U256,
        mut liquidity_asset: U256,
        fee_value: U256,
        spot_price: U256,
        sender: Address,
    ) -> Result<(), Vec<u8>> {
        let last_op_ts = U256::from(self.last_operation_timestamp.get());

        // Funding rate (computed-and-added) -> funding fee -> position.fundingFee.
        let (nfr, nfr_sign) = self.compute_funding_rate(spot_price, last_op_ts)?;
        let (local_fr, local_fr_sign) =
            cm::signed_sum(self.funding_rate.get(), self.funding_rate_sign.get(), nfr, nfr_sign);
        let (local_ff, local_ff_sign) = self.compute_funding_fee_with(sender, local_fr, local_fr_sign);
        {
            let mut pos = self.user_virtual_trader_position.setter(sender);
            let (nff, nffs) =
                cm::signed_sum(pos.funding_fee.get(), pos.funding_fee_sign.get(), local_ff, local_ff_sign);
            pos.funding_fee.set(nff);
            pos.funding_fee_sign.set(nffs);
        }

        // LP debt grows by the deposited amounts (it is borrowed against collateral).
        {
            let mut lp = self.liquidity_position.setter(sender);
            let ds = lp.debt_stable.get();
            lp.debt_stable.set(ds + liquidity_stable);
            let da = lp.debt_asset.get();
            lp.debt_asset.set(da + liquidity_asset);
        }

        // Deduct the deposit fee from the stable side (overflow into LP stable debt).
        if liquidity_stable >= fee_value {
            liquidity_stable -= fee_value;
        } else {
            let mut lp = self.liquidity_position.setter(sender);
            let ds = lp.debt_stable.get();
            lp.debt_stable.set(ds + (fee_value - liquidity_stable));
            liquidity_stable = U256::ZERO;
        }

        self.distribute_liquidity_fee(fee_value, spot_price);
        self.update_fg(spot_price, last_op_ts)?;

        // Remove the LP's OLD balance to re-add it folded with the new deposit.
        let (old_lp_stable, old_lp_asset) = self.get_lp_liquidity_balance(sender);
        liquidity_stable += old_lp_stable;
        liquidity_asset += old_lp_asset;

        self.update_snapshots(sender, U256::ZERO, U256::ZERO);
        {
            let mut lp = self.liquidity_position.setter(sender);
            lp.initial_stable_balance.set(liquidity_stable);
            lp.initial_asset_balance.set(liquidity_asset);
        }

        let liq_m_dec = self.liquidity_m_decimals.get();
        if self.global_liquidity_asset.get() == U256::ZERO && self.global_liquidity_stable.get() == U256::ZERO {
            // Empty pool: bootstrap the snapshot to identity * liquidityMDecimals.
            let mut lp = self.liquidity_position.setter(sender);
            lp.inverse_snapshot_m00.set(liq_m_dec);
            lp.inverse_snapshot_m01.set(I256::ZERO);
            lp.inverse_snapshot_m10.set(I256::ZERO);
            lp.inverse_snapshot_m11.set(liq_m_dec);
        } else {
            let gs = self.global_liquidity_stable.get();
            let ga = self.global_liquidity_asset.get();
            self.global_liquidity_stable.set(gs - old_lp_stable);
            self.global_liquidity_asset.set(ga - old_lp_asset);
            let (inv00, inv01, inv10, inv11) = cm::mat_inverse_2x2(
                self.liquidity_m00.get(), self.liquidity_m01.get(), self.liquidity_m10.get(), self.liquidity_m11.get(),
                liq_m_dec,
            )?;
            let mut lp = self.liquidity_position.setter(sender);
            lp.inverse_snapshot_m00.set(inv00);
            lp.inverse_snapshot_m01.set(inv01);
            lp.inverse_snapshot_m10.set(inv10);
            lp.inverse_snapshot_m11.set(inv11);
        }

        let gs = self.global_liquidity_stable.get();
        self.global_liquidity_stable.set(gs + liquidity_stable);
        let ga = self.global_liquidity_asset.get();
        self.global_liquidity_asset.set(ga + liquidity_asset);

        let block_ts = self.vm().block_timestamp();
        self.last_operation_timestamp.set(U64::from(block_ts));
        self.emit(LiquidityMoved {
            user: sender,
            liquidityStable: liquidity_stable,
            liquidityAsset: liquidity_asset,
            fee: fee_value,
            added: true,
        });
        Ok(())
    }

    /// Shared `addLiquidity` body (EOA + forwarded) parameterized by the LP `sender`.
    pub(crate) fn add_liquidity_outer(
        &mut self,
        sender: Address,
        liquidity_stable: U256,
        liquidity_asset: U256,
        max_fee_value: U256,
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

        let oracle_dec = U256::from(self.oracle_decimals.get());
        // L1: minimum movement.
        if !(liquidity_stable + cm::md(liquidity_asset, price, oracle_dec) >= self.minimum_liquidity_movement.get()) {
            return Err(err(b"L1"));
        }

        let mut fee = cm::compute_liquidity_deposit_fee(
            liquidity_stable, liquidity_asset, self.global_liquidity_stable.get(), self.global_liquidity_asset.get(),
            price, oracle_dec, self.liquidity_max_fee.get(), self.liquidity_min_fee.get(),
            self.liquidity_fee_k.get(), U256::from(10_000_000_000u64),
        );
        if self.global_liquidity_asset.get() == U256::ZERO && self.global_liquidity_stable.get() == U256::ZERO {
            fee = U256::ZERO;
        }
        let fee_value =
            cm::md(liquidity_stable + cm::md(liquidity_asset, price, oracle_dec), fee, U256::from(10_000_000_000u64));
        // L2: fee cap.
        if !(fee_value <= max_fee_value || max_fee_value == U256::ZERO) {
            return Err(err(b"L2"));
        }

        self.add_liquidity(liquidity_stable, liquidity_asset, fee_value, price, sender)?;

        let block_ts = self.vm().block_timestamp();
        self.last_curve_update.set(U64::from(block_ts));
        self.last_validated_price.set(price);
        self.dy0.set(U256::ZERO);
        self.dx0.set(U256::ZERO);

        // getCollateral(sender) — read once (used by C1 and L3).
        let collateral: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral = vault.user_collateral(self.vm(), Call::new(), sender)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral = U256::from(1_000u64) * U256::from(WAD_U64);
        }

        // C1: cannot operate while in bad debt.
        let (pnl, pnl_sign) = self.calc_pnl_user(sender, price)?;
        if !(pnl < collateral || pnl_sign) {
            return Err(err(b"C1"));
        }

        // L3: total debt backed by collateral at max LP leverage.
        let total_debt_stable =
            self.liquidity_position.getter(sender).debt_stable.get() + self.user_virtual_trader_position.getter(sender).debt_stable.get();
        let total_debt_asset =
            self.liquidity_position.getter(sender).debt_asset.get() + self.user_virtual_trader_position.getter(sender).debt_asset.get();
        if !(total_debt_stable + cm::md(total_debt_asset, price, oracle_dec)
            <= collateral * U256::from(self.max_lp_leverage.get()))
        {
            return Err(err(b"L3"));
        }

        self.entered.set(false);
        Ok(())
    }

    /// Shared `removeLiquidity` body (EOA + forwarded) parameterized by the LP `sender`.
    pub(crate) fn remove_liquidity_outer(
        &mut self,
        sender: Address,
        liquidity_stable_to_remove: U256,
        liquidity_asset_to_remove: U256,
        max_fee_value: U256,
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

        let oracle_dec = U256::from(self.oracle_decimals.get());
        // L4: minimum movement.
        if !(liquidity_stable_to_remove + cm::md(liquidity_asset_to_remove, price, oracle_dec)
            >= self.minimum_liquidity_movement.get())
        {
            return Err(err(b"L4"));
        }

        self.remove_liquidity(liquidity_stable_to_remove, liquidity_asset_to_remove, sender, price, max_fee_value)?;

        let collateral: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral = vault.user_collateral(self.vm(), Call::new(), sender)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral = U256::from(1_000u64) * U256::from(WAD_U64);
        }
        let (pnl, pnl_sign) = self.calc_pnl_user(sender, price)?;
        if !(pnl < collateral || pnl_sign) {
            return Err(err(b"C1"));
        }

        self.entered.set(false);
        Ok(())
    }

    /// `delete liquidityPosition[user]` — zero the whole LP struct.
    pub(crate) fn clear_liquidity_position(&mut self, user: Address) {
        let mut lp = self.liquidity_position.setter(user);
        lp.initial_stable_balance.set(U256::ZERO);
        lp.initial_asset_balance.set(U256::ZERO);
        lp.debt_stable.set(U256::ZERO);
        lp.debt_asset.set(U256::ZERO);
        lp.inverse_snapshot_m00.set(I256::ZERO);
        lp.inverse_snapshot_m01.set(I256::ZERO);
        lp.inverse_snapshot_m10.set(I256::ZERO);
        lp.inverse_snapshot_m11.set(I256::ZERO);
        lp.snapshot_g0.set(I256::ZERO);
        lp.snapshot_g1.set(I256::ZERO);
    }
}
