//! Initialization constants + the time-locked-parameter keccak hash. Internal `pub(crate)` methods on `PerpEngine`; the public ABI lives in lib.rs.
use super::*;

#[allow(dead_code)]
impl PerpEngine {
    /// The non-configurable protocol constants the Solidity `PerpPair` constructor hardcodes
    /// (the `Decimals` struct, `CurveParameters`, `ClampParameters`, the identity liquidity
    /// matrix ×`liquidityMDecimals`) plus the `PerpStorage` defaults the engine relies on
    /// (signs, leverage caps, oracle decimals, `minimumTradeSize`, funding/liquidation
    /// config). Shared by `initializeBenchmark` + `initializeProduction`; sets nothing that
    /// either initializer configures (oracle/vault/forwarder/MMR/ticker/fees/ema).
    pub(crate) fn init_protocol_constants(&mut self) {
        let wad = U256::from(WAD_U64);
        // Sign-bit defaults must match Solidity `PerpStorage`: `insuranceFundSign = true`,
        // but `fundingRateSign` / `totalTraderExposureSign` default to FALSE (uninitialized
        // bool). Setting the latter two to `true` was a latent state divergence — benign
        // while their magnitudes are zero (and masked once any op overwrites them), but
        // caught bit-exact by the liquidity differential suite (first op is a non-trade, so
        // `totalTraderExposureSign` is never overwritten before the comparison). Stylus
        // storage bools default to false, so they are simply left unset here.
        self.insurance_fund_sign.set(true);
        self.max_leverage.set(U8::from(15u8));
        self.max_lp_leverage.set(U8::from(15u8));
        self.ins_fund_fraction.set(U8::from(6u8));
        self.slip_liquidation_th.set(U8::from(10u8));
        self.oracle_decimals.set(U64::from(100_000_000u64));
        self.minimum_trade_size.set(U256::from(48u64) * wad);
        self.trading_fee_decimals.set(wad);
        self.fee_fractions_decimals.set(U256::from(1_000_000u64));
        self.curve_update_interval.set(U64::from(6u64));
        self.long_curve_parameter_a.set(U256::from(100_000_000u64));
        self.long_curve_parameter_b.set(U256::from(10_000_000u64));
        self.short_curve_parameter_a.set(U256::from(100_000_000u64));
        self.short_curve_parameter_b.set(U256::from(10_000_000u64));
        self.insurance_fund_cap.set(U256::from(500u64) * wad);
        // Liquidation / auto-close / LP-movement config (real PerpStorage defaults).
        // NOTE (gap-analysis fix): liquidation_discount must be set before liquidation
        // (it was previously left at ZERO, which `_computeLiquidationDiscount` reads).
        self.liquidation_discount.set(U32::from(7_500u32));
        self.auto_close_fee.set(U256::from(200_000_000_000_000_000u64)); // 2e17
        self.minimum_liquidity_movement.set(wad / U256::from(100u64)); // 1e16
        // Q80 fixed-point matrix scale: 2^80 (LIQUIDITY_M_Q80), replacing the old decimal 1e22.
        // The adjugate snapshot recovery keys its fast path off `liquidityMDecimals <= 2^80`.
        let liq_m_dec = U256::from_limbs([0u64, 65_536u64, 0, 0]); // 2^80 = 2^16 << 64
        self.liquidity_m_decimals.set(cm::i(liq_m_dec));
        // Bootstrap LP accounting epoch 0 to the Q80 identity matrix; the current/oldest epoch
        // pointers default to 0. All subsequent matrix/funding state lives per epoch.
        self.initialize_liquidity_epoch(U256::ZERO);
        // Decimals matching the real PerpPair constructor:
        // Decimals(1e6,1e6,1e6,1e10,1e18,1e5,2^80,1e18,1e24).
        self.mmr_decimals.set(U256::from(1_000_000u64)); // 1e6
        self.liquidation_decimals.set(U256::from(1_000_000u64)); // 1e6
        self.liquidity_fee_decimals.set(U256::from(10_000_000_000u64)); // 1e10
        self.funding_rate_decimals.set(wad); // 1e18
        self.funding_c_decimals.set(U256::from(100_000u64)); // 1e5
        self.liquidity_g_decimals.set(U256::from(1_000_000_000_000_000_000u64) * U256::from(1_000_000u64)); // 1e24
        self.funding_c.set(U32::from(1_000_000u32)); // 10*1e5
        self.funding_interval.set(U64::from(86_400u64));
        self.param_time_lock.set(U64::from(10u64)); // real default
    }

    /// Common initializer tail: set `MOD_ROLE = keccak256("MOD_ROLE")`, grant
    /// DEFAULT_ADMIN_ROLE (0x0) + MOD_ROLE to the deployer, and flip `initialized`.
    pub(crate) fn finalize_init(&mut self) {
        let mod_role = keccak256("MOD_ROLE");
        self.mod_role.set(mod_role);
        let deployer = self.vm().msg_sender();
        self.grant_role_internal(B256::ZERO, deployer);
        self.grant_role_internal(mod_role, deployer);
        self.initialized.set(true);
    }

    /// Bit-exact `keccak256(abi.encode(keccak256(abi.encodePacked(MMR, tradingFee,
    /// flatTradingFee, feeLP)), liquidityMinFee, liquidityMaxFee, liquidityFeeK,
    /// fundingC, paramTimeLock, minimumTradeSize))`.
    /// All operands are uint256 ABI words, so abi.encode == 32-byte big-endian
    /// concatenation and abi.encodePacked of uint256 == the same 32-byte words.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn time_locked_param_hash(
        &self,
        mmr: U256, trading_fee: U256, flat_trading_fee: U256, fee_lp: U256,
        liq_min_fee: U256, liq_max_fee: U256, liq_fee_k: U256, funding_c: U256,
        param_time_lock: U256, minimum_trade_size: U256,
    ) -> B256 {
        let mut packed = Vec::with_capacity(128);
        for v in [mmr, trading_fee, flat_trading_fee, fee_lp] {
            packed.extend_from_slice(&v.to_be_bytes::<32>());
        }
        let inner = keccak256(&packed);
        let mut enc = Vec::with_capacity(32 * 7);
        enc.extend_from_slice(inner.as_slice());
        for v in [liq_min_fee, liq_max_fee, liq_fee_k, funding_c, param_time_lock, minimum_trade_size] {
            enc.extend_from_slice(&v.to_be_bytes::<32>());
        }
        keccak256(&enc)
    }
}
