// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BadDebtAssertion} from "../src/assertionBadDebt.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {IPerpPair} from "../src/IPerpPair.sol";

contract MockPerpPair is IPerpPair {

    uint256 pnl;
    bool sign;
    uint256 collateral;

    event ExecutedTrade(
        address indexed user,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        uint256 leverage
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

    function setPnL(uint256 _pnl, bool _sign) public {
        pnl = _pnl;
        sign = _sign;
    }

    function setCollateral(uint256 _collateral) public {
        collateral = _collateral;
    }

    function calcPnL(address user, uint256 price) public view returns (uint256, bool){
        return (pnl, sign);
    }
    function getCollateral(address user) public view returns(uint256){
        return collateral;
    }
    function trade(bool direction, uint256 size, uint256 minTradeReturn, uint256 initialGuess, address frontendAddress, uint8 leverage, bytes memory unverifiedReport) external returns (uint256) {
        emit ExecutedTrade(msg.sender, direction, size, minTradeReturn, minTradeReturn, leverage);
    }
    function addLiquidity(uint256 liquidityStable, uint256 liquidityAsset, uint256 maxFeeValue, bytes memory unverifiedReport) public {

    }
    function closeAndWithdraw(uint256 maxSlippage, uint256 maxLiqFee, address frontendAddress, bytes memory unverifiedReport) public {

    }
    function enableAutoClose(uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) public {
        
    }
    function getPrice() external view returns (uint256){

    }
    function liquidate(address user, uint256 liquidatedPositionSize, bytes memory unverifiedReport) external {
        emit LiquidatedUser(user, msg.sender, 1, liquidatedPositionSize, liquidatedPositionSize, 1, 1, true);
    }
    function realizePnL(bytes calldata unverifiedReport) external{

    }
    function removeLiquidity(uint256 liquidityStableToRemove, uint256 liquidityAssetToRemove, uint256 maxFeeValue, bytes memory unverifiedReport) public {

    }
}

contract TestOwnableAssertion is CredibleTest, Test {
    MockPerpPair public perpPair;
    bytes public fakeReport;

    // Set up the test environment
    function setUp() public {
        perpPair = new MockPerpPair();
    }

    
    function test_assertionNoBadDebtTrade(uint256 collateral, uint256 pnl, bool sign) public {
        vm.assume(collateral > 0);
        pnl = bound(pnl, 0, collateral);
        
        address bob = makeAddr("bob");

        perpPair.setCollateral(collateral);
        perpPair.setPnL(pnl, sign);

        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.trade(true, 1000*1e18, 100 * 1e5, 0, address(0), 1, fakeReport);
    }

    
    function test_assertionNoBadDebtClose(uint256 collateral, bool sign) public {
        vm.assume(collateral > 0);

        address bob = makeAddr("bob");

        perpPair.setCollateral(collateral);
        perpPair.setPnL(0, sign);
        
        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.closeAndWithdraw(1e5, 0, address(0), fakeReport);
    
    }


    function test_assertionNoBadDebtLiquidityMove(uint256 collateral, uint256 pnl, bool sign) public {
        vm.assume(collateral > 0);

        address bob = makeAddr("bob");
        uint256 bobLiquidityStable = 1_000 * 1e18;
        uint256 bobLiquidityAsset = 10 * 1e18;

        pnl = bound(pnl, 0, collateral);

        perpPair.setCollateral(collateral);
        perpPair.setPnL(pnl, sign);

        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.addLiquidity(bobLiquidityStable, bobLiquidityAsset, 0, fakeReport);
        

        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.removeLiquidity(bobLiquidityStable, bobLiquidityAsset, 0, fakeReport);
    }

    function test_assertionNoBadDebtTradeFailing(uint256 collateral, uint256 pnl) public {
        vm.assume(collateral > 0);
        vm.assume(collateral < pnl);
        
        address bob = makeAddr("bob");

        perpPair.setCollateral(collateral);
        perpPair.setPnL(pnl, false);

        vm.expectRevert();
        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.trade(true, 1000*1e18, 100 * 1e5, 0, address(0), 1, fakeReport);
    }


    function test_assertionNoBadDebtLiquidationFailing(uint256 collateral, uint256 pnl) public {
        vm.assume(collateral > 0);
        vm.assume(collateral < pnl);
        
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        perpPair.setCollateral(collateral);
        perpPair.setPnL(pnl, false);

        vm.expectRevert();
        cl.assertion({
            adopter: address(perpPair),
            createData: type(BadDebtAssertion).creationCode,
            fnSelector: BadDebtAssertion.assertionBadDebt.selector
        });
        vm.prank(bob);
        perpPair.liquidate(alice, 1, fakeReport);
    }


}