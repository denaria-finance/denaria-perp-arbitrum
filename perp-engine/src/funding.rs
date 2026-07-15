//! Funding-rate math — bit-exact port of perpFunding.sol. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

/// Roll a fresh LP accounting epoch once the current epoch's matrix determinant decays to
/// `liquidity_m_decimals / LIQUIDITY_EPOCH_DET_DENOMINATOR` (~1e-12 of full Q80 scale).
const LIQUIDITY_EPOCH_DET_DENOMINATOR: u64 = 1_000_000_000_000; // 1e12
/// Cap on the number of simultaneously-active LP accounting epochs.
const MAX_ACTIVE_LIQUIDITY_EPOCHS: u64 = 8;

#[allow(dead_code)]
impl PerpEngine {
    /// Solidity `_liquidityEpochDeterminant`: determinant (Q80) of an epoch's matrix; ZERO if uninitialized.
    pub(crate) fn liquidity_epoch_determinant(&self, epoch_id: U256) -> Result<I256, Vec<u8>> {
        let epoch = self.liquidity_epochs.getter(epoch_id);
        let m00 = epoch.liquidity_m00.get();
        if m00 == I256::ZERO {
            return Ok(I256::ZERO);
        }
        let m11 = epoch.liquidity_m11.get();
        let m10 = epoch.liquidity_m10.get();
        let m01 = epoch.liquidity_m01.get();
        cm::sum_mul_div_signed(m00, m11, -m10, m01, self.liquidity_m_decimals.get()).map_err(|e| err(&e))
    }

    /// Solidity `_initializeLiquidityEpoch`: reset an epoch to the Q80 identity matrix with a zeroed
    /// funding row G (active_lp_count is left untouched).
    pub(crate) fn initialize_liquidity_epoch(&mut self, epoch_id: U256) {
        let d = self.liquidity_m_decimals.get();
        let mut epoch = self.liquidity_epochs.setter(epoch_id);
        epoch.liquidity_m00.set(d);
        epoch.liquidity_m01.set(I256::ZERO);
        epoch.liquidity_m10.set(I256::ZERO);
        epoch.liquidity_m11.set(d);
        epoch.matrix_row_g0.set(I256::ZERO);
        epoch.matrix_row_g1.set(I256::ZERO);
    }

    /// Increment an epoch's active-LP refcount.
    pub(crate) fn increment_active_lp_count(&mut self, epoch_id: U256) {
        let mut epoch = self.liquidity_epochs.setter(epoch_id);
        let c = epoch.active_lp_count.get();
        epoch.active_lp_count.set(c + U256::from(1u64));
    }

    /// Decrement an epoch's active-LP refcount.
    pub(crate) fn decrement_active_lp_count(&mut self, epoch_id: U256) {
        let mut epoch = self.liquidity_epochs.setter(epoch_id);
        let c = epoch.active_lp_count.get();
        epoch.active_lp_count.set(c - U256::from(1u64));
    }

    /// Zero every field of an epoch slot — the analogue of Solidity `delete liquidityEpochs[id]`.
    fn delete_liquidity_epoch(&mut self, epoch_id: U256) {
        let mut epoch = self.liquidity_epochs.setter(epoch_id);
        epoch.liquidity_m00.set(I256::ZERO);
        epoch.liquidity_m01.set(I256::ZERO);
        epoch.liquidity_m10.set(I256::ZERO);
        epoch.liquidity_m11.set(I256::ZERO);
        epoch.matrix_row_g0.set(I256::ZERO);
        epoch.matrix_row_g1.set(I256::ZERO);
        epoch.active_lp_count.set(U256::ZERO);
    }

    /// Solidity `_retireInactiveLiquidityEpochs`: advance oldest_active_liquidity_epoch past any
    /// drained/uninitialized epoch below current, freeing its storage.
    pub(crate) fn retire_inactive_liquidity_epochs(&mut self) {
        loop {
            let oldest = self.oldest_active_liquidity_epoch.get();
            if oldest >= self.current_liquidity_epoch.get() {
                break;
            }
            let (m00, count) = {
                let epoch = self.liquidity_epochs.getter(oldest);
                (epoch.liquidity_m00.get(), epoch.active_lp_count.get())
            };
            if m00 != I256::ZERO && count != U256::ZERO {
                return;
            }
            if m00 != I256::ZERO {
                self.delete_liquidity_epoch(oldest);
            }
            self.oldest_active_liquidity_epoch.set(oldest + U256::from(1u64));
        }
    }

