// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "smartcontractkit-chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

enum Feed {
    EthUsd,
    DaiUsd
}

contract PriceOracle {
    /**
     * Network: Eth mainnet
     * Aggregator: DAI/USD
     * Address: 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9
     */
    address DaiUsdFeed = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    /**
     * Network: Eth mainnet
     * Aggregator: ETH/USD
     * Address: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     */
    address EthUsdFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    constructor() {
        // dataFeed = AggregatorV3Interface(DaiUsdFeed);
    }

    function setFeeds(address daiUsd, address ethUsd) external {
        _setFeed(daiUsd, ethUsd);
    }

    function _setFeed(address daiUsd, address ethUsd) internal virtual {
        DaiUsdFeed = daiUsd;
        EthUsdFeed = ethUsd;
    }

    /**
     * Returns the latest answer.
     */
    function getChainlinkDataFeedLatestAnswer(
        Feed feed
    ) public view returns (int, uint) {
        // @todo: add checks to confirm this is not an outdated price
        AggregatorV3Interface dataFeed = feed == Feed.EthUsd
            ? AggregatorV3Interface(EthUsdFeed)
            : AggregatorV3Interface(DaiUsdFeed);
        (
            ,
            /* uint80 roundId */ int256 answer,
            ,
            /*uint256 startedAt*/ uint256 updatedAt /*uint80 answeredInRound*/,

        ) = dataFeed.latestRoundData();
        uint precision = dataFeed.decimals();
        require(updatedAt >= block.timestamp - 30 minutes, "Price is outdated");
        require(answer > 0, "Invalid price");
        return (answer, precision);
    }
}
