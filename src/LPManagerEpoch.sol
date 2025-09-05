// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-contracts/access/Ownable.sol";
import "./interfaces/ILPManagerEpoch.sol";

/**
 * @title Perpetuals LP - Epoch / Cohort Implementation
 * @dev Implements epoch-based liquidity cohorts where each epoch is frozen when trades lock liquidity.
 * Leftover free liquidity is rolled forward into new epochs using a lazy-split mechanism.
 * LPs hold epoch-specific "shares" (scaled by PRECISION) and can materialize virtual rollovers on demand.
 *
 * Key invariants:
 *  - epoch.totalShares = (epoch.freeAssets + epoch.lockedAssets) * PRECISION  (at epoch creation and after splits)
 *  - per-LP epochSharesOf[lp][eid] are stored in scaled share units (token * PRECISION)
 *  - lp.totalShares is sum of their epochShares (scaled) and corresponds to their total token entitlement = lp.totalShares / PRECISION
 */
contract LPManagerEpoch is ReentrancyGuard, Ownable, ILPManagerEpoch {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18; // share scaling factor
    uint256 public constant MIN_AMOUNT = 1e18; // share scaling factor

    IERC20 public immutable liquidityToken;

    // ============= Epoch data structures =============

    // epoch id => Epoch
    mapping(uint256 => Epoch) public epochs;

    // LP -> epochId -> scaled shares
    mapping(address => mapping(uint256 => uint256)) public epochSharesOf;

    // current epoch that receives new deposits
    uint256 public currentEpochId;

    // aggregate free assets across all epochs (cached for efficiency)
    uint256 public globalFreeAssets;

    // ============= LP summary state =============

    mapping(address => LiquidityProvider) public liquidityProviders;
    mapping(address => uint256) public lastMaterializedEpoch;

    // ============= Trade layer data =============

    mapping(uint256 => TradeLayer) internal tradeLayers;
    uint256 public temporalSequenceCounter;

    constructor(address _liquidityToken) Ownable(msg.sender) {
        if (_liquidityToken == address(0)) revert ZeroAddress();
        liquidityToken = IERC20(_liquidityToken);

        // create initial epoch
        currentEpochId = 1;
        epochs[currentEpochId] = Epoch({
            id: currentEpochId,
            totalShares: 0,
            freeAssets: 0,
            lockedAssets: 0,
            frozen: false,
            split: false,
            preSplitTotalShares: 0,
            rolloverEpochId: 0
        });
        emit EpochCreated(currentEpochId);
    }

    // ============= Deposit / Withdraw =============

    /**
     * @dev Deposit tokens into the current epoch. Mints shares = amount * PRECISION.
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_AMOUNT, "amount>0");
        Epoch storage e = epochs[currentEpochId];

        // transfer tokens
        liquidityToken.safeTransferFrom(msg.sender, address(this), amount);

        // mint scaled shares
        uint256 shares = amount * PRECISION;

        // update epoch accounting
        e.freeAssets += amount;
        e.totalShares += shares;

        // credit LP
        epochSharesOf[msg.sender][currentEpochId] += shares;

        // update LP summary
        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        if (!lp.exists) {
            lp.exists = true;
            lastMaterializedEpoch[msg.sender] = currentEpochId;
        }
        lp.totalShares += shares;

        // update global free assets
        globalFreeAssets += amount;

        emit Deposit(msg.sender, currentEpochId, amount, shares);
    }

    /**
     * @dev Withdraw from a specific epoch. Requires that the epoch has enough free assets.
     * burns shares = amount * PRECISION from the epoch ownership of the LP.
     */
    function withdrawFromEpoch(uint256 epochId, uint256 amount) external nonReentrant {
        require(amount > 0, "amount>0");
        Epoch storage e = epochs[epochId];
        require(e.id == epochId, "invalid epoch");

        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        require(lp.exists, "no lp");

        // check LP overall availability across epochs
        uint256 totalBalance = lp.totalShares / PRECISION; // tokens
        uint256 available = 0;
        if (totalBalance > lp.accumulatedUtilization) available = totalBalance - lp.accumulatedUtilization;
        require(amount <= available, "insufficient available across epochs");

        // check epoch-level availability
        require(e.freeAssets >= amount, "epoch insufficient free assets");

        uint256 sharesToBurn = amount * PRECISION;
        require(epochSharesOf[msg.sender][epochId] >= sharesToBurn, "not enough shares in epoch");

        // update epoch and LP bookkeeping
        epochSharesOf[msg.sender][epochId] -= sharesToBurn;
        lp.totalShares -= sharesToBurn;
        if (e.totalShares >= sharesToBurn) {
            e.totalShares -= sharesToBurn;
        } else {
            e.totalShares = 0;
        }
        e.freeAssets -= amount;

        // update global free assets
        if (globalFreeAssets >= amount) globalFreeAssets -= amount;
        else globalFreeAssets = 0;

        // transfer tokens
        liquidityToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, epochId, amount, sharesToBurn);
    }

    // ============= Epoch split & materialize =============

    /**
     * @dev Split an epoch that has been frozen (i.e., some lockedAssets exist).
     * The locked portion remains in the original epoch (its totalShares becomes lockedShareCount).
     * The leftover freeAssets are moved to a new rollover epoch whose totalShares = rolloverShareCount.
     * This function updates epoch-level totals but does NOT touch per-LP balances.
     */
    function _splitEpoch(uint256 epochId) internal returns (uint256 newEpochId) {
        Epoch storage e = epochs[epochId];
        require(e.frozen, "epoch not frozen");
        require(!e.split, "already split");

        uint256 epochTotalAssets = e.freeAssets + e.lockedAssets;
        require(epochTotalAssets > 0, "empty epoch");
        require(e.totalShares > 0, "no shares in epoch");

        uint256 originalTotalShares = e.totalShares; // scaled

        // compute locked shares representing the lockedAssets
        uint256 lockedShareCount = (originalTotalShares * e.lockedAssets) / epochTotalAssets;
        uint256 rolloverShareCount = originalTotalShares - lockedShareCount;

        // create new rollover epoch
        newEpochId = ++currentEpochId;
        epochs[newEpochId] = Epoch({
            id: newEpochId,
            totalShares: rolloverShareCount,
            freeAssets: e.freeAssets,
            lockedAssets: 0,
            frozen: false,
            split: false,
            preSplitTotalShares: 0,
            rolloverEpochId: 0
        });
        emit EpochCreated(newEpochId);

        // update original epoch to represent locked portion only
        e.preSplitTotalShares = originalTotalShares;
        e.totalShares = lockedShareCount;
        e.freeAssets = 0; // leftover moved to rollover
        e.split = true;
        e.rolloverEpochId = newEpochId;

        emit EpochSplit(epochId, lockedShareCount, newEpochId);

        return newEpochId;
    }

    /**
     * @dev Materialize a sequence of splits for msg.sender starting from `epochId` to +10 epochs.
     * This moves the caller's rollover shares down the split chain into concrete epochs.
     * Gas cost is paid by the caller. The function is idempotent.
     */
    function materializeShares(uint256 epochId) external nonReentrant {
        uint256 eid = epochId;
        if (eid != lastMaterializedEpoch[msg.sender]) {
            revert MustMaterializeSequentially();
        }

        uint256 noOfTimesMaterialized;

        while (noOfTimesMaterialized < 10) {
            Epoch storage e = epochs[eid];
            if (!e.split) break; // nothing to do for this epoch

            uint256 originalTotal = e.preSplitTotalShares;
            uint256 lockedTotal = e.totalShares; // locked share count after split
            uint256 rolloverEid = e.rolloverEpochId;
            if (!(originalTotal > 0)) revert BadSplitState();

            uint256 sOld = epochSharesOf[msg.sender][eid];
            if (sOld > 0) {
                // compute locked and rollover shares for this LP
                uint256 sLocked = (sOld * lockedTotal) / originalTotal;
                uint256 sRollover = sOld - sLocked;

                // set LP's shares in original epoch to sLocked
                epochSharesOf[msg.sender][eid] = sLocked;

                // credit LP with shares in rollover epoch
                if (sRollover > 0) {
                    epochSharesOf[msg.sender][rolloverEid] += sRollover;
                }

                noOfTimesMaterialized++;
                emit Materialized(msg.sender, eid, sLocked, sRollover);
            }

            // continue down the chain (in case rollover epoch itself is split later)
            eid = rolloverEid;
            if (eid == 0) break;
        }

        lastMaterializedEpoch[msg.sender] = eid;
    }

    // ============= Trade layer flows =============

    /**
     * @dev Internal: lock funds from the current epoch, freeze it, and split to roll leftover forward.
     * Returns the epochId that was used to fund (the locked epoch, which after split will contain only locked shares/assets).
     */
    function _lockFromCurrentEpoch(uint256 amount) internal returns (uint256 fundingEpochId) {
        Epoch storage e = epochs[currentEpochId];
        require(!e.frozen, "current epoch already frozen");
        require(e.freeAssets >= amount, "not enough free in current epoch");

        // move assets to locked
        e.freeAssets -= amount;
        e.lockedAssets += amount;

        globalFreeAssets -= amount;

        // freeze epoch
        e.frozen = true;

        uint256 originalEpochId = currentEpochId;

        // split epoch to move leftover freeAssets into a new epoch (rollover)
        _splitEpoch(currentEpochId);

        // after split, the original epoch now represents the locked portion
        fundingEpochId = originalEpochId;

        // set currentEpochId to the newly created rollover epoch (already set inside _splitEpoch)
        // (currentEpochId was incremented by _splitEpoch)
        return fundingEpochId;
    }

    /**
     * @dev Create a trade layer that is backed by the current epoch. This will lock `requiredBacking` tokens
     * from the current epoch, freeze it, and roll leftover forward.
     */
    function createTradeLayer(uint256 requiredBacking) external onlyOwner returns (uint256 layerId) {
        require(requiredBacking > 0, "backing>0");
        require(globalFreeAssets >= requiredBacking, "insufficient global free liquidity");

        // lock from current epoch and split
        uint256 fundingEpoch = _lockFromCurrentEpoch(requiredBacking);

        // create layer
        layerId = ++temporalSequenceCounter;
        TradeLayer storage layer = tradeLayers[layerId];
        layer.id = layerId;
        layer.requiredBacking = requiredBacking;
        layer.fundingEpochId = fundingEpoch;
        layer.status = LayerStatus.Open;
        layer.totalAllocated = requiredBacking;
        layer.remainingBacking = 0;

        emit TradeLayerCreated(layerId, requiredBacking, fundingEpoch);
    }

    /**
     * @dev LP claims allocation for a layer. LP's effective locked shares in the funding epoch are computed
     * using split metadata if necessary (no need to materialize first for claiming from the locked epoch).
     */
    function claimLayerAllocation(uint256 layerId) external nonReentrant {
        TradeLayer storage layer = tradeLayers[layerId];
        require(layer.status == LayerStatus.Open, "layer not open");
        require(!layer.hasAllocated[msg.sender], "already allocated");

        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        require(lp.exists, "no lp");

        Epoch storage funding = epochs[layer.fundingEpochId];
        require(funding.id == layer.fundingEpochId, "invalid funding epoch");

        // compute LP's effective locked shares in funding epoch
        uint256 sOld = epochSharesOf[msg.sender][layer.fundingEpochId];

        // If LP materialized earlier, sOld is already the locked portion. If not, and epoch was split,
        // compute locked portion virtually using preSplitTotalShares metadata.
        uint256 effectiveLockedShares;
        if (funding.split && funding.preSplitTotalShares > 0) {
            effectiveLockedShares = (sOld * funding.totalShares) / funding.preSplitTotalShares;
        } else {
            effectiveLockedShares = sOld; // no split or already in locked form
        }

        require(effectiveLockedShares > 0, "no eligible shares in funding epoch");

        uint256 allocation = (effectiveLockedShares * layer.requiredBacking) / funding.totalShares;

        // cap with remainingBacking to prevent over-allocation races
        if (allocation > layer.remainingBacking) allocation = layer.remainingBacking;
        require(allocation > 0, "zero allocation");

        // ensure LP has available capacity (across all epochs)
        uint256 totalBalance = lp.totalShares / PRECISION;
        uint256 available = 0;
        if (totalBalance > lp.accumulatedUtilization) available = totalBalance - lp.accumulatedUtilization;
        require(allocation <= available, "insufficient available liquidity for allocation");

        // record allocation
        layer.allocations[msg.sender] = allocation;
        layer.hasAllocated[msg.sender] = true;
        layer.totalAllocated += allocation;
        layer.remainingBacking -= allocation;

        // update LP and global utilization
        lp.accumulatedUtilization += allocation;

        // globalFreeAssets already decreased at lock time; allocation only affects LP-level locking

        emit AllocationClaimed(layerId, msg.sender, allocation);
    }

    /**
     * @dev LP releases their allocation after the layer is closed to free their utilized balance.
     */
    function releaseAllocation(uint256 layerId) external nonReentrant {
        TradeLayer storage layer = tradeLayers[layerId];
        require(layer.status == LayerStatus.Closed, "layer not closed");
        require(layer.hasAllocated[msg.sender], "no allocation");

        uint256 allocation = layer.allocations[msg.sender];
        require(allocation > 0, "already released");

        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        if (lp.accumulatedUtilization >= allocation) lp.accumulatedUtilization -= allocation;
        else lp.accumulatedUtilization = 0;

        layer.allocations[msg.sender] = 0;
        layer.hasAllocated[msg.sender] = false;

        emit AllocationReleased(layerId, msg.sender, allocation);
    }

    function activateTradeLayer(uint256 layerId) external onlyOwner {
        TradeLayer storage layer = tradeLayers[layerId];
        require(layer.status == LayerStatus.Open, "not open");
        require(layer.totalAllocated > 0, "no allocations");
        layer.status = LayerStatus.Active;
        emit TradeLayerActivated(layerId);
    }

    /**
     * @dev Close layer: settle PnL. Owner must ensure the profit tokens (if any) are deposited to contract before calling.
     * The locked assets are returned to the funding epoch's freeAssets along with PnL (profit increases freeAssets; loss reduces).
     */
    function closeTradeLayer(uint256 layerId, uint256 profitLoss, bool lpGains) external onlyOwner {
        TradeLayer storage layer = tradeLayers[layerId];
        require(layer.status == LayerStatus.Open || layer.status == LayerStatus.Active, "already closed");

        Epoch storage funding = epochs[layer.fundingEpochId];
        uint256 lockedAmount = layer.requiredBacking; // amount that was locked from funding epoch

        // Ensure contract has tokens to reflect the final state before we update epoch accounting
        uint256 contractBal = liquidityToken.balanceOf(address(this));

        if (lpGains) {
            uint256 profit = (profitLoss);
            // require contract coverage for principal + profit
            require(contractBal >= (globalFreeAssets + profit), "contract not funded with profit");
            // credit profit to funding epoch's freeAssets
            funding.lockedAssets = funding.lockedAssets >= lockedAmount ? funding.lockedAssets - lockedAmount : 0;
            funding.freeAssets += (lockedAmount + profit);
            globalFreeAssets += (lockedAmount + profit);
        } else {
            uint256 loss = (profitLoss);
            // ensure contract has enough to absorb loss
            require(contractBal + loss >= globalFreeAssets, "insufficient tokens to absorb loss");
            require(loss < (funding.lockedAssets + globalFreeAssets), "loss too large");

            funding.lockedAssets = funding.lockedAssets >= lockedAmount ? funding.lockedAssets - lockedAmount : 0;

            // if loss >= lockedAmount then freeAssets doesn't increase
            if (loss >= lockedAmount) {
                // all locked principal lost (edge case handled)
                // no freeAssets returned
            } else {
                uint256 returned = lockedAmount - loss;
                funding.freeAssets += returned;
                globalFreeAssets += returned;
            }
            liquidityToken.safeTransfer(msg.sender, loss);
        }

        // mark layer closed. LPs must call releaseAllocation to free their utilization.
        layer.status = LayerStatus.Closed;

        emit TradeLayerClosed(layerId, profitLoss, lpGains);
    }

    // ============= Views & helpers =============

    function getEpoch(uint256 epochId)
        external
        view
        returns (
            uint256 id,
            uint256 totalShares,
            uint256 freeAssets,
            uint256 lockedAssets,
            bool frozen,
            bool split,
            uint256 preSplitTotalShares,
            uint256 rolloverEpochId
        )
    {
        Epoch storage e = epochs[epochId];
        return (
            e.id,
            e.totalShares,
            e.freeAssets,
            e.lockedAssets,
            e.frozen,
            e.split,
            e.preSplitTotalShares,
            e.rolloverEpochId
        );
    }

    function getLPTotalBalance(address lp) external view returns (uint256) {
        LiquidityProvider storage p = liquidityProviders[lp];
        if (!p.exists) return 0;
        return p.totalShares / PRECISION;
    }

    function getLPAvailable(address lp) external view returns (uint256) {
        LiquidityProvider storage p = liquidityProviders[lp];
        if (!p.exists) return 0;
        uint256 total = p.totalShares / PRECISION;
        if (total > p.accumulatedUtilization) return total - p.accumulatedUtilization;
        return 0;
    }

    // Get a virtual view of LP's effective locked shares for a funding epoch (without materializing)
    function getEffectiveLockedShares(address lp, uint256 fundingEpochId) public view returns (uint256) {
        Epoch storage funding = epochs[fundingEpochId];
        uint256 sOld = epochSharesOf[lp][fundingEpochId];
        if (funding.split && funding.preSplitTotalShares > 0) {
            return (sOld * funding.totalShares) / funding.preSplitTotalShares;
        } else {
            return sOld;
        }
    }

    // Get withdrawable amount from a specific epoch for an LP (virtual, doesn't materialize)
    function getEpochWithdrawable(address lp, uint256 epochId) external view returns (uint256) {
        Epoch storage e = epochs[epochId];
        uint256 s = epochSharesOf[lp][epochId];
        if (s == 0) return 0;
        if (e.totalShares == 0) return 0;
        // withdrawable fraction = s / e.totalShares * e.freeAssets
        return (s * e.freeAssets) / e.totalShares;
    }

    // Get total available liquidity across epochs (cached)
    function getTotalAvailableLiquidity() external view returns (uint256) {
        return globalFreeAssets;
    }

    // Get trade layer snapshot (non-mapping fields)
    function getTradeLayer(uint256 layerId)
        external
        view
        returns (
            uint256 id,
            uint256 requiredBacking,
            uint256 fundingEpochId,
            LayerStatus status,
            uint256 totalAllocated,
            uint256 remainingBacking
        )
    {
        TradeLayer storage layer = tradeLayers[layerId];
        return (
            layer.id,
            layer.requiredBacking,
            layer.fundingEpochId,
            layer.status,
            layer.totalAllocated,
            layer.remainingBacking
        );
    }
}
