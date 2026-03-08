// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FixedPointMath.sol";

/**
 * @title BinaryMarket
 * @notice LMSR-based AMM for binary (Yes/No) prediction markets
 * @dev Uses Hybrid LMSR: pricing only, settlement is parimutuel.
 *      Collateral is native token (msg.value / payable).
 *
 *  #1 - Replaced broken Taylor-series expApprox with FixedPointMath.expUint (shift+polynomial)
 *  #2 - Replaced integer Math.log2 with FixedPointMath.ln (proper fixed-point logarithm)
 *  #3 - Added pool solvency guard on sells + cost-basis tracking
 *  #4 - Replaced broken isSettled flag with per-user hasClaimed + snapshot payoutPerShare
 */
contract BinaryMarket is ReentrancyGuard {
    using Math for uint256;
    using FixedPointMath for uint256;

    // ── Constants ──────────────────────────────────────────────────────
    uint256 public constant OUTCOME_YES = 0;
    uint256 public constant OUTCOME_NO = 1;
    uint256 public constant OUTCOME_COUNT = 2;
    uint256 public constant B_SCALING_FACTOR = 10;
    uint256 public constant PRECISION = 1e18;

    // ── Market info ────────────────────────────────────────────────────
    uint256 public immutable marketId;
    string public question;
    string[2] public outcomeNames;
    uint256 public resolutionTime;
    address public immutable creator;
    address public owner;

    // ── External contracts ─────────────────────────────────────────────
    address public settlementContract;

    // ── LMSR parameters ────────────────────────────────────────────────
    uint256 public b;
    uint256 public immutable initialB;
    uint256 public qYes;
    uint256 public qNo;

    // ── Settlement pool (parimutuel) ───────────────────────────────────
    uint256 public settlementPool;

    // ── Share tracking ─────────────────────────────────────────────────
    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    uint256 public totalYesShares;
    uint256 public totalNoShares;

    // ── Cost-basis tracking for solvency on sells ────────────────────
    // Tracks total native token a user has paid for shares of each outcome.
    // Sell refund is capped at min(lmsrRefund, userCostBasis) to prevent
    // pool drain when adaptive b shifts pricing between buy and sell.
    mapping(address => uint256) public yesCostBasis;
    mapping(address => uint256) public noCostBasis;

    // ── Market state ───────────────────────────────────────────────────
    bool public isResolved;
    uint256 public winningOutcome;

    //  Per-user claim tracking + snapshotted payout ───────────
    // payoutPerShare is computed once at resolution and frozen.
    // hasClaimed prevents double-claims without relying on a broken global flag.
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
        bool isYes,
        uint256 shares,
        uint256 cost
    );
    event SharesSold(
        address indexed seller,
        bool isYes,
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
        string[2] memory _outcomeNames,
        uint256 _resolutionTime,
        uint256 _initialB,
        address _settlementContract,
        address _creator,
        address _owner
    ) {
        marketId = _marketId;
        question = _question;
        outcomeNames = _outcomeNames;
        resolutionTime = _resolutionTime;
        initialB = _initialB;
        b = _initialB;
        settlementContract = _settlementContract;
        creator = _creator;
    }

    // ── Receive native token ──────────────────────────────────────────
    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════════
    // LMSR PRICING WITH PROPER FIXED-POINT MATH
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate LMSR cost function C(q) = b * ln(e^(qYes/b) + e^(qNo/b))
     * @dev Uses FixedPointMath library for precise exp() and ln()
     *
     * Previous issues:
     *   - expApprox used 10-term Taylor series that diverges for x > ~5
     *   - Math.log2 returns integer log2, not fixed-point ln
     *
     * Fix: FixedPointMath.expUint uses base-change (e^x = 2^(x/ln2))
     *      with shift for integer part + minimax polynomial for fractional.
     *      FixedPointMath.ln uses iterative squaring for 64-bit fractional precision.
     */
    function calculateCost(
        uint256 _qYes,
        uint256 _qNo
    ) public view returns (uint256) {
        // Scale q/b to 1e18 fixed-point
        uint256 term1 = (_qYes * PRECISION) / b;
        uint256 term2 = (_qNo * PRECISION) / b;

        // Proper exp via shift+polynomial (replaces broken Taylor series)
        uint256 exp1 = FixedPointMath.expUint(term1);
        uint256 exp2 = FixedPointMath.expUint(term2);

        uint256 sum = exp1 + exp2;
        require(sum > 0, "Cost overflow");

        // Proper fixed-point ln (replaces integer Math.log2)
        // FixedPointMath.ln returns int256 in 1e18 scale
        int256 lnSum = FixedPointMath.ln(sum);
        require(lnSum >= 0, "Negative ln");

        return (b * uint256(lnSum)) / PRECISION;
    }

    /**
     * @notice Get current price (probability) of an outcome
     * @param _outcome 0 for YES, 1 for NO
     * @return price Probability in 1e6 (1,000,000 = 100%)
     */
    function getPrice(uint256 _outcome) external view returns (uint256) {
        require(_outcome < OUTCOME_COUNT, "Invalid outcome");

        uint256 expYes = FixedPointMath.expUint((qYes * PRECISION) / b);
        uint256 expNo = FixedPointMath.expUint((qNo * PRECISION) / b);
        uint256 sum = expYes + expNo;

        if (_outcome == OUTCOME_YES) {
            return (expYes * 1e6) / sum;
        } else {
            return (expNo * 1e6) / sum;
        }
    }

    /**
     * @notice Calculate cost to buy shares
     */
    function getBuyCost(
        uint256 _outcome,
        uint256 _shareAmount
    ) public view returns (uint256) {
        require(_outcome < OUTCOME_COUNT, "Invalid outcome");

        uint256 newQYes = qYes;
        uint256 newQNo = qNo;

        if (_outcome == OUTCOME_YES) {
            newQYes += _shareAmount;
        } else {
            newQNo += _shareAmount;
        }

        uint256 costBefore = calculateCost(qYes, qNo);
        uint256 costAfter = calculateCost(newQYes, newQNo);

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
        require(_outcome < OUTCOME_COUNT, "Invalid outcome");

        uint256 newQYes = qYes;
        uint256 newQNo = qNo;

        if (_outcome == OUTCOME_YES) {
            require(qYes >= _shareAmount, "Insufficient shares outstanding");
            newQYes -= _shareAmount;
        } else {
            require(qNo >= _shareAmount, "Insufficient shares outstanding");
            newQNo -= _shareAmount;
        }

        uint256 costBefore = calculateCost(qYes, qNo);
        uint256 costAfter = calculateCost(newQYes, newQNo);

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
        require(_outcome < OUTCOME_COUNT, "Invalid outcome");
        require(_shareAmount > 0, "Amount must be > 0");

        uint256 cost = getBuyCost(_outcome, _shareAmount);
        require(cost <= _maxCost, "Slippage exceeded");
        require(cost > 0, "Cost too low");
        require(msg.value >= cost, "Insufficient payment");

        // Refund excess
        if (msg.value > cost) {
            (bool refundOk, ) = payable(msg.sender).call{
                value: msg.value - cost
            }("");
            require(refundOk, "Refund failed");
        }

        // Update LMSR quantities
        if (_outcome == OUTCOME_YES) {
            qYes += _shareAmount;
            yesShares[msg.sender] += _shareAmount;
            totalYesShares += _shareAmount;
            // Track cost basis
            yesCostBasis[msg.sender] += cost;
        } else {
            qNo += _shareAmount;
            noShares[msg.sender] += _shareAmount;
            totalNoShares += _shareAmount;
            //  Track cost basis
            noCostBasis[msg.sender] += cost;
        }

        settlementPool += cost;
        totalCostBasis += cost;
        _updateAdaptiveB();

        emit SharesPurchased(
            msg.sender,
            _outcome == OUTCOME_YES,
            _shareAmount,
            cost
        );
    }

    /**
     * @notice Sell shares — LMSR pricing with solvency guard
     *
     *  Refund is capped to prevent pool drain.
     * When adaptive b grows between buy and sell, LMSR can compute a refund
     * larger than what the user originally paid. Without a cap, this drains
     * the pool and makes it insolvent for settlement.
     *
     * The cap is: min(lmsrRefund, userCostBasis, settlementPool)
     * Cost basis is reduced proportionally to shares sold.
     */
    function swapOut(
        uint256 _outcome,
        uint256 _shareAmount,
        uint256 _minRefund
    ) external nonReentrant notResolved whenNotPaused {
        require(_outcome < OUTCOME_COUNT, "Invalid outcome");
        require(_shareAmount > 0, "Amount must be > 0");

        uint256 userShareBalance;
        uint256 userCostBasis;

        if (_outcome == OUTCOME_YES) {
            userShareBalance = yesShares[msg.sender];
            userCostBasis = yesCostBasis[msg.sender];
        } else {
            userShareBalance = noShares[msg.sender];
            userCostBasis = noCostBasis[msg.sender];
        }
        require(userShareBalance >= _shareAmount, "Insufficient shares");

        // LMSR-computed refund
        uint256 lmsrRefund = getSellRefund(_outcome, _shareAmount);

        // Cap refund to protect pool solvency
        // Pro-rata cost basis for the shares being sold
        uint256 proRataCostBasis = (userCostBasis * _shareAmount) /
            userShareBalance;
        // Take the lesser of LMSR refund, cost basis, and available pool
        uint256 refund = Math.min(lmsrRefund, proRataCostBasis);
        refund = Math.min(refund, settlementPool);

        require(refund >= _minRefund, "Slippage exceeded");

        // Update state before transfer (CEI pattern)
        if (_outcome == OUTCOME_YES) {
            yesShares[msg.sender] -= _shareAmount;
            totalYesShares -= _shareAmount;
            yesCostBasis[msg.sender] -= proRataCostBasis;
            qYes -= _shareAmount;
        } else {
            noShares[msg.sender] -= _shareAmount;
            totalNoShares -= _shareAmount;
            noCostBasis[msg.sender] -= proRataCostBasis;
            qNo -= _shareAmount;
        }

        totalCostBasis -= proRataCostBasis;
        settlementPool -= refund;

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "Transfer failed");

        _updateAdaptiveB();

        emit SharesSold(
            msg.sender,
            _outcome == OUTCOME_YES,
            _shareAmount,
            refund
        );
    }

    /**
     * @notice Update liquidity parameter b based on pool size
     */
    function _updateAdaptiveB() internal {
        uint256 poolBasedB = settlementPool / B_SCALING_FACTOR;
        uint256 newB = Math.max(initialB, poolBasedB);
        if (newB != b) {
            b = newB;
            emit AdaptiveBUpdated(b);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // RESOLUTION & SETTLEMENT (per-user claims + snapshot)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Called by SettlementLogic contract to resolve market
     *
     *  Snapshots payoutPerShare at resolution time.
     * Previous code had `isSettled` (global flag) that was never set,
     * and totalShares weren't decremented, causing rounding drift.
     * Now: payout is frozen at resolution so all claimants get the same rate.
     */
    function resolve(uint256 _winningOutcome) external onlySettlementContract {
        require(!isCancelled, "Market is cancelled");
        require(!isResolved, "Already resolved");
        require(block.timestamp >= resolutionTime, "Too early to resolve");
        require(_winningOutcome < OUTCOME_COUNT, "Invalid outcome");

        winningOutcome = _winningOutcome;
        isResolved = true;

        // Snapshot payout per share (1e12 precision)
        uint256 winningShares = (_winningOutcome == OUTCOME_YES)
            ? totalYesShares
            : totalNoShares;

        if (winningShares > 0) {
            payoutPerShareSnapshot = (settlementPool * 1e12) / winningShares;
        }

        payoutSnapshotted = true;

        emit MarketResolved(_winningOutcome, payoutPerShareSnapshot);
    }

    /**
     * @notice Claim winnings using snapshotted payout rate
     *
     *  Uses per-user `hasClaimed` mapping instead of broken global `isSettled`.
     * Uses frozen `payoutPerShareSnapshot` so claim order doesn't matter
     * and rounding dust doesn't accumulate against late claimants.
     */
    function claimWinnings() external nonReentrant returns (uint256) {
        require(!isCancelled, "Market is cancelled");
        require(isResolved, "Not resolved");
        require(payoutSnapshotted, "Payout not set");
        require(!hasClaimed[msg.sender], "Already claimed");

        uint256 userShareCount;
        if (winningOutcome == OUTCOME_YES) {
            userShareCount = yesShares[msg.sender];
            yesShares[msg.sender] = 0;
        } else {
            userShareCount = noShares[msg.sender];
            noShares[msg.sender] = 0;
        }

        require(userShareCount > 0, "No winning shares");

        // Use snapshotted rate: payout = shares * payoutPerShare / 1e12
        uint256 payout = (userShareCount * payoutPerShareSnapshot) / 1e12;

        // Safety: never pay more than the pool holds
        payout = Math.min(payout, settlementPool);
        settlementPool -= payout;

        hasClaimed[msg.sender] = true;

        (bool ok, ) = payable(msg.sender).call{value: payout}("");
        require(ok, "Transfer failed");

        emit WinningsClaimed(msg.sender, payout);
        return payout;
    }

    /**
     * @notice Preview claimable amount without state changes
     */
    function getPayoutPerShare() external view returns (uint256) {
        require(isResolved && payoutSnapshotted, "Not resolved");
        return payoutPerShareSnapshot / 1e12;
    }

    /**
     * @notice Preview a user's claimable payout
     */
    function previewClaim(address _user) external view returns (uint256) {
        if (!isResolved || !payoutSnapshotted || hasClaimed[_user]) return 0;

        uint256 userShareCount;
        if (winningOutcome == OUTCOME_YES) {
            userShareCount = yesShares[_user];
        } else {
            userShareCount = noShares[_user];
        }
        return (userShareCount * payoutPerShareSnapshot) / 1e12;
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

        uint256 userBasis = yesCostBasis[msg.sender] + noCostBasis[msg.sender];
        require(userBasis > 0, "No funds to refund");

        // Proportional share of remaining pool
        uint256 refund = (userBasis * settlementPool) / totalCostBasis;

        hasClaimedRefund[msg.sender] = true;
        yesCostBasis[msg.sender] = 0;
        noCostBasis[msg.sender] = 0;
        yesShares[msg.sender] = 0;
        noShares[msg.sender] = 0;
        totalCostBasis -= userBasis;
        settlementPool -= refund;

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "Transfer failed");

        emit RefundClaimed(msg.sender, refund);
        return refund;
    }

    // ═══════════════════════════════════════════════════════════════════
    // IMarket COMPATIBILITY + PRIZE DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════

    function outcomeCount() external pure returns (uint256) {
        return OUTCOME_COUNT;
    }

    /// @notice IMarket-compatible: returns shares for a user by outcome index
    function userShares(
        address _user,
        uint256 _outcome
    ) external view returns (uint256) {
        if (_outcome == OUTCOME_YES) return yesShares[_user];
        if (_outcome == OUTCOME_NO) return noShares[_user];
        return 0;
    }

    /// @notice IMarket-compatible: returns total shares for an outcome index
    function totalSharesPerOutcome(
        uint256 _outcome
    ) external view returns (uint256) {
        if (_outcome == OUTCOME_YES) return totalYesShares;
        if (_outcome == OUTCOME_NO) return totalNoShares;
        return 0;
    }

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

    function getMarketInfo()
        external
        view
        returns (
            uint256 _marketId,
            string memory _question,
            uint256 _qYes,
            uint256 _qNo,
            uint256 _b,
            uint256 _settlementPool,
            bool _isResolved,
            uint256 _winningOutcome
        )
    {
        return (
            marketId,
            question,
            qYes,
            qNo,
            b,
            settlementPool,
            isResolved,
            winningOutcome
        );
    }
}
