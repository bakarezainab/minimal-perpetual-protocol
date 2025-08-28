// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

enum PositionType {
    LONG,
    SHORT
}

struct Position {
    uint size;
    address owner;
    uint id;
    uint openedAt;
    uint indexTokenPrice;
    uint indexTokenSize;
    uint leverage;
    PositionType positionType;
}
