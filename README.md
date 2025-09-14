## *1. Executive Summary*

This report details a *Critical* severity vulnerability discovered in the PositionManager.sol contract of the Minimal Perpetual Protocol. The core of the issue lies in an inconsistent handling of scaled-price arithmetic, leading to a critical miscalculation in the position liquidation logic.

The isLiquidatable() function calculates unrealized losses without normalizing for the precision of the Chainlink price oracle, while the getPositionPnL() function does. This discrepancy causes the liquidation function to perceive losses as *100,000,000 times (10^8) larger* than they actually are.

This flaw will lead to *premature and incorrect liquidations*, causing a direct and irreversible loss of user funds. The entire risk management and solvency of the protocol is compromised. Immediate remediation is required.

---

## *2. Vulnerability Details*

*   *Title:* Incorrect Loss Calculation in Liquidation Logic Due to Missing Precision Division
*   *Severity:* <span style="color:red">*Critical*</span>
*   *Component:* contracts/src/PositionManager.sol
*   *Function:* isLiquidatable(uint256 positionId)

### *Description*

The protocol's core logic for determining if a position can be liquidated is flawed. The isLiquidatable() function calculates a position's unrealized loss by multiplying the position.indexTokenSize by the priceDelta. However, it fails to divide the result by the precision (e.g., 10^8 for ETH/USD) of the Chainlink price feed.

This is inconsistent with the getPositionPnL() function, which correctly performs this division to normalize the value. As a result, the isLiquidatable() function operates with a loss value that is artificially inflated by a factor of 10^8, leading to catastrophic consequences for position holders.

---

## *3. Technical Analysis & Root Cause*

The bug stems from the interaction between three values: indexTokenSize, priceDelta, and precision.

1.  *Price Scaling:* Chainlink price feeds for assets like ETH/USD do not use 18 decimals. They typically use 8. The price is returned as an integer, scaled up by 10**decimals.
    *   ethPrice = real_price * 10^8

2.  **Pre-scaled indexTokenSize:** When a position is opened in openPosition(), the indexTokenSize is calculated. This value represents the position's size in the base asset (ETH).
    solidity
    // from openPosition()
    indexTokenSize = (positionSize * precision) / uint256(ethPrice);
    
    This calculation correctly accounts for the scaled ethPrice and precision, resulting in indexTokenSize being a properly scaled value.

3.  *Inconsistent Calculations:*
    *   **Correct (getPositionPnL):** The profit and loss is correctly calculated by multiplying the two scaled numbers and then normalizing the result by dividing by precision.
      solidity
      // Correct PnL Calculation
      pnl = int256(position.indexTokenSize) * priceDelta / int256(precision);
      
    *   **Incorrect (isLiquidatable):** The function multiplies the two scaled numbers but **forgets to divide by precision**.
      solidity
      // BUGGY Loss Calculation
      int256 loss = int256(position.indexTokenSize) * priceDelta; // Missing: / int256(precision)
      

This omission is the root cause. The loss variable in isLiquidatable holds a value that is 10^8 times larger than the actual loss.

---




















// Details and Instruction
1. Collateral collection
2. Position tracking
3. Price discovery

### Assumptions

1. Only DAI is supported. As such, we do not bother about fee on transfer tokens.

1. LPs provide liquidity
1. Traders are basically betting against the LPs on the direction in which the price of the index token is going to go in the near future
1. Traders open positions with collateral

### Invariants

- User can't withdraw when position is open

### Getting supported

`forge soldeer install`
