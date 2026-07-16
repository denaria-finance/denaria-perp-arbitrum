//! Auto-close (perpAutoClose) enable + execute bodies. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

/// Protocol-level cap on a single `batchAutoCloseUserPositionFor` call — bounds worst-case
/// resource consumption to a predictable maximum (mirrors `MAX_LIQUIDATION_BATCH`).
pub(crate) const MAX_AUTOCLOSE_BATCH: usize = 100;

#[allow(dead_code)]
impl PerpEngine {
    /// Shared `enableAutoClose` body (EOA + forwarded) parameterized by the position
    /// owner `user`. Port of `perpAutoClose.enableAutoClose` (pure storage writes + event;
    /// not reentrancy-guarded in Solidity).
    pub(crate) fn enable_auto_close_impl(
        &mut self,
        user: Address,
        profit_th: U256,
        loss_th: U256,
        max_slippage: U256,
        max_liq_fee: U256,
    ) -> Result<(), Vec<u8>> {
        if !(profit_th > U256::ZERO || loss_th > U256::ZERO) {
            return Err(err(b"A"));
        }
        {
            let mut ac = self.auto_close_users_data.setter(user);
            ac.authorized.set(true);
            ac.profit_th.set(profit_th);
            ac.loss_th.set(loss_th);
            ac.max_slippage.set(max_slippage);
            ac.max_liq_fee.set(max_liq_fee);
        }
        self.emit(ToggledAutoClose {
            user,
            profitTh: profit_th,
            lossTh: loss_th,
            maxSlippage: max_slippage,
            maxLiqFee: max_liq_fee,
        });
        Ok(())
    }

    /// Shared `autoCloseUserPosition` body (EOA + forwarded) parameterized by the
    /// `caller` (the auto-close fee recipient). Port of `perpAutoClose.autoCloseUserPosition`.
    pub(crate) fn auto_close_user_position_impl(
        &mut self,
        caller: Address,
        user: Address,
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
        let price = U256::from(300_000_000_000u64);

        self.auto_close_with_price(caller, user, frontend_address, price)?;
        self.entered.set(false);
        Ok(())
    }

    /// Guard-free per-user auto-close body, parameterized by the already-read `price`. Shared by
    /// the single (`auto_close_user_position_impl`) and batch (`batch_auto_close_user_position_impl`)
    /// paths so the batch pays the reentrancy guard + report verify + oracle read ONCE. Returns A1
    /// for an INELIGIBLE user (not authorized / threshold not met) so the batch can skip it; any
    /// other Err is a hard failure that must propagate.
    pub(crate) fn auto_close_with_price(
        &mut self,
        caller: Address,
        user: Address,
        frontend_address: Address,
        price: U256,
    ) -> Result<(), Vec<u8>> {
        if !self.auto_close_users_data.getter(user).authorized.get() {
            return Err(err(b"A1"));
        }

        let (user_pnl, user_pnl_sign) = self.calc_pnl_user(user, price)?;

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

        let profit_th = self.auto_close_users_data.getter(user).profit_th.get();
        let loss_th = self.auto_close_users_data.getter(user).loss_th.get();
        if user_pnl_sign {
            if !(profit_th != U256::ZERO && user_pnl >= profit_th) {
                return Err(err(b"A1"));
            }
        } else if !(loss_th != U256::ZERO && user_pnl >= loss_th && user_pnl <= collateral) {
            return Err(err(b"A1"));
        }

        let auto_close_fee = self.auto_close_fee.get();
        {
            let mut up = self.user_virtual_trader_position.setter(user);
            let ds = up.debt_stable.get();
            up.debt_stable.set(ds + auto_close_fee);
        }
        {
            let mut cp = self.user_virtual_trader_position.setter(caller);
            let bs = cp.balance_stable.get();
            cp.balance_stable.set(bs + auto_close_fee);
        }

        let max_slippage = self.auto_close_users_data.getter(user).max_slippage.get();
        let max_liq_fee = self.auto_close_users_data.getter(user).max_liq_fee.get();
        // Log ToggledAutoClose(mode 1 = third-party auto-close) and clear BEFORE the shared close
        // body: that body clears too (mode 0), and running it first would emit mode 0 and flip
        // `authorized` off, suppressing this mode-1 log. The close params are already captured above.
        self.clear_auto_close_data(user, U256::from(1u64));
        // Force the C1 self-close bad-debt guard on auto-close regardless of caller: a distinct
        // auto-close caller must not be able to close a bad-debt position (that would drain the
        // insurance fund). The auto-close fee is still credited to the distinct `caller` above.
        let (cpnl, cpnl_sign) =
            self.close_and_withdraw_inner(max_slippage, max_liq_fee, frontend_address, user, price, collateral, true)?;

        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            let cfg = Call::new_mutating(self);
            vault.add_pnl_to_collateral(self.vm(), cfg, user, cpnl, cpnl_sign)?;
        }
        #[cfg(feature = "stub_boundary")]
        let _ = (cpnl, cpnl_sign);

