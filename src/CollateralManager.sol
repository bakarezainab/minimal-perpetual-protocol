// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import "./interfaces/ICollateralManager.sol";

// Collect usdc and save the amounts of each deposit of the users
contract CollateralManager is Ownable, ICollateralManager {
    using SafeERC20 for IERC20;

    address collateral;
    mapping(address depositor => Deposit) private userDeposits;
    uint256 public totalDeposits;

    constructor(address _collateral) Ownable(msg.sender) {
        collateral = _collateral;
    }

    function getUserDeposit(address user) public view returns (address, uint256, uint256) {
        Deposit memory userDeposit = userDeposits[user];
        return (userDeposit.user, userDeposit.amount, userDeposit.lastUpdatedAt);
    }

    function updateUserDeposit(address user, uint256 amount, bool isIncreasing) public onlyOwner {
        Deposit storage userDeposit = userDeposits[user];
        if (isIncreasing) {
            totalDeposits += amount;
            userDeposit.amount += amount;
        } else {
            totalDeposits -= amount;
            userDeposit.amount -= amount;
            IERC20(collateral).transfer(msg.sender, amount);
        }
        userDeposit.lastUpdatedAt = block.timestamp;
        emit UpdatedUserDeposit(user, amount, block.timestamp);
    }

    function deposit(uint256 amount) public {
        require(amount > 0, "Deposit amount must be greater than zero");
        totalDeposits += amount; // This assumes we do not support free-on-transfer tokens.
        Deposit storage userDeposit = userDeposits[msg.sender];
        userDeposit.user = msg.sender;
        userDeposit.amount += amount;
        userDeposit.lastUpdatedAt = block.timestamp;
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositCreated(msg.sender, amount, block.timestamp);
    }

    function withdraw(uint256 amount) public {
        // @todo: This is wrongly implemented.
        //  Revisit this once we have position health check in place
        Deposit storage userDeposit = userDeposits[msg.sender];
        require(userDeposit.amount >= amount, "Insufficient deposit");
        totalDeposits -= amount;
        userDeposit.amount -= amount;
        userDeposit.lastUpdatedAt = block.timestamp;
        IERC20(collateral).safeTransfer(msg.sender, amount);
    }

    // The losses of the traders are the profits of the LPs.
    function withdrawLosses(address recipient, uint256 amount) public onlyOwner {
        IERC20(collateral).safeTransfer(recipient, amount);
    }
}
