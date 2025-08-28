// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

contract LPManager is ERC4626, Ownable {
    using Math for uint256;

    uint lockedAmount;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner) {}

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        // user can't deposit less than 10 dai of collateral.
        // This isn't an issue as DAI has 18 decimals on ETH mainnet
        require(assets >= 10 ether, "Can't deposit less than 10 DAI");
        super._deposit(caller, receiver, assets, shares);
    }

    function decreaseLockedAmount(uint amount) external onlyOwner {
        lockedAmount -= amount;
    }

    function increaseLockedAmount(uint amount) external onlyOwner {
        lockedAmount += amount;
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - lockedAmount;
    }

    // the losses of the LP are the profits of the traders
    function withdrawLosses(address recipient, uint amount) public onlyOwner {
        bool success = IERC20(asset()).transfer(recipient, amount);
        require(success, "transfer failed");
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    // function _convertToAssets(
    //     uint256 shares,
    //     Math.Rounding rounding
    // ) internal view override returns (uint256) {
    //     return
    //         shares.mulDiv(
    //             totalAssets() + 1 + lockedAmount,
    //             totalSupply() + 10 ** _decimalsOffset(),
    //             rounding
    //         );
    // }
}
