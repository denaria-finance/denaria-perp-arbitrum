//! Auto-close (perpAutoClose) enable + execute bodies. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

/// Protocol-level cap on a single `batchAutoCloseUserPositionFor` call — bounds worst-case
/// resource consumption to a predictable maximum (mirrors `MAX_LIQUIDATION_BATCH`).
pub(crate) const MAX_AUTOCLOSE_BATCH: usize = 100;

/// Typed per-user auto-close outcome. `IneligibleBeforeExecution` is returned ONLY from checks
/// that run before any state mutation, so the batch can skip that user with nothing to roll
/// back. Every failure after execution starts is an `Err` and must revert the whole call —
/// the batch must never classify errors by comparing revert bytes.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AutoCloseOutcome {
    Executed,
    IneligibleBeforeExecution,
}

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

        match self.auto_close_with_price(caller, user, frontend_address, price)? {
            AutoCloseOutcome::Executed => {}
            // Single-user external ABI: not-authorized surfaces as the same A1 the Solidity
            // reference reverts with.
            AutoCloseOutcome::IneligibleBeforeExecution => return Err(err(b"A1")),
        }
        self.entered.set(false);
        Ok(())
    }

    /// Guard-free per-user auto-close body, parameterized by the already-read `price`. Shared by
    /// the single (`auto_close_user_position_impl`) and batch (`batch_auto_close_user_position_impl`)
    /// paths so the batch pays the reentrancy guard + report verify + oracle read ONCE.
    ///
    /// Eligibility is decided AFTER the close, from the collateral delta the close actually
    /// produced in the Vault: a pre-close PnL estimate diverges from the realized delta whenever
    /// fees or the close curves move the outcome across a threshold. The only pre-execution check
    /// is authorization, surfaced as the typed `IneligibleBeforeExecution` (nothing written yet,
    /// so the batch may skip it). A realized delta that misses both thresholds is a hard A1 `Err`
    /// AFTER mutation — it must revert the entire transaction, batch included.
    pub(crate) fn auto_close_with_price(
        &mut self,
        caller: Address,
        user: Address,
        frontend_address: Address,
        price: U256,
    ) -> Result<AutoCloseOutcome, Vec<u8>> {
        if !self.auto_close_users_data.getter(user).authorized.get() {
            return Ok(AutoCloseOutcome::IneligibleBeforeExecution);
        }

        let collateral_before: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            collateral_before = vault.user_collateral(self.vm(), Call::new(), user)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            collateral_before = U256::from(1_000u64) * U256::from(WAD_U64);
        }

        // Capture the whole config before the mode-1 clear below zeroes it.
        let profit_th = self.auto_close_users_data.getter(user).profit_th.get();
        let loss_th = self.auto_close_users_data.getter(user).loss_th.get();
        let max_slippage = self.auto_close_users_data.getter(user).max_slippage.get();
        let max_liq_fee = self.auto_close_users_data.getter(user).max_liq_fee.get();

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

        // Log ToggledAutoClose(mode 1 = third-party auto-close) and clear BEFORE the shared close
        // body: that body clears too (mode 0), and running it first would emit mode 0 and flip
        // `authorized` off, suppressing this mode-1 log. The close params are already captured above.
        self.clear_auto_close_data(user, U256::from(1u64));
        // The close's buy-back feeds the slippage EMA like any trade; restore it so a keeper-timed
        // auto-close cannot prime the liquidation pricing benchmark.
        let avg_slippage_l_before = self.avg_slippage_l.get();
        let avg_slippage_s_before = self.avg_slippage_s.get();
        // Force the C1 self-close bad-debt guard on auto-close regardless of caller: a distinct
        // auto-close caller must not be able to close a bad-debt position (that would drain the
        // insurance fund). The auto-close fee is still credited to the distinct `caller` above.
        let (cpnl, cpnl_sign) = self.close_and_withdraw_inner(
            max_slippage,
            max_liq_fee,
            frontend_address,
            user,
            price,
            collateral_before,
            true,
        )?;
        self.avg_slippage_l.set(avg_slippage_l_before);
        self.avg_slippage_s.set(avg_slippage_s_before);

        let collateral_after: U256;
        #[cfg(not(feature = "stub_boundary"))]
        {
            let vault = IVault::new(self.vault.get());
            let cfg = Call::new_mutating(self);
            vault.add_pnl_to_collateral(self.vm(), cfg, user, cpnl, cpnl_sign)?;
            // Measure, don't model: re-read the Vault so the delta reflects whatever the write
            // actually did (its loss branch clamps at zero).
            collateral_after = vault.user_collateral(self.vm(), Call::new(), user)?;
        }
        #[cfg(feature = "stub_boundary")]
        {
            // Stubbed boundary: mirror Vault.addPnlToCollateral exactly (losses clamp at zero).
            // The clamp branch is defensive: the C1 guard forced on this path rejects any close
            // whose loss reaches the collateral before the write, so no auto-close can reach it.
            collateral_after = if cpnl_sign {
                collateral_before + cpnl
            } else if collateral_before >= cpnl {
                collateral_before - cpnl
            } else {
                U256::ZERO
            };
        }

        if collateral_after >= collateral_before {
            if !(profit_th != U256::ZERO && collateral_after - collateral_before >= profit_th) {
                return Err(err(b"A1"));
            }
        } else if !(loss_th != U256::ZERO && collateral_before - collateral_after >= loss_th) {
            return Err(err(b"A1"));
        }

        Ok(AutoCloseOutcome::Executed)
    }

    /// Batch `autoCloseUserPosition` (forwarded keeper helper): verify the report + read the oracle
    /// price ONCE, then run the per-user auto-close body for each target. Best-effort ONLY for the
    /// typed pre-mutation outcome: a user that never authorized auto-close is SKIPPED (nothing was
    /// written for it). EVERY other per-user failure — including a realized collateral delta that
    /// misses the user's thresholds, discovered after that close executed — is a hard error that
    /// reverts the whole batch, so no ineligible close can stand. Bounded by MAX_AUTOCLOSE_BATCH;
    /// duplicate targets are rejected (BA3).
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

        for (user, frontend) in users.iter().zip(frontend_addresses.iter()) {
            match self.auto_close_with_price(caller, *user, *frontend, price)? {
                AutoCloseOutcome::Executed => {}
                // Proven pre-mutation (first check in the body) -> nothing to roll back, skip.
                AutoCloseOutcome::IneligibleBeforeExecution => continue,
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
