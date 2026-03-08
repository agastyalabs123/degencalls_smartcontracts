// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IAccessMaster.sol";

interface IMarket {
    function resolve(uint256 winningOutcome) external;

    function outcomeCount() external view returns (uint256);
}

/**
 * @title SettlementLogic
 * @notice Creator-submitted resolution with a 24-hour dispute window.
 *
 * Flow:
 *  1. Creator calls submitCreatorResolution() and stakes ETH.
 *  2. A 24-hour dispute window opens.
 *  3. Anyone can call challengeResolution() during the window by staking
 *     a fraction of the creator's stake (challengeStakeBps, default 20%).
 *  4a. No challenge → anyone calls finalizeResolution() after the window;
 *      creator gets their stake back and the market is resolved.
 *  4b. Challenge exists → an Operator calls operatorResolveDispute():
 *      - Creator correct : challenger forfeits stake → creator keeps all.
 *      - Challenger correct : creator forfeits stake → challenger keeps all.
 */
contract SettlementLogic is ReentrancyGuard {
    IAccessMaster public immutable accessMaster;

    // ─── Dispute state ───────────────────────────────────────────────────────

    enum DisputeStatus {
        NONE, // No challenge raised
        CHALLENGED, // Operator review pending
        RESOLVED // Operator (or auto-finalize) resolved
    }

    struct ResolutionRequest {
        uint256 marketId;
        address marketContract;
        bool isResolved;
        uint256 outcome;
        uint256 submittedAt;
        uint256 resolvedAt;
        address creator;
        DisputeStatus disputeStatus;
        address challenger;
        uint256 challengerStake;
        uint256 challengedAt;
    }

    mapping(uint256 => ResolutionRequest) public resolutions;

    // ─── Config ──────────────────────────────────────────────────────────────

    uint256 public disputePeriod = 24 hours;
    uint256 public challengeStakeBps = 2000; // 20% of creator stake
    uint256 public minCreatorStake = 0.01 ether;

    // ─── Events ──────────────────────────────────────────────────────────────

    event ResolutionSubmitted(
        uint256 indexed marketId,
        address indexed creator,
        uint256 outcome
    );

    event ResolutionChallenged(
        uint256 indexed marketId,
        address indexed challenger,
        uint256 challengerStake
    );
    event ResolutionFinalized(uint256 indexed marketId, uint256 outcome);
    event DisputeResolved(
        uint256 indexed marketId,
        bool creatorCorrect,
        uint256 finalOutcome,
        address indexed operator
    );

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(
            accessMaster.isOperator(msg.sender),
            "SettlementLogic: Not operator"
        );
        _;
    }

    modifier onlyCreator() {
        require(
            accessMaster.isCreator(msg.sender),
            "SettlementLogic: Not creator"
        );
        _;
    }

    modifier onlyAdmin() {
        require(accessMaster.isAdmin(msg.sender), "SettlementLogic: Not admin");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _accessMaster) {
        require(_accessMaster != address(0), "Zero address");
        accessMaster = IAccessMaster(_accessMaster);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 1 — CREATOR SUBMITS RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Creator submits the winning outcome and stakes ETH as a bond.
     *         If unchallenged for `disputePeriod`, the resolution is final.
     * @param _marketId       Unique market identifier.
     * @param _marketContract Address of the market contract to resolve.
     * @param _outcome        Creator's claimed winning outcome index.
     */
    function submitCreatorResolution(
        uint256 _marketId,
        address _marketContract,
        uint256 _outcome
    ) external onlyCreator nonReentrant {
        require(resolutions[_marketId].submittedAt == 0, "Already submitted");
        require(_marketContract != address(0), "Zero market address");

        uint256 outcomeCount = IMarket(_marketContract).outcomeCount();
        require(_outcome < outcomeCount, "Invalid outcome");

        resolutions[_marketId] = ResolutionRequest({
            marketId: _marketId,
            marketContract: _marketContract,
            isResolved: false,
            outcome: _outcome,
            submittedAt: block.timestamp,
            resolvedAt: 0,
            creator: msg.sender,
            disputeStatus: DisputeStatus.NONE,
            challenger: address(0),
            challengerStake: 0,
            challengedAt: 0
        });

        emit ResolutionSubmitted(_marketId, msg.sender, _outcome);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 2 — CHALLENGER DISPUTES (within dispute window)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Dispute the creator's resolution during the 24-hour window.
     *         Caller must stake at least `challengeStakeBps` of creator's stake.
     *         Only one active challenge per market is allowed (first challenger wins).
     * @param _marketId Market to challenge.
     */
    function challengeResolution(
        uint256 _marketId
    ) external payable nonReentrant {
        ResolutionRequest storage req = resolutions[_marketId];
        require(req.submittedAt > 0, "Not submitted");
        require(!req.isResolved, "Already resolved");
        require(req.disputeStatus == DisputeStatus.NONE, "Already challenged");
        require(
            block.timestamp < req.submittedAt + disputePeriod,
            "Dispute window closed"
        );

        uint256 required = (IAccessMaster(accessMaster).creator_stake_amount() *
            challengeStakeBps) / 10_000;
        require(msg.value >= required, "Challenge stake too low");

        req.disputeStatus = DisputeStatus.CHALLENGED;
        req.challenger = msg.sender;
        req.challengerStake = msg.value;
        req.challengedAt = block.timestamp;

        emit ResolutionChallenged(_marketId, msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 3A — AUTO-FINALIZE (no challenge after window)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Finalize an unchallenged resolution after the dispute window.
     *         Anyone can call this. Creator's stake is returned.
     * @param _marketId Market to finalize.
     */
    function finalizeResolution(uint256 _marketId) external nonReentrant {
        ResolutionRequest storage req = resolutions[_marketId];
        require(req.submittedAt > 0, "Not submitted");
        require(!req.isResolved, "Already resolved");
        require(req.disputeStatus == DisputeStatus.NONE, "Has active dispute");
        require(
            block.timestamp >= req.submittedAt + disputePeriod,
            "Dispute window still open"
        );

        req.isResolved = true;
        req.resolvedAt = block.timestamp;
        req.disputeStatus = DisputeStatus.RESOLVED;

        IMarket(req.marketContract).resolve(req.outcome);

        emit ResolutionFinalized(_marketId, req.outcome);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 3B — OPERATOR RESOLVES DISPUTE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Operator reviews the evidence and settles a disputed resolution.
     *
     *   Creator correct  → creator keeps own stake + receives challenger's stake.
     *   Challenger correct → challenger keeps own stake + receives creator's stake.
     *                        Operator must supply the corrected outcome index.
     *
     * @param _marketId      Disputed market.
     * @param _creatorCorrect True if the creator's original answer stands.
     * @param _correctedOutcome Winning outcome when creator was wrong (ignored otherwise).
     */
    function operatorResolveDispute(
        uint256 _marketId,
        bool _creatorCorrect,
        uint256 _correctedOutcome
    ) external onlyOperator nonReentrant {
        ResolutionRequest storage req = resolutions[_marketId];
        require(
            req.disputeStatus == DisputeStatus.CHALLENGED,
            "No active dispute"
        );
        require(!req.isResolved, "Already resolved");

        req.isResolved = true;
        req.resolvedAt = block.timestamp;
        req.disputeStatus = DisputeStatus.RESOLVED;

        uint256 finalOutcome;

        if (_creatorCorrect) {
            finalOutcome = req.outcome;
            _safeTransfer(req.creator, req.challengerStake);
        } else {
            // Challenger was right → creator forfeits stake to challenger
            // Challenger gets their own stake back from this contract; creator stake from AccessMaster
            uint256 outcomeCount = IMarket(req.marketContract).outcomeCount();
            require(
                _correctedOutcome < outcomeCount,
                "Invalid corrected outcome"
            );
            finalOutcome = _correctedOutcome;
            req.outcome = _correctedOutcome;
            _safeTransfer(req.challenger, req.challengerStake);
            accessMaster.slashCreatorStake(req.creator, req.challenger);
        }

        IMarket(req.marketContract).resolve(finalOutcome);

        emit DisputeResolved(
            _marketId,
            _creatorCorrect,
            finalOutcome,
            msg.sender
        );
        emit ResolutionFinalized(_marketId, finalOutcome);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN CONFIG
    // ═══════════════════════════════════════════════════════════════════════

    function setDisputePeriod(uint256 _period) external onlyAdmin {
        require(_period >= 1 hours, "Too short");
        disputePeriod = _period;
    }

    /// @param _bps Basis points (e.g. 2000 = 20%). Must be < 10000.
    function setChallengeStakeBps(uint256 _bps) external onlyAdmin {
        require(_bps > 0 && _bps < 10_000, "Invalid bps");
        challengeStakeBps = _bps;
    }

    function setMinCreatorStake(uint256 _min) external onlyAdmin {
        minCreatorStake = _min;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    function _safeTransfer(address _to, uint256 _amount) internal {
        (bool ok, ) = _to.call{value: _amount}("");
        require(ok, "ETH transfer failed");
    }
}
