// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {PositionType, Position} from "./interfaces/IPosition.sol";
import {LPManager} from "./LPManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {CollateralManager} from "./CollateralManager.sol";
import {PriceOracle, Feed} from "./PriceOracle.sol";

contract PositionManager is PriceOracle, Ownable {
    uint currentPositionId;
    mapping(uint => Position) public positions;
    mapping(address owner => uint[] positionIds) public userPosition;
    uint maximumLeverage = 5; // 5x
    LPManager public lpManager;
    CollateralManager public collateralManager;

    constructor(address owner, address asset) Ownable(owner) {
        lpManager = new LPManager(
            IERC20(asset),
            "LP DAI",
            "LPDAI",
            address(this)
        );
        collateralManager = new CollateralManager(asset);
    }

    function _setFeed(
        address daiUsd,
        address ethUsd
    ) internal override onlyOwner {
        super._setFeed(daiUsd, ethUsd);
    }

    function getPositionProfit(uint positionId) public view returns (uint) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return 0;
        }
        (int ethPrice, ) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int priceDelta = ethPrice - int(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            if (priceDelta < 0) {
                return 0;
            }
            uint profit = position.indexTokenSize * uint(priceDelta);
            return profit;
        }
        return 0;
    }

    function isClosable(uint positionId) public view returns (bool) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return false;
        }
        (int ethPrice, ) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int priceDelta = ethPrice - int(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            if (priceDelta < 0) {
                return false;
            }
            uint profit = position.indexTokenSize * uint(priceDelta);
            if (profit > (position.size * 90) / 100) {
                return true;
            }
            return false;
        }
        return false;
    }

    function isLiquidatable(
        uint positionId
    ) public view returns (bool, uint losses) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return (false, 0);
        }
        (int ethPrice, ) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int priceDelta = ethPrice - int(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            // should be positive if the trade is going in favour of the trader
            // Otherwise it is negative
            if (priceDelta > 0) {
                return (false, 0);
            }
            int loss = int(position.indexTokenSize) * priceDelta; // this will be negative
            (, uint positionCollateral, ) = collateralManager.getUserDeposit(
                position.owner
            );
            // there is a bug here
            if (loss >= int(positionCollateral)) {
                return (true, uint(loss));
            }
            // we know that `positionCollateral > loss`, so we can safely cast the result into a uint
            uint remainingCollateral = uint(int(positionCollateral) + loss);
            uint newLeverage = position.size / remainingCollateral;
            if (newLeverage > maximumLeverage) {
                return (true, uint(loss));
            }
        } else {
            // here the user is shorting

            // should be negative if the trade is going in favour of the trader
            // Otherwise it is positive
            if (priceDelta < 0) {
                return (false, 0);
            }
            // this will be positive
            uint loss = position.indexTokenSize * uint(priceDelta);
            (, uint positionCollateral, ) = collateralManager.getUserDeposit(
                position.owner
            );
            if (loss >= positionCollateral) {
                return (true, loss);
            }
            // we know that `positionCollateral > loss`, so we can safely cast the result into a uint
            uint remainingCollateral = positionCollateral - loss;
            uint newLeverage = position.size / remainingCollateral;
            if (newLeverage > maximumLeverage) {
                return (true, loss);
            }
        }

        return (false, 0);
    }

    function openPosition(uint leverage, PositionType positionType) external {
        require(
            userPosition[msg.sender].length == 0,
            "User can't open more than one position"
        );
        require(
            leverage < maximumLeverage,
            "Can't leverage more than maximum leverage"
        );

        (, uint userCollateral, ) = collateralManager.getUserDeposit(
            msg.sender
        );
        (int ethPrice, uint precision) = getChainlinkDataFeedLatestAnswer(
            Feed.EthUsd
        );
        // precision is that of DAI ( 18 decimals )
        uint positionSize = userCollateral * leverage;

        Position memory newPosition = Position({
            size: positionSize,
            owner: msg.sender,
            indexTokenPrice: uint(ethPrice),
            indexTokenSize: (positionSize * precision) / uint(ethPrice),
            leverage: leverage,
            id: currentPositionId,
            openedAt: block.timestamp,
            positionType: positionType
        });
        positions[currentPositionId] = newPosition;
        userPosition[msg.sender].push(currentPositionId);
        currentPositionId++;
        lpManager.increaseLockedAmount(positionSize);
    }

    function closePosition(uint positionId) external {
        // verify said position is ripe for liquidation
        (bool liquidatable, uint losses) = isLiquidatable(positionId);
        if (isLiquidatable) {
            liquidate(positionId);
            return;
        }
        // pullling user collateral and covering his losses with
        uint profits = getPositionProfit(positionId);
        require(profits > 0, "This position has no profits");
        Position memory position = positions[positionId];
        bool success = windDownPosition(positionId);
        require(success, "Couldn't delete position");
    }

    function liquidate(uint positionId) external {
        // verify said position is ripe for liquidation
        (bool liquidatable, uint losses) = isLiquidatable(positionId);
        require(liquidatable, "Position isn't liquidatable");
        // pullling user collateral and covering his losses with
        Position memory position = positions[positionId];
        (, uint positionCollateral, ) = collateralManager.getUserDeposit(
            position.owner
        );
        collateralManager.updateUserDeposit(
            position.owner,
            losses /** + liquidationFee **/,
            false
        );
        collateralManager.withdrawLosses(
            address(lpManager),
            losses /** + liquidationFee **/
        );
        bool success = windDownPosition(positionId);
        require(success, "Couldn't delete position");
    }

    function windDownPosition(uint positionId) internal {
        delete positions[positionId];
    }
}
