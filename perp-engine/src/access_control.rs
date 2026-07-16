//! Hand-rolled OZ-style AccessControl, event emit, and the forwarder gate. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// Emit a typed event (topic0 = its SIGNATURE_HASH + indexed topics + ABI data).
    pub(crate) fn emit<E: SolEvent>(&self, event: E) {
        let log = event.encode_log_data();
        let _ = self.vm().raw_log(log.topics(), log.data.as_ref());
    }

    /// OZ `AccessControl.hasRole(role, account)`.
    pub(crate) fn has_role(&self, role: B256, account: Address) -> bool {
        self.role_members.getter(role).get(account)
    }

    /// OZ `AccessControl._grantRole` — grants the role and emits `RoleGranted` ONLY on an
    /// actual change (matching OZ, which returns whether it granted), with `sender` = caller.
    pub(crate) fn grant_role_internal(&mut self, role: B256, account: Address) {
        if self.has_role(role, account) {
            return;
        }
        self.role_members.setter(role).setter(account).set(true);
        let sender = self.vm().msg_sender();
        self.emit(RoleGranted { role, account, sender });
    }

    /// OZ `AccessControl._revokeRole` — revokes the role and emits `RoleRevoked` ONLY on an
    /// actual change, with `sender` = caller.
    pub(crate) fn revoke_role_internal(&mut self, role: B256, account: Address) {
        if !self.has_role(role, account) {
            return;
        }
        self.role_members.setter(role).setter(account).set(false);
        let sender = self.vm().msg_sender();
        self.emit(RoleRevoked { role, account, sender });
    }

    /// OZ `onlyRole(role)` modifier — reverts unless the direct caller holds `role`.
    pub(crate) fn only_role(&self, role: B256) -> Result<(), Vec<u8>> {
        if !self.has_role(role, self.vm().msg_sender()) {
            return Err(err(b"AC"));
        }
        Ok(())
    }

    /// Explicit-sender forwarding gate: the `*For` entrypoints are callable
    /// ONLY by the trusted forwarder, which passes the real `user` as an explicit arg.
    /// This is the Stylus-feasible stand-in for the OZ ERC2771 calldata-suffix
    /// `_msgSender` (the high-level `#[public]` router has no raw-calldata access).
    pub(crate) fn require_forwarder(&self, user: Address) -> Result<Address, Vec<u8>> {
        if self.vm().msg_sender() != self.trusted_forwarder.get() {
            return Err(err(b"F"));
        }
        Ok(user)
    }
}
