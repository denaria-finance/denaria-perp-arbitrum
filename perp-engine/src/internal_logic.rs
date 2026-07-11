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
        // Clamp each signed recovery leg to the pool floor (0) before the U256 cast and the
        // global cap: an ill-conditioned M(t)·M⁻¹(t0) can drive a leg negative, and `cm::u`
        // reverts on a negative I256. Mirrors Solidity `result > 0 ? uint256(result) : 0`.
        let mut lp_stable = cm::u_or_zero((init_stable * am00 + init_asset * am01) / d);
        let mut lp_asset = cm::u_or_zero((init_stable * am10 + init_asset * am11) / d);
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
        let threshold = cm::md(U256::from(10u64).pow(U256::from(13u64)), oracle_dec, price);
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
                // Solidity `require(diffAsset <= getTotalLiquidityAsset(...), "PNL1")` —
                // return the standard Error(string) revert (Solidity-standard encoding), not a panic.
                if diff_asset > ta {
                    return Err(err(b"PNL1"));
                }
                short_return = self.compute_exact_amount_in_long(
                    diff_asset, price, oracle_dec, ts, ts, ta,
                    U256::from(100_000_000u64), U256::from(10_000_000u64),
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

        // Oversized-short spot fallback (liquidation only): a net-short position larger than
        // the pool's asset liquidity cannot be bought back on the curve, so value it at spot.
        let total_balance_asset = vp.balance_asset.get() + asset_lp;
        let total_debt_asset = vp.debt_asset.get() + lp.debt_asset.get();
        let use_spot_price = allow_oversized_short_spot_fallback
            && total_debt_asset > total_balance_asset
            && total_debt_asset - total_balance_asset > self.global_liquidity_asset.get();

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
