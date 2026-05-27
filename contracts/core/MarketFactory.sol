// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IMarketFactory.sol";
import "../interfaces/IConditionalTokens.sol";

contract MarketFactory is IMarketFactory, AccessControl, Pausable {
    IConditionalTokens public immutable conditionalTokens;

    mapping(bytes32 => Market) public markets;

    bytes32[] public allMarkets;

    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error InvalidEndTime();
    error InvalidOutcomeCount();
    error MarketNotFound();
    error InvalidStatusTransition();
    error Unauthorized();
    error MarketNotYetConcluded();

    uint256 private _questionNonce;

    constructor(address conditionalTokens_) {
        conditionalTokens = IConditionalTokens(conditionalTokens_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_CREATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function createBinaryMarket(
        string calldata question,
        string[2] calldata outcomes,
        address collateralToken,
        uint256 endTime,
        address oracle
    ) external override onlyRole(MARKET_CREATOR_ROLE) whenNotPaused returns (bytes32) {
        if (endTime <= block.timestamp) revert InvalidEndTime();

        // ID + nonce
        bytes32 questionId = keccak256(
            abi.encode(question, outcomes[0], outcomes[1], block.timestamp, _questionNonce++)
        );

        //
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        // ID
        bytes32 conditionId = conditionalTokens.getConditionId(oracle, questionId, 2);

        //
        markets[conditionId] = Market({
            conditionId: conditionId,
            questionId: questionId,
            question: question,
            oracle: oracle,
            collateralToken: collateralToken,
            outcomeSlotCount: 2,
            endTime: endTime,
            createdAt: block.timestamp,
            status: MarketStatus.Active
        });

        allMarkets.push(conditionId);

        emit MarketCreated(
            conditionId,
            questionId,
            question,
            oracle,
            collateralToken,
            2,
            endTime
        );

        return conditionId;
    }

    function createCategoricalMarket(
        string calldata question,
        string[] calldata outcomes,
        address collateralToken,
        uint256 endTime,
        address oracle
    ) external override onlyRole(MARKET_CREATOR_ROLE) whenNotPaused returns (bytes32) {
        if (endTime <= block.timestamp) revert InvalidEndTime();
        if (outcomes.length < 2) revert InvalidOutcomeCount();

        // ID nonce
        bytes32 questionId = keccak256(
            abi.encode(question, outcomes, block.timestamp, _questionNonce++)
        );

        //
        uint256 outcomeSlotCount = outcomes.length;
        conditionalTokens.prepareCondition(oracle, questionId, outcomeSlotCount);

        // ID
        bytes32 conditionId = conditionalTokens.getConditionId(
            oracle,
            questionId,
            outcomeSlotCount
        );

        //
        markets[conditionId] = Market({
            conditionId: conditionId,
            questionId: questionId,
            question: question,
            oracle: oracle,
            collateralToken: collateralToken,
            outcomeSlotCount: outcomeSlotCount,
            endTime: endTime,
            createdAt: block.timestamp,
            status: MarketStatus.Active
        });

        allMarkets.push(conditionId);

        emit MarketCreated(
            conditionId,
            questionId,
            question,
            oracle,
            collateralToken,
            outcomeSlotCount,
            endTime
        );

        return conditionId;
    }

    function getMarket(bytes32 conditionId)
        external
        view
        override
        returns (Market memory)
    {
        Market memory market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        return market;
    }

    function updateMarketStatus(
        bytes32 conditionId,
        MarketStatus newStatus
    ) external override {
        Market storage market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();

        //
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && msg.sender != market.oracle) {
            revert Unauthorized();
        }

        MarketStatus oldStatus = market.status;

        // / endTime Cancelled
        if (newStatus == MarketStatus.Closed || newStatus == MarketStatus.Resolved) {
            if (block.timestamp < market.endTime) {
                revert MarketNotYetConcluded();
            }
        }

        //
        if (!_isValidStatusTransition(oldStatus, newStatus)) {
            revert InvalidStatusTransition();
        }

        market.status = newStatus;

        emit MarketStatusUpdated(conditionId, oldStatus, newStatus);
    }

    function getMarketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    function getMarkets(uint256 offset, uint256 limit)
        external
        view
        returns (Market[] memory markets_)
    {
        uint256 total = allMarkets.length;
        if (offset >= total) {
            return new Market[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        markets_ = new Market[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            markets_[i - offset] = markets[allMarkets[i]];
        }
    }

    function _isValidStatusTransition(
        MarketStatus from,
        MarketStatus to
    ) internal pure returns (bool) {
        if (from == to) return false;

        // Active -> Closed, Resolved, Cancelled
        if (from == MarketStatus.Active) {
            return to == MarketStatus.Closed ||
                   to == MarketStatus.Resolved ||
                   to == MarketStatus.Cancelled;
        }

        // Closed -> Resolved, Cancelled
        if (from == MarketStatus.Closed) {
            return to == MarketStatus.Resolved || to == MarketStatus.Cancelled;
        }

        // Resolved  Cancelled
        return false;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