    /// Solidity `_rollLiquidityEpochIfNeeded`: roll a fresh epoch once the current matrix determinant
    /// decays past the threshold; reverts LECAP if the active window is already full.
    pub(crate) fn roll_liquidity_epoch_if_needed(&mut self) -> Result<(), Vec<u8>> {
        let current = self.current_liquidity_epoch.get();
        let determinant = self.liquidity_epoch_determinant(current)?;
        let threshold = self.liquidity_m_decimals.get() / cm::i(U256::from(LIQUIDITY_EPOCH_DET_DENOMINATOR));
        if determinant > threshold {
            return Ok(());
        }

        let previous = current;
        let oldest = self.oldest_active_liquidity_epoch.get();
        let mut active_window = previous + U256::from(1u64) - oldest;
        if self.liquidity_epochs.getter(previous).active_lp_count.get() == U256::ZERO {
            active_window -= U256::from(1u64);
        }
        if !(active_window < U256::from(MAX_ACTIVE_LIQUIDITY_EPOCHS)) {
            return Err(err(b"LECAP"));
        }

        let new_epoch = previous + U256::from(1u64);
        self.current_liquidity_epoch.set(new_epoch);
        self.initialize_liquidity_epoch(new_epoch);
        self.retire_inactive_liquidity_epochs();
        Ok(())
    }

    /// Solidity `_hasActiveLiquiditySnapshot`: whether the LP holds a live snapshot.
    pub(crate) fn has_active_liquidity_snapshot(&self, user: Address) -> bool {
        let lp = self.liquidity_position.getter(user);
        lp.snapshot_m00.get() != I256::ZERO
            && (lp.initial_stable_balance.get() != U256::ZERO || lp.initial_asset_balance.get() != U256::ZERO)
    }

    /// Solidity `_refreshLpFundingSnapshot`: re-baseline an LP's funding G snapshot against its own
    /// epoch's current G (the matrix snapshot is untouched); a no-op for a pure trader.
    pub(crate) fn refresh_lp_funding_snapshot(&mut self, user: Address) {
        if !self.has_active_liquidity_snapshot(user) {
            return;
        }
        let epoch_id = self.liquidity_position_epoch.getter(user).get();
        let (g0, g1) = {
            let epoch = self.liquidity_epochs.getter(epoch_id);
            (epoch.matrix_row_g0.get(), epoch.matrix_row_g1.get())
        };
        let mut lp = self.liquidity_position.setter(user);
        lp.snapshot_g0.set(g0);
        lp.snapshot_g1.set(g1);
    }

    /// Solidity `_applyLiquidityMatrixUpdate`: apply a trade/fee matrix update to every active epoch.
    /// update_kind: 0 = long, 1 = short, 2 = fee distribution.
    pub(crate) fn apply_liquidity_matrix_update(&mut self, a_x: I256, a_y: I256, update_kind: u8) {
        let liq_m_dec = self.liquidity_m_decimals.get();
        let current = self.current_liquidity_epoch.get();
        let oldest = self.oldest_active_liquidity_epoch.get();
        let mut epoch_id = oldest;
        while epoch_id <= current {
            let (m00, m01, m10, m11, count) = {
                let e = self.liquidity_epochs.getter(epoch_id);
                (
                    e.liquidity_m00.get(),
                    e.liquidity_m01.get(),
                    e.liquidity_m10.get(),
                    e.liquidity_m11.get(),
                    e.active_lp_count.get(),
                )
            };
            if m00 == I256::ZERO || (epoch_id != current && count == U256::ZERO) {
                epoch_id += U256::from(1u64);
                continue;
            }
            {
                let mut e = self.liquidity_epochs.setter(epoch_id);
                if update_kind == 0 {
                    e.liquidity_m00.set(m00 + a_y * m10 / liq_m_dec);
                    e.liquidity_m01.set(m01 + a_y * m11 / liq_m_dec);
                    e.liquidity_m10.set(m10 - cm::div_ceil(a_x * m10, liq_m_dec));
                    e.liquidity_m11.set(m11 - cm::div_ceil(a_x * m11, liq_m_dec));
                } else if update_kind == 1 {
                    e.liquidity_m10.set(m10 + a_x * m00 / liq_m_dec);
                    e.liquidity_m11.set(m11 + a_x * m01 / liq_m_dec);
                    e.liquidity_m00.set(m00 - cm::div_ceil(a_y * m00, liq_m_dec));
                    e.liquidity_m01.set(m01 - cm::div_ceil(a_y * m01, liq_m_dec));
                } else {
                    e.liquidity_m00.set(m00 + (a_y * m10 + a_x * m00) / liq_m_dec);
                    e.liquidity_m01.set(m01 + (a_y * m11 + a_x * m01) / liq_m_dec);
                }
            }
            epoch_id += U256::from(1u64);
        }
    }

