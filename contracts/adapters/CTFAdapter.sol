// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IConditionalTokens.sol";

contract CTFAdapter is IERC1155Receiver, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IConditionalTokens public immutable conditionalTokens;

    // CTFExchange
    address public ctfExchange;

    //  mergeAndReturn
    mapping(address => bool) public authorizedCallers;

    //
    event Deposit(
        address indexed user,
        IERC20 indexed collateralToken,
        bytes32 indexed conditionId,
        uint256 amount
    );

    event ExchangeApproved(
        address indexed user,
        address indexed exchange
    );

    event Withdraw(
        address indexed user,
        IERC20 indexed collateralToken,
        bytes32 indexed conditionId,
        uint256 amount
    );

    event MergeAndReturn(
        address indexed recipient,
        IERC20 indexed collateralToken,
        bytes32 indexed conditionId,
        uint256 amount
    );

    event PositionBought(
        address indexed user,
        bytes32 indexed conditionId,
        uint256 outcomeIndex,
        uint256 amount
    );

    event PositionSold(
        address indexed user,
        bytes32 indexed conditionId,
        uint256 outcomeIndex,
        uint256 amount
    );

    //
    error InvalidAmount();
    error InvalidOutcome();
    error InsufficientBalance();
    error TransferFailed();
    error UnauthorizedCaller();

    constructor(
        address _conditionalTokens,
        address _ctfExchange
    ) Ownable(msg.sender) {
        require(_conditionalTokens != address(0), "Invalid CT address");
        require(_ctfExchange != address(0), "Invalid Exchange address");
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        ctfExchange = _ctfExchange;
    }

    function deposit(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        // 1.
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // 2.  ConditionalTokens
        collateralToken.forceApprove(address(conditionalTokens), amount);

        // 3.
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        uint256[] memory partition = _getFullPartition(outcomeSlotCount);

        conditionalTokens.splitPosition(
            collateralToken,
            bytes32(0), // parentCollectionId
            conditionId,
            partition,
            amount
        );

        // 4.
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);

            conditionalTokens.safeTransferFrom(
                address(this),
                msg.sender,
                positionId,
                amount,
                ""
            );
        }

        emit Deposit(msg.sender, collateralToken, conditionId, amount);
    }

    function withdraw(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);

        // 1.
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);

            conditionalTokens.safeTransferFrom(
                msg.sender,
                address(this),
                positionId,
                amount,
                ""
            );
        }

        // 2.
        uint256[] memory partition = _getFullPartition(outcomeSlotCount);
        conditionalTokens.mergePositions(
            collateralToken,
            bytes32(0),
            conditionId,
            partition,
            amount
        );

        // 3.
        collateralToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, collateralToken, conditionId, amount);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        require(caller != address(0), "Invalid caller");
        authorizedCallers[caller] = authorized;
    }

    function mergeAndReturn(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 amount,
        address recipient
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert TransferFailed();
        require(authorizedCallers[msg.sender], "CTFAdapter: caller not authorized");

        // CTFAdapter
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        uint256[] memory partition = _getFullPartition(outcomeSlotCount);

        conditionalTokens.mergePositions(
            collateralToken,
            bytes32(0),
            conditionId,
            partition,
            amount
        );

        //  ProxyWallet
        collateralToken.safeTransfer(recipient, amount);

        emit MergeAndReturn(recipient, collateralToken, conditionId, amount);
    }

    function depositAndBuy(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 outcomeIndex,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        if (outcomeIndex == 0 || outcomeIndex > outcomeSlotCount) revert InvalidOutcome();

        // 1.
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // 2.
        collateralToken.forceApprove(address(conditionalTokens), amount);
        uint256[] memory partition = _getFullPartition(outcomeSlotCount);

        conditionalTokens.splitPosition(
            collateralToken,
            bytes32(0),
            conditionId,
            partition,
            amount
        );

        // 3.
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);

            conditionalTokens.safeTransferFrom(
                address(this),
                msg.sender,
                positionId,
                amount,
                ""
            );
        }

        emit PositionBought(msg.sender, conditionId, outcomeIndex, amount);
    }

    function redeemAndWithdraw(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256[] calldata outcomeIndexes
    ) external nonReentrant {
        if (outcomeIndexes.length == 0) revert InvalidAmount();

        // 1.  collateral
        uint256 collateralBefore = collateralToken.balanceOf(address(this));

        // 2.
        bool hasTransferred = false;
        for (uint256 i = 0; i < outcomeIndexes.length; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                outcomeIndexes[i]
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);
            uint256 balance = conditionalTokens.balanceOf(msg.sender, positionId);

            if (balance > 0) {
                conditionalTokens.safeTransferFrom(
                    msg.sender,
                    address(this),
                    positionId,
                    balance,
                    ""
                );
                hasTransferred = true;
            }
        }
        require(hasTransferred, "No positions transferred");

        // 3.
        conditionalTokens.redeemPositions(
            collateralToken,
            bytes32(0),
            conditionId,
            outcomeIndexes
        );
        uint256 payout = collateralToken.balanceOf(address(this)) - collateralBefore;

        // 4.
        if (payout > 0) {
            collateralToken.safeTransfer(msg.sender, payout);
        }

        emit Withdraw(msg.sender, collateralToken, conditionId, payout);
    }

    // ====================  ====================

    function depositAndNotifyApproval(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 amount
    ) external nonReentrant {
        // 1.
        if (amount == 0) revert InvalidAmount();

        //
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        //  ConditionalTokens
        collateralToken.forceApprove(address(conditionalTokens), amount);

        //
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        uint256[] memory partition = _getFullPartition(outcomeSlotCount);

        conditionalTokens.splitPosition(
            collateralToken,
            bytes32(0),
            conditionId,
            partition,
            amount
        );

        //
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);

            conditionalTokens.safeTransferFrom(
                address(this),
                msg.sender,
                positionId,
                amount,
                ""
            );
        }

        emit Deposit(msg.sender, collateralToken, conditionId, amount);

        // 2.  CTFExchange
        if (!conditionalTokens.isApprovedForAll(msg.sender, ctfExchange)) {
            //
            //
            emit ExchangeApproved(msg.sender, ctfExchange);
        }
    }

    function isApprovedForExchange(address user) external view returns (bool) {
        return conditionalTokens.isApprovedForAll(user, ctfExchange);
    }

    function getUserBalances(
        address user,
        IERC20 collateralToken,
        bytes32 conditionId
    ) external view returns (uint256[] memory balances) {
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        balances = new uint256[](outcomeSlotCount);

        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            uint256 positionId = conditionalTokens.getPositionId(collateralToken, collectionId);
            balances[i] = conditionalTokens.balanceOf(user, positionId);
        }

        return balances;
    }

    function getMarketPositionIds(
        IERC20 collateralToken,
        bytes32 conditionId
    ) external view returns (uint256[] memory positionIds) {
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        positionIds = new uint256[](outcomeSlotCount);

        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(
                bytes32(0),
                conditionId,
                1 << i
            );
            positionIds[i] = conditionalTokens.getPositionId(collateralToken, collectionId);
        }

        return positionIds;
    }

    function setCTFExchange(address newExchange) external onlyOwner {
        require(newExchange != address(0), "Invalid exchange address");
        ctfExchange = newExchange;
    }

    function _getFullPartition(uint256 outcomeSlotCount) internal pure returns (uint256[] memory) {
        uint256[] memory partition = new uint256[](outcomeSlotCount);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            partition[i] = 1 << i;
        }
        return partition;
    }

    // ==================== ERC1155  ====================

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ====================  ====================

    function emergencyWithdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
    }

    function emergencyWithdrawERC1155(uint256 tokenId, uint256 amount) external onlyOwner {
        conditionalTokens.safeTransferFrom(address(this), owner(), tokenId, amount, "");
    }
}
