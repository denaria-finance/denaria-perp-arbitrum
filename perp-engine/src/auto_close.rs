//! Auto-close (perpAutoClose) enable + execute bodies. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

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
        self.emit(EnabledAutoClose { user, profitTh: profit_th, lossTh: loss_th });
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

        self.clear_auto_close_data(user);
        self.entered.set(false);
        Ok(())
    }

    /// `delete autoCloseUsersData[user]` — zero the whole auto-close config.
    pub(crate) fn clear_auto_close_data(&mut self, user: Address) {
        let mut ac = self.auto_close_users_data.setter(user);
        ac.authorized.set(false);
        ac.profit_th.set(U256::ZERO);
        ac.loss_th.set(U256::ZERO);
        ac.max_slippage.set(U256::ZERO);
        ac.max_liq_fee.set(U256::ZERO);
    }
}
