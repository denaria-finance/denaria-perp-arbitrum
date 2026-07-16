// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import "../../src/util/UtilMath.sol";

/// @notice Golden vectors for the engine event topic0 (signature) hashes. The events
///         are copied VERBATIM (types only matter for the selector) from the perp
///         modules; `.selector` yields the real Solidity topic0. The Stylus engine's
///         `sol!`-derived `Event::SIGNATURE_HASH` must equal these — catches any
///         type/order transcription error in the Rust event declarations.
contract EventSelectorGoldenVectorTest is Test {
    // --- verbatim from the perp modules (param names irrelevant to the selector) ---
    event ExecutedTrade(
        address indexed user,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        uint256 leverage
    );
    event ClosedPosition(address indexed user, uint256 pnl, bool pnlSign);
    event LiquidityMoved(
        address indexed user, uint256 liquidityStable, uint256 liquidityAsset, uint256 fee, bool added
    );
    event LiquidatedUser(
        address indexed user,
        address liquidator,
        uint256 fraction,
        uint256 liquidationFee,
        uint256 positionSize,
        uint256 currentPrice,
        int256 deltaPnl,
        bool liquidationDirection
    );
    event ToggledAutoClose(
        address indexed user, uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee
    );
    event RealizedPnL(address indexed user, uint256 pnl, bool pnlSign);
    event ParametersUpdated(
        address _oracle,
        uint256 _feeFrontend,
        address _feeProtocolAddr,
        uint256 _insuranceFundCap,
        uint256 _maxLeverage,
        uint256 _liquidationDiscount
    );
    event LockedParameterUpdate(
        uint256 paramLockedUntil,
        uint256 _MMR,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        uint256 _paramTimeLock,
        uint256 _minimumTradeSize
    );
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event TradingPaused(bool paused, address indexed account);

    string internal constant FIXTURE_PATH = "/test/fixtures/event_selector_vectors.json";

    function testWriteEventSelectorFixture() public {
        string memory json = string(
            abi.encodePacked(
                '{\n  "schema": "denaria.event_selector.parity.v1",\n  "events": {\n',
                row("ExecutedTrade", ExecutedTrade.selector),
                ",\n",
                row("ClosedPosition", ClosedPosition.selector),
                ",\n",
                row("LiquidityMoved", LiquidityMoved.selector),
                ",\n",
                row("LiquidatedUser", LiquidatedUser.selector),
                ",\n",
                row("ToggledAutoClose", ToggledAutoClose.selector),
                ",\n",
                row("RealizedPnL", RealizedPnL.selector),
                ",\n",
                row("ParametersUpdated", ParametersUpdated.selector),
                ",\n",
                row("LockedParameterUpdate", LockedParameterUpdate.selector),
                ",\n",
                row("RoleGranted", RoleGranted.selector),
                ",\n",
                row("RoleRevoked", RoleRevoked.selector),
                ",\n",
                rowLast("TradingPaused", TradingPaused.selector),
                "\n  }\n}\n"
            )
        );
        string memory dir = string.concat(vm.projectRoot(), "/test/fixtures");
        string memory path = string.concat(vm.projectRoot(), FIXTURE_PATH);
        vm.createDir(dir, true);
        vm.writeFile(path, json);
        assertEq(vm.readFile(path), json, "fixture write mismatch");
    }

    function row(string memory name, bytes32 sel) internal pure returns (string memory) {
        return string(abi.encodePacked('    "', name, '": "', Strings.toHexString(uint256(sel), 32), '"'));
    }

    function rowLast(string memory name, bytes32 sel) internal pure returns (string memory) {
        return row(name, sel);
    }
}
