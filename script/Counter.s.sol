// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {CollateralManager} from "../src/CollateralManager.sol";

contract CounterScript is Script {
    CollateralManager public collateralManager;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        collateralManager = new CollateralManager();

        vm.stopBroadcast();
    }
}