        Ok(())
    }

    /// Batch `autoCloseUserPosition` (forwarded keeper helper): verify the report + read the oracle
    /// price ONCE, then run the per-user auto-close body for each target. BEST-EFFORT — a user that
    /// is not currently eligible (A1: not authorized / threshold not met) is SKIPPED, not fatal, so
    /// a keeper can sweep every eligible position in one call. Any OTHER per-user failure reverts the
    /// whole batch (all-or-nothing on real errors; a skip leaves no partial state — the A1 returns
    /// precede any mutation). Bounded by MAX_AUTOCLOSE_BATCH; duplicate targets are rejected (BA3).
    pub(crate) fn batch_auto_close_user_position_impl(
        &mut self,
        caller: Address,
        users: Vec<Address>,
        frontend_addresses: Vec<Address>,
        unverified_report: Bytes,
    ) -> Result<(), Vec<u8>> {
        if users.len() != frontend_addresses.len() {
            return Err(err(b"BA1"));
        }
        if users.len() > MAX_AUTOCLOSE_BATCH {
            return Err(err(b"BA2"));
        }
        for i in 0..users.len() {
            for j in (i + 1)..users.len() {
                if users[i] == users[j] {
                    return Err(err(b"BA3"));
                }
            }
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

        #[cfg(not(feature = "stub_boundary"))]
        let price = {
            let oracle = IOracleMiddleware::new(self.oracle.get());
            cm::u(oracle.get_price(self.vm(), Call::new())?)
        };
        #[cfg(feature = "stub_boundary")]
        let price = U256::from(300_000_000_000u64);

        let ineligible = err(b"A1");
        for (user, frontend) in users.iter().zip(frontend_addresses.iter()) {
            match self.auto_close_with_price(caller, *user, *frontend, price) {
                Ok(()) => {}
                Err(e) if e == ineligible => continue, // not eligible at this price -> skip
                Err(e) => return Err(e),               // hard failure -> revert the whole batch
            }
        }

        self.entered.set(false);
        Ok(())
    }

    /// `delete autoCloseUsersData[user]` — zero the whole auto-close config. Emits
    /// `ToggledAutoClose(user, 0, 0, mode, mode)` when the user actually had auto-close
    /// enabled, so an indexer sees the clear (mode 0 = user disable / normal close, 1 =
    /// third-party auto-close). No event is emitted for a user that never enabled it.
    pub(crate) fn clear_auto_close_data(&mut self, user: Address, mode: U256) {
        if self.auto_close_users_data.getter(user).authorized.get() {
            self.emit(ToggledAutoClose {
                user,
                profitTh: U256::ZERO,
                lossTh: U256::ZERO,
                maxSlippage: mode,
                maxLiqFee: mode,
            });
        }
        let mut ac = self.auto_close_users_data.setter(user);
        ac.authorized.set(false);
        ac.profit_th.set(U256::ZERO);
        ac.loss_th.set(U256::ZERO);
        ac.max_slippage.set(U256::ZERO);
        ac.max_liq_fee.set(U256::ZERO);
    }
}
