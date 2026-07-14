// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../storage/PerpStorage.sol";
import "./perpTrade.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpAutoClose is PerpTrade {
    using Math for uint256;
    using SignedMath for int256;

    event ToggledAutoClose(
        address indexed user, uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee
    );

    ///@notice Function to enable third party users to close your position. Can also be used to change thresholds if the user has this already enabled.
    ///@param profitTh Profit threshold over which the user's position will be closable
    ///@param lossTh Loss threshold under which the user's position will be closable
    ///@param maxSlippage Maximum slippage tolerated by the user when autoclosing the position
    ///@param maxLiqFee Maximum liquidity fee tolerated by the user when autoclosing the position
    function enableAutoClose(uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) external {
        require(profitTh > 0 || lossTh > 0, "A");
        address user = _msgSender();
        autoCloseUsersData[user].authorized = true;
        autoCloseUsersData[user].profitTh = profitTh;
        autoCloseUsersData[user].lossTh = lossTh;
        autoCloseUsersData[user].maxSlippage = maxSlippage;
        autoCloseUsersData[user].maxLiqFee = maxLiqFee;
        emit ToggledAutoClose(user, profitTh, lossTh, maxSlippage, maxLiqFee);
    }

    ///@notice Function to disable third party users to close your position.
    function disableAutoClose() external {
        _disableAutoClose(_msgSender(), 0);
    }

    ///@notice Clear a user's auto-close config, emitting ToggledAutoClose when it was set.
    ///@param mode 0 = user disable / normal close, 1 = third-party auto-close.
    function _disableAutoClose(address user, uint256 mode) internal override {
        if (autoCloseUsersData[user].authorized) {
            emit ToggledAutoClose(user, 0, 0, mode, mode);
        }
        delete autoCloseUsersData[user];
    }

    ///@notice Function to close the position of another user. They must have enabled the autoTrade feature and established the thresholds.
    ///@param user user which position is to be closed.
    ///@param frontendAddress address that will receive the frontend part of the fees.
    ///@param unverifiedReport Chainlink price report.
    function autoCloseUserPosition(
        address user,
        address frontendAddress,
        bytes memory unverifiedReport
    )
        external
        nonReentrant
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        require(autoCloseUsersData[user].authorized, "A1");
        (uint256 userPnL, bool userPnLSign) = calcPnL(user, getPrice());
        if (userPnLSign) {
            require(autoCloseUsersData[user].profitTh != 0 && userPnL >= autoCloseUsersData[user].profitTh, "A1");
        } else {
            require(
                autoCloseUsersData[user].lossTh != 0 && userPnL >= autoCloseUsersData[user].lossTh
                    && userPnL <= getCollateral(user),
                "A1"
            );
        }
        userVirtualTraderPosition[user].debtStable += autoCloseFee;
        userVirtualTraderPosition[_msgSender()].balanceStable += autoCloseFee;
        uint256 acMaxSlippage = autoCloseUsersData[user].maxSlippage;
        uint256 acMaxLiqFee = autoCloseUsersData[user].maxLiqFee;
        // Log ToggledAutoClose(mode 1 = third-party auto-close) and clear BEFORE the shared close
        // body: its own clear (mode 0) runs first otherwise and suppresses this mode-1 log.
        _disableAutoClose(user, 1);
        _closeAndWithdraw(acMaxSlippage, acMaxLiqFee, frontendAddress, user, true);
    }
}
