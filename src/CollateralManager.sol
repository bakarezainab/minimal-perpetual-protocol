// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

struct Deposit {
    address user;
    uint amount;
    uint lastUpdatedAt;
}

// Collect usdc and save the amounts of each deposit of the users
contract CollateralManager is Ownable {
    address collateral;
    mapping(address depositor => Deposit) private userDeposits;
    uint public totalDeposits;

    event DepositCreated(address indexed user, uint amount, uint depositedAt);
    event UpdatedUserDeposit(address indexed user, uint amount, uint updatedAt);

    constructor(address _collateral) Ownable(msg.sender) {
        collateral = _collateral;
    }

    function getUserDeposit(
        address user
    ) public view returns (address, uint, uint) {
        Deposit memory userDeposit = userDeposits[user];
        return (
            userDeposit.user,
            userDeposit.amount,
            userDeposit.lastUpdatedAt
        );
    }

    function updateUserDeposit(
        address user,
        uint amount,
        bool isIncreasing
    ) public onlyOwner {
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

    function deposit(uint amount) public {
        require(amount > 0, "Deposit amount must be greater than zero");
        totalDeposits += amount; // This assumes we do not support free-on-transfer tokens.
        Deposit storage userDeposit = userDeposits[msg.sender];
        userDeposit.amount += amount;
        userDeposit.lastUpdatedAt = block.timestamp;
        IERC20(collateral).transferFrom(msg.sender, address(this), amount);
        emit DepositCreated(msg.sender, amount, block.timestamp);
    }

    function withdraw(uint amount) public {
        // @todo: This is wrongly implemented.
        //  Revisit this once we have position health check in place
        Deposit storage userDeposit = userDeposits[msg.sender];
        require(userDeposit.amount >= amount, "Insufficient deposit");
        totalDeposits -= amount;
        userDeposit.amount -= amount;
        userDeposit.lastUpdatedAt = block.timestamp;
        IERC20(collateral).transfer(msg.sender, amount);
    }

    // The losses of the traders are the profits of the LPs.
    function withdrawLosses(address recipient, uint amount) public onlyOwner {
        bool success = IERC20(collateral).transfer(recipient, amount);
        require(success, "transfer failed");
    }
}
