// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../src/util/UtilMath.sol";

/// @title FundingGoldenVectorTest
/// @notice Generates Solidity golden vectors for the funding-rate math so the
///         Rust/Stylus engine port (perp-engine compute_funding_rate) can be
///         checked bit-exact. `FundingRef.computeFundingRate` is a line-for-line
///         transcription of `src/perpModules/perpFunding.sol::computeFundingRate`
///         with `block.timestamp` lifted to an explicit `blockTs` argument and
///         storage reads lifted to explicit inputs; it calls the REAL
///         `UtilMath.clamp` library, so the clamp logic is not transcribed.
///         (computeFundingFee golden vectors are a follow-up; it has ~3x the
///         inputs and is covered by an engine native smoke test in the meantime.)
library FundingRef {
    function computeFundingRate(
        uint256 price,
        uint256 timestamp,
        uint256 blockTs,
        uint256 globalLiquidityAsset,
        uint256 globalLiquidityStable,
        uint256 totalTraderExposure,
        bool totalTraderExposureSign,
        uint256 oracleDecimals,
        uint256 fundingC,
        uint256 fundingInterval,
        uint256 fundingCDecimals,
        uint256 fundingRateDecimals,
        uint256 clampMinFR,
        uint256 clampMaxFR,
        uint256 clampOffset
    )
        internal
        pure
        returns (uint256, bool)
    {
        require(timestamp <= blockTs, "F1");
        uint256 assetLiq = globalLiquidityAsset;
        uint256 stableLiq = globalLiquidityStable;
        if (assetLiq + stableLiq == 0) return (0, true);

        uint256 priceO = price * 1e18 / oracleDecimals;
        uint256 raw = totalTraderExposure * priceO / 1e18 * fundingCDecimals * fundingRateDecimals;
        uint256 denomAsset = assetLiq * priceO / 1e18;
        uint256 denom = fundingC * (denomAsset + stableLiq);

        UtilMath.ClampParameters memory cp = UtilMath.ClampParameters(clampMinFR, clampMaxFR, clampOffset);
        (uint256 coeff, bool coeffSign) = UtilMath.clamp(raw / denom, cp, totalTraderExposureSign);

        uint256 delta = blockTs - timestamp;
        uint256 newRate = coeff * delta / fundingInterval;
        return (priceO * newRate / 1e18, coeffSign);
    }

    struct FeeMarket {
        uint256 fundingRate;
        bool fundingRateSign;
        int256 invLMD;
        uint256 liquidityGDecimals;
        uint256 fundingRateDecimals;
        int256 matrixRowG0;
        int256 matrixRowG1;
        int256 liquidityM10;
        int256 liquidityM11;
    }

    struct FeeLp {
        int256 snapshotG0;
        int256 snapshotG1;
        uint256 initialStableBalance;
        uint256 initialAssetBalance;
        int256 invM00;
        int256 invM01;
        int256 invM10;
        int256 invM11;
        uint256 debtAsset;
    }

    struct FeeVp {
        uint256 balanceAsset;
        uint256 debtAsset;
        uint256 initialFundingRate;
        bool initialFundingRateSign;
    }

    /// Transcription of perpFunding._computeFundingFee(user, fr, frSign) with the
    /// per-user/market storage lifted to explicit structs. Calls the REAL
    /// UtilMath.signedSum + SafeCast.toInt256.
    function computeFundingFee(
        uint256 fr,
        bool frSign,
        FeeMarket memory m,
        FeeLp memory lp,
        FeeVp memory vp
    )
        internal
        pure
        returns (uint256, bool)
    {
        int256 invLMD = m.invLMD;
        (uint256 deltaF, bool deltaFSign) = UtilMath.signedSum(fr, frSign, m.fundingRate, !m.fundingRateSign);
        int256 b = SafeCast.toInt256(deltaF * m.liquidityGDecimals / m.fundingRateDecimals);
        if (!deltaFSign) {
            b = -b;
        }
        int256 deltaG0 = m.matrixRowG0 - lp.snapshotG0 + b * m.liquidityM10 / invLMD;
        int256 deltaG1 = m.matrixRowG1 - lp.snapshotG1 + b * m.liquidityM11 / invLMD;
        int256 LiqStable = int256(lp.initialStableBalance);
        int256 LiqAsset = int256(lp.initialAssetBalance);
        int256 x0 = (deltaG0 * lp.invM00 + deltaG1 * lp.invM10) / invLMD;
        int256 x1 = (deltaG0 * lp.invM01 + deltaG1 * lp.invM11) / invLMD;
        int256 star = (x0 * LiqStable + x1 * LiqAsset) / int256(m.liquidityGDecimals);
        (deltaF, deltaFSign) = UtilMath.signedSum(fr, frSign, vp.initialFundingRate, !vp.initialFundingRateSign);
        (uint256 exposure, bool exposureSign) =
            UtilMath.signedSum(vp.balanceAsset, true, vp.debtAsset + lp.debtAsset, false);
        uint256 absStar = star >= 0 ? uint256(star) : uint256(-star);
        return UtilMath.signedSum(
            absStar, star >= 0, (exposure * deltaF) / m.fundingRateDecimals, deltaFSign == exposureSign
        );
    }
}

