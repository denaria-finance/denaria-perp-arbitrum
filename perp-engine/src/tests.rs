//! Native test suite for the Stylus `PerpEngine` (extracted from lib.rs).

    use super::*;
    use serde_json::Value;
    use stylus_sdk::alloy_primitives::{Address, B256, I256, U256, U32, U64, U8};
    use stylus_test::TestVM;

    const FUNDING_FIXTURE: &str = include_str!("../../test/fixtures/funding_solidity_vectors.json");
    const PARAM_HASH_FIXTURE: &str = include_str!("../../test/fixtures/param_hash_vectors.json");
    const EVENT_SELECTOR_FIXTURE: &str = include_str!("../../test/fixtures/event_selector_vectors.json");
    const TRADE_FUNDING_DIFF_FIXTURE: &str = include_str!("../../test/fixtures/trade_funding_differential.json");
    const LIQUIDITY_DIFF_FIXTURE: &str = include_str!("../../test/fixtures/liquidity_differential.json");
    const CLOSE_PNL_DIFF_FIXTURE: &str = include_str!("../../test/fixtures/close_pnl_differential.json");
    const LIQUIDATION_DIFF_FIXTURE: &str = include_str!("../../test/fixtures/liquidation_differential.json");

    fn si(v: i64) -> I256 {
        I256::try_from(v).unwrap()
    }
    fn u256s(s: &str) -> U256 {
        U256::from_str_radix(s, 10).unwrap_or_else(|_| panic!("bad u256: {s}"))
    }
    fn idecs(s: &str) -> I256 {
        I256::from_dec_str(s).unwrap_or_else(|_| panic!("bad i256: {s}"))
    }
    fn addr(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    // Writes a distinct value to every field (and one entry of each mapping),
    // then reads them all back. If the packed layout aliased any two fields, a
    // later write would corrupt an earlier field and an assertion would fail.
    #[test]
    fn storage_layout_round_trips() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);

        // -- write everything --
        e.vault.set(addr(0x01));
        e.insurance_fund_sign.set(true);
        e.funding_rate_sign.set(false);
        e.total_trader_exposure_sign.set(true);
        e.last_trade_direction.set(false);
        e.max_leverage.set(U8::from(15u8));
        e.max_lp_leverage.set(U8::from(16u8));
        e.ins_fund_fraction.set(U8::from(6u8));
        e.slip_liquidation_th.set(U8::from(10u8));

        e.oracle.set(addr(0x02));
        e.oracle_decimals.set(U64::from(100_000_000u64));
        e.fee_protocol_addr.set(addr(0x03));
        e.ema_param.set(U64::from(90_000_000u64));
        e.curve_math_adapter.set(addr(0x04));
        e.last_operation_timestamp.set(U64::from(1_700_000_001u64));

        e.last_curve_update.set(U64::from(1_700_000_002u64));
        e.curve_update_interval.set(U64::from(6u64));
        e.funding_interval.set(U64::from(86_400u64));
        e.param_locked_until.set(U64::from(1_700_000_003u64));

        e.param_time_lock.set(U64::from(10u64));
        e.mmr.set(U32::from(40_000u32));
        e.fee_frontend.set(U32::from(300_000u32));
        e.fee_lp.set(U32::from(500_000u32));
        e.liquidation_discount.set(U32::from(7_500u32));
        e.funding_c.set(U32::from(1_000_000u32));

        let wad = U256::from(1_000_000_000_000_000_000u64);
        e.minimum_trade_size.set(U256::from(201));
        e.minimum_liquidity_movement.set(U256::from(202));
        e.trading_fee.set(U256::from(203));
        e.flat_trading_fee.set(U256::from(204));
        e.auto_close_fee.set(U256::from(205));
        e.insurance_fund.set(U256::from(206));
        e.insurance_fund_cap.set(U256::from(207));
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad); // large, tests full width
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);
        e.liquidity_min_fee.set(U256::from(210));
        e.liquidity_max_fee.set(U256::from(211));
        e.liquidity_fee_k.set(U256::from(212));
        e.funding_rate.set(U256::from(213));
        e.total_trader_exposure.set(U256::from(214));
        e.dx0.set(U256::from(215));
        e.dy0.set(U256::from(216));
        e.avg_slippage_l.set(U256::from(217));
        e.avg_slippage_s.set(U256::from(218));
        e.last_validated_price.set(U256::from(219));
        e.short_curve_parameter_a.set(U256::from(220));
        e.short_curve_parameter_b.set(U256::from(221));
        e.long_curve_parameter_a.set(U256::from(222));
        e.long_curve_parameter_b.set(U256::from(223));

        e.liquidity_m00.set(si(-501));
        e.liquidity_m01.set(si(502));
        e.liquidity_m10.set(si(-503));
        e.liquidity_m11.set(si(504));
        e.matrix_row_g0.set(si(505));
        e.matrix_row_g1.set(si(-506));

        e.mmr_decimals.set(U256::from(301));
        e.liquidation_decimals.set(U256::from(302));
        e.fee_fractions_decimals.set(U256::from(303));
        e.liquidity_fee_decimals.set(U256::from(304));
        e.funding_rate_decimals.set(U256::from(305));
        e.funding_c_decimals.set(U256::from(306));
        e.liquidity_m_decimals.set(si(307));
        e.trading_fee_decimals.set(U256::from(308));
        e.liquidity_g_decimals.set(U256::from(309));

        e.mod_role.set(B256::repeat_byte(0xAA));
        e.param_hash.set(B256::repeat_byte(0xBB));
        e.ticker_asset_currency.set(B256::repeat_byte(0xCC));

        {
            let mut p = e.user_virtual_trader_position.setter(addr(0x11));
            p.balance_stable.set(U256::from(601));
            p.balance_asset.set(U256::from(602));
            p.debt_stable.set(U256::from(603));
            p.debt_asset.set(U256::from(604));
            p.funding_fee.set(U256::from(605));
            p.funding_fee_sign.set(true);
            p.initial_funding_rate.set(U256::from(606));
            p.initial_funding_rate_sign.set(false);
        }
        {
            let mut p = e.liquidity_position.setter(addr(0x22));
            p.initial_stable_balance.set(U256::from(701));
            p.initial_asset_balance.set(U256::from(702));
            p.debt_stable.set(U256::from(703));
            p.debt_asset.set(U256::from(704));
            p.inverse_snapshot_m00.set(si(705));
            p.inverse_snapshot_m01.set(si(-706));
            p.inverse_snapshot_m10.set(si(707));
            p.inverse_snapshot_m11.set(si(-708));
            p.snapshot_g0.set(si(709));
            p.snapshot_g1.set(si(-710));
        }
        {
            let mut p = e.auto_close_users_data.setter(addr(0x33));
            p.authorized.set(true);
            p.profit_th.set(U256::from(801));
            p.loss_th.set(U256::from(802));
            p.max_slippage.set(U256::from(803));
            p.max_liq_fee.set(U256::from(804));
        }

        // -- read everything back --
        assert_eq!(e.vault.get(), addr(0x01), "vault");
        assert!(e.insurance_fund_sign.get(), "insurance_fund_sign");
        assert!(!e.funding_rate_sign.get(), "funding_rate_sign");
        assert!(e.total_trader_exposure_sign.get(), "total_trader_exposure_sign");
        assert!(!e.last_trade_direction.get(), "last_trade_direction");
        assert_eq!(e.max_leverage.get(), U8::from(15u8), "max_leverage");
        assert_eq!(e.max_lp_leverage.get(), U8::from(16u8), "max_lp_leverage");
        assert_eq!(e.ins_fund_fraction.get(), U8::from(6u8), "ins_fund_fraction");
        assert_eq!(e.slip_liquidation_th.get(), U8::from(10u8), "slip_liquidation_th");

        assert_eq!(e.oracle.get(), addr(0x02), "oracle");
        assert_eq!(e.oracle_decimals.get(), U64::from(100_000_000u64), "oracle_decimals");
        assert_eq!(e.fee_protocol_addr.get(), addr(0x03), "fee_protocol_addr");
        assert_eq!(e.ema_param.get(), U64::from(90_000_000u64), "ema_param");
        assert_eq!(e.curve_math_adapter.get(), addr(0x04), "curve_math_adapter");
        assert_eq!(e.last_operation_timestamp.get(), U64::from(1_700_000_001u64), "last_operation_timestamp");

        assert_eq!(e.last_curve_update.get(), U64::from(1_700_000_002u64), "last_curve_update");
        assert_eq!(e.curve_update_interval.get(), U64::from(6u64), "curve_update_interval");
        assert_eq!(e.funding_interval.get(), U64::from(86_400u64), "funding_interval");
        assert_eq!(e.param_locked_until.get(), U64::from(1_700_000_003u64), "param_locked_until");

        assert_eq!(e.param_time_lock.get(), U64::from(10u64), "param_time_lock");
        assert_eq!(e.mmr.get(), U32::from(40_000u32), "mmr");
        assert_eq!(e.fee_frontend.get(), U32::from(300_000u32), "fee_frontend");
        assert_eq!(e.fee_lp.get(), U32::from(500_000u32), "fee_lp");
        assert_eq!(e.liquidation_discount.get(), U32::from(7_500u32), "liquidation_discount");
        assert_eq!(e.funding_c.get(), U32::from(1_000_000u32), "funding_c");

        assert_eq!(e.minimum_trade_size.get(), U256::from(201), "minimum_trade_size");
        assert_eq!(e.minimum_liquidity_movement.get(), U256::from(202), "minimum_liquidity_movement");
        assert_eq!(e.trading_fee.get(), U256::from(203), "trading_fee");
        assert_eq!(e.flat_trading_fee.get(), U256::from(204), "flat_trading_fee");
        assert_eq!(e.auto_close_fee.get(), U256::from(205), "auto_close_fee");
        assert_eq!(e.insurance_fund.get(), U256::from(206), "insurance_fund");
        assert_eq!(e.insurance_fund_cap.get(), U256::from(207), "insurance_fund_cap");
        assert_eq!(e.global_liquidity_stable.get(), U256::from(18_000_000u64) * wad, "global_liquidity_stable");
        assert_eq!(e.global_liquidity_asset.get(), U256::from(6_000u64) * wad, "global_liquidity_asset");
        assert_eq!(e.liquidity_min_fee.get(), U256::from(210), "liquidity_min_fee");
        assert_eq!(e.liquidity_max_fee.get(), U256::from(211), "liquidity_max_fee");
        assert_eq!(e.liquidity_fee_k.get(), U256::from(212), "liquidity_fee_k");
        assert_eq!(e.funding_rate.get(), U256::from(213), "funding_rate");
        assert_eq!(e.total_trader_exposure.get(), U256::from(214), "total_trader_exposure");
        assert_eq!(e.dx0.get(), U256::from(215), "dx0");
        assert_eq!(e.dy0.get(), U256::from(216), "dy0");
        assert_eq!(e.avg_slippage_l.get(), U256::from(217), "avg_slippage_l");
        assert_eq!(e.avg_slippage_s.get(), U256::from(218), "avg_slippage_s");
        assert_eq!(e.last_validated_price.get(), U256::from(219), "last_validated_price");
        assert_eq!(e.short_curve_parameter_a.get(), U256::from(220), "short_curve_parameter_a");
        assert_eq!(e.short_curve_parameter_b.get(), U256::from(221), "short_curve_parameter_b");
        assert_eq!(e.long_curve_parameter_a.get(), U256::from(222), "long_curve_parameter_a");
        assert_eq!(e.long_curve_parameter_b.get(), U256::from(223), "long_curve_parameter_b");

        assert_eq!(e.liquidity_m00.get(), si(-501), "liquidity_m00");
        assert_eq!(e.liquidity_m01.get(), si(502), "liquidity_m01");
        assert_eq!(e.liquidity_m10.get(), si(-503), "liquidity_m10");
        assert_eq!(e.liquidity_m11.get(), si(504), "liquidity_m11");
        assert_eq!(e.matrix_row_g0.get(), si(505), "matrix_row_g0");
        assert_eq!(e.matrix_row_g1.get(), si(-506), "matrix_row_g1");

        assert_eq!(e.mmr_decimals.get(), U256::from(301), "mmr_decimals");
        assert_eq!(e.liquidation_decimals.get(), U256::from(302), "liquidation_decimals");
        assert_eq!(e.fee_fractions_decimals.get(), U256::from(303), "fee_fractions_decimals");
        assert_eq!(e.liquidity_fee_decimals.get(), U256::from(304), "liquidity_fee_decimals");
        assert_eq!(e.funding_rate_decimals.get(), U256::from(305), "funding_rate_decimals");
        assert_eq!(e.funding_c_decimals.get(), U256::from(306), "funding_c_decimals");
        assert_eq!(e.liquidity_m_decimals.get(), si(307), "liquidity_m_decimals");
        assert_eq!(e.trading_fee_decimals.get(), U256::from(308), "trading_fee_decimals");
        assert_eq!(e.liquidity_g_decimals.get(), U256::from(309), "liquidity_g_decimals");

        assert_eq!(e.mod_role.get(), B256::repeat_byte(0xAA), "mod_role");
        assert_eq!(e.param_hash.get(), B256::repeat_byte(0xBB), "param_hash");
        assert_eq!(e.ticker_asset_currency.get(), B256::repeat_byte(0xCC), "ticker_asset_currency");

        let p = e.user_virtual_trader_position.getter(addr(0x11));
        assert_eq!(p.balance_stable.get(), U256::from(601), "vtp.balance_stable");
        assert_eq!(p.balance_asset.get(), U256::from(602), "vtp.balance_asset");
        assert_eq!(p.debt_stable.get(), U256::from(603), "vtp.debt_stable");
        assert_eq!(p.debt_asset.get(), U256::from(604), "vtp.debt_asset");
        assert_eq!(p.funding_fee.get(), U256::from(605), "vtp.funding_fee");
        assert!(p.funding_fee_sign.get(), "vtp.funding_fee_sign");
        assert_eq!(p.initial_funding_rate.get(), U256::from(606), "vtp.initial_funding_rate");
        assert!(!p.initial_funding_rate_sign.get(), "vtp.initial_funding_rate_sign");

        let l = e.liquidity_position.getter(addr(0x22));
        assert_eq!(l.initial_stable_balance.get(), U256::from(701), "lp.initial_stable_balance");
        assert_eq!(l.initial_asset_balance.get(), U256::from(702), "lp.initial_asset_balance");
        assert_eq!(l.debt_stable.get(), U256::from(703), "lp.debt_stable");
        assert_eq!(l.debt_asset.get(), U256::from(704), "lp.debt_asset");
        assert_eq!(l.inverse_snapshot_m00.get(), si(705), "lp.inv_m00");
        assert_eq!(l.inverse_snapshot_m01.get(), si(-706), "lp.inv_m01");
        assert_eq!(l.inverse_snapshot_m10.get(), si(707), "lp.inv_m10");
        assert_eq!(l.inverse_snapshot_m11.get(), si(-708), "lp.inv_m11");
        assert_eq!(l.snapshot_g0.get(), si(709), "lp.snapshot_g0");
        assert_eq!(l.snapshot_g1.get(), si(-710), "lp.snapshot_g1");

        let a = e.auto_close_users_data.getter(addr(0x33));
        assert!(a.authorized.get(), "acd.authorized");
        assert_eq!(a.profit_th.get(), U256::from(801), "acd.profit_th");
        assert_eq!(a.loss_th.get(), U256::from(802), "acd.loss_th");
        assert_eq!(a.max_slippage.get(), U256::from(803), "acd.max_slippage");
        assert_eq!(a.max_liq_fee.get(), U256::from(804), "acd.max_liq_fee");

        // distinct user keys must not collide
        assert_eq!(
            e.user_virtual_trader_position.getter(addr(0x99)).balance_stable.get(),
            U256::ZERO,
            "unset mapping key must be zero"
        );
    }

    // Proves the shared math crate is reachable from the engine crate without an
    // entrypoint clash (depended on with default-features=false). Reuses the
    // direct-long-default golden vector; the engine's trade path
    // will call these helpers for real.
    #[test]
    fn core_math_is_callable_from_engine() {
        use denaria_curve_math_stylus as cm;
        let wad = U256::from(1_000_000_000_000_000_000u64);
        let out = cm::compute_long_return_inner(
            cm::i(U256::from(1_000u64) * wad),                                  // size 1000e18
            cm::i(U256::from(300_000_000_000u64)),                             // spot 3000e8
            cm::i(U256::from(100_000_000u64)),                                 // oracle 1e8
            cm::i(U256::from(5_999_700u64) * U256::from(1_000_000_000_000u64)), // guess 5999.7e18
            cm::i(U256::from(10_000_000u64) * wad),                            // stable 1e25
            cm::i(U256::from(6_000u64) * wad),                                 // asset 6000e18
            cm::i(U256::from(100_000_000u64)),                                 // A 1e8
            cm::i(U256::from(10_000_000u64)),                                  // B 1e7
            cm::i(U256::from(100_000_000u64)),                                 // curve decimals 1e8
        );
        assert_eq!(
            cm::u(out),
            U256::from_str_radix("333333049680100365", 10).unwrap(),
            "engine must reproduce the direct-long golden vector via the shared math crate"
        );
    }

    // Bit-exact parity of compute_funding_rate against the Solidity FundingRef
    // transcription of perpFunding.computeFundingRate (golden vectors).
    #[test]
    fn funding_rate_golden_vectors() {
        let root: Value = serde_json::from_str(FUNDING_FIXTURE).expect("funding fixture json");
        let vectors = root["vectors"].as_array().expect("vectors array");
        let mut checked = 0u32;
        let mut failures: Vec<String> = Vec::new();

        for v in vectors {
            if v["kind"].as_str().unwrap() != "fundingRate" {
                continue;
            }
            let label = v["label"].as_str().unwrap();
            let inp = &v["inputs"];

            let block_ts: u64 = inp["blockTs"].as_str().unwrap().parse().unwrap();
            let vm = TestVM::new();
            vm.set_block_timestamp(block_ts);
            let mut e = PerpEngine::from(&vm);

            e.global_liquidity_asset.set(u256s(inp["globalLiquidityAsset"].as_str().unwrap()));
            e.global_liquidity_stable.set(u256s(inp["globalLiquidityStable"].as_str().unwrap()));
            e.total_trader_exposure.set(u256s(inp["totalTraderExposure"].as_str().unwrap()));
            e.total_trader_exposure_sign.set(inp["totalTraderExposureSign"].as_bool().unwrap());
            e.oracle_decimals.set(U64::from(inp["oracleDecimals"].as_str().unwrap().parse::<u64>().unwrap()));
            e.funding_c.set(U32::from(inp["fundingC"].as_str().unwrap().parse::<u32>().unwrap()));
            e.funding_interval.set(U64::from(inp["fundingInterval"].as_str().unwrap().parse::<u64>().unwrap()));
            e.funding_c_decimals.set(u256s(inp["fundingCDecimals"].as_str().unwrap()));
            e.funding_rate_decimals.set(u256s(inp["fundingRateDecimals"].as_str().unwrap()));

            let price = u256s(inp["price"].as_str().unwrap());
            let timestamp = u256s(inp["timestamp"].as_str().unwrap());
            let (rate, sign) = e.compute_funding_rate(price, timestamp).expect("compute_funding_rate");

            let exp_rate = u256s(v["expected"]["rate"].as_str().unwrap());
            let exp_sign = v["expected"]["rateSign"].as_bool().unwrap();
            if rate != exp_rate || sign != exp_sign {
                failures.push(format!(
                    "[{label}] got ({rate},{sign}), expected ({exp_rate},{exp_sign})"
                ));
            }
            checked += 1;
        }

        assert!(failures.is_empty(), "funding-rate parity failures:\n{}", failures.join("\n"));
        assert!(checked >= 4, "expected >=4 funding-rate vectors, got {checked}");
    }

    // Smoke coverage for compute_funding_fee with no LP position (star == 0), so
    // the fee reduces to the trader-exposure term. Exercises the exposure and
    // deltaF signedSum paths for both result signs. (Full golden-vector parity
    // for the LP/star path is the next funding step.)
    #[test]
    fn funding_fee_zero_lp_exposure_term() {
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        let wad = U256::from(1_000_000_000_000_000_000u64);

        e.funding_rate.set(U256::from(2u64) * wad);
        e.funding_rate_sign.set(true);
        e.funding_rate_decimals.set(wad);
        e.liquidity_g_decimals.set(wad);
        // invLMD must be non-zero (it divides even when b == 0).
        e.liquidity_m_decimals.set(cm::i(U256::from(10_000u64) * wad)); // 1e22

        // case 1: balanceAsset 10e18, no debt -> exposure (10e18,+); deltaF2 (1e18,+)
        //         fee = 10e18 * 1e18 / 1e18 = 10e18, positive.
        let user1 = addr(0x55);
        {
            let mut p = e.user_virtual_trader_position.setter(user1);
            p.balance_asset.set(U256::from(10u64) * wad);
            p.initial_funding_rate.set(wad);
            p.initial_funding_rate_sign.set(true);
        }
        let (fee1, sign1) = e.compute_funding_fee(user1);
        assert_eq!(fee1, U256::from(10u64) * wad, "fee1 magnitude");
        assert!(sign1, "fee1 sign");

        // case 2: balanceAsset 5e18, debtAsset 8e18 -> exposure (3e18,-); fee (3e18,-)
        let user2 = addr(0x56);
        {
            let mut p = e.user_virtual_trader_position.setter(user2);
            p.balance_asset.set(U256::from(5u64) * wad);
            p.debt_asset.set(U256::from(8u64) * wad);
            p.initial_funding_rate.set(wad);
            p.initial_funding_rate_sign.set(true);
        }
        let (fee2, sign2) = e.compute_funding_fee(user2);
        assert_eq!(fee2, U256::from(3u64) * wad, "fee2 magnitude");
        assert!(!sign2, "fee2 sign");
    }

    // Bit-exact parity of compute_funding_fee_with against the Solidity FundingRef
    // transcription of perpFunding._computeFundingFee — including the LP/star path.
    #[test]
    fn funding_fee_golden_vectors() {
        let root: Value = serde_json::from_str(FUNDING_FIXTURE).expect("funding fixture json");
        let vectors = root["vectors"].as_array().expect("vectors array");
        let mut checked = 0u32;
        let mut failures: Vec<String> = Vec::new();

        for v in vectors {
            if v["kind"].as_str().unwrap() != "fundingFee" {
                continue;
            }
            let label = v["label"].as_str().unwrap();
            let inp = &v["inputs"];

            let vm = TestVM::new();
            let mut e = PerpEngine::from(&vm);

            e.funding_rate.set(u256s(inp["fundingRate"].as_str().unwrap()));
            e.funding_rate_sign.set(inp["fundingRateSign"].as_bool().unwrap());
            e.liquidity_m_decimals.set(idecs(inp["invLMD"].as_str().unwrap()));
            e.liquidity_g_decimals.set(u256s(inp["liquidityGDecimals"].as_str().unwrap()));
            e.funding_rate_decimals.set(u256s(inp["fundingRateDecimals"].as_str().unwrap()));
            e.matrix_row_g0.set(idecs(inp["matrixRowG0"].as_str().unwrap()));
            e.matrix_row_g1.set(idecs(inp["matrixRowG1"].as_str().unwrap()));
            e.liquidity_m10.set(idecs(inp["liquidityM10"].as_str().unwrap()));
            e.liquidity_m11.set(idecs(inp["liquidityM11"].as_str().unwrap()));

            let user = addr(0x77);
            {
                let mut lp = e.liquidity_position.setter(user);
                lp.snapshot_g0.set(idecs(inp["snapshotG0"].as_str().unwrap()));
                lp.snapshot_g1.set(idecs(inp["snapshotG1"].as_str().unwrap()));
                lp.initial_stable_balance.set(u256s(inp["initialStableBalance"].as_str().unwrap()));
                lp.initial_asset_balance.set(u256s(inp["initialAssetBalance"].as_str().unwrap()));
                lp.inverse_snapshot_m00.set(idecs(inp["invM00"].as_str().unwrap()));
                lp.inverse_snapshot_m01.set(idecs(inp["invM01"].as_str().unwrap()));
                lp.inverse_snapshot_m10.set(idecs(inp["invM10"].as_str().unwrap()));
                lp.inverse_snapshot_m11.set(idecs(inp["invM11"].as_str().unwrap()));
                lp.debt_asset.set(u256s(inp["lpDebtAsset"].as_str().unwrap()));
            }
            {
                let mut vp = e.user_virtual_trader_position.setter(user);
                vp.balance_asset.set(u256s(inp["balanceAsset"].as_str().unwrap()));
                vp.debt_asset.set(u256s(inp["vpDebtAsset"].as_str().unwrap()));
                vp.initial_funding_rate.set(u256s(inp["initialFundingRate"].as_str().unwrap()));
                vp.initial_funding_rate_sign.set(inp["initialFundingRateSign"].as_bool().unwrap());
            }

            let fr = u256s(inp["fr"].as_str().unwrap());
            let fr_sign = inp["frSign"].as_bool().unwrap();
            let (fee, sign) = e.compute_funding_fee_with(user, fr, fr_sign);

            let exp_fee = u256s(v["expected"]["fee"].as_str().unwrap());
            let exp_sign = v["expected"]["feeSign"].as_bool().unwrap();
            if fee != exp_fee || sign != exp_sign {
                failures.push(format!(
                    "[{label}] got ({fee},{sign}), expected ({exp_fee},{exp_sign})"
                ));
            }
            checked += 1;
        }

        assert!(failures.is_empty(), "funding-fee parity failures:\n{}", failures.join("\n"));
        assert!(checked >= 2, "expected >=2 funding-fee vectors, got {checked}");
    }

    // update_fg accumulates the funding rate (signedSum) and advances row G by
    // b*M[1][i]/invLMD. Inputs reuse the "rate-within" golden vector, whose newRate
    // = 104166666666666000 (+); from there b and G are derived by hand.
    #[test]
    fn update_fg_accumulates_rate_and_g() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(4600);
        let mut e = PerpEngine::from(&vm);

        // rate-within storage
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.total_trader_exposure.set(U256::from(100u64) * wad);
        e.total_trader_exposure_sign.set(true);
        e.oracle_decimals.set(U64::from(100_000_000u64));
        e.funding_c.set(U32::from(1_000_000u32));
        e.funding_interval.set(U64::from(86_400u64));
        e.funding_c_decimals.set(U256::from(100_000u64));
        e.funding_rate_decimals.set(wad);

        // G-update params
        e.liquidity_g_decimals.set(U256::from(10_000_000_000u64)); // 1e10
        e.liquidity_m_decimals.set(cm::i(U256::from(10_000u64) * wad)); // 1e22
        e.liquidity_m10.set(cm::i(U256::from(10_000u64) * wad)); // 1e22
        e.liquidity_m11.set(cm::i(U256::from(20_000u64) * wad)); // 2e22
        e.funding_rate.set(U256::ZERO);
        e.funding_rate_sign.set(true);

        e.update_fg(U256::from(300_000_000_000u64), U256::from(1000u64)).expect("update_fg");

        assert_eq!(e.funding_rate.get(), u256s("104166666666666000"), "accumulated funding rate");
        assert!(e.funding_rate_sign.get(), "funding rate sign");
        assert_eq!(e.matrix_row_g0.get(), cm::i(U256::from(1_041_666_666u64)), "G0 = b*m10/invLMD");
        assert_eq!(e.matrix_row_g1.get(), cm::i(U256::from(2_083_333_332u64)), "G1 = b*m11/invLMD");
    }

    // Seeds a balanced engine (price 3000, stable 1.8e25, asset 6000e18) with the
    // default fee/curve/funding config, ready for a trade.
    fn seed_trade_engine(e: &mut PerpEngine) {
        let wad = U256::from(WAD_U64);
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);
        e.oracle_decimals.set(U64::from(100_000_000u64));
        e.trading_fee.set(U256::ZERO);
        e.trading_fee_decimals.set(wad);
        e.flat_trading_fee.set(U256::from(120_000_000_000_000_000u64)); // 0.12e18
        e.fee_frontend.set(U32::from(300_000u32));
        e.fee_lp.set(U32::from(500_000u32));
        e.fee_fractions_decimals.set(U256::from(1_000_000u64));
        e.ema_param.set(U64::from(90_000_000u64));
        e.long_curve_parameter_a.set(U256::from(100_000_000u64));
        e.long_curve_parameter_b.set(U256::from(10_000_000u64));
        e.short_curve_parameter_a.set(U256::from(100_000_000u64));
        e.short_curve_parameter_b.set(U256::from(10_000_000u64));
        e.curve_update_interval.set(U64::from(6u64));
        // liquidity removal fee config (real PerpStorage defaults)
        e.liquidity_min_fee.set(U256::ZERO);
        e.liquidity_max_fee.set(U256::from(500_000_000u64)); // 5e8 = 0.5% (in 1e10)
        e.liquidity_fee_k.set(U256::from(10_000_000_000u64)); // 1e10
        e.liquidity_fee_decimals.set(U256::from(10_000_000_000u64)); // 1e10
        // liquidity matrix M = identity * liqMDec (det normalized 1)
        let liq_m_dec = U256::from(10_000u64) * wad; // 1e22
        e.liquidity_m_decimals.set(cm::i(liq_m_dec));
        e.liquidity_m00.set(cm::i(liq_m_dec));
        e.liquidity_m11.set(cm::i(liq_m_dec));
        // funding config (so update_fg / compute_funding_fee don't divide by zero)
        e.funding_rate_decimals.set(wad);
        e.liquidity_g_decimals.set(U256::from(10_000_000_000u64)); // 1e10
        e.funding_c.set(U32::from(1_000_000u32));
        e.funding_interval.set(U64::from(86_400u64));
        e.funding_c_decimals.set(U256::from(100_000u64));
        e.total_trader_exposure_sign.set(true);
        e.funding_rate_sign.set(true);
        e.insurance_fund_sign.set(true);
        e.insurance_fund_cap.set(U256::from(500u64) * wad);
        e.fee_protocol_addr.set(addr(0x99));
        e.max_leverage.set(U8::from(15u8));
        e.max_lp_leverage.set(U8::from(15u8));
        e.minimum_trade_size.set(U256::from(48u64) * wad);
        // liquidation / auto-close config (real PerpStorage defaults)
        e.mmr.set(U32::from(40_000u32)); // (40*1e6)/1000
        e.mmr_decimals.set(U256::from(1_000_000u64)); // 1e6
        e.liquidation_decimals.set(U256::from(1_000_000u64)); // 1e6
        e.liquidation_discount.set(U32::from(7_500u32));
        e.ins_fund_fraction.set(U8::from(6u8));
        e.slip_liquidation_th.set(U8::from(10u8));
        e.auto_close_fee.set(U256::from(200_000_000_000_000_000u64)); // 2e17
    }

    // Wiring check for the long branch of execute_trade: trade_return must equal
    // the (golden-tested) curve solver on the engine-computed effective input and
    // clamped guess, and the pool/position state must update accordingly.
    #[test]
    fn execute_trade_long_wiring() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);

        let size = U256::from(1_000u64) * wad;
        let spot = U256::from(300_000_000_000u64); // 3000 * 1e8
        let od = U256::from(100_000_000u64);
        let stable = U256::from(18_000_000u64) * wad;
        let asset = U256::from(6_000u64) * wad;

        // Replicate the engine's guess clamp and effective-input derivation.
        let zsr = size * od / spot;
        let clamped_guess = asset - zsr; // since guess=0 < asset - zsr
        let flat_fee = U256::from(120_000_000_000_000_000u64);
        let frontend_fee_part = flat_fee * U256::from(300_000u64) / U256::from(1_000_000u64);
        let effective = size - (flat_fee - frontend_fee_part); // dy0 == 0
        let expected_return = e.compute_long_return(
            effective, spot, od, clamped_guess, stable, asset,
            U256::from(100_000_000u64), U256::from(10_000_000u64),
        );

        let user = addr(0xAA);
        let got = e
            .execute_trade(true, size, U256::ZERO, U256::ZERO, Address::ZERO, user, spot)
            .expect("long trade should not revert");

        assert_eq!(got, expected_return, "trade_return matches the curve solver on the wired inputs");
        assert!(got > U256::ZERO && got <= zsr, "0 < tradeReturn <= zeroSlippage");
        // long: globalLiquidityAsset -= tradeReturn; user.balanceAsset += tradeReturn
        assert_eq!(e.global_liquidity_asset.get(), asset - got, "asset reserve drops by tradeReturn");
        assert_eq!(
            e.user_virtual_trader_position.getter(user).balance_asset.get(),
            got,
            "user gains tradeReturn in balanceAsset"
        );
        // adjSize added to stable reserve
        let adj_size = size - flat_fee * (U256::from(1_000_000u64) - U256::from(500_000u64)) / U256::from(1_000_000u64)
            + flat_fee * U256::from(300_000u64) / U256::from(1_000_000u64);
        assert_eq!(e.global_liquidity_stable.get(), stable + adj_size, "stable reserve grows by adjSize");
    }

    // get_lp_liquidity_balance: empty LP -> (0,0); with M(t)==M(t0) (identity*d and
    // inverseSnapshotM = identity*d) the balance equals the initial shares.
    #[test]
    fn lp_liquidity_balance() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        let d = U256::from(10_000u64) * wad; // 1e22
        e.liquidity_m_decimals.set(cm::i(d));
        e.liquidity_m00.set(cm::i(d));
        e.liquidity_m11.set(cm::i(d));
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);

        // empty LP
        assert_eq!(e.get_lp_liquidity_balance(addr(0x01)), (U256::ZERO, U256::ZERO), "empty LP");

        // LP with M^-1(t0) = identity*d -> M(t)*M^-1(t0) = identity -> initial shares
        let lpa = addr(0x02);
        {
            let mut lp = e.liquidity_position.setter(lpa);
            lp.inverse_snapshot_m00.set(cm::i(d));
            lp.inverse_snapshot_m11.set(cm::i(d));
            lp.initial_stable_balance.set(U256::from(1_000u64) * wad);
            lp.initial_asset_balance.set(U256::from(2u64) * wad);
        }
        assert_eq!(
            e.get_lp_liquidity_balance(lpa),
            (U256::from(1_000u64) * wad, U256::from(2u64) * wad),
            "identity snapshot returns initial shares"
        );

        // Public view wrappers expose the same values (selector wiring + return).
        assert_eq!(
            e.get_lp_liquidity_balance_public(lpa).unwrap(),
            e.get_lp_liquidity_balance(lpa),
            "getLpLiquidityBalance wrapper == private helper"
        );
    }

    // Negative-LP-balance clamp (parity + DoS-hardening): when a recovered leg
    // (initialShares · M(t)·M⁻¹(t0)) goes negative, get_lp_liquidity_balance must return 0
    // for that leg instead of reverting on the `cm::u` cast. Here M(t) flips the stable leg
    // negative (m00 = -d) while leaving the asset leg positive (m11 = d), with an identity
    // snapshot so actualM == M(t): stable raw leg = -initialStable (clamped to 0), asset raw
    // leg = initialAsset (preserved). Pre-fix this path panicked in `cm::u`.
    #[test]
    fn lp_liquidity_balance_clamps_negative_leg() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        let d = U256::from(10_000u64) * wad; // 1e22
        e.liquidity_m_decimals.set(cm::i(d));
        e.liquidity_m00.set(-cm::i(d)); // stable leg -> negative recovery
        e.liquidity_m11.set(cm::i(d)); // asset leg  -> positive recovery
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);

        let lpa = addr(0x02);
        {
            let mut lp = e.liquidity_position.setter(lpa);
            lp.inverse_snapshot_m00.set(cm::i(d)); // identity snapshot -> actualM == M(t)
            lp.inverse_snapshot_m11.set(cm::i(d));
            lp.initial_stable_balance.set(U256::from(1_000u64) * wad);
            lp.initial_asset_balance.set(U256::from(2u64) * wad);
        }
        assert_eq!(
            e.get_lp_liquidity_balance(lpa),
            (U256::ZERO, U256::from(2u64) * wad),
            "negative stable leg clamps to 0, positive asset leg preserved"
        );
    }

    // Public config view: ReadParameters returns the 8-field tuple in PerpStorage
    // order (vault, oracle, minTradeSize, minLiquidityMovement, feeFrontend, feeLP,
    // insuranceFundCap, tickerAssetCurrency) — the manager reads [3] as liquidityTh.
    #[test]
    fn vault_integration_getters() {
        // The real Vault reads these from perpPair; the engine must expose them
        // (matching the Solidity auto-getter shapes) or addCollateral/removeCollateral revert.
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.last_operation_timestamp.set(U64::from(1_700_000_000u64));
        e.mmr.set(U32::from(40_000u32));
        e.max_lp_leverage.set(U8::from(15u8));
        let u = addr(0x33);
        {
            let mut p = e.user_virtual_trader_position.setter(u);
            p.balance_stable.set(U256::from(11u64));
            p.balance_asset.set(U256::from(22u64));
            p.debt_stable.set(U256::from(33u64));
            p.debt_asset.set(U256::from(44u64));
            p.funding_fee.set(U256::from(55u64));
            p.funding_fee_sign.set(true);
            p.initial_funding_rate.set(U256::from(66u64));
            p.initial_funding_rate_sign.set(false);
        }
        {
            let mut lp = e.liquidity_position.setter(u);
            lp.initial_stable_balance.set(U256::from(77u64));
            lp.initial_asset_balance.set(U256::from(88u64));
            lp.debt_stable.set(U256::from(99u64));
            lp.debt_asset.set(U256::from(111u64));
        }
        assert_eq!(e.last_operation_timestamp_public().unwrap(), U256::from(1_700_000_000u64), "lastOperationTimestamp");
        assert_eq!(e.mmr_public().unwrap(), U256::from(40_000u64), "MMR");
        assert_eq!(e.max_lp_leverage_public().unwrap(), U256::from(15u64), "maxLpLeverage");
        assert_eq!(
            e.user_virtual_trader_position_public(u).unwrap(),
            (U256::from(11u64), U256::from(22u64), U256::from(33u64), U256::from(44u64), U256::from(55u64), true, U256::from(66u64), false),
            "userVirtualTraderPosition 8-tuple"
        );
        assert_eq!(
            e.liquidity_position_public(u).unwrap(),
            (U256::from(77u64), U256::from(88u64), U256::from(99u64), U256::from(111u64)),
            "liquidityPosition 4-tuple"
        );
    }

    #[test]
    fn read_parameters_view() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.vault.set(addr(0x11));
        e.oracle.set(addr(0x22));
        e.minimum_trade_size.set(U256::from(48u64) * wad);
        e.minimum_liquidity_movement.set(wad / U256::from(100u64));
        e.fee_frontend.set(U32::from(300_000u32));
        e.fee_lp.set(U32::from(500_000u32));
        e.insurance_fund_cap.set(U256::from(500u64) * wad);
        e.ticker_asset_currency.set(B256::from(U256::from(0xABCDu64)));

        let (vault, oracle, min_trade, min_liq, fee_fe, fee_lp, ins_cap, ticker) =
            e.read_parameters().unwrap();
        assert_eq!(vault, addr(0x11), "vault");
        assert_eq!(oracle, addr(0x22), "oracle");
        assert_eq!(min_trade, U256::from(48u64) * wad, "minimumTradeSize");
        assert_eq!(min_liq, wad / U256::from(100u64), "minimumLiquidityMovement (liquidityTh)");
        assert_eq!(fee_fe, U256::from(300_000u64), "feeFrontend widened");
        assert_eq!(fee_lp, U256::from(500_000u64), "feeLP widened");
        assert_eq!(ins_cap, U256::from(500u64) * wad, "insuranceFundCap");
        assert_eq!(ticker, B256::from(U256::from(0xABCDu64)), "tickerAssetCurrency");
    }

    // Under stub_boundary, getPrice() returns the host oracle constant (3000e8),
    // matching the price used across the other stub_boundary end-to-end tests.
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn get_price_stub() {
        let vm = TestVM::new();
        let e = PerpEngine::from(&vm);
        assert_eq!(e.get_price().unwrap(), U256::from(300_000_000_000u64), "stub oracle price");
    }

    // calc_mr for a pure long-asset position (no debt/funding, no LP):
    // PnL = balanceAsset*price = 3000e18; positionValue = 3000e18;
    // totColl = collateral(1000e18) + 3000e18 = 4000e18;
    // MR = 4000e18 * 1e6 / 3000e18 = 1,333,333.
    #[test]
    fn calc_mr_pure_asset_position() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let ts = 1_700_000_000u64;
        vm.set_block_timestamp(ts);
        let mut e = PerpEngine::from(&vm);
        e.liquidity_m_decimals.set(cm::i(U256::from(10_000u64) * wad)); // invLMD nonzero
        e.funding_rate_decimals.set(wad);
        e.liquidity_g_decimals.set(U256::from(10_000_000_000u64));
        e.funding_rate.set(U256::ZERO);
        e.funding_rate_sign.set(true);
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);

        let user = addr(0xAB);
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad); // 1e18 asset, no debt, no funding
        }
        let mr = e.calc_mr(user, U256::from(300_000_000_000u64), U256::from(1_000u64) * wad, U256::from(ts)).expect("calc_mr");
        assert_eq!(mr, U256::from(1_333_333u64), "MR = 4000e18*1e6/3000e18");
    }

    // margin_check_data (the Vault's one-call margin read) must return the SAME margin ratio as
    // calc_mr — both build on margin_check_core — plus raw fields matching the individual getters
    // and maxLpLeverage/MMR. Same state as calc_mr_pure_asset_position (last_op == block ts).
    #[test]
    fn margin_check_data_matches_calc_mr_and_getters() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let ts = 1_700_000_000u64;
        vm.set_block_timestamp(ts);
        let mut e = PerpEngine::from(&vm);
        e.liquidity_m_decimals.set(cm::i(U256::from(10_000u64) * wad));
        e.funding_rate_decimals.set(wad);
        e.liquidity_g_decimals.set(U256::from(10_000_000_000u64));
        e.funding_rate.set(U256::ZERO);
        e.funding_rate_sign.set(true);
        e.global_liquidity_stable.set(U256::from(18_000_000u64) * wad);
        e.global_liquidity_asset.set(U256::from(6_000u64) * wad);
        e.last_operation_timestamp.set(U64::from(ts));
        e.max_lp_leverage.set(U8::from(10u8));
        e.mmr.set(U32::from(40_000u32));

        let user = addr(0xAB);
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad); // 1e18 asset, no debt/funding/LP
        }

        let price = U256::from(300_000_000_000u64);
        let collateral = U256::from(1_000u64) * wad;
        let last_op = U256::from(e.last_operation_timestamp.get());
        let expected_mr = e.calc_mr(user, price, collateral, last_op).expect("calc_mr");

        let (mr, bs, ba, ds, da, lpds, lpda, slp, alp, max_lp, mmr) =
            e.margin_check_data(user, price, collateral).expect("margin_check_data");

        assert_eq!(mr, expected_mr, "margin_check_data MR must equal calc_mr");
        let vp = e.user_virtual_trader_position.getter(user);
        assert_eq!(bs, vp.balance_stable.get());
        assert_eq!(ba, vp.balance_asset.get());
        assert_eq!(ds, vp.debt_stable.get());
        assert_eq!(da, vp.debt_asset.get());
        let lp = e.liquidity_position.getter(user);
        assert_eq!(lpds, lp.debt_stable.get());
        assert_eq!(lpda, lp.debt_asset.get());
        let (elp_s, elp_a) = e.get_lp_liquidity_balance(user);
        assert_eq!(slp, elp_s);
        assert_eq!(alp, elp_a);
        assert_eq!(max_lp, U256::from(10u64), "maxLpLeverage");
        assert_eq!(mmr, U256::from(40_000u64), "MMR");
    }

    // remove_liquidity with the removal fee waived (maxFee=0): an identity-snapshot
    // LP of (1000e18 stable, 2e18 asset) is pulled entirely back into the trader's
    // virtual balances; globals drop by the removed amounts; dx0/dy0 reset; exposure
    // grows by the returned asset.
    #[test]
    fn remove_liquidity_no_fee() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.liquidity_max_fee.set(U256::ZERO); // waive the removal fee → fee == 0

        let d = U256::from(10_000u64) * wad; // 1e22 (matches seed's identity M)
        let lp_stable = U256::from(1_000u64) * wad;
        let lp_asset = U256::from(2u64) * wad;
        let user = addr(0x42);
        {
            let mut lp = e.liquidity_position.setter(user);
            lp.inverse_snapshot_m00.set(cm::i(d));
            lp.inverse_snapshot_m11.set(cm::i(d));
            lp.initial_stable_balance.set(lp_stable);
            lp.initial_asset_balance.set(lp_asset);
        }
        let gs0 = e.global_liquidity_stable.get();
        let ga0 = e.global_liquidity_asset.get();

        // remove the LP's full balance (identity snapshot → balance == initial shares)
        e.remove_liquidity(lp_stable, lp_asset, user, U256::from(300_000_000_000u64), U256::ZERO)
            .expect("remove_liquidity should not revert");

        let pos = e.user_virtual_trader_position.getter(user);
        assert_eq!(pos.balance_stable.get(), lp_stable, "trader credited removed stable");
        assert_eq!(pos.balance_asset.get(), lp_asset, "trader credited removed asset");
        let lp = e.liquidity_position.getter(user);
        assert_eq!(lp.debt_stable.get(), U256::ZERO, "no LP stable debt");
        assert_eq!(lp.debt_asset.get(), U256::ZERO, "no LP asset debt");
        assert_eq!(e.global_liquidity_stable.get(), gs0 - lp_stable, "global stable reduced");
        assert_eq!(e.global_liquidity_asset.get(), ga0 - lp_asset, "global asset reduced");
        assert_eq!(e.dx0.get(), U256::ZERO, "dx0 reset");
        assert_eq!(e.dy0.get(), U256::ZERO, "dy0 reset");
        assert_eq!(e.total_trader_exposure.get(), lp_asset, "exposure grows by returned asset");
        assert!(e.total_trader_exposure_sign.get(), "exposure sign positive");
    }

    // close on a flat position (balanceAsset == debtAsset, diff*price < 1e10 dust):
    // no trade is executed, PnL is ~0, and the position is fully cleared.
    #[test]
    fn close_dust_position() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let gs0 = e.global_liquidity_stable.get();
        let ga0 = e.global_liquidity_asset.get();

        let user = addr(0x43);
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad); // 1e18
            p.debt_asset.set(wad); // 1e18 -> diff 0 (dust)
        }
        let (pnl, pnl_sign) = e
            .close_and_withdraw_inner(
                U256::ZERO, U256::ZERO, addr(0xFE), user, U256::from(300_000_000_000u64),
                U256::from(1_000u64) * wad, true,
            )
            .expect("close should not revert");

        assert_eq!(pnl, U256::ZERO, "flat position realizes ~0 PnL");
        // position fully cleared
        let p = e.user_virtual_trader_position.getter(user);
        assert_eq!(p.balance_asset.get(), U256::ZERO, "balance_asset cleared");
        assert_eq!(p.debt_asset.get(), U256::ZERO, "debt_asset cleared");
        assert_eq!(p.balance_stable.get(), U256::ZERO, "balance_stable cleared");
        // no trade ran -> globals unchanged
        assert_eq!(e.global_liquidity_stable.get(), gs0, "no trade: global stable unchanged");
        assert_eq!(e.global_liquidity_asset.get(), ga0, "no trade: global asset unchanged");
        let _ = pnl_sign;
    }

    // Auto-close bad-debt guard (parity): the C1 self-close guard rejects closing a
    // bad-debt position (loss >= collateral) when is_self_close is set. The auto-close path now
    // forces is_self_close=true, so a distinct auto-close caller can no longer close a bad-debt
    // position (which would drain the insurance fund). Verified directly on the shared close body.
    #[test]
    fn self_close_rejects_bad_debt_c1() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let user = addr(0x44);
        {
            // Pure over-indebted position: no asset/debt-asset (diff == 0 -> dust, no close-out
            // trade), only stable debt -> the realized PnL is a straight loss of the debt, well
            // above collateral. This reaches the C1 guard directly (no trade to revert first).
            let mut p = e.user_virtual_trader_position.setter(user);
            p.debt_stable.set(U256::from(100_000u64) * wad); // loss >> collateral
        }
        let price = U256::from(300_000_000_000u64); // 3000e8
        let collateral = U256::from(1_000u64) * wad; // < the loss -> bad debt
        assert_eq!(
            e.close_and_withdraw_inner(U256::ZERO, U256::ZERO, addr(0xFE), user, price, collateral, true),
            Err(err(b"C1")),
            "self-close (is_self=true) of a bad-debt position reverts C1"
        );
    }

    // close on a pure long (balanceAsset 1e18, no debt/LP): the engine SELLs the asset
    // (short _trade), so the asset reserve grows by exactly the input size (1e18), the
    // position is cleared, and realized PnL is positive (~residual equity).
    #[test]
    fn close_long_position() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let ga0 = e.global_liquidity_asset.get();
        let gs0 = e.global_liquidity_stable.get();

        let user = addr(0x44);
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad); // 1e18 long, worth ~3000e18
        }
        // 1% max slippage so the short _trade clears T4 (zeroSlippage*0.99 floor).
        let (pnl, pnl_sign) = e
            .close_and_withdraw_inner(
                U256::from(1_000u64), U256::ZERO, addr(0xFE), user, U256::from(300_000_000_000u64),
                U256::from(1_000u64) * wad, true,
            )
            .expect("close should not revert");

        // short _trade adds the input size (1e18) to the asset reserve exactly
        assert_eq!(e.global_liquidity_asset.get(), ga0 + wad, "asset reserve += sold size");
        assert!(e.global_liquidity_stable.get() < gs0, "stable reserve paid out");
        // position fully cleared
        let p = e.user_virtual_trader_position.getter(user);
        assert_eq!(p.balance_asset.get(), U256::ZERO, "balance_asset cleared");
        assert_eq!(p.balance_stable.get(), U256::ZERO, "balance_stable cleared");
        assert_eq!(p.debt_asset.get(), U256::ZERO, "debt_asset cleared");
        // sold ~1e18 asset @3000 for ~2999e18 stable -> positive residual equity
        assert!(pnl_sign, "PnL sign positive");
        assert!(pnl > U256::from(2_900u64) * wad && pnl < U256::from(3_000u64) * wad, "PnL ~2999e18: got {pnl}");
    }

    // A zero-frontend close is allowed again (no C2): the corrected buy-back gross-up accounts
    // for the frontend-fee rebate so it no longer overshoots. The position closes cleanly.
    #[test]
    fn close_allows_zero_frontend() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);

        let user = addr(0x45);
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad);
        }
        e.close_and_withdraw_inner(
            U256::from(1_000u64), U256::ZERO, Address::ZERO, user, U256::from(300_000_000_000u64),
            U256::from(1_000u64) * wad, true,
        )
        .expect("zero-frontend close should succeed");
        assert_eq!(
            e.user_virtual_trader_position.getter(user).balance_asset.get(), U256::ZERO,
            "position cleared after a valid zero-frontend close",
        );
    }

    // add_liquidity into an EMPTY pool bootstraps inverseSnapshotM to identity*liqMDec
    // (the only place M is seeded from a real deposit), folds the deposit into globals,
    // records it as LP debt, and the resulting LP balance equals the deposit.
    #[test]
    fn add_liquidity_empty_pool_bootstrap() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.global_liquidity_stable.set(U256::ZERO); // empty pool
        e.global_liquidity_asset.set(U256::ZERO);
        let liq_m_dec = e.liquidity_m_decimals.get();

        let user = addr(0x51);
        let s = U256::from(1_000u64) * wad;
        let a = U256::from(2u64) * wad;
        e.add_liquidity(s, a, U256::ZERO, U256::from(300_000_000_000u64), user)
            .expect("add into empty pool should not revert");

        {
            let lp = e.liquidity_position.getter(user);
            assert_eq!(lp.inverse_snapshot_m00.get(), liq_m_dec, "bootstrap inv m00 = liqMDec");
            assert_eq!(lp.inverse_snapshot_m01.get(), I256::ZERO, "bootstrap inv m01 = 0");
            assert_eq!(lp.inverse_snapshot_m10.get(), I256::ZERO, "bootstrap inv m10 = 0");
            assert_eq!(lp.inverse_snapshot_m11.get(), liq_m_dec, "bootstrap inv m11 = liqMDec");
            assert_eq!(lp.initial_stable_balance.get(), s, "initial stable = deposit");
            assert_eq!(lp.initial_asset_balance.get(), a, "initial asset = deposit");
            assert_eq!(lp.debt_stable.get(), s, "LP debt stable = deposit (debt-financed)");
            assert_eq!(lp.debt_asset.get(), a, "LP debt asset = deposit");
        }
        assert_eq!(e.global_liquidity_stable.get(), s, "global stable = deposit");
        assert_eq!(e.global_liquidity_asset.get(), a, "global asset = deposit");
        assert_eq!(e.get_lp_liquidity_balance(user), (s, a), "LP balance == deposit");
    }

    // Funding-dilution guard: add_liquidity settles global funding on the PRE-deposit
    // liquidity denominator. `distribute_liquidity_fee` credits the deposit fee to global
    // stable liquidity, so settling funding AFTER it would compute the funding coefficient
    // on an inflated denominator and shrink every trader's accrued funding. `update_fg`
    // runs before the fee/deposit mutations; this pins that ordering.
    #[test]
    fn add_liquidity_settles_funding_on_pre_deposit_denominator() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);

        // Funding config with open trader exposure, so a non-zero rate accrues over time.
        e.total_trader_exposure.set(U256::from(100u64) * wad);
        e.total_trader_exposure_sign.set(true);
        e.funding_c.set(U32::from(1_000_000u32));
        e.funding_interval.set(U64::from(86_400u64));
        e.funding_c_decimals.set(U256::from(100_000u64));
        e.funding_rate_decimals.set(wad);

        // Bootstrap the pool from empty (fee-free) so the LP has a valid snapshot + matrix.
        e.global_liquidity_stable.set(U256::ZERO);
        e.global_liquidity_asset.set(U256::ZERO);
        let lp = addr(0x61);
        let price = U256::from(300_000_000_000u64);
        e.add_liquidity(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad, U256::ZERO, price, lp)
            .expect("bootstrap add");

        // Fresh funding accrual over a 3600s window on the (now non-empty) pool.
        e.funding_rate.set(U256::ZERO);
        e.funding_rate_sign.set(true);
        vm.set_block_timestamp(4600);
        let last_op = U256::from(e.last_operation_timestamp.get());

        // What funding SHOULD settle to: the coefficient on the current (pre-deposit) denominator.
        let (expected_fr, expected_sign) = e.compute_funding_rate(price, last_op).expect("pre-deposit fr");
        assert!(expected_fr > U256::ZERO, "test needs a non-zero funding rate to be meaningful");

        // Guard: crediting the fee to global stable FIRST would move the coefficient, so the
        // final assertion genuinely distinguishes the fixed ordering from the buggy one.
        let fee = U256::from(6_000_000u64) * wad;
        let gs_pre = e.global_liquidity_stable.get();
        e.global_liquidity_stable.set(gs_pre + fee);
        let (diluted_fr, _) = e.compute_funding_rate(price, last_op).expect("diluted fr");
        e.global_liquidity_stable.set(gs_pre);
        assert_ne!(diluted_fr, expected_fr, "fee must shift the funding coefficient");

        // Second add WITH that fee: funding settles before the fee dilutes global stable.
        e.add_liquidity(U256::from(1_000u64) * wad, U256::ZERO, fee, price, lp).expect("second add with fee");

        assert_eq!(e.funding_rate.get(), expected_fr, "funding settled on pre-deposit denominator");
        assert_eq!(e.funding_rate_sign.get(), expected_sign, "funding sign preserved");
    }

    // Round-trip invariant: deposit then withdraw the same amounts (fees waived) from an
    // empty pool. Because an LP deposit is DEBT-financed, removing it repays the debt
    // exactly — net-zero to the trader balance — and the pool returns to empty.
    #[test]
    fn add_then_remove_round_trip() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.global_liquidity_stable.set(U256::ZERO);
        e.global_liquidity_asset.set(U256::ZERO);
        e.liquidity_max_fee.set(U256::ZERO); // waive removal fee

        let user = addr(0x52);
        let s = U256::from(1_000u64) * wad;
        let a = U256::from(2u64) * wad;
        let price = U256::from(300_000_000_000u64);
        e.add_liquidity(s, a, U256::ZERO, price, user).expect("add");
        assert_eq!(e.get_lp_liquidity_balance(user), (s, a), "post-add LP balance == deposit");
        assert_eq!(e.global_liquidity_stable.get(), s, "post-add global stable");
        assert_eq!(e.global_liquidity_asset.get(), a, "post-add global asset");

        e.remove_liquidity(s, a, user, price, U256::ZERO).expect("remove");

        assert_eq!(e.global_liquidity_stable.get(), U256::ZERO, "pool stable back to 0");
        assert_eq!(e.global_liquidity_asset.get(), U256::ZERO, "pool asset back to 0");
        {
            let lp = e.liquidity_position.getter(user);
            assert_eq!(lp.debt_stable.get(), U256::ZERO, "LP stable debt repaid");
            assert_eq!(lp.debt_asset.get(), U256::ZERO, "LP asset debt repaid");
        }
        let pos = e.user_virtual_trader_position.getter(user);
        assert_eq!(pos.balance_stable.get(), U256::ZERO, "net-zero trader stable (debt-financed)");
        assert_eq!(pos.balance_asset.get(), U256::ZERO, "net-zero trader asset");
    }

    // _computeLiquidationDiscount piecewise curve (MMR=40000 -> step0=20000), hand-derived:
    // mr<=step0: 7500*(1e10 + (step0-mr)*1e10/step0)/1e10; else: 3750*(1e10 + (step1-mr)*1e10/(step1-step0))/1e10.
    #[test]
    fn liquidation_discount_curve() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.mmr.set(U32::from(40_000u32));
        e.liquidation_discount.set(U32::from(7_500u32));
        assert_eq!(e.compute_liquidation_discount(U256::from(20_000u64)), U256::from(7_500u64), "mr==step0 -> base 7500");
        assert_eq!(e.compute_liquidation_discount(U256::ZERO), U256::from(15_000u64), "mr=0 -> 2x = 15000");
        assert_eq!(e.compute_liquidation_discount(U256::from(40_000u64)), U256::from(3_750u64), "mr==MMR -> half-base 3750");
        assert_eq!(e.compute_liquidation_discount(U256::from(30_000u64)), U256::from(5_625u64), "mr=30000 -> 5625");
    }

    // _liquidatePosition long branch via the spot-price path (avg_slippage_s=0 forces
    // spot): exact transfers with discount=0 -> dy = d_amount*price/od, insurance=0.
    #[test]
    fn liquidate_position_long_spot() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let user = addr(0x61);
        let liquidator = addr(0x62);
        {
            let mut up = e.user_virtual_trader_position.setter(user);
            up.balance_asset.set(U256::from(10u64) * wad);
        }
        {
            let mut lp = e.user_virtual_trader_position.setter(liquidator);
            lp.balance_stable.set(U256::from(100_000u64) * wad);
        }
        let price = U256::from(300_000_000_000u64);
        e.liquidate_position(U256::from(5u64) * wad, user, U256::ZERO, true, liquidator, price, U256::from(1_000u64) * wad)
            .expect("liquidate_position long");
        // spot dy = 5e18*3000 = 15000e18; insurance = 0
        assert_eq!(e.user_virtual_trader_position.getter(user).balance_asset.get(), U256::from(5u64) * wad, "user asset -= d_amount");
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_asset.get(), U256::from(5u64) * wad, "liquidator asset += d_amount");
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_stable.get(), U256::from(85_000u64) * wad, "liquidator paid dy=15000e18");
        assert_eq!(e.user_virtual_trader_position.getter(user).balance_stable.get(), U256::from(15_000u64) * wad, "user received dy (no debt)");
    }

    // _liquidatePosition short branch via the spot-price path (d_amount > pool asset
    // forces spot): exact transfers with discount=0 -> dySecond = d_amount*price/od.
    #[test]
    fn liquidate_position_short_spot() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let user = addr(0x63);
        let liquidator = addr(0x64);
        {
            let mut up = e.user_virtual_trader_position.setter(user);
            up.debt_asset.set(U256::from(7_000u64) * wad);
            up.balance_stable.set(U256::from(25_000_000u64) * wad);
        }
        {
            let mut lp = e.user_virtual_trader_position.setter(liquidator);
            lp.balance_asset.set(U256::from(8_000u64) * wad);
        }
        let price = U256::from(300_000_000_000u64);
        // d_amount 7000e18 > globalLiquidityAsset 6000e18 -> spot path, no calcPnL
        e.liquidate_position(U256::from(7_000u64) * wad, user, U256::ZERO, false, liquidator, price, U256::from(1_000u64) * wad)
            .expect("liquidate_position short");
        // dySecond = 7000e18 * 3000 = 21,000,000e18; insurance = 0
        assert_eq!(e.user_virtual_trader_position.getter(user).balance_stable.get(), U256::from(4_000_000u64) * wad, "user paid dySecond=21,000,000e18 from 25,000,000e18");
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_stable.get(), U256::from(21_000_000u64) * wad, "liquidator received dySecond");
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_asset.get(), U256::from(1_000u64) * wad, "liquidator gave d_amount asset");
        assert_eq!(e.user_virtual_trader_position.getter(user).debt_asset.get(), U256::ZERO, "user asset debt repaid");
    }

    // batch_liquidate_impl must produce state bit-identical to liquidating the same users one
    // by one: the batch only hoists the reentrancy guard and the oracle verify/price read (a
    // no-op under stub_boundary) out of the per-user loop, so the per-user results are unchanged.
    // Reads the oracle price, so it needs the mocked boundary — same gate as the other
    // oracle-path tests (get_price_stub, trade_wrapper_long_stub, ...).
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn batch_liquidate_matches_loop() {
        let wad = U256::from(WAD_U64);
        let liquidator = addr(0x71);
        let user1 = addr(0x72);
        let user2 = addr(0x73);
        let size1 = wad / U256::from(2u64); // 0.5e18 -> partial fraction
        let size2 = U256::from(3u64) * wad / U256::from(10u64); // 0.3e18

        // Two underwater long positions (large stable debt -> bad debt -> margin ratio 0 ->
        // liquidatable) plus a well-capitalized liquidator.
        fn build(vm: &TestVM, liquidator: Address, user1: Address, user2: Address) -> PerpEngine {
            let wad = U256::from(WAD_U64);
            let mut e = PerpEngine::from(vm);
            seed_trade_engine(&mut e);
            for u in [user1, user2] {
                let mut up = e.user_virtual_trader_position.setter(u);
                up.balance_asset.set(wad);
                up.debt_stable.set(U256::from(100_000u64) * wad);
            }
            let mut lq = e.user_virtual_trader_position.setter(liquidator);
            lq.balance_stable.set(U256::from(1_000_000_000u64) * wad);
            e
        }

        // Engine A: one batch call.
        let vma = TestVM::new();
        vma.set_block_timestamp(1_700_000_000);
        let mut ea = build(&vma, liquidator, user1, user2);
        ea.batch_liquidate_impl(liquidator, vec![user1, user2], vec![size1, size2], Bytes::new()).expect("batch");

        // Engine B: two single-user calls in the same order.
        let vmb = TestVM::new();
        vmb.set_block_timestamp(1_700_000_000);
        let mut eb = build(&vmb, liquidator, user1, user2);
        eb.liquidate_impl(liquidator, user1, size1, Bytes::new()).expect("single 1");
        eb.liquidate_impl(liquidator, user2, size2, Bytes::new()).expect("single 2");

        // Per-user + global state must be bit-identical.
        for u in [user1, user2, liquidator] {
            let pa = ea.user_virtual_trader_position.getter(u);
            let pb = eb.user_virtual_trader_position.getter(u);
            assert_eq!(pa.balance_stable.get(), pb.balance_stable.get(), "balance_stable");
            assert_eq!(pa.balance_asset.get(), pb.balance_asset.get(), "balance_asset");
            assert_eq!(pa.debt_stable.get(), pb.debt_stable.get(), "debt_stable");
            assert_eq!(pa.debt_asset.get(), pb.debt_asset.get(), "debt_asset");
            assert_eq!(pa.funding_fee.get(), pb.funding_fee.get(), "funding_fee");
        }
        assert_eq!(ea.global_liquidity_stable.get(), eb.global_liquidity_stable.get(), "gLS");
        assert_eq!(ea.global_liquidity_asset.get(), eb.global_liquidity_asset.get(), "gLA");
        assert_eq!(ea.funding_rate.get(), eb.funding_rate.get(), "funding_rate");
        assert_eq!(ea.total_trader_exposure.get(), eb.total_trader_exposure.get(), "exposure");
        assert_eq!(ea.insurance_fund.get(), eb.insurance_fund.get(), "insurance");
        assert_eq!(ea.last_operation_timestamp.get(), eb.last_operation_timestamp.get(), "last_op_ts");
    }

    // Self-liquidation guard (LQ0): the shared liquidate body rejects user == liquidator before
    // any funding/margin work. Tested directly on liquidate_with_price, so no oracle read is
    // needed (the guard is position-independent — it fires on identity alone).
    #[test]
    fn liquidate_rejects_self_liquidation() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let actor = addr(0x71);
        let price = U256::from(300_000_000_000u64);
        assert_eq!(
            e.liquidate_with_price(actor, actor, wad, price),
            Err(err(b"LQ0")),
            "user == liquidator reverts LQ0"
        );
    }

    // A self-liquidating target in a batch reverts the WHOLE batch with LQ0 (revert-all, matching
    // the manager loop). Goes through batch_liquidate_impl, which reads the oracle -> stub gate.
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn batch_liquidate_reverts_all_on_self_liquidation() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let liquidator = addr(0x71);
        assert_eq!(
            e.batch_liquidate_impl(liquidator, vec![liquidator], vec![wad], Bytes::new()),
            Err(err(b"LQ0")),
            "batch with a self-liq target reverts LQ0"
        );
    }

    // enableAutoClose stores the config (require profitTh>0||lossTh>0); disableAutoClose
    // deletes it. Neither makes external calls, so they run in the default build.
    #[test]
    fn enable_disable_auto_close() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        let user = e.vm().msg_sender();
        assert_eq!(
            e.enable_auto_close(U256::ZERO, U256::ZERO, U256::ZERO, U256::ZERO),
            Err(err(b"A")),
            "both thresholds zero reverts A"
        );
        e.enable_auto_close(U256::from(50u64) * wad, U256::ZERO, U256::from(1_000u64), U256::ZERO)
            .expect("enable");
        {
            let ac = e.auto_close_users_data.getter(user);
            assert!(ac.authorized.get(), "authorized");
            assert_eq!(ac.profit_th.get(), U256::from(50u64) * wad, "profit_th stored");
            assert_eq!(ac.max_slippage.get(), U256::from(1_000u64), "max_slippage stored");
        }
        e.disable_auto_close().expect("disable");
        assert!(!e.auto_close_users_data.getter(user).authorized.get(), "disabled");

        // Forwarded variants: the caller acts as the trusted forwarder and
        // the config accrues to the explicit `user`; a non-forwarder caller reverts "F".
        let forwarder = e.vm().msg_sender();
        e.trusted_forwarder.set(forwarder);
        let owner = addr(0x77); // position owner, distinct from the forwarder
        e.enable_auto_close_for(owner, U256::from(50u64) * wad, U256::ZERO, U256::from(1_000u64), U256::ZERO)
            .expect("enableAutoCloseFor");
        assert!(e.auto_close_users_data.getter(owner).authorized.get(), "owner authorized via forwarder");
        assert!(!e.auto_close_users_data.getter(forwarder).authorized.get(), "forwarder itself unaffected");
        e.disable_auto_close_for(owner).expect("disableAutoCloseFor");
        assert!(!e.auto_close_users_data.getter(owner).authorized.get(), "owner disabled via forwarder");

        e.trusted_forwarder.set(addr(0xEE)); // not the caller
        assert_eq!(
            e.enable_auto_close_for(owner, U256::from(50u64) * wad, U256::ZERO, U256::ZERO, U256::ZERO),
            Err(err(b"F")),
            "non-forwarder enableAutoCloseFor reverts F"
        );
        assert_eq!(e.disable_auto_close_for(owner), Err(err(b"F")), "non-forwarder disableAutoCloseFor reverts F");
    }

    // Event topic0 parity: each engine event's sol!-derived SIGNATURE_HASH must equal
    // the real Solidity event `.selector` (golden vectors from the verbatim event decls
    // in test/config/EventSelectorGoldenVector.t.sol). Catches any type/order error.
    #[test]
    fn event_selectors_match_solidity() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(EVENT_SELECTOR_FIXTURE).expect("event selector fixture");
        let ev = &root["events"];
        let want = |k: &str| B256::from_str(ev[k].as_str().unwrap()).expect("hex selector");
        assert_eq!(ExecutedTrade::SIGNATURE_HASH, want("ExecutedTrade"), "ExecutedTrade");
        assert_eq!(ClosedPosition::SIGNATURE_HASH, want("ClosedPosition"), "ClosedPosition");
        assert_eq!(LiquidityMoved::SIGNATURE_HASH, want("LiquidityMoved"), "LiquidityMoved");
        assert_eq!(LiquidatedUser::SIGNATURE_HASH, want("LiquidatedUser"), "LiquidatedUser");
        assert_eq!(EnabledAutoClose::SIGNATURE_HASH, want("EnabledAutoClose"), "EnabledAutoClose");
        assert_eq!(RealizedPnL::SIGNATURE_HASH, want("RealizedPnL"), "RealizedPnL");
        assert_eq!(ParametersUpdated::SIGNATURE_HASH, want("ParametersUpdated"), "ParametersUpdated");
        assert_eq!(LockedParameterUpdate::SIGNATURE_HASH, want("LockedParameterUpdate"), "LockedParameterUpdate");
    }

    // End-to-end emit: enableAutoClose emits one EnabledAutoClose log with topic0 =
    // signature, topic1 = indexed user, and data = abi.encode(profitTh, lossTh).
    #[test]
    fn emits_enabled_auto_close_event() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        let user = e.vm().msg_sender();
        e.enable_auto_close(U256::from(50u64) * wad, U256::from(10u64) * wad, U256::from(1_000u64), U256::ZERO)
            .expect("enable");
        let logs = vm.get_emitted_logs();
        assert_eq!(logs.len(), 1, "exactly one event emitted");
        let (topics, data) = &logs[0];
        assert_eq!(topics[0], EnabledAutoClose::SIGNATURE_HASH, "topic0 = event signature");
        assert_eq!(topics[1], user.into_word(), "topic1 = indexed user");
        assert_eq!(data.len(), 64, "two uint256 data words");
        assert_eq!(U256::from_be_slice(&data[0..32]), U256::from(50u64) * wad, "profitTh");
        assert_eq!(U256::from_be_slice(&data[32..64]), U256::from(10u64) * wad, "lossTh");
    }

    // The time-locked param keccak hash is bit-exact vs Solidity's
    // keccak256(abi.encode(keccak256(abi.encodePacked(...)), ...)) — locked by vectors
    // generated from a verbatim transcription of perpConfig (test/config/...).
    #[test]
    fn param_hash_golden_vectors() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(PARAM_HASH_FIXTURE).expect("param hash fixture");
        let vectors = root["vectors"].as_array().expect("vectors array");
        let vm = TestVM::new();
        let e = PerpEngine::from(&vm);
        let mut checked = 0u32;
        for v in vectors {
            let inp = &v["inputs"];
            let g = |k: &str| u256s(inp[k].as_str().unwrap());
            let got = e.time_locked_param_hash(
                g("mmr"), g("tradingFee"), g("flatTradingFee"), g("feeLP"),
                g("liquidityMinFee"), g("liquidityMaxFee"), g("liquidityFeeK"), g("fundingC"),
                g("paramTimeLock"), g("minimumTradeSize"),
            );
            let want = B256::from_str(v["expected"].as_str().unwrap()).expect("hex hash");
            assert_eq!(got, want, "param hash mismatch for {}", v["label"].as_str().unwrap());
            checked += 1;
        }
        assert!(checked >= 2, "expected >=2 param-hash vectors, got {checked}");
    }

    // AccessControl: initialize grants DEFAULT_ADMIN_ROLE + MOD_ROLE to the deployer;
    // strangers hold neither; the admin can grantRole.
    #[test]
    fn config_access_control() {
        let vm = TestVM::new();
        vm.set_block_timestamp(1000);
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        let caller = e.vm().msg_sender();
        let mod_role = e.mod_role.get();
        assert_eq!(mod_role, keccak256("MOD_ROLE"), "MOD_ROLE = keccak256(\"MOD_ROLE\")");
        assert!(e.has_role(mod_role, caller), "deployer has MOD_ROLE");
        assert!(e.has_role(B256::ZERO, caller), "deployer has DEFAULT_ADMIN_ROLE");
        assert!(!e.has_role(mod_role, addr(0xFF)), "stranger has no MOD_ROLE");
        e.grant_role(mod_role, addr(0x44)).expect("admin can grant");
        assert!(e.has_role(mod_role, addr(0x44)), "grant took effect");
    }

    // Front-end read parity (partial — size-constrained): only the read views the front-end
    // strictly needs were restored on the engine, because the engine is at the Stylus size
    // ceiling (the full set breaks `cargo stylus` activation). Each restored getter must
    // return the underlying storage value. Selector parity is enforced separately by
    // script/selector_manifest.py.
    #[test]
    fn front_end_read_parity_getters() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);

        // ReadFees
        e.trading_fee.set(U256::from(1001));
        e.flat_trading_fee.set(U256::from(1002));
        e.auto_close_fee.set(U256::from(1003));
        e.liquidity_min_fee.set(U256::from(1004));
        e.liquidity_max_fee.set(U256::from(1005));
        e.liquidity_fee_k.set(U256::from(1006));
        e.liquidation_discount.set(U32::from(7_500u32));
        assert_eq!(
            e.read_fees().unwrap(),
            (
                U256::from(1001), U256::from(1002), U256::from(1003), U256::from(1004),
                U256::from(1005), U256::from(1006), U256::from(7_500),
            ),
            "ReadFees"
        );

        // ReadFundingParameters + ReadInsuranceFund
        e.funding_c.set(U32::from(1_000_000u32));
        e.funding_interval.set(U64::from(86_400u64));
        assert_eq!(
            e.read_funding_parameters().unwrap(),
            (U256::from(1_000_000), U256::from(86_400)),
            "ReadFundingParameters"
        );
        e.insurance_fund.set(U256::from(2002));
        e.insurance_fund_sign.set(true);
        assert_eq!(e.read_insurance_fund().unwrap(), (U256::from(2002), true), "ReadInsuranceFund");

        // fundingRateSign
        e.funding_rate_sign.set(true);
        assert!(e.funding_rate_sign_public().unwrap(), "fundingRateSign");
    }

    // AccessControl revokeRole + renounceRole — the production-safety lever
    // to drop a granted (e.g. compromised) role. revokeRole is admin-gated; renounceRole drops
    // the caller's own role and requires callerConfirmation == caller (OZ guard).
    #[test]
    fn access_control_revoke_renounce() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        let admin = e.vm().msg_sender();
        let mod_role = e.mod_role.get();
        // admin grants, then revokes
        e.grant_role(mod_role, addr(0x44)).expect("grant");
        assert!(e.has_role(mod_role, addr(0x44)), "granted");
        e.revoke_role(mod_role, addr(0x44)).expect("admin revokes");
        assert!(!e.has_role(mod_role, addr(0x44)), "revoked");
        // revoke without admin -> AC (encoded Error(string))
        e.revoke_role_internal(B256::ZERO, admin); // drop the caller's DEFAULT_ADMIN_ROLE
        assert_eq!(e.revoke_role(mod_role, addr(0x44)).err(), Some(err(b"AC")), "non-admin revoke -> AC");
        // renounce: re-grant admin to caller, then renounce it (self)
        e.grant_role_internal(B256::ZERO, admin);
        assert!(e.has_role(B256::ZERO, admin), "admin restored");
        // bad confirmation -> ACB
        assert_eq!(e.renounce_role(B256::ZERO, addr(0xBB)).err(), Some(err(b"ACB")), "bad confirmation -> ACB");
        e.renounce_role(B256::ZERO, admin).expect("renounce own role");
        assert!(!e.has_role(B256::ZERO, admin), "renounced");
    }

    // seedBenchmarkState must be MOD_ROLE-
    // gated so an arbitrary caller cannot rewrite the global reserves post-initialization.
    #[test]
    fn seed_benchmark_state_mod_role_gated() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.mod_role.set(keccak256("MOD_ROLE"));
        // Not initialized yet -> S0 (the initialized check precedes the role check).
        assert_eq!(
            e.seed_benchmark_state(wad, wad),
            Err(err(b"S0")),
            "uninitialized -> S0"
        );
        // Initialized, but the caller does NOT hold MOD_ROLE -> AC, reserves untouched.
        e.initialized.set(true);
        assert_eq!(
            e.seed_benchmark_state(wad, U256::from(2u64) * wad),
            Err(err(b"AC")),
            "non-MOD_ROLE caller cannot seed reserves"
        );
        assert_eq!(e.global_liquidity_stable.get(), U256::ZERO, "reserves untouched on rejection");
        // Grant MOD_ROLE -> governance can seed.
        let caller = e.vm().msg_sender();
        e.grant_role_internal(keccak256("MOD_ROLE"), caller);
        e.seed_benchmark_state(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad)
            .expect("MOD_ROLE seeds");
        assert_eq!(e.global_liquidity_stable.get(), U256::from(18_000_000u64) * wad, "stable reserves seeded");
        assert_eq!(e.global_liquidity_asset.get(), U256::from(6_000u64) * wad, "asset reserves seeded");
    }

    // initializeProduction matches the PerpPair constructor — full param set + SET*
    // validation, and the fixed protocol constants identical to the benchmark initializer.
    #[test]
    fn initialize_production_parity_and_validation() {
        let wad = U256::from(WAD_U64);
        let ticker = B256::from(U256::from(0x455448u64)); // "ETH"
        // Build a fresh engine + run initialize_production with the given params.
        let go = |oracle, vault, fwd, mmr, ff: u64, fl: u64, fp, tf, flat| {
            let vm = TestVM::new();
            let mut e = PerpEngine::from(&vm);
            let r = e.initialize_production(
                oracle, vault, fwd, mmr, ticker, U32::from(ff as u32), U32::from(fl as u32), fp, tf, flat,
                U256::from(90_000_000u64),
            );
            (e, r)
        };
        // Valid params (trading_fee=0, flat=0.12e18 → SET6 holds: 12e16*1e18 < 1e18*48e18).
        let valid = || (addr(0x01), addr(0x02), addr(0x03), U256::from(40_000u64), 300_000u64, 500_000u64, addr(0x04), U256::ZERO, U256::from(120_000_000_000_000_000u64));

        // success
        let (e, r) = { let v = valid(); go(v.0, v.1, v.2, v.3, v.4, v.5, v.6, v.7, v.8) };
        r.expect("valid production init");
        assert_eq!(e.oracle.get(), addr(0x01), "oracle");
        assert_eq!(e.vault.get(), addr(0x02), "vault");
        assert_eq!(e.trusted_forwarder.get(), addr(0x03), "trusted forwarder = multiCallManager");
        assert_eq!(e.mmr.get(), U32::from(40_000u32), "mmr");
        assert_eq!(e.ticker_asset_currency.get(), ticker, "ticker");
        assert_eq!(e.fee_frontend.get(), U32::from(300_000u32), "feeFrontend");
        assert_eq!(e.fee_lp.get(), U32::from(500_000u32), "feeLP");
        assert_eq!(e.fee_protocol_addr.get(), addr(0x04), "feeProtocol");
        assert_eq!(e.ema_param.get(), U64::from(90_000_000u64), "emaParam");
        // fixed constants identical to the benchmark init
        assert_eq!(e.minimum_trade_size.get(), U256::from(48u64) * wad, "minimumTradeSize const");
        assert_eq!(e.mmr_decimals.get(), U256::from(1_000_000u64), "mmrDecimals const");
        assert_eq!(e.liquidity_m00.get(), cm::i(U256::from(10_000u64) * wad), "identity M const");
        assert_eq!(e.funding_c.get(), U32::from(1_000_000u32), "fundingC const");
        assert!(e.has_role(keccak256("MOD_ROLE"), e.vm().msg_sender()), "deployer granted MOD_ROLE");
        assert!(e.initialized.get(), "initialized");

        // SET branches (each on a fresh engine)
        let v = valid();
        assert_eq!(go(Address::ZERO, v.1, v.2, v.3, v.4, v.5, v.6, v.7, v.8).1, Err(err(b"SET2")), "oracle=0 -> SET2");
        assert_eq!(go(v.0, Address::ZERO, v.2, v.3, v.4, v.5, v.6, v.7, v.8).1, Err(err(b"SET3")), "vault=0 -> SET3");
        assert_eq!(go(v.0, v.1, v.2, v.3, 600_000, 500_000, v.6, v.7, v.8).1, Err(err(b"SET1")), "fee sum >= 1e6 -> SET1");
        assert_eq!(go(v.0, v.1, v.2, v.3, v.4, v.5, v.6, wad, v.8).1, Err(err(b"SET5")), "tradingFee >= 1e18 -> SET5");
        assert_eq!(go(v.0, v.1, v.2, v.3, v.4, v.5, v.6, U256::ZERO, U256::from(48u64) * wad).1, Err(err(b"SET6")), "flat fee too large -> SET6");
        assert_eq!(go(v.0, v.1, v.2, v.3, v.4, v.5, Address::ZERO, v.7, v.8).1, Err(err(b"SET7")), "feeProtocol=0 -> SET7");
        assert_eq!(go(v.0, v.1, v.2, U256::from(u64::MAX), v.4, v.5, v.6, v.7, v.8).1, Err(err(b"C")), "MMR > u32::MAX -> C");
    }

    // setUnguardedParameters: MOD_ROLE-gated (revert "AC" without it), then applies the
    // non-time-locked config when the caller holds MOD_ROLE.
    #[test]
    fn set_unguarded_parameters_flow() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.mod_role.set(keccak256("MOD_ROLE"));
        // no role -> AC
        let denied = e.set_unguarded_parameters(
            addr(0x11), U32::from(100u32), addr(0x12), U256::from(999u64), U8::from(20u8), U32::from(100u32), U8::from(10u8), U8::from(5u8),
        );
        assert_eq!(denied, Err(err(b"AC")), "no MOD_ROLE reverts AC");
        // grant + retry
        let caller = e.vm().msg_sender();
        e.grant_role_internal(keccak256("MOD_ROLE"), caller);
        e.set_unguarded_parameters(
            addr(0x11), U32::from(100u32), addr(0x12), U256::from(999u64), U8::from(20u8), U32::from(7_000u32), U8::from(10u8), U8::from(5u8),
        )
        .expect("with MOD_ROLE");
        assert_eq!(e.oracle.get(), addr(0x11), "oracle updated");
        assert_eq!(e.max_leverage.get(), U8::from(20u8), "maxLeverage updated");
        assert_eq!(e.liquidation_discount.get(), U32::from(7_000u32), "liquidationDiscount updated");
        assert_eq!(e.insurance_fund_cap.get(), U256::from(999u64), "insuranceFundCap updated");
    }

    // Time-locked config: prepare arms (lock = now + STORAGE paramTimeLock, hash stored);
    // setTimeLocked reverts "C" before unlock and on hash mismatch, then applies.
    #[test]
    fn time_locked_parameters_flow() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1000);
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init"); // grants MOD_ROLE; param_time_lock=10
        let (mmr, tf, flat, flp) = (U256::from(30_000u64), U256::ZERO, U256::from(120_000_000_000_000_000u64), U256::from(500_000u64));
        let (lmin, lmax, lk, fc) = (U256::ZERO, U256::from(500_000_000u64), U256::from(10_000_000_000u64), U256::from(1_000_000u64));
        let (ptl, mts) = (U256::from(20u64), U256::from(48u64) * wad);

        e.prepare_time_locked_parameters(mmr, tf, flat, flp, lmin, lmax, lk, fc, ptl, mts)
            .expect("prepare");
        assert_eq!(e.param_locked_until.get(), U64::from(1010u64), "lock = now(1000) + storage paramTimeLock(10)");

        let early = e.set_time_locked_parameters(mmr, tf, flat, flp, lmin, lmax, lk, fc, ptl, mts);
        assert_eq!(early, Err(err(b"C")), "before unlock reverts C");

        vm.set_block_timestamp(1010);
        let mismatch = e.set_time_locked_parameters(U256::from(31_000u64), tf, flat, flp, lmin, lmax, lk, fc, ptl, mts);
        assert_eq!(mismatch, Err(err(b"C")), "hash mismatch reverts C");

        e.set_time_locked_parameters(mmr, tf, flat, flp, lmin, lmax, lk, fc, ptl, mts)
            .expect("apply at unlock with matching hash");
        assert_eq!(e.mmr.get(), U32::from(30_000u32), "mmr applied");
        assert_eq!(e.minimum_trade_size.get(), mts, "minimumTradeSize applied");
        assert_eq!(e.param_time_lock.get(), U64::from(20u64), "paramTimeLock(arg) applied");
        assert_eq!(e.liquidity_max_fee.get(), lmax, "liquidityMaxFee applied");
    }

    // Storage-narrowing boundary tests. Fields the packed layout narrows
    // below Solidity's uint256 must REVERT on an un-storable value, never silently truncate.
    // funding_c (u32) and param_time_lock (u64) pass prepare's validation (which doesn't bound
    // them) and so reach the `set` narrowing guard; ema (u64) is narrowed in initializeProduction.
    #[test]
    fn narrowing_boundaries() {
        let wad = U256::from(WAD_U64);
        let over_u32 = U256::from(u32::MAX) + U256::from(1u64);
        let at_u32 = U256::from(u32::MAX);
        let over_u64 = U256::from(u64::MAX) + U256::from(1u64);
        // valid base params (mirror time_locked_parameters_flow)
        let (mmr, tf, flat, flp) = (U256::from(30_000u64), U256::ZERO, U256::from(120_000_000_000_000_000u64), U256::from(500_000u64));
        let (lmin, lmax, lk) = (U256::ZERO, U256::from(500_000_000u64), U256::from(10_000_000_000u64));
        let (cmin, cmax, coff) = (U256::ZERO, wad, U256::ZERO);
        let mts = U256::from(48u64) * wad;

        // helper: prepare(at ts) then advance + set; returns the set result
        let run = |ts: u64, fc: U256, ptl: U256| {
            let vm = TestVM::new();
            vm.set_block_timestamp(ts);
            let mut e = PerpEngine::from(&vm);
            e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
            e.prepare_time_locked_parameters(mmr, tf, flat, flp, lmin, lmax, lk, fc, ptl, mts).expect("prepare");
            vm.set_block_timestamp(ts + 10); // storage paramTimeLock == 10
            (e.set_time_locked_parameters(mmr, tf, flat, flp, lmin, lmax, lk, fc, ptl, mts), e)
        };

        // funding_c just over u32::MAX -> set reverts C (narrowing, not truncation)
        assert_eq!(run(1_000, over_u32, U256::from(20u64)).0, Err(err(b"C")), "funding_c > u32::MAX -> C");
        // param_time_lock just over u64::MAX -> set reverts C
        assert_eq!(run(1_000, U256::from(1_000_000u64), over_u64).0, Err(err(b"C")), "param_time_lock > u64::MAX -> C");
        // funding_c exactly u32::MAX -> accepted, stored bit-exact
        let (ok, e) = run(1_000, at_u32, U256::from(20u64));
        ok.expect("funding_c == u32::MAX accepted");
        assert_eq!(e.funding_c.get(), U32::from(u32::MAX), "funding_c stored at boundary");

        // initializeProduction: ema (u64) over-range reverts C
        let vm = TestVM::new();
        let mut e2 = PerpEngine::from(&vm);
        let r = e2.initialize_production(
            addr(0x01), addr(0x02), addr(0x03), U256::from(40_000u64), B256::ZERO, U32::from(300_000u32), U32::from(500_000u32),
            addr(0x04), U256::ZERO, U256::from(120_000_000_000_000_000u64), over_u64,
        );
        assert_eq!(r, Err(err(b"C")), "ema > u64::MAX -> C");
    }

    // setTrustedForwarder is MOD_ROLE-gated; isTrustedForwarder reflects it.
    #[test]
    fn trusted_forwarder_config() {
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.mod_role.set(keccak256("MOD_ROLE"));
        assert_eq!(e.set_trusted_forwarder(addr(0xAB)), Err(err(b"AC")), "no MOD_ROLE -> AC");
        let caller = e.vm().msg_sender();
        e.grant_role_internal(keccak256("MOD_ROLE"), caller);
        e.set_trusted_forwarder(addr(0xAB)).expect("set with MOD_ROLE");
        assert!(e.is_trusted_forwarder(addr(0xAB)).unwrap(), "AB is the forwarder");
        assert!(!e.is_trusted_forwarder(addr(0xCD)).unwrap(), "CD is not");

        // The change is observable — one TrustedForwarderUpdated(old=0x0, new=0xAB)
        // (the earlier AC revert emitted nothing). Both addresses are indexed topics.
        let logs = vm.get_emitted_logs();
        assert_eq!(logs.len(), 1, "exactly one forwarder-update event");
        let (topics, data) = &logs[0];
        assert_eq!(topics[0], TrustedForwarderUpdated::SIGNATURE_HASH, "topic0 = event signature");
        assert_eq!(topics[1], Address::ZERO.into_word(), "topic1 = old forwarder (0x0)");
        assert_eq!(topics[2], addr(0xAB).into_word(), "topic2 = new forwarder");
        assert!(data.is_empty(), "both args indexed -> no data");
    }

    // Forwarder hardening: EVERY forwarded `*For` entrypoint must reject a caller that
    // is not the trusted forwarder with "F" — the gate is the load-bearing security property
    // of the explicit-sender topology (a private `*_impl` reachable by a non-forwarder would
    // let anyone act as any user). The gate runs before any external call, so this needs no
    // stub_boundary. Covers all nine: trade, close, add/removeLiquidity, realizePnL,
    // liquidate, autoClose, enable/disableAutoClose.
    #[test]
    fn forwarded_entrypoints_reject_non_forwarder() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.trusted_forwarder.set(addr(0xEE)); // NOT the test caller
        let u = addr(0x55);
        let f = err(b"F");
        let rpt = Bytes::new();
        assert_eq!(e.trade_for(u, true, wad, U256::ZERO, U256::ZERO, Address::ZERO, 1, rpt.clone()).err(), Some(f.clone()), "tradeFor");
        assert_eq!(e.close_and_withdraw_for(u, U256::ZERO, U256::ZERO, Address::ZERO, rpt.clone()).err(), Some(f.clone()), "closeAndWithdrawFor");
        assert_eq!(e.add_liquidity_for(u, wad, wad, U256::ZERO, rpt.clone()).err(), Some(f.clone()), "addLiquidityFor");
        assert_eq!(e.remove_liquidity_for(u, wad, wad, U256::ZERO, rpt.clone()).err(), Some(f.clone()), "removeLiquidityFor");
        assert_eq!(e.realize_pnl_for(u, rpt.clone()).err(), Some(f.clone()), "realizePnLFor");
        assert_eq!(e.liquidate_for(addr(0x66), u, wad, rpt.clone()).err(), Some(f.clone()), "liquidateFor");
        assert_eq!(e.auto_close_user_position_for(addr(0x66), u, Address::ZERO, rpt).err(), Some(f.clone()), "autoCloseUserPositionFor");
        assert_eq!(e.enable_auto_close_for(u, wad, U256::ZERO, U256::ZERO, U256::ZERO).err(), Some(f.clone()), "enableAutoCloseFor");
        assert_eq!(e.disable_auto_close_for(u).err(), Some(f), "disableAutoCloseFor");
    }

    // Revert codes are encoded as Solidity-standard Error(string) revert data
    // (0x08c379a0 + abi.encode(string)) so explorers/tooling decode the reason. The
    // expected bytes are the canonical `cast abi-encode "x(string)" "<code>"` output
    // (prefixed with the Error(string) selector) — so this is locked against the real
    // Solidity encoding, not just self-consistent.
    #[test]
    fn revert_error_string_encoding() {
        use stylus_sdk::alloy_primitives::hex;
        assert_eq!(&err(b"T0")[..4], &[0x08, 0xc3, 0x79, 0xa0], "Error(string) selector");
        assert_eq!(
            hex::encode(err(b"T0")),
            "08c379a000000000000000000000000000000000000000000000000000000000\
             0000002000000000000000000000000000000000000000000000000000000000\
             000000025430000000000000000000000000000000000000000000000000000000000000"
                .replace(' ', ""),
            "T0 == Solidity require(false, \"T0\") revert data"
        );
        assert_eq!(
            hex::encode(err(b"SET6")),
            "08c379a000000000000000000000000000000000000000000000000000000000\
             0000002000000000000000000000000000000000000000000000000000000000\
             000000045345543600000000000000000000000000000000000000000000000000000000"
                .replace(' ', ""),
            "SET6 == Solidity Error(string) revert data"
        );
    }

    // Public `trade` wrapper end-to-end under stub_boundary (oracle getPrice=3000e8,
    // verify no-op, Vault collateral=stub). Run with: cargo test -p
    // denaria-perp-engine-stylus --features stub_boundary
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn trade_wrapper_long_stub() {
        let wad = U256::from(WAD_U64);
        let size = U256::from(1_000u64) * wad;
        let spot = U256::from(300_000_000_000u64);
        let od = U256::from(100_000_000u64);
        let asset = U256::from(6_000u64) * wad;
        let stable = U256::from(18_000_000u64) * wad;
        let zsr = size * od / spot;
        let clamped_guess = asset - zsr;
        let flat_fee = U256::from(120_000_000_000_000_000u64);
        let frontend_fee_part = flat_fee * U256::from(300_000u64) / U256::from(1_000_000u64);
        let effective = size - (flat_fee - frontend_fee_part);

        // Note: each case uses a FRESH TestVM. On-chain an Err return reverts and
        // rolls back the `entered` guard write (like Solidity's nonReentrant); the
        // host TestVM does NOT auto-rollback, and engines from the same VM share
        // storage, so a separate VM is needed per case.

        // success case
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        let expected_return = e.compute_long_return(
            effective, spot, od, clamped_guess, stable, asset,
            U256::from(100_000_000u64), U256::from(10_000_000u64),
        );
        let got = e
            .trade(true, size, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new())
            .expect("stub trade should not revert");
        assert_eq!(got, expected_return, "trade wraps execute_trade => same return");
        assert!(!e.entered.get(), "reentrancy guard reset after a successful trade");
        assert_eq!(e.global_liquidity_asset.get(), asset - got, "pool updated via execute_trade");

        // T0: leverage above max reverts
        let vm2 = TestVM::new();
        vm2.set_block_timestamp(1_700_000_000);
        let mut e2 = PerpEngine::from(&vm2);
        seed_trade_engine(&mut e2);
        let too_much = e2.trade(true, size, U256::ZERO, U256::ZERO, Address::ZERO, 16, Bytes::new());
        assert_eq!(too_much, Err(err(b"T0")), "leverage 16 > max 15 must revert T0");
    }

    // Public `closeAndWithdraw` end-to-end under stub_boundary (oracle getPrice=3000e8,
    // verify no-op, Vault collateral=stub, addPnlToCollateral no-op). Closes a pure-long
    // position: succeeds, clears the position, resets the reentrancy guard.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn close_wrapper_long_stub() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        let ga0 = e.global_liquidity_asset.get();

        let user = e.vm().msg_sender();
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_asset.set(wad); // 1e18 long
        }

        e.close_and_withdraw(U256::from(1_000u64), U256::ZERO, addr(0xFE), Bytes::new())
            .expect("stub close should not revert");

        assert!(!e.entered.get(), "reentrancy guard reset after a successful close");
        assert_eq!(e.global_liquidity_asset.get(), ga0 + wad, "short _trade added sold size to asset reserve");
        let p = e.user_virtual_trader_position.getter(user);
        assert_eq!(p.balance_asset.get(), U256::ZERO, "position cleared");
        assert_eq!(p.balance_stable.get(), U256::ZERO, "position cleared");
    }

    // Public `addLiquidity` end-to-end under stub_boundary (mock oracle/vault): deposit
    // into an empty pool passes L1/L2/C1/L3, folds into globals, resets the guard.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn add_liquidity_wrapper_stub() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        e.global_liquidity_stable.set(U256::ZERO); // empty pool -> deposit fee 0
        e.global_liquidity_asset.set(U256::ZERO);

        let s = U256::from(100u64) * wad;
        let a = U256::from(1u64) * wad;
        e.add_liquidity_public(s, a, U256::ZERO, Bytes::new())
            .expect("stub add should not revert");

        assert!(!e.entered.get(), "reentrancy guard reset after a successful add");
        assert_eq!(e.global_liquidity_stable.get(), s, "pool stable = deposit");
        assert_eq!(e.global_liquidity_asset.get(), a, "pool asset = deposit");
        let sender = e.vm().msg_sender();
        assert_eq!(e.get_lp_liquidity_balance(sender), (s, a), "LP balance == deposit");
    }

    // Public `realizePnL` end-to-end under stub_boundary: a stable-only position with a
    // positive PnL settles in place. PnL = balanceStable (no asset/debt/funding) = 100e18,
    // sign positive; R1 passes; the profit-equals-balance else branch zeroes balanceStable.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn realize_pnl_stub() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        let user = e.vm().msg_sender();
        {
            let mut p = e.user_virtual_trader_position.setter(user);
            p.balance_stable.set(U256::from(100u64) * wad);
        }
        let (pnl, pnl_sign) = e.realize_pnl(Bytes::new()).expect("stub realizePnL");
        assert_eq!(pnl, U256::from(100u64) * wad, "PnL = stable balance");
        assert!(pnl_sign, "PnL positive");
        assert!(!e.entered.get(), "guard reset");
        assert_eq!(e.user_virtual_trader_position.getter(user).balance_stable.get(), U256::ZERO, "balance_stable settled to 0");
    }

    // Public `liquidate` end-to-end under stub_boundary: a deeply-underwater user
    // (debt_asset 10e18, nothing else -> MR=0 bad debt) is FULLY liquidated by a
    // healthy liquidator. d_amount 10e18 < pool asset so the short curve branch runs,
    // but avg_slippage_l=0 forces the spot price (dy'=30000e18). discount(MR=0)=15000:
    // dySecond=30450e18, insurance=75e18. fraction==1 -> closeAndWithdraw sweeps the user.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn liquidate_full_short_stub() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));

        let liquidator = e.vm().msg_sender(); // the caller
        let user = addr(0x71);
        {
            let mut up = e.user_virtual_trader_position.setter(user);
            up.debt_asset.set(U256::from(10u64) * wad); // bad-debt short -> MR = 0
        }
        {
            // liquidator pre-funded with asset so debit_asset reduces balance (no new debt)
            let mut lp = e.user_virtual_trader_position.setter(liquidator);
            lp.balance_asset.set(U256::from(10u64) * wad);
        }

        e.liquidate(user, U256::from(10u64) * wad, Bytes::new())
            .expect("stub full liquidation");

        assert!(!e.entered.get(), "reentrancy guard reset");
        // liquidator absorbed the short: gave 10e18 asset, received dySecond - insurance stable
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_asset.get(), U256::ZERO, "liquidator gave the asset");
        assert_eq!(e.user_virtual_trader_position.getter(liquidator).balance_stable.get(), U256::from(30_375u64) * wad, "liquidator net stable = dySecond - insurance");
        // user fully closed out (fraction == 1)
        let up = e.user_virtual_trader_position.getter(user);
        assert_eq!(up.balance_stable.get(), U256::ZERO, "user closed: balance_stable 0");
        assert_eq!(up.debt_stable.get(), U256::ZERO, "user closed: debt_stable 0");
        assert_eq!(up.debt_asset.get(), U256::ZERO, "user closed: debt_asset 0");
        assert_eq!(up.balance_asset.get(), U256::ZERO, "user closed: balance_asset 0");
    }

    // Keeper updateFG under stub_boundary: advances the funding rate to the current
    // block and stamps lastOperationTimestamp, with no trade/close activity.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn update_fg_keeper_stub() {
        let vm = TestVM::new();
        vm.set_block_timestamp(4600);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.total_trader_exposure.set(U256::from(100u64) * U256::from(WAD_U64));
        e.last_operation_timestamp.set(U64::from(1000u64));
        assert_eq!(e.funding_rate.get(), U256::ZERO, "rate starts at 0");
        e.update_fg_keeper(Bytes::new()).expect("stub updateFG");
        assert_eq!(e.last_operation_timestamp.get(), U64::from(4600u64), "lastOperationTimestamp stamped to block");
        assert!(e.funding_rate.get() > U256::ZERO, "funding rate advanced over [1000,4600]");
    }

    // Forwarded trade: the trusted forwarder opens a position FOR a distinct
    // user; the position accrues to the user, not the forwarder.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn trade_for_forwarded_stub() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        let forwarder = e.vm().msg_sender(); // the caller acts as the trusted forwarder
        e.trusted_forwarder.set(forwarder);
        let user = addr(0x55); // the real trader, distinct from the forwarder
        let size = U256::from(1_000u64) * wad;

        let got = e
            .trade_for(user, true, size, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new())
            .expect("forwarded trade should not revert");
        assert!(got > U256::ZERO, "trade executed");
        assert_eq!(e.user_virtual_trader_position.getter(user).balance_asset.get(), got, "USER holds the asset");
        assert_eq!(
            e.user_virtual_trader_position.getter(forwarder).balance_asset.get(),
            U256::ZERO,
            "forwarder holds nothing"
        );
        assert!(!e.entered.get(), "guard reset");
    }

    // tradeFor reverts "F" unless the direct caller is the trusted forwarder.
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn trade_for_rejects_non_forwarder() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        e.trusted_forwarder.set(addr(0xEE)); // some address that is NOT the caller
        let r = e.trade_for(addr(0x55), true, U256::from(1_000u64) * wad, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new());
        assert_eq!(r, Err(err(b"F")), "non-forwarder caller reverts F");
    }

    // STATEFUL trade + funding differential.
    // Replays the exact op sequence the Solidity PerpPair generator ran
    // (test/differential/TradeFundingDifferential.t.sol) and asserts the full engine
    // state bit-exact after EACH op — return value, global pool, funding rate/sign,
    // exposure/sign, lastOpTs, matrix row G, insurance fund, and the acting user's
    // virtual position. Proves multi-operation state evolution parity (funding accrual
    // across ops), beyond the single-path golden vectors. Uses trade_for to act as the
    // fixture's distinct user addresses (trusted_forwarder = the test caller). Env mirrors
    // the Solidity generator: stub price 3000e8 + stub collateral 1000e18.
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn trade_funding_differential() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(TRADE_FUNDING_DIFF_FIXTURE).expect("diff fixture json");
        let init = &root["init"];
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init"); // grants MOD_ROLE to caller
        e.seed_benchmark_state(u256s(init["stable"].as_str().unwrap()), u256s(init["asset"].as_str().unwrap()))
            .expect("seed");
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd); // act as any user via trade_for

        for (i, op) in root["ops"].as_array().unwrap().iter().enumerate() {
            let user = Address::from_str(op["user"].as_str().unwrap()).expect("user addr");
            let direction = op["direction"].as_bool().unwrap();
            let size = u256s(op["size"].as_str().unwrap());
            let leverage = op["leverage"].as_u64().unwrap() as u8;
            let block_ts: u64 = op["blockTs"].as_str().unwrap().parse().unwrap();
            vm.set_block_timestamp(block_ts);

            let ret = e
                .trade_for(user, direction, size, U256::ZERO, U256::ZERO, Address::ZERO, leverage, Bytes::new())
                .unwrap_or_else(|_| panic!("op {i} reverted on Stylus (expected success)"));

            let us = |k: &str| u256s(op[k].as_str().unwrap());
            let bs = |k: &str| op[k].as_bool().unwrap();
            assert_eq!(ret, us("ret"), "op {i} tradeReturn");
            // global state
            assert_eq!(e.global_liquidity_stable.get(), us("gStable"), "op {i} gStable");
            assert_eq!(e.global_liquidity_asset.get(), us("gAsset"), "op {i} gAsset");
            assert_eq!(e.funding_rate.get(), us("fundingRate"), "op {i} fundingRate");
            assert_eq!(e.funding_rate_sign.get(), bs("fundingRateSign"), "op {i} fundingRateSign");
            assert_eq!(e.total_trader_exposure.get(), us("exposure"), "op {i} exposure");
            assert_eq!(e.total_trader_exposure_sign.get(), bs("exposureSign"), "op {i} exposureSign");
            assert_eq!(U256::from(e.last_operation_timestamp.get()), us("lastOpTs"), "op {i} lastOpTs");
            assert_eq!(e.matrix_row_g0.get(), idecs(op["g0"].as_str().unwrap()), "op {i} g0");
            assert_eq!(e.matrix_row_g1.get(), idecs(op["g1"].as_str().unwrap()), "op {i} g1");
            assert_eq!(e.insurance_fund.get(), us("insurance"), "op {i} insurance");
            assert_eq!(e.insurance_fund_sign.get(), bs("insuranceSign"), "op {i} insuranceSign");
            // acting user's virtual position
            let p = e.user_virtual_trader_position.getter(user);
            assert_eq!(p.balance_stable.get(), us("uBalStable"), "op {i} uBalStable");
            assert_eq!(p.balance_asset.get(), us("uBalAsset"), "op {i} uBalAsset");
            assert_eq!(p.debt_stable.get(), us("uDebtStable"), "op {i} uDebtStable");
            assert_eq!(p.debt_asset.get(), us("uDebtAsset"), "op {i} uDebtAsset");
            assert_eq!(p.funding_fee.get(), us("uFee"), "op {i} uFee");
            assert_eq!(p.funding_fee_sign.get(), bs("uFeeSign"), "op {i} uFeeSign");
            assert_eq!(p.initial_funding_rate.get(), us("uInitFR"), "op {i} uInitFR");
            assert_eq!(p.initial_funding_rate_sign.get(), bs("uInitFRSign"), "op {i} uInitFRSign");
        }
    }

    // STATEFUL liquidity differential. Replays the exact add/remove
    // sequence the Solidity PerpPair generator ran (LiquidityDifferential.t.sol): empty-pool
    // bootstrap → general add → partial remove → full remove (fee-free default config), and
    // asserts the full liquidity state bit-exact after each op — globals, funding, exposure,
    // insurance, the M matrix, matrix row G, and the LP's LiquidityPosition (initial balances,
    // inverseSnapshotM, snapshotG, LP debt) + the LP's virtual trader position (debt-financing).
    // Replays via add/removeLiquidityFor (trusted_forwarder = the test caller); env mirrors
    // the Solidity generator (stub price 3000e8, collateral 1000e18). No pre-seeded reserves:
    // the engine starts empty (M = identity*1e22 from initializeBenchmark), like the harness.
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn liquidity_differential() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(LIQUIDITY_DIFF_FIXTURE).expect("liquidity diff fixture");
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init"); // empty pool, M=identity
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd);

        for (i, op) in root["ops"].as_array().unwrap().iter().enumerate() {
            let kind = op["kind"].as_str().unwrap();
            let user = Address::from_str(op["user"].as_str().unwrap()).expect("user addr");
            let stable = u256s(op["stable"].as_str().unwrap());
            let asset = u256s(op["asset"].as_str().unwrap());
            let block_ts: u64 = op["blockTs"].as_str().unwrap().parse().unwrap();
            vm.set_block_timestamp(block_ts);

            match kind {
                "add" => e
                    .add_liquidity_for(user, stable, asset, U256::ZERO, Bytes::new())
                    .unwrap_or_else(|_| panic!("op {i} add reverted on Stylus")),
                "remove" => e
                    .remove_liquidity_for(user, stable, asset, U256::ZERO, Bytes::new())
                    .unwrap_or_else(|_| panic!("op {i} remove reverted on Stylus")),
                other => panic!("op {i}: unknown kind {other}"),
            }

            let us = |k: &str| u256s(op[k].as_str().unwrap());
            let bs = |k: &str| op[k].as_bool().unwrap();
            let is = |k: &str| idecs(op[k].as_str().unwrap());
            // global + funding + exposure + insurance
            assert_eq!(e.global_liquidity_stable.get(), us("gStable"), "op {i} gStable");
            assert_eq!(e.global_liquidity_asset.get(), us("gAsset"), "op {i} gAsset");
            assert_eq!(e.funding_rate.get(), us("fundingRate"), "op {i} fundingRate");
            assert_eq!(e.funding_rate_sign.get(), bs("fundingRateSign"), "op {i} fundingRateSign");
            assert_eq!(e.total_trader_exposure.get(), us("exposure"), "op {i} exposure");
            assert_eq!(e.total_trader_exposure_sign.get(), bs("exposureSign"), "op {i} exposureSign");
            assert_eq!(e.insurance_fund.get(), us("insurance"), "op {i} insurance");
            assert_eq!(e.insurance_fund_sign.get(), bs("insuranceSign"), "op {i} insuranceSign");
            // liquidity matrix M + row G
            assert_eq!(e.liquidity_m00.get(), is("m00"), "op {i} m00");
            assert_eq!(e.liquidity_m01.get(), is("m01"), "op {i} m01");
            assert_eq!(e.liquidity_m10.get(), is("m10"), "op {i} m10");
            assert_eq!(e.liquidity_m11.get(), is("m11"), "op {i} m11");
            assert_eq!(e.matrix_row_g0.get(), is("g0"), "op {i} g0");
            assert_eq!(e.matrix_row_g1.get(), is("g1"), "op {i} g1");
            // LP position
            let lp = e.liquidity_position.getter(user);
            assert_eq!(lp.initial_stable_balance.get(), us("initS"), "op {i} initS");
            assert_eq!(lp.initial_asset_balance.get(), us("initA"), "op {i} initA");
            assert_eq!(lp.debt_stable.get(), us("lpDebtS"), "op {i} lpDebtS");
            assert_eq!(lp.debt_asset.get(), us("lpDebtA"), "op {i} lpDebtA");
            assert_eq!(lp.inverse_snapshot_m00.get(), is("im00"), "op {i} im00");
            assert_eq!(lp.inverse_snapshot_m01.get(), is("im01"), "op {i} im01");
            assert_eq!(lp.inverse_snapshot_m10.get(), is("im10"), "op {i} im10");
            assert_eq!(lp.inverse_snapshot_m11.get(), is("im11"), "op {i} im11");
            assert_eq!(lp.snapshot_g0.get(), is("sg0"), "op {i} sg0");
            assert_eq!(lp.snapshot_g1.get(), is("sg1"), "op {i} sg1");
            // LP's virtual trader position (debt-financing)
            let p = e.user_virtual_trader_position.getter(user);
            assert_eq!(p.balance_stable.get(), us("vBalS"), "op {i} vBalS");
            assert_eq!(p.balance_asset.get(), us("vBalA"), "op {i} vBalA");
            assert_eq!(p.debt_stable.get(), us("vDebtS"), "op {i} vDebtS");
            assert_eq!(p.debt_asset.get(), us("vDebtA"), "op {i} vDebtA");
        }
    }

    // STATEFUL close + PnL differential. Replays the Solidity
    // PerpPair generator's sequence (ClosePnlDifferential.t.sol): open long → close (×2),
    // then open long → realizePnL. Asserts bit-exact after each op — for trade/realizePnL
    // the return value (realizePnL also the pnl SIGN), and the full state snapshot (globals,
    // funding, exposure, insurance, G, and the user's virtual position — cleared after a
    // close, settled after realizePnL). Replays via trade_for / closeAndWithdrawFor /
    // realizePnLFor; env mirrors the generator (stub price 3000e8, collateral 1000e18).
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn close_pnl_differential() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(CLOSE_PNL_DIFF_FIXTURE).expect("close+pnl diff fixture");
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        e.seed_benchmark_state(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad).expect("seed");
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd);
        let max_slip = U256::from(50_000u64);
        let max_liq_fee = wad; // 1e18

        for (i, op) in root["ops"].as_array().unwrap().iter().enumerate() {
            let kind = op["kind"].as_str().unwrap();
            let user = Address::from_str(op["user"].as_str().unwrap()).expect("user addr");
            let block_ts: u64 = op["blockTs"].as_str().unwrap().parse().unwrap();
            vm.set_block_timestamp(block_ts);
            let us = |k: &str| u256s(op[k].as_str().unwrap());
            let bs = |k: &str| op[k].as_bool().unwrap();

            match kind {
                "trade" => {
                    let direction = bs("direction");
                    let size = us("size");
                    let leverage = op["leverage"].as_u64().unwrap() as u8;
                    let ret = e
                        .trade_for(user, direction, size, U256::ZERO, U256::ZERO, Address::ZERO, leverage, Bytes::new())
                        .unwrap_or_else(|_| panic!("op {i} trade reverted on Stylus"));
                    assert_eq!(ret, us("ret"), "op {i} tradeReturn");
                }
                "close" => {
                    e.close_and_withdraw_for(user, max_slip, max_liq_fee, addr(0xFE), Bytes::new())
                        .unwrap_or_else(|_| panic!("op {i} close reverted on Stylus"));
                }
                "realizepnl" => {
                    let (pnl, sign) = e
                        .realize_pnl_for(user, Bytes::new())
                        .unwrap_or_else(|_| panic!("op {i} realizePnL reverted on Stylus"));
                    assert_eq!(pnl, us("ret"), "op {i} realizePnL pnl");
                    assert_eq!(sign, bs("retSign"), "op {i} realizePnL pnlSign");
                }
                other => panic!("op {i}: unknown kind {other}"),
            }

            // full state snapshot (same fields as the trade+funding differential)
            assert_eq!(e.global_liquidity_stable.get(), us("gStable"), "op {i} gStable");
            assert_eq!(e.global_liquidity_asset.get(), us("gAsset"), "op {i} gAsset");
            assert_eq!(e.funding_rate.get(), us("fundingRate"), "op {i} fundingRate");
            assert_eq!(e.funding_rate_sign.get(), bs("fundingRateSign"), "op {i} fundingRateSign");
            assert_eq!(e.total_trader_exposure.get(), us("exposure"), "op {i} exposure");
            assert_eq!(e.total_trader_exposure_sign.get(), bs("exposureSign"), "op {i} exposureSign");
            assert_eq!(U256::from(e.last_operation_timestamp.get()), us("lastOpTs"), "op {i} lastOpTs");
            assert_eq!(e.matrix_row_g0.get(), idecs(op["g0"].as_str().unwrap()), "op {i} g0");
            assert_eq!(e.matrix_row_g1.get(), idecs(op["g1"].as_str().unwrap()), "op {i} g1");
            assert_eq!(e.insurance_fund.get(), us("insurance"), "op {i} insurance");
            assert_eq!(e.insurance_fund_sign.get(), bs("insuranceSign"), "op {i} insuranceSign");
            let p = e.user_virtual_trader_position.getter(user);
            assert_eq!(p.balance_stable.get(), us("uBalStable"), "op {i} uBalStable");
            assert_eq!(p.balance_asset.get(), us("uBalAsset"), "op {i} uBalAsset");
            assert_eq!(p.debt_stable.get(), us("uDebtStable"), "op {i} uDebtStable");
            assert_eq!(p.debt_asset.get(), us("uDebtAsset"), "op {i} uDebtAsset");
            assert_eq!(p.funding_fee.get(), us("uFee"), "op {i} uFee");
            assert_eq!(p.funding_fee_sign.get(), bs("uFeeSign"), "op {i} uFeeSign");
        }
    }

    // STATEFUL liquidation differential. Replays the Solidity
    // PerpPair generator's sequence (LiquidationDifferential.t.sol): full bad-debt SHORT
    // liquidation (also exercises short close) + full bad-debt LONG liquidation. Each op's
    // liquidatable pre-state + the liquidator's funding are written from the fixture
    // (identical to the generator's harness setter), then liquidateFor is called and the
    // result asserted bit-exact — globals, exposure, insurance fund (bad-debt absorption:
    // sign flips negative), and BOTH the user's (cleared) and liquidator's (absorbed)
    // virtual positions. Env mirrors the generator (stub price 3000e8, MMR-gate collateral
    // 1000e18).
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn liquidation_differential() {
        use core::str::FromStr;
        let root: Value = serde_json::from_str(LIQUIDATION_DIFF_FIXTURE).expect("liquidation diff fixture");
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        e.seed_benchmark_state(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad).expect("seed");
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd);

        for (i, op) in root["ops"].as_array().unwrap().iter().enumerate() {
            let user = Address::from_str(op["user"].as_str().unwrap()).expect("user addr");
            let liquidator = Address::from_str(op["liquidator"].as_str().unwrap()).expect("liq addr");
            let size = u256s(op["size"].as_str().unwrap());
            let block_ts: u64 = op["blockTs"].as_str().unwrap().parse().unwrap();
            let us = |k: &str| u256s(op[k].as_str().unwrap());
            let bs = |k: &str| op[k].as_bool().unwrap();
            vm.set_block_timestamp(block_ts);

            // Setup: write the liquidatable position + the liquidator's funding (== the
            // generator's setVtp). The fixture is the single source of truth for the setup.
            {
                let mut up = e.user_virtual_trader_position.setter(user);
                up.balance_stable.set(us("uBalS"));
                up.balance_asset.set(us("uBalA"));
                up.debt_stable.set(us("uDebtS"));
                up.debt_asset.set(us("uDebtA"));
            }
            {
                let mut lp = e.user_virtual_trader_position.setter(liquidator);
                lp.balance_stable.set(us("lqBalS"));
                lp.balance_asset.set(us("lqBalA"));
            }

            match op["kind"].as_str().unwrap() {
                "liquidate" => e
                    .liquidate_for(liquidator, user, size, Bytes::new())
                    .unwrap_or_else(|_| panic!("op {i} liquidate reverted on Stylus")),
                "autoclose" => {
                    // owner authorizes auto-close (loss threshold), keeper triggers it
                    e.enable_auto_close_for(user, U256::ZERO, us("lossTh"), us("maxSlip"), us("maxLiqFee"))
                        .unwrap_or_else(|_| panic!("op {i} enableAutoClose reverted on Stylus"));
                    e.auto_close_user_position_for(liquidator, user, addr(0xFE), Bytes::new())
                        .unwrap_or_else(|_| panic!("op {i} autoClose reverted on Stylus"));
                }
                other => panic!("op {i}: unknown kind {other}"),
            }

            assert_eq!(e.global_liquidity_stable.get(), us("gStable"), "op {i} gStable");
            assert_eq!(e.global_liquidity_asset.get(), us("gAsset"), "op {i} gAsset");
            assert_eq!(e.total_trader_exposure.get(), us("exposure"), "op {i} exposure");
            assert_eq!(e.total_trader_exposure_sign.get(), bs("exposureSign"), "op {i} exposureSign");
            assert_eq!(e.insurance_fund.get(), us("insurance"), "op {i} insurance");
            assert_eq!(e.insurance_fund_sign.get(), bs("insuranceSign"), "op {i} insuranceSign");
            // user position — fully closed out
            let up = e.user_virtual_trader_position.getter(user);
            assert_eq!(up.balance_stable.get(), us("uBalS_post"), "op {i} user balS");
            assert_eq!(up.balance_asset.get(), us("uBalA_post"), "op {i} user balA");
            assert_eq!(up.debt_stable.get(), us("uDebtS_post"), "op {i} user debtS");
            assert_eq!(up.debt_asset.get(), us("uDebtA_post"), "op {i} user debtA");
            // liquidator position — absorbed the position
            let lq = e.user_virtual_trader_position.getter(liquidator);
            assert_eq!(lq.balance_stable.get(), us("lqBalS_post"), "op {i} liq balS");
            assert_eq!(lq.balance_asset.get(), us("lqBalA_post"), "op {i} liq balA");
            assert_eq!(lq.debt_stable.get(), us("lqDebtS_post"), "op {i} liq debtS");
            assert_eq!(lq.debt_asset.get(), us("lqDebtA_post"), "op {i} liq debtA");
        }
    }

    // Shared invariant oracle: the coupled accounting invariants the engine must
    // satisfy after every successful op. Used by `financial_invariants` (fixed sequence) and
    // `financial_invariants_fuzz` (randomized sequence).
    #[cfg(feature = "stub_boundary")]
    fn check_financial_invariants(e: &PerpEngine, users: &[Address], label: &str) {
        let gs = e.global_liquidity_stable.get();
        let ga = e.global_liquidity_asset.get();
        // INV-EXPOSURE: totalTraderExposure (signed) == Σ signed(balanceAsset − debtAsset),
        // up to the bounded dust drift a short close leaves in totalTraderExposure. The
        // close buy-back inverts via computeExactAmountInLong, whose fixed-point residual is
        // capped per close by the pool-relative C0 dust bound (and priced into PnL); the
        // residual asset is zeroed with the position but not subtracted from exposure, so the
        // identity holds only within that envelope (see close path / perpTrade.sol).
        let mut net = I256::ZERO;
        for &u in users {
            let p = e.user_virtual_trader_position.getter(u);
            net += cm::i(p.balance_asset.get()) - cm::i(p.debt_asset.get());
        }
        let exp = cm::i(e.total_trader_exposure.get());
        let signed_exp = if e.total_trader_exposure_sign.get() { exp } else { -exp };
        let drift = if net >= signed_exp { net - signed_exp } else { signed_exp - net };
        let price = U256::from(300_000_000_000u64); // stub oracle price both callers run under
        let drift_stable = cm::md(cm::u(drift), price, U256::from(e.oracle_decimals.get()));
        let dust_bound = (gs / U256::from(10_000_000_000u64)).max(U256::from(10_000_000_000u64));
        assert!(
            drift_stable <= dust_bound,
            "{label}: exposure == Σ trader net asset within close dust bound (drift_stable={drift_stable}, bound={dust_bound})",
        );
        // INV-LP-BOUND: each LP's reconstructed balance is clamped to the global pool.
        for &u in users {
            let (ls, la) = e.get_lp_liquidity_balance(u);
            assert!(ls <= gs && la <= ga, "{label}: LP balance bounded by globals");
        }
        // INV-INS-CAP: a positive insurance fund never exceeds the cap (excess → protocol).
        if e.insurance_fund_sign.get() {
            assert!(e.insurance_fund.get() <= e.insurance_fund_cap.get(), "{label}: insurance ≤ cap");
        }
        // INV-NONNEG: the pool is never drained to empty while liquidity exists.
        assert!(gs > U256::ZERO && ga > U256::ZERO, "{label}: pool reserves stay positive");
    }

    // System-level FINANCIAL INVARIANTS over a realistic mixed sequence (long/short
    // trades + funding accrual + add/remove liquidity, several users). After EVERY successful
    // op the engine must satisfy a set of coupled accounting invariants — proving solvency
    // properties beyond single-path tests. Asserted on engine state alone (no Solidity ref).
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn financial_invariants() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        e.seed_benchmark_state(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad).expect("seed");
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd);
        let a = addr(0xA1);
        let b = addr(0xB1);
        let c = addr(0xC1);
        let d = addr(0xD1); // liquidity provider
        let users = [a, b, c, d];

        // run all invariants against the current engine state
        let check = check_financial_invariants;

        check(&e, &users, "seed");
        vm.set_block_timestamp(1_000);
        e.trade_for(a, true, U256::from(1_000u64) * wad, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new()).expect("a long");
        check(&e, &users, "after a long");
        vm.set_block_timestamp(4_600);
        e.trade_for(b, false, wad / U256::from(20u64), U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new()).expect("b short");
        check(&e, &users, "after b short");
        vm.set_block_timestamp(8_200);
        e.add_liquidity_for(d, U256::from(3_000u64) * wad, wad, U256::ZERO, Bytes::new()).expect("d add lp");
        check(&e, &users, "after d add liquidity");
        vm.set_block_timestamp(11_800);
        e.trade_for(c, true, U256::from(500u64) * wad, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new()).expect("c long");
        check(&e, &users, "after c long");
        vm.set_block_timestamp(15_400);
        let (ds, da) = e.get_lp_liquidity_balance(d);
        e.remove_liquidity_for(d, ds / U256::from(2u64), da / U256::from(2u64), U256::ZERO, Bytes::new()).expect("d remove half");
        check(&e, &users, "after d remove liquidity");
        vm.set_block_timestamp(19_000);
        e.trade_for(a, true, U256::from(200u64) * wad, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new()).expect("a re-long (funding fee accrues)");
        check(&e, &users, "after a re-long");
    }

    // RANDOMIZED invariant fuzz. A deterministic LCG drives 40 ops (long/short
    // trades from a 6-user pool with bounded-safe sizes, an LP add, periodic LP removes, random
    // time advances → funding accrues) and asserts the coupled invariants after EVERY op. All
    // ops must succeed (the TestVM does not roll back), so sizes are bounded to stay healthy.
    #[cfg(feature = "stub_boundary")]
    #[test]
    fn financial_invariants_fuzz() {
        let wad = U256::from(WAD_U64);
        let vm = TestVM::new();
        let mut e = PerpEngine::from(&vm);
        e.initialize_benchmark(addr(0x01), addr(0x02), addr(0x03)).expect("init");
        e.seed_benchmark_state(U256::from(18_000_000u64) * wad, U256::from(6_000u64) * wad).expect("seed");
        let fwd = e.vm().msg_sender();
        e.trusted_forwarder.set(fwd);
        let traders = [addr(0xA1), addr(0xA2), addr(0xA3), addr(0xA4), addr(0xA5), addr(0xA6)];
        let lp = addr(0xD1);
        let all = [addr(0xA1), addr(0xA2), addr(0xA3), addr(0xA4), addr(0xA5), addr(0xA6), addr(0xD1)];

        let mut s: u64 = 0x9E3779B97F4A7C15;
        let mut ts: u64 = 1_000;
        let mut lp_added = false;
        for _ in 0..40u64 {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); // LCG
            ts += 1 + (s >> 40) % 7_200; // 1..7200s advance → funding accrues
            vm.set_block_timestamp(ts);
            // All ops are TOLERANT: an op that reverts (e.g. T1 margin after a close, a short
            // self-close outside the 1e10 dust band → `C0`, a no-position close/realizePnL) is a
            // clean Err that leaves state unchanged, so the invariants still hold. The invariant
            // suite — not per-op success — is the assertion; this lets the randomized sequence mix
            // open/close/realizePnL/LP ops without hand-tuning every draw to succeed.
            let u = traders[((s >> 20) % 6) as usize];
            match (s >> 33) % 10 {
                0..=3 => {
                    // long: `size` is the STABLE input — ≥ minimumTradeSize(48e18); 50..99e18.
                    let size = U256::from(50u64 + (s >> 16) % 50) * wad;
                    let _ = e.trade_for(u, true, size, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new());
                }
                4..=5 => {
                    // short: size*3000 ≥ minTradeSize(48e18) → ≥0.016e18; use 0.02..0.1e18
                    let size = wad / U256::from(50u64) + U256::from((s >> 16) % 80) * (wad / U256::from(1_000u64));
                    let _ = e.trade_for(u, false, size, U256::ZERO, U256::ZERO, Address::ZERO, 1, Bytes::new());
                }
                6 => {
                    // close: open→close cycles (full close of the user's position).
                    let _ = e.close_and_withdraw_for(u, U256::from(50_000u64), wad, addr(0xFE), Bytes::new());
                }
                7 => {
                    // realizePnL: settles the user's funding PnL.
                    let _ = e.realize_pnl_for(u, Bytes::new());
                }
                8 => {
                    if !lp_added
                        && e.add_liquidity_for(lp, U256::from(2_000u64) * wad, wad / U256::from(2u64), U256::ZERO, Bytes::new()).is_ok()
                    {
                        lp_added = true;
                    }
                }
                _ => {
                    if lp_added {
                        let (ls, la) = e.get_lp_liquidity_balance(lp);
                        if ls > wad && la > U256::ZERO {
                            let _ = e.remove_liquidity_for(lp, ls / U256::from(4u64), la / U256::from(4u64), U256::ZERO, Bytes::new());
                        }
                    }
                }
            }
            check_financial_invariants(&e, &all, "fuzz");
        }
    }

    // addLiquidityFor: confirms the second forwarded variant's wiring (arg order + gate).
    // The LP position accrues to the explicit user; a non-forwarder caller reverts "F".
    #[test]
    #[cfg(feature = "stub_boundary")]
    fn add_liquidity_for_forwarded_stub() {
        let wad = U256::from(WAD_U64);
        let s = U256::from(100u64) * wad;
        let a = U256::from(1u64) * wad;
        let user = addr(0x56);

        // forwarded success
        let vm = TestVM::new();
        vm.set_block_timestamp(1_700_000_000);
        let mut e = PerpEngine::from(&vm);
        seed_trade_engine(&mut e);
        e.vault.set(addr(0x99));
        e.global_liquidity_stable.set(U256::ZERO);
        e.global_liquidity_asset.set(U256::ZERO);
        let forwarder = e.vm().msg_sender();
        e.trusted_forwarder.set(forwarder);
        e.add_liquidity_for(user, s, a, U256::ZERO, Bytes::new()).expect("forwarded add");
        assert_eq!(e.get_lp_liquidity_balance(user), (s, a), "LP accrues to the explicit user");
        assert_eq!(e.get_lp_liquidity_balance(forwarder), (U256::ZERO, U256::ZERO), "forwarder has no LP");
        assert!(!e.entered.get(), "guard reset");

        // non-forwarder rejection (fresh VM: the on-chain revert would roll back the guard)
        let vm2 = TestVM::new();
        vm2.set_block_timestamp(1_700_000_000);
        let mut e2 = PerpEngine::from(&vm2);
        seed_trade_engine(&mut e2);
        e2.vault.set(addr(0x99));
        e2.trusted_forwarder.set(addr(0xEE)); // not the caller
        e2.global_liquidity_stable.set(U256::ZERO);
        e2.global_liquidity_asset.set(U256::ZERO);
        assert_eq!(
            e2.add_liquidity_for(user, s, a, U256::ZERO, Bytes::new()),
            Err(err(b"F")),
            "non-forwarder caller reverts F"
        );
    }