    /// Solidity `computeFundingRate(price, timestamp)`.
    pub(crate) fn compute_funding_rate(&self, price: U256, timestamp: U256) -> Result<(U256, bool), Vec<u8>> {
        let block_ts = U256::from(self.vm().block_timestamp());
        // Solidity `require(timestamp <= block.timestamp, "F1")` — return the standard
        // Error(string) revert (Solidity-standard encoding), not an opaque WASM panic.
        if timestamp > block_ts {
            return Err(err(b"F1"));
        }

        let asset_liq = self.global_liquidity_asset.get();
        let stable_liq = self.global_liquidity_stable.get();
        if asset_liq + stable_liq == U256::ZERO {
            return Ok((U256::ZERO, true));
        }

        let wad = U256::from(WAD_U64);
        let oracle_dec = U256::from(self.oracle_decimals.get());
        let price_o = cm::md(price, wad, oracle_dec);

        let raw = cm::md(self.total_trader_exposure.get(), price_o, wad)
            * U256::from(100_000u64)
            * U256::from(1_000_000_000_000_000_000u64);

        let denom_asset = cm::md(asset_liq, price_o, wad);
        let denom = U256::from(self.funding_c.get()) * (denom_asset + stable_liq);

        // Raw (unclamped) signed funding coefficient.
        let coeff = raw / denom;
        let coeff_sign = self.total_trader_exposure_sign.get();

        let delta = block_ts - timestamp;
        let new_rate = cm::md(coeff, delta, U256::from(self.funding_interval.get()));
        Ok((cm::md(price_o, new_rate, wad), coeff_sign))
    }

    /// Solidity `_updateFG(price, timestamp)`: advance the cumulative funding rate
    /// and the funding row G.
    pub(crate) fn update_fg(&mut self, price: U256, timestamp: U256) -> Result<(), Vec<u8>> {
        // Idempotent within a block: once funding is settled and the timestamp stamped, a
        // second settlement in the same block would double-count. The stamp lives here (not
        // in the callers) so every subsequent reader sees the refreshed timestamp.
        let block_ts = self.vm().block_timestamp();
        if self.last_operation_timestamp.get() == U64::from(block_ts) {
            return Ok(());
        }
        let inv_lmd = self.liquidity_m_decimals.get();
        let (new_fr, new_fr_sign) = self.compute_funding_rate(price, timestamp)?;

        let (fr, fr_sign) = cm::signed_sum(
            self.funding_rate.get(),
            self.funding_rate_sign.get(),
            new_fr,
            new_fr_sign,
        );
        self.funding_rate.set(fr);
        self.funding_rate_sign.set(fr_sign);

        let mut b = cm::i(cm::md(new_fr, self.liquidity_g_decimals.get(), U256::from(1_000_000_000_000_000_000u64)));
        if !new_fr_sign {
            b = -b;
        }

        // Accrue G into every live LP accounting epoch — overflow-safe signed mulDiv (Q80 scale).
        let current = self.current_liquidity_epoch.get();
        let oldest = self.oldest_active_liquidity_epoch.get();
        let mut epoch_id = oldest;
        while epoch_id <= current {
            let (m00, m10, m11, count) = {
                let e = self.liquidity_epochs.getter(epoch_id);
                (e.liquidity_m00.get(), e.liquidity_m10.get(), e.liquidity_m11.get(), e.active_lp_count.get())
            };
            if m00 == I256::ZERO || (epoch_id != current && count == U256::ZERO) {
                epoch_id += U256::from(1u64);
                continue;
            }
            let dg0 = cm::mul_div_signed(b, m10, inv_lmd).map_err(|e| err(&e))?;
            let dg1 = cm::mul_div_signed(b, m11, inv_lmd).map_err(|e| err(&e))?;
            {
                let mut e = self.liquidity_epochs.setter(epoch_id);
                let g0 = e.matrix_row_g0.get();
                e.matrix_row_g0.set(g0 + dg0);
                let g1 = e.matrix_row_g1.get();
                e.matrix_row_g1.set(g1 + dg1);
            }
            epoch_id += U256::from(1u64);
        }

        self.last_operation_timestamp.set(U64::from(block_ts));
        Ok(())
    }

