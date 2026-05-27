// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IOracleAdapter {
    enum QuestionStatus {
        None,           //
        Registered,     //
        Pending,        //
        Resolved,       //
        Cancelled       //
    }

    event QuestionRegistered(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        uint256 endTime
    );

    event QuestionResolved(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        uint256[] payouts
    );

    event QuestionCancelled(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        address indexed cancelledBy,
        string reason
    );

    function registerQuestion(
        bytes32 questionId,
        bytes32 conditionId,
        string calldata questionText,
        uint256 endTime,
        bytes calldata config
    ) external;

    function resolve(bytes32 questionId) external;

    function getQuestionStatus(bytes32 questionId) external view returns (QuestionStatus);

    function isResolved(bytes32 questionId) external view returns (bool);

    function cancelQuestion(bytes32 questionId, string calldata reason) external;

    function getDisputePeriod() external view returns (uint256);
}
