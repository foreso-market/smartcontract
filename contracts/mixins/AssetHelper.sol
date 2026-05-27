// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IConditionalTokens.sol";

abstract contract AssetHelper {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    IConditionalTokens public immutable conditionalTokens;

    address public immutable collateral;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    constructor(address conditionalTokens_, address collateral_) {
        require(conditionalTokens_ != address(0), "AssetHelper: zero conditionalTokens");
        require(collateral_ != address(0), "AssetHelper: zero collateral");
        conditionalTokens = IConditionalTokens(conditionalTokens_);
        collateral = collateral_;

        // ⭐ Polymarket:  collateral  ConditionalTokens
        //  MINT/MERGE  splitPosition/mergePositions
        IERC20(collateral_).safeIncreaseAllowance(conditionalTokens_, type(uint256).max);
    }

    function getCollateral() public view returns (address) {
        return collateral;
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function _isCollateral(uint256 assetId) internal pure returns (bool) {
        return assetId == 0;
    }

    function _isERC1155TokenId(uint256 assetId) internal pure returns (bool) {
        return assetId > type(uint160).max;
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function _transferCollateral(
        address from,
        address to,
        uint256 amount
    ) internal {
        IERC20 token = IERC20(collateral);
        if (from == address(this)) {
            token.safeTransfer(to, amount);
        } else {
            token.safeTransferFrom(from, to, amount);
        }
    }

    function _transferERC1155(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) internal {
        require(_isERC1155TokenId(tokenId), "AssetHelper: not ERC1155");

        conditionalTokens.safeTransferFrom(
            from,
            to,
            tokenId,
            amount,
            ""
        );
    }

    function _transferAsset(
        address from,
        address to,
        uint256 assetId,
        uint256 amount
    ) internal {
        if (_isCollateral(assetId)) {
            _transferCollateral(from, to, amount);
        } else if (_isERC1155TokenId(assetId)) {
            _transferERC1155(from, to, assetId, amount);
        } else {
            revert("AssetHelper: invalid assetId");
        }
    }
}