    /// Solidity `computeFundingFee(user)` = `_computeFundingFee(user, fundingRate, fundingRateSign)`.
    pub(crate) fn compute_funding_fee(&self, user: Address) -> Result<(U256, bool), Vec<u8>> {
        self.compute_funding_fee_with(user, self.funding_rate.get(), self.funding_rate_sign.get())
    }

    /// Solidity `_computeFundingFee(user, _fundingRate, _fundingRateSign)`.
    pub(crate) fn compute_funding_fee_with(
        &self,
        user: Address,
        fr: U256,
        fr_sign: bool,
    ) -> Result<(U256, bool), Vec<u8>> {
        let inv_lmd = self.liquidity_m_decimals.get();
        let lp = self.liquidity_position.getter(user);
        let vp = self.user_virtual_trader_position.getter(user);
        // Read the LP's OWN accounting epoch bases (M and G).
        let lp_epoch_id = self.liquidity_position_epoch.getter(user).get();
        let epoch = self.liquidity_epochs.getter(lp_epoch_id);
        let frd = U256::from(1_000_000_000_000_000_000u64);
        let lgd = self.liquidity_g_decimals.get();
        let cur_fr = self.funding_rate.get();
        let cur_fr_sign = self.funding_rate_sign.get();

        // b = signedSum(_fundingRate, _fundingRateSign, fundingRate, !fundingRateSign)
        let (delta_f, delta_f_sign) = cm::signed_sum(fr, fr_sign, cur_fr, !cur_fr_sign);
        let mut b = cm::i(cm::md(delta_f, lgd, frd));
        if !delta_f_sign {
            b = -b;
        }

        // DeltaG = epoch.matrixRowG - snapshotG + mulDivSigned(b, epoch.M[1][*], invLMD)
        let delta_g0 = epoch.matrix_row_g0.get() - lp.snapshot_g0.get()
            + cm::mul_div_signed(b, epoch.liquidity_m10.get(), inv_lmd).map_err(|e| err(&e))?;
        let delta_g1 = epoch.matrix_row_g1.get() - lp.snapshot_g1.get()
            + cm::mul_div_signed(b, epoch.liquidity_m11.get(), inv_lmd).map_err(|e| err(&e))?;

        // star = DeltaG * M^-1(t0) * v(t0), recovered via the adjugate from the RAW forward
        // snapshot M(t0). Only an LP with a live position runs it (else star = 0); a real LP
        // with a corrupted (det ≤ 0) snapshot reverts MDET, matching the reference.
        let star = if lp.initial_stable_balance.get() != U256::ZERO || lp.initial_asset_balance.get() != U256::ZERO {
            cm::recover_funding_star_from_snapshot(
                delta_g0,
                delta_g1,
                lp.snapshot_m00.get(),
                lp.snapshot_m01.get(),
                lp.snapshot_m10.get(),
                lp.snapshot_m11.get(),
                lp.initial_stable_balance.get(),
                lp.initial_asset_balance.get(),
                inv_lmd,
                lgd,
            )
            .map_err(|e| err(&e))?
        } else {
            I256::ZERO
        };

        // deltaF re-used with the trader's initialFundingRate snapshot
        let (delta_f2, delta_f2_sign) = cm::signed_sum(
            fr,
            fr_sign,
            vp.initial_funding_rate.get(),
            !vp.initial_funding_rate_sign.get(),
        );

        let (exposure, exposure_sign) = cm::signed_sum(
            vp.balance_asset.get(),
            true,
            vp.debt_asset.get() + lp.debt_asset.get(),
            false,
        );

        let (abs_star, star_sign) = if star >= I256::ZERO {
            (cm::u(star), true)
        } else {
            (cm::u(-star), false)
        };

        Ok(cm::signed_sum(
            abs_star,
            star_sign,
            cm::md(exposure, delta_f2, frd),
            delta_f2_sign == exposure_sign,
        ))
    }
}
