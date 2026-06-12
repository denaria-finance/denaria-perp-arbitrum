//! LP-balance reconstruction, calcPnL, and calcMR (internalPerpLogic). Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Solidity `InternalPerpLogic.getLpLiquidityBalance(user)`:
    /// current LP balance = (initialShares) · M(t)·M⁻¹(t0), clamped to the pool.
    pub(crate) fn get_lp_liquidity_balance(&self, user: Address) -> (U256, U256) {
        let lp = self.liquidity_position.getter(user);
        if lp.inverse_snapshot_m00.get() == I256::ZERO {
            return (U256::ZERO, U256::ZERO);
        }
        let d = self.liquidity_m_decimals.get();
        let (am00, am01, am10, am11) = cm::mat_mul_2x2(
            self.liquidity_m00.get(), self.liquidity_m01.get(), self.liquidity_m10.get(), self.liquidity_m11.get(),
            lp.inverse_snapshot_m00.get(), lp.inverse_snapshot_m01.get(), lp.inverse_snapshot_m10.get(), lp.inverse_snapshot_m11.get(),
            d,
        );
        let init_stable = cm::i(lp.initial_stable_balance.get());
        let init_asset = cm::i(lp.initial_asset_balance.get());
        let mut lp_stable = cm::u((init_stable * am00 + init_asset * am01) / d);
        let mut lp_asset = cm::u((init_stable * am10 + init_asset * am11) / d);
        let gs = self.global_liquidity_stable.get();
        let ga = self.global_liquidity_asset.get();
        if lp_stable > gs {
            lp_stable = gs;
        }
        if lp_asset > ga {
            lp_asset = ga;
        }
        (lp_stable, lp_asset)
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
        let threshold = U256::from(10u64).pow(U256::from(13u64)) * oracle_dec / price;
        if diff_asset > threshold {
            if use_spot_price {
                short_return = diff_asset * price / oracle_dec;
            } else if diff_asset_sign {
                let ts = self.global_liquidity_stable.get();
                let ta = self.global_liquidity_asset.get();
                short_return = self.compute_short_return(
                    diff_asset, price, oracle_dec, ts, ts, ta,
                    self.short_curve_parameter_a.get(), self.short_curve_parameter_b.get(),
                );
            } else {
                let ts = self.global_liquidity_stable.get();
                let ta = self.global_liquidity_asset.get();
                // Solidity `require(diffAsset <= getTotalLiquidityAsset(...), "PNL1")` —
                // return the standard Error(string) revert (Solidity-standard encoding), not a panic.
                if diff_asset > ta {
                    return Err(err(b"PNL1"));
                }
                short_return = self.compute_exact_amount_in_long(
                    diff_asset, price, oracle_dec, ts, ts, ta,
                    self.long_curve_parameter_a.get(), self.long_curve_parameter_b.get(),
                );
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
        let position_value = cm::util_diff_abs(balance_asset, debt_asset) * price / oracle_dec;
        let (tot_coll, tot_coll_sign) = cm::signed_sum(collateral, true, pnl, pnl_sign);
        if !tot_coll_sign && tot_coll != U256::ZERO {
            return Ok(U256::ZERO); // bad debt
        }
        if position_value == U256::ZERO {
            return Ok(mmr_decimals);
        }
        Ok(tot_coll * mmr_decimals / position_value)
    }

    /// Solidity `UtilMath.calcMR(user, price, perpPair, collateral, lastOperationTimestamp)`.
    pub(crate) fn calc_mr(&self, user: Address, price: U256, collateral: U256, last_op_ts: U256) -> Result<U256, Vec<u8>> {
        let (stable_lp, asset_lp) = self.get_lp_liquidity_balance(user);

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
        let (local_ff, local_ff_sign) = self.compute_funding_fee_with(user, funding_rate, funding_rate_sign);
        let (funding_fee, funding_fee_sign) =
            cm::signed_sum(pos_funding_fee, pos_funding_fee_sign, local_ff, local_ff_sign);

        self.calc_hypothetical_mr(
            stable_lp + balance_stable,
            asset_lp + balance_asset,
            debt_stable + lp_debt_stable,
            debt_asset + lp_debt_asset,
            funding_fee,
            funding_fee_sign,
            price,
            collateral,
        )
    }

    /// Solidity `internalPerpLogic.calcPnL(user, price)` — the close-path PnL
    /// (curve valuation, `useSpotPrice=false`). Always recomputes the funding
    /// rate to `price` (no `block.timestamp` gate, unlike `calcMR`).
    pub(crate) fn calc_pnl_user(&self, user: Address, price: U256) -> Result<(U256, bool), Vec<u8>> {
        let (stable_lp, asset_lp) = self.get_lp_liquidity_balance(user);
        let last_op_ts = U256::from(self.last_operation_timestamp.get());
        let (nfr, nfr_sign) = self.compute_funding_rate(price, last_op_ts)?;
        let (fr, frs) =
            cm::signed_sum(self.funding_rate.get(), self.funding_rate_sign.get(), nfr, nfr_sign);
        let (local_ff, local_ff_sign) = self.compute_funding_fee_with(user, fr, frs);

        let vp = self.user_virtual_trader_position.getter(user);
        let (funding_fee, funding_fee_sign) =
            cm::signed_sum(vp.funding_fee.get(), vp.funding_fee_sign.get(), local_ff, local_ff_sign);
        let lp = self.liquidity_position.getter(user);
        let oracle_dec = U256::from(self.oracle_decimals.get());
        self.calc_pnl(
            vp.balance_stable.get() + stable_lp,
            vp.balance_asset.get() + asset_lp,
            vp.debt_stable.get() + lp.debt_stable.get(),
            vp.debt_asset.get() + lp.debt_asset.get(),
            funding_fee,
            funding_fee_sign,
            price,
            oracle_dec,
            false,
        )
    }
}
