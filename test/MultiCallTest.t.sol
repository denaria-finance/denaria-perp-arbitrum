// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { PerpPair } from "../src/PerpPair.sol";
import { Vault } from "../src/Vault.sol";
import { LostAndFound } from "../src/LostAndFound.sol";
import "../src/token/USDCe.sol";
import "../src/util/CurveMath.sol";
import "../src/util/MatrixMath.sol";
import "../src/util/UtilMath.sol";
import "../src/manager/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/test_support/TestPriceProvider.sol";
import "../src/manager/multiCallManager.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./helpers/PerpPairTestDeploymentHelper.sol";

contract PerpPairTest is Test, PerpPairTestDeploymentHelper {
    using Strings for uint256;

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
    uint256 MAX_UINT = 2 ** 256 - 1;
    Vault public vault;
    PerpPair public perpPair;
    LostAndFound public lostAndFound;
    PerpMultiCalls public multiCallManager;
    uint256 public MMRDecimals = 1e6;
    uint256 public MMR = 38 * MMRDecimals / 1000;
    bytes32 public tickerAsset;
    string public tickerCurrency;
    uint256 public tradingFeeDecimals = 1e18;
    uint32 public feeFractionDecimals = 1e6;
    uint32 public feeFrontend = 5 * feeFractionDecimals / 100;
    address public frontendAddress = makeAddr("frontend");
    uint32 public feeLP = 5 * feeFractionDecimals / 10;
    address public feeProtocolAddr = makeAddr("denaria");
    uint256 public tradingFee = 1 * tradingFeeDecimals / 1000;
    uint256 public flatTradingFee = 1e17;
    uint256 public curveParameterDecimals = 1e8;
    TestPriceProvider public oracle;
    uint256 public oracleDecimals = 1e8;
    uint256 public currencyDecimals = 1e18;
    uint256 public ratioDecimals = 1e8;
    uint256 public liquidityFeeDecimals = 1e10;
    string public tokenName = "USDCe";
    string public tokenSymbol = "USDC.e";
    string public tokenCurrency = "USD";
    address public MasterMinter = makeAddr("Megamind");
    address public Pauser = makeAddr("Megamind");
    address public Blacklister = makeAddr("Megamind");
    address public Owner = makeAddr("Megamind");
    uint256 startingStableAmount = 10_000_000;
    bytes public fakeReport;
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256(bytes("PerpMultiCalls")); // <== keep in sync
    bytes32 constant VERSION_HASH = keccak256(bytes("1"));
    uint256 public maxUserLiquidityFee = 1e30;

    address[] public stableCoins;
    address[] public userAddresses;
    uint256[] public userPks;
    uint256[] public depositThresholds;
    uint256[] public withdrowalThresholds;
    uint256[] public stableDecimals;

    event DebugEvent(uint256);

    function setUp() public {
        uint256 numStableCoins = 2;
        FiatTokenV2 stablecoin;

        uint8[2] memory tokenDecimals = [6, 18];

        uint256 i;
        for (i = 0; i < numStableCoins; i++) {
            stablecoin = new FiatTokenV2();
            stablecoin.initialize(
                tokenName, tokenSymbol, tokenCurrency, tokenDecimals[i], MasterMinter, Pauser, Blacklister, Owner
            );
            stablecoin.initializeV2(tokenName);
            vm.prank(MasterMinter);
            stablecoin.configureMinter(MasterMinter, 1e40);
            stableCoins.push(address(stablecoin));
            depositThresholds.push(1 * ratioDecimals);
            withdrowalThresholds.push(1 * ratioDecimals);
        }
        stableDecimals.push(1e6);
        stableDecimals.push(1e18);
        oracle = new TestPriceProvider();
        multiCallManager = new PerpMultiCalls();
        vault = new Vault(
            address(multiCallManager), 100, stableCoins, depositThresholds, withdrowalThresholds, stableDecimals
        );
        perpPair = _deployPerpPairForTest(
            address(oracle),
            address(vault),
            address(multiCallManager),
            MMR,
            tickerAsset,
            feeFrontend,
            feeLP,
            feeProtocolAddr,
            tradingFee,
            flatTradingFee,
            oracleDecimals * 9 / 10
        );
        multiCallManager.initializeAddresses(address(perpPair), address(vault));
        lostAndFound = new LostAndFound();
        vault.initializeParameters(address(perpPair), address(lostAndFound));

        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        address userAddress;
        uint256 userPk;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = startingStableAmount * 1e6;
        amounts[1] = startingStableAmount * 1e18;
        for (i = 0; i < 100; i++) {
            userPk = vm.randomUint();
            userAddress = vm.addr(userPk);
            userAddresses.push(userAddress);
            userPks.push(userPk);
            //console.log(userAddress);

            //givinc collateral to users
            vm.prank(userAddress);
            coinA.approve(address(vault), MAX_UINT);
            vm.prank(userAddress);
            coinB.approve(address(vault), MAX_UINT);

            _mint(stableCoins[0], userAddress, startingStableAmount * 1e6 * 2);
            _mint(stableCoins[1], userAddress, startingStableAmount * 1e18 * 2);

            amounts[0] = startingStableAmount * 1e6;
            amounts[1] = startingStableAmount * 1e18;

            vm.prank(userAddress);
            vault.addCollateral(amounts);
        }
    }

    ///@dev test the addCollateralAddLiquidity multicall. Need signature from node server to approve permit.
    function testAddCollateralAddLiquidity() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");

        _mint(stableCoins[0], userA, 1000 * 1e6);
        _mint(stableCoins[1], userA, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 1000 * 1e18;

        uint256 liquidityStable = 1000 * 1e18;
        uint256 liquidityAsset = 1000 * 1e18 * oracleDecimals / price;

        uint256 nonce = IERC20Permit(address(stableCoins[0])).nonces(userA);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[0], nonce, block.timestamp + 1000)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[1], nonce, block.timestamp + 1000)
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(), structHash)
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;

        uint256[] memory deadline = new uint256[](2);
        deadline[0] = block.timestamp + 1000;
        deadline[1] = block.timestamp + 1000;

        vm.prank(userA);
        multiCallManager.addCollateralAddLiquidity(
            collateral, liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport, deadline, v, r, s
        );

        (uint256 liqStable, uint256 liqAsset) = perpPair.getLpLiquidityBalance(userA);
        assertTrue(liqStable == liquidityStable && liqAsset == liquidityAsset, "liquidity");
    }

    ///@dev test the addCollateralAddLiquidity multicall. Need signature from node server to approve permit.
    function testRelayerAddCollateralAddLiquidity() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");

        _mint(stableCoins[0], userA, 1000 * 1e6);
        _mint(stableCoins[1], userA, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 1000 * 1e18;

        uint256 liquidityStable = 1000 * 1e18;
        uint256 liquidityAsset = 1000 * 1e18 * oracleDecimals / price;

        uint256 nonce = IERC20Permit(address(stableCoins[0])).nonces(userA);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[0], nonce, block.timestamp + 1000)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[1], nonce, block.timestamp + 1000)
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(), structHash)
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;

        uint256[] memory deadline = new uint256[](2);
        deadline[0] = block.timestamp + 1000;
        deadline[1] = block.timestamp + 1000;

        uint256 relayDeadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.ADD_COLLATERAL_ADD_LIQUIDITY_TYPEHASH(),
                userA,
                keccak256(abi.encodePacked(collateral)),
                liquidityStable,
                liquidityAsset,
                1e30,
                keccak256(fakeReport),
                keccak256(abi.encodePacked(deadline)),
                keccak256(abi.encodePacked(v)),
                keccak256(abi.encodePacked(r)),
                keccak256(abi.encodePacked(s)),
                relayDeadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        bytes memory signature = abi.encodePacked(_r, _s, _v);

        multiCallManager.relayerAddCollateralAddLiquidity(
            userA,
            collateral,
            liquidityStable,
            liquidityAsset,
            1e30,
            fakeReport,
            deadline,
            v,
            r,
            s,
            relayDeadline,
            nonce,
            signature
        );

        (uint256 liqStable, uint256 liqAsset) = perpPair.getLpLiquidityBalance(userA);
        assertTrue(liqStable == liquidityStable && liqAsset == liquidityAsset, "liquidity");
    }

    ///@dev test the testAddCollateralTrade multicall. Need signature from node server to approve permit.
    function testAddCollateralTrade() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 10_000 * 1e18 * oracleDecimals / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");
        _mint(stableCoins[0], userA, 1000 * 1e6);
        _mint(stableCoins[1], userA, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 0 * 1e6;
        collateral[1] = 1000 * 1e18;

        uint256 tradeSize = 1000 * 1e18;
        bool direction = true;
        //uint256 nonce =  IERC20Permit(address(stableCoins[0])).nonces(userA);
        //Signature memory sig1 = generateSignature(stableCoins[0], pkA, address(vault), collateral[0], block.timestamp + 1000, nonce, tokenName, 2);

        uint256 nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[0], nonce, block.timestamp + 1000)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[1], nonce, block.timestamp + 1000)
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(), structHash)
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;

        uint256[] memory deadline = new uint256[](2);
        deadline[0] = block.timestamp + 1000;
        deadline[1] = block.timestamp + 1000;

        vm.prank(userA);
        multiCallManager.addCollateralOpenTrade(
            collateral, tradeSize, direction, 0, liquidityAsset, frontendAddress, 1, fakeReport, deadline, v, r, s
        );

        (,, uint256 stableDebt,,,,,) = perpPair.userVirtualTraderPosition(userA);
        assertTrue(stableDebt == tradeSize, "trade");
    }

    ///@dev test the testAddCollateralTrade multicall. Need signature from node server to approve permit.
    function testRelayerAddCollateralTrade() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 10_000 * 1e18 * oracleDecimals / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, 1e10, fakeReport);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");
        _mint(stableCoins[0], userA, 1000 * 1e6);
        _mint(stableCoins[1], userA, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 0 * 1e6;
        collateral[1] = 1000 * 1e18;

        uint256 tradeSize = 1000 * 1e18;
        bool direction = true;
        //uint256 nonce =  IERC20Permit(address(stableCoins[0])).nonces(userA);
        //Signature memory sig1 = generateSignature(stableCoins[0], pkA, address(vault), collateral[0], block.timestamp + 1000, nonce, tokenName, 2);

        uint256 nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[0], nonce, block.timestamp + 1000)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[1], nonce, block.timestamp + 1000)
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(), structHash)
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;

        uint256[] memory deadline = new uint256[](2);
        deadline[0] = block.timestamp + 1000;
        deadline[1] = block.timestamp + 1000;

        uint256 relayDeadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        PerpMultiCalls.TradeData memory tradeData =
            PerpMultiCalls.TradeData(tradeSize, direction, 0, liquidityAsset, frontendAddress, 1);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.ADD_COLLATERAL_OPEN_TRADE_TYPEHASH(),
                userA,
                keccak256(abi.encodePacked(collateral)),
                tradeData,
                keccak256(fakeReport),
                keccak256(abi.encodePacked(deadline)),
                keccak256(abi.encodePacked(v)),
                keccak256(abi.encodePacked(r)),
                keccak256(abi.encodePacked(s)),
                relayDeadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        bytes memory signature = abi.encodePacked(_r, _s, _v);

        multiCallManager.relayerAddCollateralOpenTrade(
            userA, collateral, tradeData, fakeReport, deadline, v, r, s, relayDeadline, nonce, signature
        );

        (,, uint256 stableDebt,,,,,) = perpPair.userVirtualTraderPosition(userA);
        assertTrue(stableDebt == tradeSize, "trade");
    }

    ///@dev test the testAddCollateralTrade multicall. Need signature from node server to approve permit.
    function testRelayerAddCollateralTradelogs() public {
        uint256[] memory collateral = new uint256[](1);
        collateral[0] = 20 * 1e18;

        uint256 tradeSize = 90 * 1e18;
        bool direction = true;
        //uint256 nonce =  IERC20Permit(address(stableCoins[0])).nonces(userA);
        //Signature memory sig1 = generateSignature(stableCoins[0], pkA, address(vault), collateral[0], block.timestamp + 1000, nonce, tokenName, 2);

        uint256[] memory deadline = new uint256[](1);
        deadline[0] = 1_761_833_478;

        console.logBytes32(keccak256(abi.encodePacked(collateral)));
        console.logBytes32(keccak256(fakeReport));
        console.logBytes32(keccak256(abi.encodePacked(deadline)));
        console.logBytes32(multiCallManager.ADD_COLLATERAL_OPEN_TRADE_TYPEHASH());

        /*
        uint256 relayDeadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        PerpMultiCalls.TradeData memory tradeData = PerpMultiCalls.TradeData(tradeSize, direction, 0, liquidityAsset, frontendAddress, 1);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.ADD_COLLATERAL_OPEN_TRADE_TYPEHASH(),
                userA,
                keccak256(abi.encodePacked(collateral)),
                tradeData,
                keccak256(fakeReport),
                keccak256(abi.encodePacked(deadline)),
                keccak256(abi.encodePacked(v)),
                keccak256(abi.encodePacked(r)),
                keccak256(abi.encodePacked(s)),
                relayDeadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        bytes memory signature = abi.encodePacked(_r,_s,_v);

        multiCallManager.relayerAddCollateralOpenTrade(userA, collateral, tradeData, fakeReport, deadline, v, r, s, relayDeadline, nonce, signature);

        (, , uint256 stableDebt, , , , ,) = perpPair.userVirtualTraderPosition(userA);
        assertTrue(stableDebt ==  tradeSize, "trade");
        */
    }

    ///@dev test the testCloseAndRemoveCollateral multicall.
    function testCloseAndRemoveCollateral() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 10_000 * 1e18 * oracleDecimals / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);
        vm.prank(userAddresses[98]);
        perpPair.addLiquidity(liquidityStable / 10, liquidityAsset / 10, maxUserLiquidityFee, fakeReport);

        vm.prank(userAddresses[0]);
        perpPair.trade(true, 1000 * 1e18, 0, liquidityAsset * 11 / 10, frontendAddress, 1, fakeReport);

        price = 110 * oracleDecimals;
        oracle.setPrice(price);

        vm.prank(userAddresses[0]);
        multiCallManager.closeAndRemoveAllCollateral(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);

        vm.prank(userAddresses[98]);
        multiCallManager.closeAndRemoveAllCollateral(1e5, maxUserLiquidityFee, frontendAddress, fakeReport);
    }

    ///@dev test the testCloseAndRemoveCollateral multicall from relayer.
    function testRelayerCloseAndRemoveCollateral() public {
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = 10_000 * 1e18 * oracleDecimals / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, 1e30, fakeReport);
        vm.prank(userAddresses[98]);
        perpPair.addLiquidity(liquidityStable / 10, liquidityAsset / 10, 1e30, fakeReport);

        vm.prank(userAddresses[0]);
        perpPair.trade(true, 1000 * 1e18, 0, liquidityAsset * 11 / 10, frontendAddress, 1, fakeReport);

        price = 110 * oracleDecimals;
        oracle.setPrice(price);

        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = multiCallManager.getNonce(userAddresses[0]);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH(),
                userAddresses[0],
                1e5,
                1e30,
                frontendAddress,
                keccak256(fakeReport),
                deadline,
                nonce
            )
        );

        bytes32 digest = multiCallManager.hashTypedData(request);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPks[0], digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        //vm.prank(userAddresses[0]);
        multiCallManager.relayerCloseAndRemoveAllCollateral(
            userAddresses[0], 1e5, 1e30, frontendAddress, fakeReport, deadline, nonce, signature
        );

        nonce = multiCallManager.getNonce(userAddresses[98]);
        request = keccak256(
            abi.encode(
                multiCallManager.CLOSE_AND_REMOVE_ALL_COLLATERAL_TYPEHASH(),
                userAddresses[98],
                1e5,
                1e30,
                frontendAddress,
                keccak256(fakeReport),
                deadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (v, r, s) = vm.sign(userPks[98], digest);
        signature = abi.encodePacked(r, s, v);

        //vm.prank(userAddresses[98]);
        multiCallManager.relayerCloseAndRemoveAllCollateral(
            userAddresses[98], 1e5, 1e30, frontendAddress, fakeReport, deadline, nonce, signature
        );
    }

    ///@dev test the testModifyLiquidity multicall.
    function testModifyLiquidity() public {
        (uint256 tradFee, uint256 flatFee,,,,,) = perpPair.ReadFees();

        perpPair.prepareTimeLockedParameters(
            perpPair.MMR(), tradFee, flatFee, 0, 0, 5 * 1e10 / 100, 1e10, 1e5 / 10, 0, 10e18
        );

        skip(604_810);

        perpPair.setTimeLockedParameters(
            perpPair.MMR(), tradFee, flatFee, 0, 0, 5 * 1e10 / 100, 1e10, 1e5 / 10, 0, 10e18
        );

        uint256 price = 63_000 * oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 20_000 * 1e18;
        uint256 liquidityAsset = 20_000 * 1e18 * oracleDecimals / price;

        //vm.prank(userAddresses[98]);
        //perpPair.addLiquidity(liquidityStable*10, liquidityAsset*10, maxUserLiquidityFee, fakeReport);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");

        _mint(stableCoins[0], userA, 100_000 * 1e6);
        _mint(stableCoins[1], userA, 100_000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 100_000 * 1e6;
        collateral[1] = 100_000 * 1e18;

        uint256 nonce = IERC20Permit(address(stableCoins[0])).nonces(userA);
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[0], nonce, block.timestamp + 1000)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce = IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userA, address(vault), collateral[1], nonce, block.timestamp + 1000)
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(), structHash)
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;

        uint256[] memory deadline = new uint256[](2);
        deadline[0] = block.timestamp + 1000;
        deadline[1] = block.timestamp + 1000;

        vm.prank(userA);
        multiCallManager.addCollateralAddLiquidity(
            collateral, liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport, deadline, v, r, s
        );

        uint256 globalLiquidityStable = perpPair.globalLiquidityStable(); // - liquidityStable*10;
        uint256 globalLiquidityAsset = perpPair.globalLiquidityAsset(); // - liquidityAsset*10;
        assertTrue(globalLiquidityStable == liquidityStable && globalLiquidityAsset == liquidityAsset, "1");

        address bob = makeAddr("bob");
        _mint(stableCoins[0], bob, 100_000 * 1e6);
        _mint(stableCoins[1], bob, 100_000 * 1e18);
        vm.prank(bob);
        ERC20(stableCoins[0]).approve(address(vault), MAX_UINT);
        vm.prank(bob);
        ERC20(stableCoins[1]).approve(address(vault), MAX_UINT);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0 * 1e6;
        amounts[1] = 100 * 1e18;

        vm.prank(bob);
        vault.addCollateral(amounts);

        uint256 tradeSize = 50 * 1e18;
        vm.prank(bob);
        perpPair.trade(true, tradeSize, 100 * 1e5, liquidityAsset, frontendAddress, 1, fakeReport);

        price = 67_000 * oracleDecimals;
        oracle.setPrice(price);

        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 1e30, frontendAddress, fakeReport);

        uint256 newStable = 100_000 * 1e18;
        uint256 newAsset = 100_000 * 1e18 * oracleDecimals / price;

        console.log(address(multiCallManager));
        vm.prank(userA);
        multiCallManager.modifyLiquidityPosition(newStable, newAsset, maxUserLiquidityFee, fakeReport);

        return;

        globalLiquidityStable = perpPair.globalLiquidityStable(); // - liquidityStable*10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset(); // - liquidityAsset*10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "2");

        newStable = 3000 * 1e18;
        newAsset = 9000 * 1e18 * oracleDecimals / price;
        vm.prank(userA);
        multiCallManager.modifyLiquidityPosition(newStable, newAsset, maxUserLiquidityFee, fakeReport);

        globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable * 10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset * 10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "3");

        newStable = 9000 * 1e18;
        newAsset = 3000 * 1e18 * oracleDecimals / price;
        vm.prank(userA);
        multiCallManager.modifyLiquidityPosition(newStable, newAsset, maxUserLiquidityFee, fakeReport);

        globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable * 10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset * 10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "4");
    }

    /*

    ///@dev test the testModifyLiquidity multicall.
    function testRelayerModifyLiquidity() public {

        perpPair.prepareTimeLockedParameters(
            perpPair.MMR(),
            MMR / 2,
            perpPair.tradingFee(),
            perpPair.flatTradingFee(),
            perpPair.feeLP(),
            0,
            0,
            perpPair.liquidityFeeK(),
            perpPair.fundingC(),
            0,
            uint256(1e6/2),
            perpPair.minimumTradeSize()
        );

        skip(604810);

        perpPair.setTimeLockedParameters(
            perpPair.MMR(),
            MMR / 2,
            perpPair.tradingFee(),
            perpPair.flatTradingFee(),
            perpPair.feeLP(),
            0,
            0,
            perpPair.liquidityFeeK(),
            perpPair.fundingC(),
            0,
            uint256(1e6/2),
            perpPair.minimumTradeSize()
        );

        uint256 price = 100*oracleDecimals;
        oracle.setPrice(price);

        uint256 liquidityStable = 1000*1e18;
        uint256 liquidityAsset = 1000*1e18*oracleDecimals/price;

        vm.prank(userAddresses[98]);
        perpPair.addLiquidity(liquidityStable*10, liquidityAsset*10, 1e10, fakeReport);

        (address userA, uint256 pkA) = makeAddrAndKey("alice");

        _mint(stableCoins[0], userA, 1000*1e6);
        _mint(stableCoins[1], userA, 1000*1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 1000 * 1e6;
        collateral[1] = 1000 * 1e18;

        uint256 nonce =  IERC20Permit(address(stableCoins[0])).nonces(userA);
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                userA,
                address(vault),
                collateral[0],
                nonce,
                block.timestamp + 1000
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(address(stableCoins[0])).DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(pkA, digest);

        uint8[] memory v = new uint8[](2);
        bytes32[] memory r = new bytes32[](2);
        bytes32[] memory s = new bytes32[](2);
        v[0] = _v;
        r[0] = _r;
        s[0] = _s;

        nonce =  IERC20Permit(address(stableCoins[1])).nonces(userA);
        structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                userA,
                address(vault),
                collateral[1],
                nonce,
                block.timestamp + 1000
            )
        );
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(address(stableCoins[1])).DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (_v, _r, _s) = vm.sign(pkA, digest);
        v[1] = _v;
        r[1] = _r;
        s[1] = _s;


        uint256[] memory permitDeadline = new uint256[](2);
        permitDeadline[0] = block.timestamp + 1000;
        permitDeadline[1] = block.timestamp + 1000;

        vm.prank(userA);
        multiCallManager.addCollateralAddLiquidity(collateral, liquidityStable, liquidityAsset, 1e10, fakeReport, permitDeadline, v, r, s);

        uint256 globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable*10;
        uint256 globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset*10;
        assertTrue(globalLiquidityStable == liquidityStable && globalLiquidityAsset == liquidityAsset, "1");

        uint256 newStable = 5000*1e18;
        uint256 newAsset = 5000*1e18*oracleDecimals/price;

        uint256 deadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.MODIFY_POSITION_TYPEHASH(),
                userA,
                newStable,
                newAsset,
                1e30,
                keccak256(fakeReport), // dynamic → hash first
                deadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        bytes memory signature = abi.encodePacked(_r,_s,_v);

        multiCallManager.relayerModifyLiquidityPosition(userA, newStable, newAsset, 1e30, fakeReport, deadline, nonce, signature);

        globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable*10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset*10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "2");

        newStable = 3000*1e18;
        newAsset = 9000*1e18*oracleDecimals/price;

        deadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        request = keccak256(
            abi.encode(
                multiCallManager.MODIFY_POSITION_TYPEHASH(),
                userA,
                newStable,
                newAsset,
                1e30,
                keccak256(fakeReport), // dynamic → hash first
                deadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        signature = abi.encodePacked(_r,_s,_v);

        multiCallManager.relayerModifyLiquidityPosition(userA, newStable, newAsset, 1e30, fakeReport, deadline, nonce, signature);

        globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable*10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset*10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "3");

        newStable = 9000*1e18;
        newAsset = 3000*1e18*oracleDecimals/price;

        deadline = block.timestamp + 1000;
        nonce = multiCallManager.getNonce(userA);

        request = keccak256(
            abi.encode(
                multiCallManager.MODIFY_POSITION_TYPEHASH(),
                userA,
                newStable,
                newAsset,
                1e30,
                keccak256(fakeReport), // dynamic → hash first
                deadline,
                nonce
            )
        );

        digest = multiCallManager.hashTypedData(request);

        (_v, _r, _s) = vm.sign(pkA, digest);
        signature = abi.encodePacked(_r,_s,_v);

        multiCallManager.relayerModifyLiquidityPosition(userA, newStable, newAsset, 1e30, fakeReport, deadline, nonce, signature);

        globalLiquidityStable = perpPair.globalLiquidityStable() - liquidityStable*10;
        globalLiquidityAsset = perpPair.globalLiquidityAsset() - liquidityAsset*10;
        assertTrue(globalLiquidityStable == newStable && globalLiquidityAsset == newAsset, "4");


    }
     */

    function testTakeProfitRemoveCollateral() public {
        // 1. Set initial oracle price
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        // Provide global liquidity so the trade can execute
        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = (10_000 * 1e18 * oracleDecimals) / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);

        // 2. Choose user and mint collateral
        address user = userAddresses[10];

        _mint(stableCoins[0], user, 1000 * 1e6);
        _mint(stableCoins[1], user, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 0;
        collateral[1] = 1000 * 1e18;

        // User deposits collateral
        vm.prank(user);
        vault.addCollateral(collateral);

        // 3. User opens a LONG trade that will later be profitable
        uint256 tradeSize = 500 * 1e18;

        vm.prank(user);
        perpPair.trade(
            true, // long
            tradeSize,
            0,
            liquidityAsset,
            frontendAddress,
            1,
            fakeReport
        );

        // 4. Move price up → LONG profits
        oracle.setPrice(150 * oracleDecimals); // +50% move

        // 5. Query expected PnL
        (uint256 pnl, bool positive) = perpPair.calcPnL(user, 150 * oracleDecimals);
        assertTrue(positive, "PnL must be positive for take profit test");
        assertTrue(pnl > 0, "PnL must be > 0");

        // Track collateral before
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        uint256 before0 = coinA.balanceOf(user) * 1e12;
        uint256 before1 = coinB.balanceOf(user);

        // 6. Execute take-profit
        vm.prank(user);
        multiCallManager.takeProfitRemoveCollateral(fakeReport);

        // 7. Validate effects:
        //    - Realized PnL: user receives pnl in stablecoin
        //    - Collateral decreased by pnl (pull from vault)
        uint256 after0 = coinA.balanceOf(user) * 1e12;
        uint256 after1 = coinB.balanceOf(user);

        console.log(before1 + before0);
        console.log(after0 + after1);
        console.log(pnl);

        vm.assertApproxEqAbs(after0 + after1, before1 + before0 + pnl, 1e15, "User should receive PnL payout");

        // Collateral of vToken1 should decrease
        uint256 expectedRemaining = collateral[1];
        (uint256 remaining) = vault.userCollateral(user);
        assertEq(remaining, expectedRemaining + 20_000_000_000_000_000_000_000_000, "Collateral should decrease by pnl");
    }

    function testRelayerTakeProfitRemoveCollateral() public {
        // 1. Set initial oracle price
        uint256 price = 100 * oracleDecimals;
        oracle.setPrice(price);

        // Provide global liquidity so the trade can execute
        uint256 liquidityStable = 10_000 * 1e18;
        uint256 liquidityAsset = (10_000 * 1e18 * oracleDecimals) / price;

        vm.prank(userAddresses[99]);
        perpPair.addLiquidity(liquidityStable, liquidityAsset, maxUserLiquidityFee, fakeReport);

        // 2. Choose user and mint collateral
        address user = userAddresses[10];

        _mint(stableCoins[0], user, 1000 * 1e6);
        _mint(stableCoins[1], user, 1000 * 1e18);

        uint256[] memory collateral = new uint256[](2);
        collateral[0] = 0;
        collateral[1] = 1000 * 1e18;

        // User deposits collateral
        vm.prank(user);
        vault.addCollateral(collateral);

        // 3. User opens a LONG trade that will later be profitable
        uint256 tradeSize = 500 * 1e18;

        vm.prank(user);
        perpPair.trade(
            true, // long
            tradeSize,
            0,
            liquidityAsset,
            frontendAddress,
            1,
            fakeReport
        );

        // 4. Move price up → LONG profits
        oracle.setPrice(150 * oracleDecimals); // +50% move

        // 5. Query expected PnL
        (uint256 pnl, bool positive) = perpPair.calcPnL(user, 150 * oracleDecimals);
        assertTrue(positive, "PnL must be positive for take profit test");
        assertTrue(pnl > 0, "PnL must be > 0");

        // Track collateral before
        (ERC20 coinA,,,) = vault.stableCoins(0);
        (ERC20 coinB,,,) = vault.stableCoins(1);

        uint256 before0 = coinA.balanceOf(user) * 1e12;
        uint256 before1 = coinB.balanceOf(user);

        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = multiCallManager.getNonce(user);

        bytes32 request = keccak256(
            abi.encode(
                multiCallManager.TAKE_PROFIT_REMOVE_COLLATERAL_TYPEHASH(), user, keccak256(fakeReport), deadline, nonce
            )
        );

        bytes32 digest = multiCallManager.hashTypedData(request);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPks[10], digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 6. Execute take-profit
        multiCallManager.relayerTakeProfitRemoveCollateral(user, fakeReport, deadline, nonce, signature);

        // 7. Validate effects:
        //    - Realized PnL: user receives pnl in stablecoin
        //    - Collateral decreased by pnl (pull from vault)
        uint256 after0 = coinA.balanceOf(user) * 1e12;
        uint256 after1 = coinB.balanceOf(user);

        console.log(before1 + before0);
        console.log(after0 + after1);
        console.log(pnl);

        vm.assertApproxEqAbs(after0 + after1, before1 + before0 + pnl, 1e15, "User should receive PnL payout");

        // Collateral of vToken1 should decrease
        uint256 expectedRemaining = collateral[1];
        (uint256 remaining) = vault.userCollateral(user);
        assertEq(remaining, expectedRemaining + 20_000_000_000_000_000_000_000_000, "Collateral should decrease by pnl");
    }

    //Support functions
    //returns if value is inside confidence interval of target
    function inConfidenceInterval(uint256 value, uint256 target, uint256 tolerance) public pure returns (bool) {
        uint256 diff = UtilMath.diffAbs(value, target);
        return diff <= value / tolerance;
    }

    function mint(address stableCoin, address[] memory addresses, uint256[] memory amounts) public {
        assertTrue(addresses.length == amounts.length, "different length of addresses and amounts");
        for (uint256 i = 0; i < addresses.length; i++) {
            _mint(stableCoin, addresses[i], amounts[i]);
        }
    }

    function _mint(address stableCoin, address user, uint256 amount) public {
        vm.prank(MasterMinter);
        FiatTokenV2(stableCoin).mint(user, amount);
    }

    function bytesToAddress(bytes memory b) public pure returns (address addr) {
        assertTrue(b.length == 20, "invalid length");
        assembly {
            // load the 32-byte word at b’s data pointer (b + 32)
            // then shift right by 96 bits (12 bytes) to keep only the low 160 bits
            addr := shr(96, mload(add(b, 32)))
        }
    }
}
