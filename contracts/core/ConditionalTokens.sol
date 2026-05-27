// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "../interfaces/IConditionalTokens.sol";

contract ConditionalTokens is
    ERC1155,
    IConditionalTokens,
    ReentrancyGuard,
    Pausable,
    AccessControl
{
    using SafeERC20 for IERC20;

    struct Condition {
        address oracle;              //
        uint256 outcomeSlotCount;    //
        uint256[] payoutNumerators;  //
        uint256 payoutDenominator;   //
    }

    mapping(bytes32 => Condition) public conditions;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    error ConditionAlreadyPrepared();
    error InvalidOutcomeSlotCount();
    error ConditionNotPrepared();
    error ConditionAlreadyResolved();
    error InvalidPayoutsLength();
    error InvalidPayoutDenominator();
    error UnauthorizedOracle();
    error InvalidPartition();
    error InsufficientBalance();
    error ConditionNotResolved();

    constructor(string memory uri_) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function prepareCondition(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external override whenNotPaused {
        require(
            hasRole(OPERATOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Unauthorized"
        );
        //
        if (outcomeSlotCount < 2) revert InvalidOutcomeSlotCount();

        // ID
        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);

        //
        if (conditions[conditionId].outcomeSlotCount != 0) {
            revert ConditionAlreadyPrepared();
        }

        //
        conditions[conditionId] = Condition({
            oracle: oracle,
            outcomeSlotCount: outcomeSlotCount,
            payoutNumerators: new uint256[](0),
            payoutDenominator: 0
        });

        emit ConditionPreparation(conditionId, oracle, questionId, outcomeSlotCount);
    }

    function reportPayouts(
        bytes32 questionId,
        uint256[] calldata payouts
    ) external override whenNotPaused {
        //
        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payouts.length));
        Condition storage condition = conditions[conditionId];

        //
        if (condition.outcomeSlotCount == 0) revert ConditionNotPrepared();

        //
        if (condition.payoutDenominator != 0) revert ConditionAlreadyResolved();

        //
        if (payouts.length != condition.outcomeSlotCount) {
            revert InvalidPayoutsLength();
        }

        //
        uint256 den = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            den += payouts[i];
        }

        if (den == 0) revert InvalidPayoutDenominator();

        //
        condition.payoutNumerators = payouts;
        condition.payoutDenominator = den;

        emit ConditionResolution(
            conditionId,
            msg.sender,
            questionId,
            condition.outcomeSlotCount,
            payouts
        );
    }

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        //
        Condition storage condition = conditions[conditionId];
        if (condition.outcomeSlotCount == 0) revert ConditionNotPrepared();

        //
        if (condition.payoutDenominator != 0) revert ConditionAlreadyResolved();

        //
        if (!_validatePartition(partition, condition.outcomeSlotCount)) {
            revert InvalidPartition();
        }

        //
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        //
        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);

        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(
                parentCollectionId,
                conditionId,
                partition[i]
            );
            positionIds[i] = getPositionId(collateralToken, collectionId);
            amounts[i] = amount;
        }

        // ERC1155
        _mintBatch(msg.sender, positionIds, amounts, "");

        emit PositionSplit(
            msg.sender,
            collateralToken,
            parentCollectionId,
            conditionId,
            partition,
            amount
        );
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        //
        Condition storage condition = conditions[conditionId];
        if (condition.outcomeSlotCount == 0) revert ConditionNotPrepared();

        //  splitPosition
        if (condition.payoutDenominator != 0) revert ConditionAlreadyResolved();

        //
        if (!_validatePartition(partition, condition.outcomeSlotCount)) {
            revert InvalidPartition();
        }

        //
        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);

        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(
                parentCollectionId,
                conditionId,
                partition[i]
            );
            positionIds[i] = getPositionId(collateralToken, collectionId);
            amounts[i] = amount;

            //
            if (balanceOf(msg.sender, positionIds[i]) < amount) {
                revert InsufficientBalance();
            }
        }

        // ERC1155
        _burnBatch(msg.sender, positionIds, amounts);

        //
        collateralToken.safeTransfer(msg.sender, amount);

        emit PositionsMerge(
            msg.sender,
            collateralToken,
            parentCollectionId,
            conditionId,
            partition,
            amount
        );
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external override nonReentrant whenNotPaused {
        //
        Condition storage condition = conditions[conditionId];
        if (condition.payoutDenominator == 0) revert ConditionNotResolved();

        uint256 totalPayout = 0;

        for (uint256 i = 0; i < indexSets.length; i++) {
            bytes32 collectionId = getCollectionId(
                parentCollectionId,
                conditionId,
                indexSets[i]
            );
            uint256 positionId = getPositionId(collateralToken, collectionId);
            uint256 balance = balanceOf(msg.sender, positionId);

            if (balance > 0) {
                //
                uint256 payout = _calculatePayout(
                    condition,
                    indexSets[i],
                    balance
                );
                totalPayout += payout;

                //
                _burn(msg.sender, positionId, balance);
            }
        }

        //
        if (totalPayout > 0) {
            collateralToken.safeTransfer(msg.sender, totalPayout);
        }

        emit PayoutRedemption(
            msg.sender,
            collateralToken,
            parentCollectionId,
            conditionId,
            indexSets,
            totalPayout
        );
    }

    function getConditionId(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256 indexSet
    ) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(
        IERC20 collateralToken,
        bytes32 collectionId
    ) public pure override returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    function getOutcomeSlotCount(bytes32 conditionId)
        external
        view
        override
        returns (uint256)
    {
        return conditions[conditionId].outcomeSlotCount;
    }

    function getPayoutNumerators(bytes32 conditionId)
        external
        view
        override
        returns (uint256[] memory)
    {
        return conditions[conditionId].payoutNumerators;
    }

    function getPayoutDenominator(bytes32 conditionId)
        external
        view
        override
        returns (uint256)
    {
        return conditions[conditionId].payoutDenominator;
    }

    function _validatePartition(
        uint256[] calldata partition,
        uint256 outcomeSlotCount
    ) internal pure returns (bool) {
        if (partition.length == 0) return false;

        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 freeIndexSet = fullIndexSet;

        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0 || indexSet > fullIndexSet) return false;
            if ((indexSet & freeIndexSet) != indexSet) return false;
            freeIndexSet ^= indexSet;
        }

        return freeIndexSet == 0;
    }

    function _calculatePayout(
        Condition storage condition,
        uint256 indexSet,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 payout = 0;

        for (uint256 i = 0; i < condition.outcomeSlotCount; i++) {
            if ((indexSet & (1 << i)) != 0) {
                payout += condition.payoutNumerators[i];
            }
        }

        return (amount * payout) / condition.payoutDenominator;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl, IERC165)
        returns (bool)
    {
        return
            ERC1155.supportsInterface(interfaceId) ||
            AccessControl.supportsInterface(interfaceId);
    }
}