contract FundingGoldenVectorTest is Test {
    using Strings for uint256;

    string internal constant FIXTURE_PATH = "/test/fixtures/funding_solidity_vectors.json";

    struct RateInput {
        string label;
        uint256 price;
        uint256 timestamp;
        uint256 blockTs;
        uint256 globalLiquidityAsset;
        uint256 globalLiquidityStable;
        uint256 totalTraderExposure;
        bool totalTraderExposureSign;
        uint256 oracleDecimals;
        uint256 fundingC;
        uint256 fundingInterval;
        uint256 fundingCDecimals;
        uint256 fundingRateDecimals;
        uint256 clampMinFR;
        uint256 clampMaxFR;
        uint256 clampOffset;
    }

    function testWriteFundingFixture() public {
        string memory vectors = "";
        uint256 count = 0;

        // within clamp bounds (large max) — straight rate
        (vectors, count) = append(
            vectors,
            rateVector(
                RateInput(
                    "rate-within",
                    300_000_000_000,
                    1000,
                    1000 + 3600,
                    6000e18,
                    18_000_000e18,
                    100e18,
                    true,
                    1e8,
                    1e6,
                    86_400,
                    1e5,
                    1e18,
                    0,
                    1e30,
                    0
                )
            ),
            count
        );

        // above max, positive sign -> clamped to max
        (vectors, count) = append(
            vectors,
            rateVector(
                RateInput(
                    "rate-above-max-pos",
                    300_000_000_000,
                    1000,
                    1000 + 86_400,
                    6000e18,
                    18_000_000e18,
                    5000e18,
                    true,
                    1e8,
                    1e6,
                    86_400,
                    1e5,
                    1e18,
                    1e12,
                    1e15,
                    1e14
                )
            ),
            count
        );

        // above max, negative exposure sign -> clamp applies the offset
        (vectors, count) = append(
            vectors,
            rateVector(
                RateInput(
                    "rate-above-max-neg",
                    300_000_000_000,
                    1000,
                    1000 + 86_400,
                    6000e18,
                    18_000_000e18,
                    5000e18,
                    false,
                    1e8,
                    1e6,
                    86_400,
                    1e5,
                    1e18,
                    1e12,
                    1e15,
                    1e14
                )
            ),
            count
        );

        // zero liquidity -> (0, true)
        (vectors, count) = append(
            vectors,
            rateVector(
                RateInput(
                    "rate-zero-liq",
                    300_000_000_000,
                    1000,
                    5000,
                    0,
                    0,
                    100e18,
                    true,
                    1e8,
                    1e6,
                    86_400,
                    1e5,
                    1e18,
                    0,
                    1e30,
                    0
                )
            ),
            count
        );

        // --- funding-fee vectors ---
        // no LP position -> star == 0; only the trader-exposure term contributes
        {
            FeeInput memory f;
            f.label = "fee-zero-lp";
            f.fr = 3e18;
            f.frSign = true;
            f.fundingRate = 1e18;
            f.fundingRateSign = true;
            f.invLMD = 1e22;
            f.liquidityGDecimals = 1e10;
            f.fundingRateDecimals = 1e18;
            f.matrixRowG0 = 5e20;
            f.matrixRowG1 = 3e20;
            f.liquidityM10 = 2e21;
            f.liquidityM11 = 1e21;
            f.balanceAsset = 4e18;
            f.vpDebtAsset = 1e18;
            f.initialFundingRate = 5e17;
            f.initialFundingRateSign = true;
            (vectors, count) = append(vectors, feeVector(f), count);
        }
        // non-zero LP position (M^-1 = identity*invLMD, snapshotG != matrixRowG) -> star != 0
        {
            FeeInput memory f;
            f.label = "fee-nonzero-lp";
            f.fr = 3e18;
            f.frSign = true;
            f.fundingRate = 1e18;
            f.fundingRateSign = true;
            f.invLMD = 1e22;
            f.liquidityGDecimals = 1e10;
            f.fundingRateDecimals = 1e18;
            f.matrixRowG0 = 5e20;
            f.matrixRowG1 = -3e20;
            f.liquidityM10 = 2e21;
            f.liquidityM11 = 1e21;
            f.snapshotG0 = 1e20;
            f.snapshotG1 = 1e20;
            f.initialStableBalance = 1000e18;
            f.initialAssetBalance = 2e18;
            f.invM00 = 1e22;
            f.invM11 = 1e22;
            f.balanceAsset = 4e18;
            f.vpDebtAsset = 1e18;
            f.initialFundingRate = 5e17;
            f.initialFundingRateSign = true;
            (vectors, count) = append(vectors, feeVector(f), count);
        }

        string memory fixture = string(
            abi.encodePacked(
                "{\n",
                '  "schema": "denaria.funding.parity.v1",\n',
                '  "generatedBy": "test/funding/FundingGoldenVector.t.sol",\n',
                '  "reference": "src/perpModules/perpFunding.sol",\n',
                '  "target": "perp-engine/src/lib.rs",\n',
                '  "vectorCount": ',
                count.toString(),
                ",\n",
                '  "vectors": [\n',
                vectors,
                "\n  ]\n}\n"
            )
        );
        string memory dir = string.concat(vm.projectRoot(), "/test/fixtures");
        string memory path = string.concat(vm.projectRoot(), FIXTURE_PATH);
        vm.createDir(dir, true);
        vm.writeFile(path, fixture);
        assertEq(vm.readFile(path), fixture, "funding fixture write mismatch");
    }

    function rateVector(RateInput memory v) internal pure returns (string memory) {
        (uint256 rate, bool rateSign) = FundingRef.computeFundingRate(
            v.price,
            v.timestamp,
            v.blockTs,
            v.globalLiquidityAsset,
            v.globalLiquidityStable,
            v.totalTraderExposure,
            v.totalTraderExposureSign,
            v.oracleDecimals,
            v.fundingC,
            v.fundingInterval,
            v.fundingCDecimals,
            v.fundingRateDecimals,
            v.clampMinFR,
            v.clampMaxFR,
            v.clampOffset
        );
        return string(
            abi.encodePacked(
                '    {"kind":"fundingRate","label":"',
                v.label,
                '","inputs":{',
                '"price":"',
                v.price.toString(),
                '","timestamp":"',
                v.timestamp.toString(),
                '","blockTs":"',
                v.blockTs.toString(),
                '","globalLiquidityAsset":"',
                v.globalLiquidityAsset.toString(),
                '","globalLiquidityStable":"',
                v.globalLiquidityStable.toString(),
                '","totalTraderExposure":"',
                v.totalTraderExposure.toString(),
                '","totalTraderExposureSign":',
                v.totalTraderExposureSign ? "true" : "false",
                ',"oracleDecimals":"',
                v.oracleDecimals.toString(),
                '","fundingC":"',
                v.fundingC.toString(),
                '","fundingInterval":"',
                v.fundingInterval.toString(),
                '","fundingCDecimals":"',
                v.fundingCDecimals.toString(),
                '","fundingRateDecimals":"',
                v.fundingRateDecimals.toString(),
                '","clampMinFR":"',
                v.clampMinFR.toString(),
                '","clampMaxFR":"',
                v.clampMaxFR.toString(),
                '","clampOffset":"',
                v.clampOffset.toString(),
                '"},"expected":{"rate":"',
                rate.toString(),
                '","rateSign":',
                rateSign ? "true" : "false",
                "}}"
            )
        );
    }

    struct FeeInput {
        string label;
        uint256 fr;
        bool frSign;
        uint256 fundingRate;
        bool fundingRateSign;
        int256 invLMD;
        uint256 liquidityGDecimals;
        uint256 fundingRateDecimals;
        int256 matrixRowG0;
        int256 matrixRowG1;
        int256 liquidityM10;
        int256 liquidityM11;
        int256 snapshotG0;
        int256 snapshotG1;
        uint256 initialStableBalance;
        uint256 initialAssetBalance;
        int256 invM00;
        int256 invM01;
        int256 invM10;
        int256 invM11;
        uint256 lpDebtAsset;
        uint256 balanceAsset;
        uint256 vpDebtAsset;
        uint256 initialFundingRate;
        bool initialFundingRateSign;
    }

    function feeVector(FeeInput memory v) internal pure returns (string memory) {
        (uint256 fee, bool feeSign) = FundingRef.computeFundingFee(
            v.fr,
            v.frSign,
            FundingRef.FeeMarket(
                v.fundingRate,
                v.fundingRateSign,
                v.invLMD,
                v.liquidityGDecimals,
                v.fundingRateDecimals,
                v.matrixRowG0,
                v.matrixRowG1,
                v.liquidityM10,
                v.liquidityM11
            ),
            FundingRef.FeeLp(
                v.snapshotG0,
                v.snapshotG1,
                v.initialStableBalance,
                v.initialAssetBalance,
                v.invM00,
                v.invM01,
                v.invM10,
                v.invM11,
                v.lpDebtAsset
            ),
            FundingRef.FeeVp(v.balanceAsset, v.vpDebtAsset, v.initialFundingRate, v.initialFundingRateSign)
        );
        return string(
            abi.encodePacked(
                '    {"kind":"fundingFee","label":"',
                v.label,
                '","inputs":',
                feeInputsJson(v),
                ',"expected":{"fee":"',
                fee.toString(),
                '","feeSign":',
                feeSign ? "true" : "false",
                "}}"
            )
        );
    }

    function feeInputsJson(FeeInput memory v) internal pure returns (string memory) {
        string memory a = string(
            abi.encodePacked(
                '{"fr":"',
                v.fr.toString(),
                '","frSign":',
                v.frSign ? "true" : "false",
                ',"fundingRate":"',
                v.fundingRate.toString(),
                '","fundingRateSign":',
                v.fundingRateSign ? "true" : "false",
                ',"invLMD":"',
                intStr(v.invLMD),
                '","liquidityGDecimals":"',
                v.liquidityGDecimals.toString(),
                '","fundingRateDecimals":"',
                v.fundingRateDecimals.toString(),
                '","matrixRowG0":"',
                intStr(v.matrixRowG0),
                '","matrixRowG1":"',
                intStr(v.matrixRowG1),
                '","liquidityM10":"',
                intStr(v.liquidityM10),
                '","liquidityM11":"',
                intStr(v.liquidityM11),
                '"'
            )
        );
        string memory b = string(
            abi.encodePacked(
                ',"snapshotG0":"',
                intStr(v.snapshotG0),
                '","snapshotG1":"',
                intStr(v.snapshotG1),
                '","initialStableBalance":"',
                v.initialStableBalance.toString(),
                '","initialAssetBalance":"',
                v.initialAssetBalance.toString(),
                '","invM00":"',
                intStr(v.invM00),
                '","invM01":"',
                intStr(v.invM01),
                '","invM10":"',
                intStr(v.invM10),
                '","invM11":"',
                intStr(v.invM11),
                '","lpDebtAsset":"',
                v.lpDebtAsset.toString(),
                '","balanceAsset":"',
                v.balanceAsset.toString(),
                '","vpDebtAsset":"',
                v.vpDebtAsset.toString(),
                '","initialFundingRate":"',
                v.initialFundingRate.toString(),
                '","initialFundingRateSign":',
                v.initialFundingRateSign ? "true" : "false",
                "}"
            )
        );
        return string.concat(a, b);
    }

    function intStr(int256 x) internal pure returns (string memory) {
        if (x >= 0) {
            return uint256(x).toString();
        }
        return string.concat("-", uint256(-x).toString());
    }

    function append(string memory acc, string memory v, uint256 count) internal pure returns (string memory, uint256) {
        return (count == 0 ? v : string.concat(acc, ",\n", v), count + 1);
    }
}
