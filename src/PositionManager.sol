// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {LPManagerEpoch} from "./LPManagerEpoch.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {CollateralManager} from "./CollateralManager.sol";
import {PriceOracle, Feed} from "./PriceOracle.sol";

contract PositionManager is PriceOracle, Ownable, IPositionManager {
    using SafeERC20 for IERC20;

    uint256 currentPositionId;
    mapping(uint256 => Position) public positions;
    mapping(address owner => uint256[] positionIds) public userPosition;
    uint256 maximumLeverage = 5; // 5x
    uint256 liquidationFeeBps = 5_000;
    uint256 constant BPS_DENOM = 100_000;
    LPManagerEpoch public lpManager;
    CollateralManager public collateralManager;

    constructor(address owner, address asset) Ownable(owner) {
        lpManager = new LPManagerEpoch((asset));
        collateralManager = new CollateralManager(asset, address(this));
    }

    function _setFeed(address daiUsd, address ethUsd) internal override onlyOwner {
        super._setFeed(daiUsd, ethUsd);
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
            uint256 absLoss = uint256(-loss);
            if (absLoss >= positionCollateral) {
                return (true, absLoss);
            }
            // we know that `positionCollateral > loss`, so we can safely cast the result into a uint
            uint256 remainingCollateral = uint256(int256(positionCollateral) + loss);
            uint256 newLeverage = position.size / remainingCollateral;
            if (newLeverage > maximumLeverage) {
                return (true, absLoss);
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
        require(leverage <= maximumLeverage, "Can't leverage more than maximum leverage");

        (, uint256 userCollateral,) = collateralManager.getUserDeposit(msg.sender);
        (int256 ethPrice, uint256 precision) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        // precision is that of DAI ( 18 decimals )
        uint256 positionSize = userCollateral * leverage;

        uint256 positionLayerId = lpManager.createTradeLayer(positionSize);
        lpManager.activateTradeLayer(positionLayerId);
        Position memory newPosition = Position({
            size: positionSize,
            owner: msg.sender,
            indexTokenPrice: uint256(ethPrice),
            indexTokenSize: (positionSize * precision) / uint256(ethPrice),
            leverage: leverage,
            id: currentPositionId,
            openedAt: block.timestamp,
            positionType: positionType,
            layerId: positionLayerId
        });
        positions[currentPositionId] = newPosition;
        userPosition[msg.sender].push(currentPositionId);
        currentPositionId++;
    }

    function closePosition(uint256 positionId) external {
        Position memory position = positions[positionId];
        require(position.owner == msg.sender, "Not position owner");
        require(position.openedAt != 0, "Position doesn't exist");

        // Check if position should be liquidated instead
        (bool liquidatable,) = isLiquidatable(positionId);
        if (liquidatable) {
            liquidate(positionId);
            return;
        }

        // Calculate current P&L
        (int256 pnl, bool isProfitable) = getPositionPnL(positionId);

        if (isProfitable) {
            // Trader wins, which means LPs lose
            uint256 profit = uint256(pnl);

            uint256 balBefore = lpManager.liquidityToken().balanceOf(address(this));

            // The LP manager needs to pay this profit to the trader
            lpManager.closeTradeLayer(position.layerId, profit, false);
            uint256 balAfter = lpManager.liquidityToken().balanceOf(address(this));
            require(balAfter - balBefore >= profit);
            lpManager.liquidityToken().safeTransfer(address(collateralManager), profit);
            collateralManager.updateUserDeposit(position.owner, profit, true);
        } else {
            // Trader loses, which means LPs gain
            uint256 loss = uint256(-pnl);

            // Transfer the loss from trader's collateral to LP manager
            collateralManager.updateUserDeposit(position.owner, loss, false);
            collateralManager.withdrawLosses(address(lpManager), loss);

            lpManager.closeTradeLayer(position.layerId, loss, true);
        }

        // Clean up position
        _windDownPosition(positionId);
    }

    function liquidate(uint256 positionId) public {
        // verify position is ripe for liquidation and get computed losses
        (bool liquidatable, uint256 losses) = isLiquidatable(positionId);
        require(liquidatable, "Position isn't liquidatable");
        require(losses > 0, "No losses to collect");

        Position memory position = positions[positionId];
        require(position.openedAt != 0, "position not found");

        (, uint256 userCollateral,) = collateralManager.getUserDeposit(position.owner);

        // Cap losses to available collateral (cannot deduct more than exists)
        uint256 cappedLosses = losses > userCollateral ? userCollateral : losses;

        uint256 fee = 0;
        if (cappedLosses > 0 && liquidationFeeBps > 0) {
            fee = (cappedLosses * liquidationFeeBps) / BPS_DENOM;
            // defensive: ensure fee <= cappedLosses
            if (fee > cappedLosses) fee = cappedLosses;
        }
        uint256 amountToLp = cappedLosses - fee;

        _windDownPosition(positionId);

        // Deduct capped loss from the trader's collateral accounting
        if (cappedLosses > 0) {
            collateralManager.updateUserDeposit(position.owner, cappedLosses, false);
        }

        // --- Transfer tokens from CollateralManager to recipients ---
        // Pay liquidation fee to the caller (liquidator) if fee > 0
        if (fee > 0) {
            collateralManager.withdrawLosses(msg.sender, fee);
        }

        // Transfer remaining loss to LPManager (LPs gain)
        if (amountToLp > 0) {
            collateralManager.withdrawLosses(address(lpManager), amountToLp);
        }

        // --- Tell LP manager to close the trade layer and account for gains ---
        // LPs gained `amountToLp`. We call closeTradeLayer to update epoch accounting.
        lpManager.closeTradeLayer(position.layerId, amountToLp, true);

        emit PositionLiquidated(positionId, msg.sender, position.owner, losses, fee);
    }

    function getPositionPnL(uint256 positionId) public view returns (int256 pnl, bool isProfitable) {
        Position memory position = positions[positionId];
        require(position.openedAt != 0, "Position doesn't exist");

        (int256 currentPrice, uint256 precision) = getChainlinkDataFeedLatestAnswer(Feed.EthUsd);
        int256 priceDelta = currentPrice - int256(position.indexTokenPrice);

        if (position.positionType == PositionType.LONG) {
            pnl = int256(position.indexTokenSize) * priceDelta / int256(precision);
            isProfitable = pnl > 0;
        } else {
            // SHORT position profits when price goes down
            pnl = int256(position.indexTokenSize) * (-priceDelta) / int256(precision);
            isProfitable = pnl > 0;
        }
    }

    function _windDownPosition(uint256 positionId) internal {
        Position memory position = positions[positionId];
        uint256[] storage positions_ = userPosition[position.owner];
        for (uint256 i = 0; i < positions_.length; i++) {
            if (positions_[i] == positionId) {
                positions_[i] = positions_[positions_.length - 1];
                positions_.pop();
                break;
            }
        }
        delete positions[positionId];
    }

    function getUserPosition(address _user)
        public
        view
        returns (
            uint256 size,
            address owner,
            uint256 id,
            uint256 openedAt,
            uint256 indexTokenPrice,
            uint256 indexTokenSize,
            uint256 leverage,
            PositionType positionType,
            uint256 layerId
        )
    {
        if (userPosition[_user].length == 0) {
            // Return empty/zero values when no position exists
            // This prevents array out-of-bounds errors
            return (0, address(0), 0, 0, 0, 0, 0, PositionType.LONG, 0);
        }

        uint256 userPositionID = userPosition[_user][0];
        Position memory position = positions[userPositionID];

        // Additional safety check: ensure position actually exists
        if (position.openedAt == 0) {
            return (0, address(0), 0, 0, 0, 0, 0, PositionType.LONG, 0);
        }

        return (
            position.size,
            position.owner,
            position.id,
            position.openedAt,
            position.indexTokenPrice,
            position.indexTokenSize,
            position.leverage,
            position.positionType,
            position.layerId
        );
    }

    function hasOpenPosition(address _user) external view returns (bool) {
        if (userPosition[_user].length == 0) {
            return false;
        }

        uint256 userPositionID = userPosition[_user][0];
        Position memory position = positions[userPositionID];

        return position.openedAt != 0; // openedAt == 0 means deleted/closed
    }
}
