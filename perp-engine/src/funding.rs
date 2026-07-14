//! Funding-rate math — bit-exact port of perpFunding.sol. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
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
        let m10 = self.liquidity_m10.get();
        let m11 = self.liquidity_m11.get();
        // Overflow-safe signed mulDiv (Q80 matrix scale), replacing raw `b * m1j / inv_lmd`.
        self.matrix_row_g0.set(self.matrix_row_g0.get() + cm::mul_div_signed(b, m10, inv_lmd).map_err(|e| err(&e))?);
        self.matrix_row_g1.set(self.matrix_row_g1.get() + cm::mul_div_signed(b, m11, inv_lmd).map_err(|e| err(&e))?);
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

        // DeltaG = matrixRowG - snapshotG + mulDivSigned(b, M[1][*], invLMD)
        let delta_g0 =
            self.matrix_row_g0.get() - lp.snapshot_g0.get() + cm::mul_div_signed(b, self.liquidity_m10.get(), inv_lmd).map_err(|e| err(&e))?;
        let delta_g1 =
            self.matrix_row_g1.get() - lp.snapshot_g1.get() + cm::mul_div_signed(b, self.liquidity_m11.get(), inv_lmd).map_err(|e| err(&e))?;

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
