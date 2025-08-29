// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {PositionType, Position} from "./interfaces/IPosition.sol";
import {LPManager} from "./LPManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {CollateralManager} from "./CollateralManager.sol";
import {PriceOracle, Feed} from "./PriceOracle.sol";

contract PositionManager is PriceOracle, Ownable {
    uint256 currentPositionId;
    mapping(uint256 => Position) public positions;
    mapping(address owner => uint256[] positionIds) public userPosition;
    uint256 maximumLeverage = 5; // 5x
    LPManager public lpManager;
    CollateralManager public collateralManager;

    constructor(address owner, address asset) Ownable(owner) {
        lpManager = new LPManager(IERC20(asset), "LP DAI", "LPDAI", address(this));
        collateralManager = new CollateralManager(asset);
    }

    function _setFeed(address daiUsd, address ethUsd) internal override onlyOwner {
        super._setFeed(daiUsd, ethUsd);
    }

    function getPositionProfit(uint256 positionId) public view returns (uint256) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return 0;
        }
        (int256 ethPrice,) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int256 priceDelta = ethPrice - int256(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            if (priceDelta < 0) {
                return 0;
            }
            uint256 profit = position.indexTokenSize * uint256(priceDelta);
            return profit;
        }
        return 0;
    }

    function isClosable(uint256 positionId) public view returns (bool) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return false;
        }
        (int256 ethPrice,) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int256 priceDelta = ethPrice - int256(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            if (priceDelta < 0) {
                return false;
            }
            uint256 profit = position.indexTokenSize * uint256(priceDelta);
            if (profit > (position.size * 90) / 100) {
                return true;
            }
            return false;
        }
        return false;
    }

    function isLiquidatable(uint256 positionId) public view returns (bool, uint256 losses) {
        Position memory position = positions[positionId];
        if (position.openedAt == 0) {
            return (false, 0);
        }
        (int256 ethPrice,) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int256 priceDelta = ethPrice - int256(position.indexTokenPrice);
        if (position.positionType == PositionType.LONG) {
            // should be positive if the trade is going in favour of the trader
            // Otherwise it is negative
            if (priceDelta > 0) {
                return (false, 0);
            }
            int256 loss = int256(position.indexTokenSize) * priceDelta; // this will be negative
            (, uint256 positionCollateral,) = collateralManager.getUserDeposit(position.owner);
            // there is a bug here
            if (loss >= int256(positionCollateral)) {
                return (true, uint256(loss));
            }
            // we know that `positionCollateral > loss`, so we can safely cast the result into a uint
            uint256 remainingCollateral = uint256(int256(positionCollateral) + loss);
            uint256 newLeverage = position.size / remainingCollateral;
            if (newLeverage > maximumLeverage) {
                return (true, uint256(loss));
            }
        } else {
            // here the user is shorting

            // should be negative if the trade is going in favour of the trader
            // Otherwise it is positive
            if (priceDelta < 0) {
                return (false, 0);
            }
            // this will be positive
            uint256 loss = position.indexTokenSize * uint256(priceDelta);
            (, uint256 positionCollateral,) = collateralManager.getUserDeposit(position.owner);
            if (loss >= positionCollateral) {
                return (true, loss);
            }
            // we know that `positionCollateral > loss`, so we can safely cast the result into a uint
            uint256 remainingCollateral = positionCollateral - loss;
            uint256 newLeverage = position.size / remainingCollateral;
            if (newLeverage > maximumLeverage) {
                return (true, loss);
            }
        }

        return (false, 0);
    }

    function openPosition(uint256 leverage, PositionType positionType) external {
        require(userPosition[msg.sender].length == 0, "User can't open more than one position");
        require(leverage < maximumLeverage, "Can't leverage more than maximum leverage");

        (, uint256 userCollateral,) = collateralManager.getUserDeposit(msg.sender);
        (int256 ethPrice, uint256 precision) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        // precision is that of DAI ( 18 decimals )
        uint256 positionSize = userCollateral * leverage;

        Position memory newPosition = Position({
            size: positionSize,
            owner: msg.sender,
            indexTokenPrice: uint256(ethPrice),
            indexTokenSize: (positionSize * precision) / uint256(ethPrice),
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

    function closePosition(uint256 positionId) external {
        // verify said position is ripe for liquidation
        (bool liquidatable, uint256 losses) = isLiquidatable(positionId);
        if (liquidatable) {
            liquidate(positionId);
            return;
        }
        // pullling user collateral and covering his losses with
        uint256 profits = getPositionProfit(positionId);
        require(profits > 0, "This position has no profits");
        Position memory position = positions[positionId];
        windDownPosition(positionId);
        // require(success, "Couldn't delete position");
    }

    function liquidate(uint256 positionId) public {
        // verify said position is ripe for liquidation
        (bool liquidatable, uint256 losses) = isLiquidatable(positionId);
        require(liquidatable, "Position isn't liquidatable");
        // pullling user collateral and covering his losses with
        Position memory position = positions[positionId];
        (, uint256 positionCollateral,) = collateralManager.getUserDeposit(position.owner);
        collateralManager.updateUserDeposit(
            position.owner,
            losses,
            /**
             * + liquidationFee *
             */
            false
        );
        collateralManager.withdrawLosses(address(lpManager), losses);
        /**
         * + liquidationFee *
         */
        windDownPosition(positionId);
        // require(success, "Couldn't delete position");
    }

    function windDownPosition(uint256 positionId) internal {
        delete positions[positionId];
    }
}
