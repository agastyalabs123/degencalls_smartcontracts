// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FixedPointMath.sol";

/**
 * @title CategoricalMarket
 * @notice LMSR-based AMM for categorical (multiple outcome) prediction markets
 * @dev Collateral is native token (msg.value / payable).
 *
 *  #1 - Replaced broken Taylor-series expApprox with FixedPointMath.expUint
 *  #2 - Replaced integer Math.log2 with FixedPointMath.ln
 *  #3 - Added pool solvency guard on sells + cost-basis tracking
 *  #4 - Per-user hasClaimed + snapshotted payoutPerShare at resolution
 */
contract CategoricalMarket is ReentrancyGuard {
    using Math for uint256;
    using FixedPointMath for uint256;

    // ── Constants ──────────────────────────────────────────────────────
    uint256 public constant B_SCALING_FACTOR = 10;
    uint256 public constant PRECISION = 1e18;

    // ── Market info ────────────────────────────────────────────────────
    uint256 public immutable marketId;
    string public question;
    string[] public outcomeNames;
    uint256 public immutable outcomeCount;
    uint256 public resolutionTime;
    address public immutable creator;
    address public owner;

    // ── External contracts ─────────────────────────────────────────────
    address public settlementContract;

    // ── LMSR parameters ────────────────────────────────────────────────
    uint256 public b;
    uint256 public immutable initialB;
    uint256[] public q; // q[i] = outstanding shares for outcome i

    // ── Settlement pool ────────────────────────────────────────────────
    uint256 public settlementPool;

    // ── Share tracking ─────────────────────────────────────────────────
    mapping(address => mapping(uint256 => uint256)) public userShares;
    uint256[] public totalSharesPerOutcome;

    // ── Cost-basis tracking per user per outcome ────────────────────
    mapping(address => mapping(uint256 => uint256)) public costBasis;

    // ── Market state ───────────────────────────────────────────────────
    bool public isResolved;
    uint256 public winningOutcome;

    // ── Per-user claims + snapshotted payout ──────────────────────────
    uint256 public payoutPerShareSnapshot; // 1e12 precision
    bool public payoutSnapshotted;
    mapping(address => bool) public hasClaimed;

    // ── Prize distribution ──────────────────────────────────────────────
    address public prizeDistributor;

    // ── Emergency & cancellation ────────────────────────────────────────
    bool public paused;
    bool public isCancelled;
    uint256 public totalCostBasis;
    mapping(address => bool) public hasClaimedRefund;

    // ── Events ─────────────────────────────────────────────────────────
    event SharesPurchased(
        address indexed buyer,
        uint256 outcome,
        uint256 shares,
        uint256 cost
    );
    event SharesSold(
        address indexed seller,
        uint256 outcome,
        uint256 shares,
        uint256 refund
    );
    event MarketResolved(uint256 winningOutcome, uint256 payoutPerShare);
    event WinningsClaimed(address indexed user, uint256 payout);
    event AdaptiveBUpdated(uint256 newB);
    event MarketPaused(address indexed by);
    event MarketUnpaused(address indexed by);
    event MarketCancelled(address indexed by);
    event RefundClaimed(address indexed user, uint256 amount);

    // ── Modifiers ──────────────────────────────────────────────────────
    modifier onlySettlementContract() {
        require(msg.sender == settlementContract, "Only settlement resolver");
        _;
    }

    modifier notResolved() {
        require(!isResolved, "Market already resolved");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Market is paused");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────
    constructor(
        uint256 _marketId,
        string memory _question,
        string[] memory _outcomeNames,
        uint256 _resolutionTime,
        uint256 _initialB,
        uint256 _outcomeCount,
        address _settlementContract,
        address _creator,
        address _owner
    ) {
        marketId = _marketId;
        question = _question;
        outcomeNames = _outcomeNames;
        outcomeCount = _outcomeCount;
        resolutionTime = _resolutionTime;
        initialB = _initialB;
        b = _initialB;
        settlementContract = _settlementContract;
        creator = _creator;

        q = new uint256[](_outcomeCount);
        totalSharesPerOutcome = new uint256[](_outcomeCount);
    }

    // ═══════════════════════════════════════════════════════════════════
    //LMSR PRICING WITH PROPER FIXED-POINT MATH
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate C(q) = b * ln(sum_i(e^(q_i/b)))
     */
    function calculateCost(uint256[] memory _q) public view returns (uint256) {
        uint256 sumExp = 0;

        for (uint256 i = 0; i < outcomeCount; i++) {
            uint256 term = (_q[i] * PRECISION) / b;
            sumExp += FixedPointMath.expUint(term);
        }

        require(sumExp > 0, "Cost overflow");

        int256 lnSum = FixedPointMath.ln(sumExp);
        require(lnSum >= 0, "Negative ln");

        return (b * uint256(lnSum)) / PRECISION;
    }

    /**
     * @notice Get price (probability) for a specific outcome
     */
    function getPrice(uint256 _outcome) external view returns (uint256) {
        require(_outcome < outcomeCount, "Invalid outcome");

        uint256 sumExp = 0;
        uint256[] memory exps = new uint256[](outcomeCount);

        for (uint256 i = 0; i < outcomeCount; i++) {
            exps[i] = FixedPointMath.expUint((q[i] * PRECISION) / b);
            sumExp += exps[i];
        }

        return (exps[_outcome] * 1e6) / sumExp;
    }

    /**
     * @notice Calculate cost to buy shares of a specific outcome
     */
    function getBuyCost(
        uint256 _outcome,
        uint256 _shareAmount
    ) public view returns (uint256) {
        require(_outcome < outcomeCount, "Invalid outcome");

        uint256[] memory newQ = new uint256[](outcomeCount);
        for (uint256 i = 0; i < outcomeCount; i++) {
            newQ[i] = q[i];
        }
        newQ[_outcome] += _shareAmount;

        uint256 costBefore = calculateCost(q);
        uint256 costAfter = calculateCost(newQ);

        require(costAfter >= costBefore, "Cost calc error");
        uint256 cost = ((costAfter - costBefore) * 1e6) / PRECISION;
        return cost > 0 ? cost : 1;
    }

    /**
     * @notice Calculate refund for selling shares
     */
    function getSellRefund(
        uint256 _outcome,
        uint256 _shareAmount
    ) public view returns (uint256) {
        require(_outcome < outcomeCount, "Invalid outcome");
        require(q[_outcome] >= _shareAmount, "Insufficient liquidity");

        uint256[] memory newQ = new uint256[](outcomeCount);
        for (uint256 i = 0; i < outcomeCount; i++) {
            newQ[i] = q[i];
        }
        newQ[_outcome] -= _shareAmount;

        uint256 costBefore = calculateCost(q);
        uint256 costAfter = calculateCost(newQ);

        require(costBefore >= costAfter, "Refund calc error");
        uint256 refund = ((costBefore - costAfter) * 1e6) / PRECISION;
        return refund;
    }

    // ═══════════════════════════════════════════════════════════════════
    // TRADING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Buy shares — LMSR pricing, funds go to settlement pool
     */
    function swapIn(
        uint256 _outcome,
        uint256 _shareAmount,
        uint256 _maxCost
    ) external payable nonReentrant notResolved whenNotPaused {
        require(_outcome < outcomeCount, "Invalid outcome");
        require(_shareAmount > 0, "Amount must be > 0");

        uint256 cost = getBuyCost(_outcome, _shareAmount);
        require(cost <= _maxCost, "Slippage exceeded");
        require(msg.value >= cost, "Insufficient payment");

        // Refund excess
        if (msg.value > cost) {
            (bool refundOk, ) = payable(msg.sender).call{
                value: msg.value - cost
            }("");
            require(refundOk, "Refund failed");
        }

        q[_outcome] += _shareAmount;
        settlementPool += cost;
        userShares[msg.sender][_outcome] += _shareAmount;
        totalSharesPerOutcome[_outcome] += _shareAmount;

        costBasis[msg.sender][_outcome] += cost;
        totalCostBasis += cost;

        _updateAdaptiveB();

        emit SharesPurchased(msg.sender, _outcome, _shareAmount, cost);
    }

    /**
     * @notice Sell shares — LMSR pricing with solvency guard
     *
     *  Refund capped at min(lmsrRefund, proRataCostBasis, settlementPool)
     */
    function swapOut(
        uint256 _outcome,
        uint256 _shareAmount,
        uint256 _minRefund
    ) external nonReentrant notResolved whenNotPaused {
        require(_outcome < outcomeCount, "Invalid outcome");
        require(_shareAmount > 0, "Amount must be > 0");

        uint256 userShareBalance = userShares[msg.sender][_outcome];
        require(userShareBalance >= _shareAmount, "Insufficient shares");

        // LMSR-computed refund
        uint256 lmsrRefund = getSellRefund(_outcome, _shareAmount);

        // Cap refund for solvency
        uint256 userCostBasis = costBasis[msg.sender][_outcome];
        uint256 proRataCostBasis = (userCostBasis * _shareAmount) /
            userShareBalance;
        uint256 refund = Math.min(lmsrRefund, proRataCostBasis);
        refund = Math.min(refund, settlementPool);

        require(refund >= _minRefund, "Slippage exceeded");

        // Update state before transfer (CEI)
        userShares[msg.sender][_outcome] -= _shareAmount;
        totalSharesPerOutcome[_outcome] -= _shareAmount;
        costBasis[msg.sender][_outcome] -= proRataCostBasis;
        q[_outcome] -= _shareAmount;
        totalCostBasis -= proRataCostBasis;
        settlementPool -= refund;

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "Transfer failed");

        _updateAdaptiveB();

        emit SharesSold(msg.sender, _outcome, _shareAmount, refund);
    }

    function _updateAdaptiveB() internal {
        uint256 poolBasedB = settlementPool / B_SCALING_FACTOR;
        uint256 newB = Math.max(initialB, poolBasedB);
        if (newB != b) {
            b = newB;
            emit AdaptiveBUpdated(b);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //RESOLUTION & SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve market and snapshot payout rate
     */
    function resolve(uint256 _winningOutcome) external onlySettlementContract {
        require(!isCancelled, "Market is cancelled");
        require(!isResolved, "Already resolved");
        require(block.timestamp >= resolutionTime, "Too early");
        require(_winningOutcome < outcomeCount, "Invalid outcome");

        winningOutcome = _winningOutcome;
        isResolved = true;

        // Snapshot payout per share at 1e12 precision
        uint256 winningShares = totalSharesPerOutcome[_winningOutcome];
        if (winningShares > 0) {
            payoutPerShareSnapshot = (settlementPool * 1e12) / winningShares;
        }
        payoutSnapshotted = true;

        emit MarketResolved(_winningOutcome, payoutPerShareSnapshot);
    }

    /**
     * @notice Claim winnings using snapshotted rate with per-user tracking
     */
    function claimWinnings() external nonReentrant returns (uint256) {
        require(!isCancelled, "Market is cancelled");
        require(isResolved, "Not resolved");
        require(payoutSnapshotted, "Payout not set");
        require(!hasClaimed[msg.sender], "Already claimed");

        uint256 userShareCount = userShares[msg.sender][winningOutcome];
        require(userShareCount > 0, "No winning shares");

        userShares[msg.sender][winningOutcome] = 0;

        // Snapshotted payout
        uint256 payout = (userShareCount * payoutPerShareSnapshot) / 1e12;
        payout = Math.min(payout, settlementPool);
        settlementPool -= payout;

        hasClaimed[msg.sender] = true;

        (bool ok, ) = payable(msg.sender).call{value: payout}("");
        require(ok, "Transfer failed");

        emit WinningsClaimed(msg.sender, payout);
        return payout;
    }

    /**
     * @notice Preview claimable amount
     */
    function previewClaim(address _user) external view returns (uint256) {
        if (!isResolved || !payoutSnapshotted || hasClaimed[_user]) return 0;
        uint256 userShareCount = userShares[_user][winningOutcome];
        return (userShareCount * payoutPerShareSnapshot) / 1e12;
    }

    function getPayoutPerShare() external view returns (uint256) {
        require(isResolved && payoutSnapshotted, "Not resolved");
        return payoutPerShareSnapshot / 1e12;
    }

    // ═══════════════════════════════════════════════════════════════════
    // EMERGENCY & CANCELLATION
    // ═══════════════════════════════════════════════════════════════════

    function pause() external {
        require(
            msg.sender == creator || msg.sender == settlementContract,
            "Unauthorized"
        );
        require(!paused, "Already paused");
        paused = true;
        emit MarketPaused(msg.sender);
    }

    function unpause() external {
        require(
            msg.sender == creator || msg.sender == settlementContract,
            "Unauthorized"
        );
        require(paused, "Not paused");
        require(!isCancelled, "Market is cancelled");
        paused = false;
        emit MarketUnpaused(msg.sender);
    }

    function cancelMarket() external {
        require(
            msg.sender == creator || msg.sender == settlementContract,
            "Unauthorized"
        );
        require(!isResolved, "Already resolved");
        require(!isCancelled, "Already cancelled");
        isCancelled = true;
        paused = true;
        emit MarketCancelled(msg.sender);
    }

    function claimRefund() external nonReentrant returns (uint256) {
        require(isCancelled, "Market not cancelled");
        require(!hasClaimedRefund[msg.sender], "Already claimed refund");

        uint256 userBasis = 0;
        for (uint256 i = 0; i < outcomeCount; i++) {
            userBasis += costBasis[msg.sender][i];
            costBasis[msg.sender][i] = 0;
            userShares[msg.sender][i] = 0;
        }
        require(userBasis > 0, "No funds to refund");

        // Proportional share of remaining pool
        uint256 refund = (userBasis * settlementPool) / totalCostBasis;

        hasClaimedRefund[msg.sender] = true;
        totalCostBasis -= userBasis;
        settlementPool -= refund;

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "Transfer failed");

        emit RefundClaimed(msg.sender, refund);
        return refund;
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRIZE DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Authorize a PrizeDistributor to pull the settlement pool
    function setPrizeDistributor(address _distributor) external {
        require(
            msg.sender == creator || msg.sender == settlementContract,
            "Unauthorized"
        );
        require(prizeDistributor == address(0), "Already set");
        prizeDistributor = _distributor;
    }

    /// @notice Transfer the entire settlement pool to the PrizeDistributor
    function transferSettlementPool() external {
        require(msg.sender == prizeDistributor, "Only distributor");
        require(isResolved, "Not resolved");
        uint256 amount = settlementPool;
        require(amount > 0, "No funds");
        settlementPool = 0;
        (bool ok, ) = payable(prizeDistributor).call{value: amount}("");
        require(ok, "Transfer failed");
    }

    function setOwner(address _newOwner) external {
        require(msg.sender == owner, "Only owner can call this function");
        owner = _newOwner;
    }
}
