// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMarketFactory {
    enum MarketStatus {
        Active,      //
        Closed,      //
        Resolved,    //
        Cancelled    //
    }

    struct Market {
        bytes32 conditionId;      // ID
        bytes32 questionId;       // ID
        string question;          //
        address oracle;           //
        address collateralToken;  //
        uint256 outcomeSlotCount; //
        uint256 endTime;          //
        uint256 createdAt;        //
        MarketStatus status;      //
    }

    event MarketCreated(
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        string question,
        address indexed oracle,
        address collateralToken,
        uint256 outcomeSlotCount,
        uint256 endTime
    );

    event MarketStatusUpdated(
        bytes32 indexed conditionId,
        MarketStatus oldStatus,
        MarketStatus newStatus
    );

    function createBinaryMarket(
        string calldata question,
        string[2] calldata outcomes,
        address collateralToken,
        uint256 endTime,
        address oracle
    ) external returns (bytes32 conditionId);

    function createCategoricalMarket(
        string calldata question,
        string[] calldata outcomes,
        address collateralToken,
        uint256 endTime,
        address oracle
    ) external returns (bytes32 conditionId);

    function getMarket(bytes32 conditionId) external view returns (Market memory market);

    function updateMarketStatus(bytes32 conditionId, MarketStatus newStatus) external;
}
