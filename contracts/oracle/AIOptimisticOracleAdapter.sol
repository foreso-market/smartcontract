// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IConditionalTokens.sol";
import "../interfaces/IOracleAdapter.sol";

contract AIOptimisticOracleAdapter is IOracleAdapter, AccessControl, ReentrancyGuard, Pausable {

    IConditionalTokens public immutable conditionalTokens;

    enum EventType {
        OffchainVerifiable, // 0:
        Subjective,         // 1: /
        Reserved1,          // 2:
        Reserved2           // 3:
    }

    enum ProposalStatus {
        None,           //
        Proposed,       //
        Challenged,     //
        Finalized       //
    }

    struct EventQuestionConfig {
        EventType eventType;          //
        string eventSourceUrl;        //  URL
        string eventId;               //  ID
        uint256 outcomeCount;         //  2Yes/No
        bool allowEarlyClose;         //
    }

    struct Proposal {
        uint256[] proposedPayouts;    //
        address proposer;             //
        uint256 proposalTime;         //
        string evidenceURI;           //  URIIPFS hash  URL
        ProposalStatus status;        //
        address challenger;           //
        string challengeReason;       //
        uint256 challengeTime;        //
        uint256 challengePeriod;      //
    }

    struct EventQuestion {
        bytes32 questionId;
        bytes32 conditionId;
        string questionText;
        uint256 endTime;              //
        uint256 resolutionTime;       //
        QuestionStatus status;
        EventQuestionConfig config;
        Proposal proposal;            //
        uint256[] finalPayouts;       //
    }

    mapping(bytes32 => EventQuestion) public questions;

    bytes32[] public allQuestionIds;

    bytes32[] public awaitingProposal;
    mapping(bytes32 => bool) public isAwaitingProposal;
    mapping(bytes32 => uint256) public awaitingProposalIndex;

    bytes32[] public awaitingFinalization;
    mapping(bytes32 => bool) public isAwaitingFinalization;
    mapping(bytes32 => uint256) public awaitingFinalizationIndex;

    bytes32[] public disputedQuestions;
    mapping(bytes32 => bool) public isDisputed;
    mapping(bytes32 => uint256) public disputedIndex;

    uint256 public challengePeriod = 2 hours;

    uint256 public challengeBond = 0.1 ether;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");       //
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");       // AI
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");   //
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");         //

    bool public openChallenge = true;

    uint256 public lockedBonds;

    /// ==========  ==========

    event EventQuestionRegistered(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        EventType eventType,
        string eventSourceUrl,
        uint256 endTime
    );

    event OutcomeProposed(
        bytes32 indexed questionId,
        address indexed proposer,
        uint256[] proposedPayouts,
        string evidenceURI,
        uint256 challengeDeadline
    );

    event ProposalChallenged(
        bytes32 indexed questionId,
        address indexed challenger,
        string reason
    );

    event QuestionFinalized(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        uint256[] finalPayouts,
        bool wasDisputed
    );

    event ArbitrationResolved(
        bytes32 indexed questionId,
        address indexed arbiter,
        uint256[] finalPayouts
    );

    event ChallengePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event ChallengeBondUpdated(uint256 oldBond, uint256 newBond);

    /// ==========  ==========

    error QuestionNotFound();
    error QuestionAlreadyExists();
    error QuestionNotEnded();
    error QuestionAlreadyResolved();
    error InvalidEndTime();
    error AlreadyProposed();
    error NoProposal();
    error ChallengePeriodNotEnded();
    error ChallengePeriodEnded();
    error AlreadyChallenged();
    error NotDisputed();
    error InvalidPayouts();
    error InsufficientBond();
    error Unauthorized();

    /// ==========  ==========

    constructor(address conditionalTokens_) {
        require(conditionalTokens_ != address(0), "Invalid CT address");
        conditionalTokens = IConditionalTokens(conditionalTokens_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(CHALLENGER_ROLE, msg.sender);
        _grantRole(ARBITER_ROLE, msg.sender);
    }

    /// ==========  ==========

    function registerQuestion(
        bytes32 questionId,
        bytes32 conditionId,
        string calldata questionText,
        uint256 endTime,
        bytes calldata config
    ) external override onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (questions[questionId].endTime != 0) revert QuestionAlreadyExists();
        if (endTime <= block.timestamp) revert InvalidEndTime();

        //
        EventQuestionConfig memory questionConfig = abi.decode(config, (EventQuestionConfig));

        //
        questions[questionId] = EventQuestion({
            questionId: questionId,
            conditionId: conditionId,
            questionText: questionText,
            endTime: endTime,
            resolutionTime: 0,
            status: QuestionStatus.Registered,
            config: questionConfig,
            proposal: Proposal({
                proposedPayouts: new uint256[](0),
                proposer: address(0),
                proposalTime: 0,
                evidenceURI: "",
                status: ProposalStatus.None,
                challenger: address(0),
                challengeReason: "",
                challengeTime: 0,
                challengePeriod: 0
            }),
            finalPayouts: new uint256[](0)
        });

        allQuestionIds.push(questionId);

        emit QuestionRegistered(questionId, conditionId, endTime);
        emit EventQuestionRegistered(
            questionId,
            conditionId,
            questionConfig.eventType,
            questionConfig.eventSourceUrl,
            endTime
        );
    }

    function proposeOutcome(
        bytes32 questionId,
        uint256[] calldata proposedPayouts,
        string calldata evidenceURI,
        uint256 _challengePeriod
    ) external onlyRole(PROPOSER_ROLE) whenNotPaused {
        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        //  endTime
        if (!question.config.allowEarlyClose && block.timestamp < question.endTime) revert QuestionNotEnded();
        if (question.proposal.status != ProposalStatus.None) revert AlreadyProposed();

        //  payouts
        _validatePayouts(proposedPayouts, question.config.outcomeCount);

        //  0
        uint256 effectivePeriod = _challengePeriod > 0 ? _challengePeriod : challengePeriod;

        //
        question.proposal = Proposal({
            proposedPayouts: proposedPayouts,
            proposer: msg.sender,
            proposalTime: block.timestamp,
            evidenceURI: evidenceURI,
            status: ProposalStatus.Proposed,
            challenger: address(0),
            challengeReason: "",
            challengeTime: 0,
            challengePeriod: effectivePeriod
        });

        question.status = QuestionStatus.Pending;

        //
        _removeFromAwaitingProposal(questionId);

        //
        _addToAwaitingFinalization(questionId);

        uint256 challengeDeadline = block.timestamp + effectivePeriod;

        emit OutcomeProposed(
            questionId,
            msg.sender,
            proposedPayouts,
            evidenceURI,
            challengeDeadline
        );
    }

    function challenge(
        bytes32 questionId,
        string calldata reason
    ) external payable nonReentrant whenNotPaused {
        //
        if (!openChallenge && !hasRole(CHALLENGER_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.proposal.status == ProposalStatus.Challenged) revert AlreadyChallenged();
        if (question.proposal.status != ProposalStatus.Proposed) revert NoProposal();

        //
        if (block.timestamp > question.proposal.proposalTime + question.proposal.challengePeriod) {
            revert ChallengePeriodEnded();
        }

        //
        if (msg.value < challengeBond) revert InsufficientBond();

        //  challengeBond  ETH
        lockedBonds += challengeBond;
        uint256 excess = msg.value - challengeBond;
        if (excess > 0) {
            (bool refunded, ) = msg.sender.call{value: excess}("");
            require(refunded, "ETH refund failed");
        }

        //
        question.proposal.status = ProposalStatus.Challenged;
        question.proposal.challenger = msg.sender;
        question.proposal.challengeReason = reason;
        question.proposal.challengeTime = block.timestamp;

        //
        _removeFromAwaitingFinalization(questionId);

        //
        _addToDisputed(questionId);

        emit ProposalChallenged(questionId, msg.sender, reason);
    }

    function finalize(bytes32 questionId) external nonReentrant whenNotPaused {
        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (question.proposal.status != ProposalStatus.Proposed) revert NoProposal();

        //
        if (block.timestamp <= question.proposal.proposalTime + question.proposal.challengePeriod) {
            revert ChallengePeriodNotEnded();
        }

        //  payouts
        uint256[] memory finalPayouts = question.proposal.proposedPayouts;

        //
        question.proposal.status = ProposalStatus.Finalized;
        question.status = QuestionStatus.Resolved;
        question.resolutionTime = block.timestamp;
        question.finalPayouts = finalPayouts;

        //
        _removeFromAwaitingFinalization(questionId);

        //  ConditionalTokens
        conditionalTokens.reportPayouts(questionId, finalPayouts);

        emit QuestionFinalized(questionId, question.conditionId, finalPayouts, false);
        emit QuestionResolved(questionId, question.conditionId, finalPayouts);
    }

    function arbitrate(
        bytes32 questionId,
        uint256[] calldata finalPayouts
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (question.proposal.status != ProposalStatus.Challenged) revert NotDisputed();

        //  payouts
        _validatePayouts(finalPayouts, question.config.outcomeCount);

        //
        question.proposal.status = ProposalStatus.Finalized;
        question.status = QuestionStatus.Resolved;
        question.resolutionTime = block.timestamp;
        question.finalPayouts = finalPayouts;

        //
        _removeFromDisputed(questionId);

        //  ConditionalTokens
        conditionalTokens.reportPayouts(questionId, finalPayouts);

        //
        if (question.proposal.challenger != address(0)) {
            uint256 bondAmount = challengeBond > lockedBonds ? lockedBonds : challengeBond;
            if (bondAmount > 0) {
                lockedBonds -= bondAmount;
                bool challengerCorrect = !_payoutsEqual(finalPayouts, question.proposal.proposedPayouts);
                if (challengerCorrect) {
                    (bool success, ) = payable(question.proposal.challenger).call{value: bondAmount}("");
                    require(success, "ETH transfer failed");
                } else {
                    (bool success, ) = payable(question.proposal.proposer).call{value: bondAmount}("");
                    require(success, "ETH transfer failed");
                }
            }
        }

        emit ArbitrationResolved(questionId, msg.sender, finalPayouts);
        emit QuestionFinalized(questionId, question.conditionId, finalPayouts, true);
        emit QuestionResolved(questionId, question.conditionId, finalPayouts);
    }

    function emergencyResolve(
        bytes32 questionId,
        uint256[] calldata finalPayouts
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();

        //  payouts
        _validatePayouts(finalPayouts, question.config.outcomeCount);

        //
        question.proposal.status = ProposalStatus.Finalized;
        question.status = QuestionStatus.Resolved;
        question.resolutionTime = block.timestamp;
        question.finalPayouts = finalPayouts;

        //
        _removeFromAwaitingProposal(questionId);
        _removeFromAwaitingFinalization(questionId);
        _removeFromDisputed(questionId);

        //  ConditionalTokens
        conditionalTokens.reportPayouts(questionId, finalPayouts);

        emit QuestionFinalized(questionId, question.conditionId, finalPayouts, false);
        emit QuestionResolved(questionId, question.conditionId, finalPayouts);
    }

    function resolve(bytes32 questionId) external override {
        //
        EventQuestion storage question = questions[questionId];
        if (question.proposal.status == ProposalStatus.Challenged) {
            revert NotDisputed(); //  arbitrate
        }

        //  finalize
        this.finalize(questionId);
    }

    function cancelQuestion(
        bytes32 questionId,
        string calldata reason
    ) external override onlyRole(OPERATOR_ROLE) {
        EventQuestion storage question = questions[questionId];

        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (question.status == QuestionStatus.Cancelled) revert QuestionAlreadyResolved();

        //
        question.status = QuestionStatus.Cancelled;
        question.resolutionTime = block.timestamp;

        //
        if (question.proposal.challenger != address(0) && challengeBond > 0) {
            uint256 bondAmount = challengeBond > lockedBonds ? lockedBonds : challengeBond;
            if (bondAmount > 0) {
                lockedBonds -= bondAmount;
                (bool success, ) = payable(question.proposal.challenger).call{value: bondAmount}("");
                require(success, "ETH transfer failed");
            }
        }

        //
        uint256 outcomeCount = question.config.outcomeCount;
        if (outcomeCount < 2) outcomeCount = 2;
        uint256[] memory refundPayouts = new uint256[](outcomeCount);
        for (uint256 i = 0; i < outcomeCount; i++) {
            refundPayouts[i] = 1;
        }
        question.finalPayouts = refundPayouts;

        //
        _removeFromAwaitingProposal(questionId);
        _removeFromAwaitingFinalization(questionId);
        _removeFromDisputed(questionId);

        //  ConditionalTokens ()
        conditionalTokens.reportPayouts(questionId, refundPayouts);

        emit QuestionCancelled(questionId, question.conditionId, msg.sender, reason);
    }

    /// ==========  ==========

    function getQuestionStatus(bytes32 questionId) external view override returns (QuestionStatus) {
        return questions[questionId].status;
    }

    function isResolved(bytes32 questionId) external view override returns (bool) {
        return questions[questionId].status == QuestionStatus.Resolved;
    }

    function getDisputePeriod() external view override returns (uint256) {
        return challengePeriod;
    }

    function getQuestion(bytes32 questionId) external view returns (EventQuestion memory) {
        return questions[questionId];
    }

    function getProposal(bytes32 questionId) external view returns (Proposal memory) {
        return questions[questionId].proposal;
    }

    function getQuestionConfig(bytes32 questionId) external view returns (EventQuestionConfig memory) {
        return questions[questionId].config;
    }

    function getChallengeDeadline(bytes32 questionId) external view returns (uint256) {
        EventQuestion storage question = questions[questionId];
        if (question.proposal.proposalTime == 0) return 0;
        return question.proposal.proposalTime + question.proposal.challengePeriod;
    }

    function canFinalize(bytes32 questionId) external view returns (bool) {
        EventQuestion storage question = questions[questionId];

        return question.endTime != 0
            && question.status != QuestionStatus.Resolved
            && question.proposal.status == ProposalStatus.Proposed
            && block.timestamp > question.proposal.proposalTime + question.proposal.challengePeriod;
    }

    function getFinalizableQuestions() external view returns (bytes32[] memory) {
        uint256 count = 0;

        for (uint256 i = 0; i < awaitingFinalization.length; i++) {
            bytes32 qId = awaitingFinalization[i];
            EventQuestion storage question = questions[qId];

            if (question.proposal.status == ProposalStatus.Proposed &&
                block.timestamp > question.proposal.proposalTime + question.proposal.challengePeriod) {
                count++;
            }
        }

        bytes32[] memory result = new bytes32[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < awaitingFinalization.length; i++) {
            bytes32 qId = awaitingFinalization[i];
            EventQuestion storage question = questions[qId];

            if (question.proposal.status == ProposalStatus.Proposed &&
                block.timestamp > question.proposal.proposalTime + question.proposal.challengePeriod) {
                result[index] = qId;
                index++;
            }
        }

        return result;
    }

    function getAwaitingProposalQuestions() external view returns (bytes32[] memory) {
        return awaitingProposal;
    }

    function getDisputedQuestions() external view returns (bytes32[] memory) {
        return disputedQuestions;
    }

    function getQuestionCount() external view returns (uint256) {
        return allQuestionIds.length;
    }

    /// ==========  ==========

    function _validatePayouts(uint256[] memory payouts, uint256 outcomeCount) internal pure {
        if (outcomeCount == 0) outcomeCount = 2; //
        if (payouts.length != outcomeCount) revert InvalidPayouts();

        uint256 sum = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            sum += payouts[i];
        }
        if (sum == 0) revert InvalidPayouts();
    }

    function _payoutsEqual(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    //
    function _addToAwaitingProposal(bytes32 questionId) internal {
        if (!isAwaitingProposal[questionId]) {
            awaitingProposalIndex[questionId] = awaitingProposal.length;
            awaitingProposal.push(questionId);
            isAwaitingProposal[questionId] = true;
        }
    }

    function _removeFromAwaitingProposal(bytes32 questionId) internal {
        if (isAwaitingProposal[questionId]) {
            uint256 index = awaitingProposalIndex[questionId];
            uint256 lastIndex = awaitingProposal.length - 1;

            if (index != lastIndex) {
                bytes32 lastId = awaitingProposal[lastIndex];
                awaitingProposal[index] = lastId;
                awaitingProposalIndex[lastId] = index;
            }

            awaitingProposal.pop();
            delete awaitingProposalIndex[questionId];
            isAwaitingProposal[questionId] = false;
        }
    }

    function _addToAwaitingFinalization(bytes32 questionId) internal {
        if (!isAwaitingFinalization[questionId]) {
            awaitingFinalizationIndex[questionId] = awaitingFinalization.length;
            awaitingFinalization.push(questionId);
            isAwaitingFinalization[questionId] = true;
        }
    }

    function _removeFromAwaitingFinalization(bytes32 questionId) internal {
        if (isAwaitingFinalization[questionId]) {
            uint256 index = awaitingFinalizationIndex[questionId];
            uint256 lastIndex = awaitingFinalization.length - 1;

            if (index != lastIndex) {
                bytes32 lastId = awaitingFinalization[lastIndex];
                awaitingFinalization[index] = lastId;
                awaitingFinalizationIndex[lastId] = index;
            }

            awaitingFinalization.pop();
            delete awaitingFinalizationIndex[questionId];
            isAwaitingFinalization[questionId] = false;
        }
    }

    function _addToDisputed(bytes32 questionId) internal {
        if (!isDisputed[questionId]) {
            disputedIndex[questionId] = disputedQuestions.length;
            disputedQuestions.push(questionId);
            isDisputed[questionId] = true;
        }
    }

    function _removeFromDisputed(bytes32 questionId) internal {
        if (isDisputed[questionId]) {
            uint256 index = disputedIndex[questionId];
            uint256 lastIndex = disputedQuestions.length - 1;

            if (index != lastIndex) {
                bytes32 lastId = disputedQuestions[lastIndex];
                disputedQuestions[index] = lastId;
                disputedIndex[lastId] = index;
            }

            disputedQuestions.pop();
            delete disputedIndex[questionId];
            isDisputed[questionId] = false;
        }
    }

    /// ==========  ==========

    function setChallengePeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldPeriod = challengePeriod;
        challengePeriod = newPeriod;
        emit ChallengePeriodUpdated(oldPeriod, newPeriod);
    }

    function setChallengeBond(uint256 newBond) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldBond = challengeBond;
        challengeBond = newBond;
        emit ChallengeBondUpdated(oldBond, newBond);
    }

    function setOpenChallenge(bool open) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openChallenge = open;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function withdraw() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 withdrawable = address(this).balance - lockedBonds;
        require(withdrawable > 0, "Nothing to withdraw");
        (bool success, ) = payable(msg.sender).call{value: withdrawable}("");
        require(success, "ETH transfer failed");
    }

    function markAwaitingProposal(bytes32 questionId) external onlyRole(OPERATOR_ROLE) {
        EventQuestion storage question = questions[questionId];
        if (question.endTime == 0) revert QuestionNotFound();
        if (question.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (question.status == QuestionStatus.Cancelled) revert QuestionAlreadyResolved();
        if (block.timestamp < question.endTime) revert QuestionNotEnded();
        if (question.proposal.status != ProposalStatus.None) revert AlreadyProposed();

        _addToAwaitingProposal(questionId);
    }

    receive() external payable {}
}
