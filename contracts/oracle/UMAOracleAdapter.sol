// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IConditionalTokens.sol";
import "../interfaces/IOracleAdapter.sol";

contract UMAOracleAdapter is IOracleAdapter, AccessControl, ReentrancyGuard, Pausable {

    IConditionalTokens public immutable conditionalTokens;

    enum ProposalStatus {
        None,               //
        Proposed,           //
        Disputed,           //
        VotingComplete,     //
        Settled             //
    }

    enum VoteSide {
        ForProposal,        //
        ForDispute          //
    }

    struct Proposal {
        uint256[] proposedPayouts;    //
        address proposer;             //
        uint256 proposalTime;         //
        uint256 bond;                 //
        string evidenceURI;           //  URI
        ProposalStatus status;        //
    }

    struct Dispute {
        address challenger;           //
        uint256[] counterPayouts;     //
        uint256 bond;                 //
        string reason;                //
        uint256 disputeTime;          //
        //
        uint256 votesForProposal;     //
        uint256 votesForDispute;      //
        uint256 votingDeadline;       //
        bool settled;                 //
    }

    struct Vote {
        VoteSide side;
        uint256 amount;               //
        bool claimed;                 //
    }

    struct OptimisticQuestion {
        bytes32 questionId;
        bytes32 conditionId;
        string questionText;
        uint256 endTime;              //
        uint256 outcomeCount;         //
        uint256 resolutionTime;       //
        QuestionStatus status;
        Proposal proposal;            //
        Dispute dispute;              //
        uint256[] finalPayouts;       //
    }

    mapping(bytes32 => OptimisticQuestion) public questions;

    mapping(bytes32 => mapping(address => Vote)) public votes;

    bytes32[] public allQuestionIds;

    // ==========  ==========

    uint256 public proposalBond = 0.01 ether;

    uint256 public disputeBond = 0.01 ether;

    uint256 public disputePeriod = 4 hours;

    uint256 public votingPeriod = 48 hours;

    uint256 public quorumAmount = 0.1 ether;

    uint256 public minVoteStake = 0.001 ether;

    // ==========  ==========

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // :  ARBITER / ADMIN_RESOLVE  —

    // ==========  ==========

    event QuestionRegisteredWithConfig(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        uint256 endTime,
        uint256 outcomeCount
    );

    event OutcomeProposed(
        bytes32 indexed questionId,
        address indexed proposer,
        uint256[] proposedPayouts,
        uint256 bond,
        string evidenceURI,
        uint256 disputeDeadline
    );

    event ProposalDisputed(
        bytes32 indexed questionId,
        address indexed challenger,
        uint256[] counterPayouts,
        uint256 bond,
        string reason,
        uint256 votingDeadline
    );

    event VoteCast(
        bytes32 indexed questionId,
        address indexed voter,
        VoteSide side,
        uint256 amount
    );

    event QuestionSettled(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        uint256[] finalPayouts,
        bool wasDisputed,
        string settlementType         // "optimistic" | "vote_majority" | "vote_quorum_default"
    );

    event BondClaimed(
        bytes32 indexed questionId,
        address indexed claimer,
        uint256 amount
    );

    event VoteRewardClaimed(
        bytes32 indexed questionId,
        address indexed voter,
        uint256 reward
    );

    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);

    // ==========  ==========

    error QuestionNotFound();
    error QuestionAlreadyExists();
    error QuestionNotEnded();
    error QuestionAlreadyResolved();
    error InvalidEndTime();
    error InvalidPayouts();
    error ProposalAlreadyExists();
    error NoProposal();
    error AlreadyDisputed();
    error DisputePeriodNotEnded();
    error DisputePeriodEnded();
    error VotingNotEnded();
    error VotingEnded();
    error NotDisputed();
    error AlreadySettled();
    error InsufficientBond();
    error InsufficientVoteStake();
    error AlreadyVoted();
    error NothingToClaim();

    // ==========  ==========

    constructor(address conditionalTokens_) {
        require(conditionalTokens_ != address(0), "Invalid CT address");
        conditionalTokens = IConditionalTokens(conditionalTokens_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // ================================================================
    //
    // ================================================================

    function registerQuestion(
        bytes32 questionId,
        bytes32 conditionId,
        string calldata questionText,
        uint256 endTime,
        bytes calldata config
    ) external override onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (questions[questionId].endTime != 0) revert QuestionAlreadyExists();
        if (endTime <= block.timestamp) revert InvalidEndTime();

        uint256 outcomeCount = abi.decode(config, (uint256));
        if (outcomeCount < 2) outcomeCount = 2;

        questions[questionId] = OptimisticQuestion({
            questionId: questionId,
            conditionId: conditionId,
            questionText: questionText,
            endTime: endTime,
            outcomeCount: outcomeCount,
            resolutionTime: 0,
            status: QuestionStatus.Registered,
            proposal: Proposal({
                proposedPayouts: new uint256[](0),
                proposer: address(0),
                proposalTime: 0,
                bond: 0,
                evidenceURI: "",
                status: ProposalStatus.None
            }),
            dispute: Dispute({
                challenger: address(0),
                counterPayouts: new uint256[](0),
                bond: 0,
                reason: "",
                disputeTime: 0,
                votesForProposal: 0,
                votesForDispute: 0,
                votingDeadline: 0,
                settled: false
            }),
            finalPayouts: new uint256[](0)
        });

        allQuestionIds.push(questionId);

        emit QuestionRegistered(questionId, conditionId, endTime);
        emit QuestionRegisteredWithConfig(questionId, conditionId, endTime, outcomeCount);
    }

    function propose(
        bytes32 questionId,
        uint256[] calldata proposedPayouts,
        string calldata evidenceURI
    ) external payable whenNotPaused {
        OptimisticQuestion storage q = questions[questionId];

        if (q.endTime == 0) revert QuestionNotFound();
        if (q.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (block.timestamp < q.endTime) revert QuestionNotEnded();
        if (q.proposal.status != ProposalStatus.None) revert ProposalAlreadyExists();
        if (msg.value < proposalBond) revert InsufficientBond();

        _validatePayouts(proposedPayouts, q.outcomeCount);

        q.proposal = Proposal({
            proposedPayouts: proposedPayouts,
            proposer: msg.sender,
            proposalTime: block.timestamp,
            bond: msg.value,
            evidenceURI: evidenceURI,
            status: ProposalStatus.Proposed
        });

        q.status = QuestionStatus.Pending;

        uint256 deadline = block.timestamp + disputePeriod;

        emit OutcomeProposed(
            questionId,
            msg.sender,
            proposedPayouts,
            msg.value,
            evidenceURI,
            deadline
        );
    }

    function dispute(
        bytes32 questionId,
        uint256[] calldata counterPayouts,
        string calldata reason
    ) external payable whenNotPaused {
        OptimisticQuestion storage q = questions[questionId];

        if (q.endTime == 0) revert QuestionNotFound();
        if (q.proposal.status != ProposalStatus.Proposed) revert NoProposal();
        if (msg.value < disputeBond) revert InsufficientBond();

        //
        if (block.timestamp > q.proposal.proposalTime + disputePeriod) {
            revert DisputePeriodEnded();
        }

        _validatePayouts(counterPayouts, q.outcomeCount);

        //
        require(!_payoutsEqual(counterPayouts, q.proposal.proposedPayouts), "Same as proposal");

        uint256 votingDeadline = block.timestamp + votingPeriod;

        q.dispute = Dispute({
            challenger: msg.sender,
            counterPayouts: counterPayouts,
            bond: msg.value,
            reason: reason,
            disputeTime: block.timestamp,
            votesForProposal: 0,
            votesForDispute: 0,
            votingDeadline: votingDeadline,
            settled: false
        });

        q.proposal.status = ProposalStatus.Disputed;

        emit ProposalDisputed(
            questionId,
            msg.sender,
            counterPayouts,
            msg.value,
            reason,
            votingDeadline
        );
    }

    function vote(
        bytes32 questionId,
        VoteSide side
    ) external payable whenNotPaused {
        OptimisticQuestion storage q = questions[questionId];

        if (q.proposal.status != ProposalStatus.Disputed) revert NotDisputed();
        if (block.timestamp > q.dispute.votingDeadline) revert VotingEnded();
        if (msg.value < minVoteStake) revert InsufficientVoteStake();
        if (votes[questionId][msg.sender].amount > 0) revert AlreadyVoted();

        //
        require(msg.sender != q.proposal.proposer, "Proposer cannot vote");
        require(msg.sender != q.dispute.challenger, "Challenger cannot vote");

        votes[questionId][msg.sender] = Vote({
            side: side,
            amount: msg.value,
            claimed: false
        });

        if (side == VoteSide.ForProposal) {
            q.dispute.votesForProposal += msg.value;
        } else {
            q.dispute.votesForDispute += msg.value;
        }

        emit VoteCast(questionId, msg.sender, side, msg.value);
    }

    function settle(bytes32 questionId) external nonReentrant whenNotPaused {
        OptimisticQuestion storage q = questions[questionId];

        if (q.endTime == 0) revert QuestionNotFound();
        if (q.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (q.proposal.status == ProposalStatus.None) revert NoProposal();

        if (q.proposal.status == ProposalStatus.Proposed) {
            //  →
            if (block.timestamp <= q.proposal.proposalTime + disputePeriod) {
                revert DisputePeriodNotEnded();
            }
            _settleOptimistic(questionId);

        } else if (q.proposal.status == ProposalStatus.Disputed) {
            //  →
            if (block.timestamp <= q.dispute.votingDeadline) {
                revert VotingNotEnded();
            }
            _settleByVote(questionId);

        } else {
            revert AlreadySettled();
        }
    }

    function resolve(bytes32 questionId) external override {
        this.settle(questionId);
    }

    // ================================================================
    //                     &
    // ================================================================

    function claimProposerBond(bytes32 questionId) external nonReentrant {
        OptimisticQuestion storage q = questions[questionId];
        if (q.status != QuestionStatus.Resolved) revert QuestionNotFound();

        bool isWinner;
        uint256 reward;

        if (q.dispute.challenger == address(0)) {
            //
            require(msg.sender == q.proposal.proposer, "Not proposer");
            require(q.proposal.bond > 0, "Already claimed");
            reward = q.proposal.bond;
            q.proposal.bond = 0;
            isWinner = true;
        } else {
            //
            bool proposerWon = _payoutsEqual(q.finalPayouts, q.proposal.proposedPayouts);

            if (proposerWon && msg.sender == q.proposal.proposer) {
                //  +
                require(q.proposal.bond > 0 || q.dispute.bond > 0, "Already claimed");
                reward = q.proposal.bond + q.dispute.bond;
                q.proposal.bond = 0;
                q.dispute.bond = 0;
                isWinner = true;
            } else if (!proposerWon && msg.sender == q.dispute.challenger) {
                //  +
                require(q.proposal.bond > 0 || q.dispute.bond > 0, "Already claimed");
                reward = q.proposal.bond + q.dispute.bond;
                q.proposal.bond = 0;
                q.dispute.bond = 0;
                isWinner = true;
            }
        }

        if (!isWinner || reward == 0) revert NothingToClaim();

        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "ETH transfer failed");

        emit BondClaimed(questionId, msg.sender, reward);
    }

    function claimVoteReward(bytes32 questionId) external nonReentrant {
        OptimisticQuestion storage q = questions[questionId];
        if (q.status != QuestionStatus.Resolved && q.status != QuestionStatus.Cancelled) revert QuestionNotFound();
        if (q.dispute.challenger == address(0)) revert NotDisputed();

        Vote storage v = votes[questionId][msg.sender];
        if (v.amount == 0) revert NothingToClaim();
        if (v.claimed) revert NothingToClaim();

        // /
        v.claimed = true;
        uint256 payout = v.amount;

        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "ETH transfer failed");

        emit VoteRewardClaimed(questionId, msg.sender, payout);
    }

    // ================================================================
    //
    // ================================================================

    function getQuestionStatus(bytes32 questionId) external view override returns (QuestionStatus) {
        return questions[questionId].status;
    }

    function isResolved(bytes32 questionId) external view override returns (bool) {
        return questions[questionId].status == QuestionStatus.Resolved;
    }

    function getDisputePeriod() external view override returns (uint256) {
        return disputePeriod;
    }

    function getQuestion(bytes32 questionId) external view returns (OptimisticQuestion memory) {
        return questions[questionId];
    }

    function getProposal(bytes32 questionId) external view returns (Proposal memory) {
        return questions[questionId].proposal;
    }

    function getDispute(bytes32 questionId) external view returns (Dispute memory) {
        return questions[questionId].dispute;
    }

    function getVote(bytes32 questionId, address voter) external view returns (Vote memory) {
        return votes[questionId][voter];
    }

    function getQuestionCount() external view returns (uint256) {
        return allQuestionIds.length;
    }

    function getDisputeDeadline(bytes32 questionId) external view returns (uint256) {
        OptimisticQuestion storage q = questions[questionId];
        if (q.proposal.proposalTime == 0) return 0;
        return q.proposal.proposalTime + disputePeriod;
    }

    function getVotingDeadline(bytes32 questionId) external view returns (uint256) {
        return questions[questionId].dispute.votingDeadline;
    }

    function canSettle(bytes32 questionId) external view returns (bool, string memory reason) {
        OptimisticQuestion storage q = questions[questionId];

        if (q.endTime == 0) return (false, "not found");
        if (q.status == QuestionStatus.Resolved) return (false, "already resolved");
        if (q.proposal.status == ProposalStatus.None) return (false, "no proposal");

        if (q.proposal.status == ProposalStatus.Proposed) {
            if (block.timestamp > q.proposal.proposalTime + disputePeriod) {
                return (true, "optimistic - dispute period ended");
            }
            return (false, "dispute period not ended");
        }

        if (q.proposal.status == ProposalStatus.Disputed) {
            if (block.timestamp > q.dispute.votingDeadline) {
                return (true, "vote - voting period ended");
            }
            return (false, "voting period not ended");
        }

        return (false, "already settled");
    }

    function getVotingStatus(bytes32 questionId) external view returns (
        uint256 forProposal,
        uint256 forDispute,
        uint256 deadline,
        bool quorumReached
    ) {
        Dispute storage d = questions[questionId].dispute;
        forProposal = d.votesForProposal;
        forDispute = d.votesForDispute;
        deadline = d.votingDeadline;
        quorumReached = (forProposal + forDispute) >= quorumAmount;
    }

    // ================================================================
    //
    // ================================================================

    function _settleOptimistic(bytes32 questionId) internal {
        OptimisticQuestion storage q = questions[questionId];

        q.proposal.status = ProposalStatus.Settled;
        q.status = QuestionStatus.Resolved;
        q.resolutionTime = block.timestamp;
        q.finalPayouts = q.proposal.proposedPayouts;

        conditionalTokens.reportPayouts(questionId, q.finalPayouts);

        emit QuestionSettled(questionId, q.conditionId, q.finalPayouts, false, "optimistic");
        emit QuestionResolved(questionId, q.conditionId, q.finalPayouts);
    }

    function _settleByVote(bytes32 questionId) internal {
        OptimisticQuestion storage q = questions[questionId];

        uint256 totalVotes = q.dispute.votesForProposal + q.dispute.votesForDispute;
        string memory settlementType;

        if (totalVotes < quorumAmount) {
            //  →
            q.finalPayouts = q.proposal.proposedPayouts;
            settlementType = "vote_quorum_default";
        } else if (q.dispute.votesForProposal >= q.dispute.votesForDispute) {
            //
            q.finalPayouts = q.proposal.proposedPayouts;
            settlementType = "vote_majority";
        } else {
            //
            q.finalPayouts = q.dispute.counterPayouts;
            settlementType = "vote_majority";
        }

        q.proposal.status = ProposalStatus.Settled;
        q.dispute.settled = true;
        q.status = QuestionStatus.Resolved;
        q.resolutionTime = block.timestamp;

        conditionalTokens.reportPayouts(questionId, q.finalPayouts);

        emit QuestionSettled(questionId, q.conditionId, q.finalPayouts, true, settlementType);
        emit QuestionResolved(questionId, q.conditionId, q.finalPayouts);
    }

    function _validatePayouts(uint256[] memory payouts, uint256 outcomeCount) internal pure {
        if (outcomeCount == 0) outcomeCount = 2;
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

    function cancelQuestion(
        bytes32 questionId,
        string calldata reason
    ) external override onlyRole(OPERATOR_ROLE) {
        OptimisticQuestion storage q = questions[questionId];

        if (q.endTime == 0) revert QuestionNotFound();
        if (q.status == QuestionStatus.Resolved) revert QuestionAlreadyResolved();
        if (q.status == QuestionStatus.Cancelled) revert QuestionAlreadyResolved();

        q.status = QuestionStatus.Cancelled;
        q.resolutionTime = block.timestamp;

        //
        if (q.proposal.bond > 0 && q.proposal.proposer != address(0)) {
            uint256 proposerBond = q.proposal.bond;
            q.proposal.bond = 0;
            (bool s1, ) = payable(q.proposal.proposer).call{value: proposerBond}("");
            require(s1, "ETH transfer failed");
        }

        //
        if (q.dispute.bond > 0 && q.dispute.challenger != address(0)) {
            uint256 challengerBond = q.dispute.bond;
            q.dispute.bond = 0;
            (bool s2, ) = payable(q.dispute.challenger).call{value: challengerBond}("");
            require(s2, "ETH transfer failed");
        }

        uint256 count = q.outcomeCount;
        if (count < 2) count = 2;
        uint256[] memory refundPayouts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            refundPayouts[i] = 1;
        }
        q.finalPayouts = refundPayouts;

        conditionalTokens.reportPayouts(questionId, refundPayouts);

        emit QuestionCancelled(questionId, q.conditionId, msg.sender, reason);
    }

    // ================================================================
    //
    // ================================================================

    function setProposalBond(uint256 newBond) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = proposalBond;
        proposalBond = newBond;
        emit ConfigUpdated("proposalBond", old, newBond);
    }

    function setDisputeBond(uint256 newBond) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = disputeBond;
        disputeBond = newBond;
        emit ConfigUpdated("disputeBond", old, newBond);
    }

    function setDisputePeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPeriod >= 1 hours, "Too short");
        uint256 old = disputePeriod;
        disputePeriod = newPeriod;
        emit ConfigUpdated("disputePeriod", old, newPeriod);
    }

    function setVotingPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPeriod >= 12 hours, "Too short");
        uint256 old = votingPeriod;
        votingPeriod = newPeriod;
        emit ConfigUpdated("votingPeriod", old, newPeriod);
    }

    function setQuorumAmount(uint256 newQuorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = quorumAmount;
        quorumAmount = newQuorum;
        emit ConfigUpdated("quorumAmount", old, newQuorum);
    }

    function setMinVoteStake(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = minVoteStake;
        minVoteStake = newMin;
        emit ConfigUpdated("minVoteStake", old, newMin);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    receive() external payable {}
}
