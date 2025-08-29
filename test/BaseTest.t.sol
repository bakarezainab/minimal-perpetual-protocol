// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std-1.10.0/src/Test.sol";
import "src/PositionManager.sol";
import "src/interfaces/ICollateralManager.sol";
import "./mocks/MockDAI.sol";

contract BaseTest is Test {
    address public OWNER = makeAddr("OWNER");
    address public ALICE = makeAddr("ALICE");
    address public BOB = makeAddr("BOB");
    address public JANE = makeAddr("JANE");

    uint256 public constant DEAL_AMOUNT = type(uint80).max;

    PositionManager posManager;
    ICollateralManager collateralManager;
    MockDAI MDAI;

    function setUp() public {
        MDAI = new MockDAI();
        posManager = new PositionManager(OWNER, address(MDAI));

        collateralManager = ICollateralManager(posManager.collateralManager());

        MDAI.mint(ALICE, DEAL_AMOUNT);
        MDAI.mint(BOB, DEAL_AMOUNT);
        MDAI.mint(JANE, DEAL_AMOUNT);
    }
}
