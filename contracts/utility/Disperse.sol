// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract Disperse {
    function disperseEther(address[] calldata recipients, uint256[] calldata values) external payable {
        require(recipients.length == values.length, "length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            (bool ok, ) = recipients[i].call{value: values[i]}("");
            require(ok, "transfer failed");
        }
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok, ) = msg.sender.call{value: balance}("");
            require(ok, "refund failed");
        }
    }

    ///          msg.sender  approve(disperse, sum(values))
    function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata values) external {
        require(recipients.length == values.length, "length mismatch");
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            total += values[i];
        }
        require(token.transferFrom(msg.sender, address(this), total), "pull failed");
        for (uint256 i = 0; i < recipients.length; i++) {
            require(token.transfer(recipients[i], values[i]), "push failed");
        }
    }

    ///          approve
    function disperseTokenSimple(IERC20 token, address[] calldata recipients, uint256[] calldata values) external {
        require(recipients.length == values.length, "length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            require(token.transferFrom(msg.sender, recipients[i], values[i]), "transferFrom failed");
        }
    }
}
