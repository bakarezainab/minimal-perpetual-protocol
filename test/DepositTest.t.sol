// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./BaseTest.t.sol";
import "src/PositionManager.sol";
import "./mocks/MockDAI.sol";

contract DepositTest is BaseTest {
    function test_userDeposit() public {
        uint256 totalDepositsBefore = collateralManager.totalDeposits();
        (, uint256 userDepositAmountBefore,) = collateralManager.getUserDeposit(ALICE);
        vm.startPrank(ALICE);

        uint256 depositAmount = 10 ether;
        MDAI.approve(address(collateralManager), type(uint256).max);
        collateralManager.deposit(depositAmount);
        vm.stopPrank();

        assert(collateralManager.totalDeposits() - totalDepositsBefore == depositAmount);
        (, uint256 userDepositAmountAfter, uint256 lastUpdatedAt) = collateralManager.getUserDeposit(ALICE);
        assert(userDepositAmountAfter - userDepositAmountBefore == depositAmount);
        assert(lastUpdatedAt == block.timestamp);
    }
}
