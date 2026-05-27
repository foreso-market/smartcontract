// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IProxyWalletModule {
    function transferERC20ForOrder(
        address safe,
        address token,
        address to,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external;

    function transferERC1155ForOrder(
        address safe,
        address token,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external;

    function transferFeeForOrder(
        address safe,
        address token,
        address to,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external;
}
