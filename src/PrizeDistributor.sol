// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Interface to query market data
interface IMarket {
    function settlementPool() external view returns (uint256);

    function winningOutcome() external view returns (uint256);

    function isResolved() external view returns (bool);

    function userShares(
        address user,
        uint256 outcome
    ) external view returns (uint256);

    function totalSharesPerOutcome(
        uint256 outcome
    ) external view returns (uint256);

    function outcomeCount() external view returns (uint256);

    function claimWinnings() external returns (uint256);

    function transferSettlementPool() external;
}

/**
 * @title PrizeDistributor
 * @notice Parimutuel prize distribution: winners split pool proportionally
 * @dev Uses native token. Can be integrated into markets or used as standalone claim processor.
 */
contract PrizeDistributor is ReentrancyGuard {
    using Math for uint256;

    struct Distribution {
        uint256 marketId;
        address marketContract;
        uint256 totalPool;
        uint256 winningOutcome;
        uint256 totalWinningShares;
        uint256 payoutPerShare; // Scaled by 1e12 for precision
        bool isDistributed;
        mapping(address => bool) hasClaimed;
    }

    mapping(uint256 => Distribution) public distributions;

    event DistributionCreated(uint256 indexed marketId, uint256 payoutPerShare);
    event PrizeClaimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount
    );

    // ── Receive native token ──────────────────────────────────────────
    receive() external payable {}

    /**
     * @notice Calculate and store distribution parameters after resolution
     * @param _marketId Unique market identifier
     * @param _marketContract Address of the resolved market
     */
    function createDistribution(
        uint256 _marketId,
        address _marketContract
    ) external returns (uint256 payoutPerShare) {
        require(
            distributions[_marketId].marketContract == address(0),
            "Already exists"
        );

        IMarket market = IMarket(_marketContract);
        require(market.isResolved(), "Market not resolved");

        uint256 winningOutcome = market.winningOutcome();
        uint256 totalPool = market.settlementPool();
        uint256 totalWinningShares = market.totalSharesPerOutcome(
            winningOutcome
        );

        require(totalWinningShares > 0, "No winning shares");

        // Calculate: payout = pool / winning_shares
        // Use high precision (1e12) to avoid rounding errors
        payoutPerShare = (totalPool * 1e12) / totalWinningShares;

        Distribution storage dist = distributions[_marketId];
        dist.marketId = _marketId;
        dist.marketContract = _marketContract;
        dist.totalPool = totalPool;
        dist.winningOutcome = winningOutcome;
        dist.totalWinningShares = totalWinningShares;
        dist.payoutPerShare = payoutPerShare;
        dist.isDistributed = true;

        // Pull funds from market so claimPrize can transfer from this contract
        market.transferSettlementPool();

        emit DistributionCreated(_marketId, payoutPerShare);

        return payoutPerShare;
    }

    /**
     * @notice Claim winnings through distributor (alternative to direct market claim)
     */
    function claimPrize(
        uint256 _marketId
    ) external nonReentrant returns (uint256) {
        Distribution storage dist = distributions[_marketId];
        require(dist.isDistributed, "Not distributed");
        require(!dist.hasClaimed[msg.sender], "Already claimed");

        IMarket market = IMarket(dist.marketContract);
        uint256 userShareCount = market.userShares(msg.sender, dist.winningOutcome);
        require(userShareCount > 0, "No winning shares");

        // Calculate: payout = (user_shares * payout_per_share) / 1e12
        uint256 payout = (userShareCount * dist.payoutPerShare) / 1e12;

        dist.hasClaimed[msg.sender] = true;

        (bool ok, ) = payable(msg.sender).call{value: payout}("");
        require(ok, "Transfer failed");

        emit PrizeClaimed(_marketId, msg.sender, payout);

        return payout;
    }

    /**
     * @notice Preview claimable amount without claiming
     */
    function previewClaim(
        uint256 _marketId,
        address _user
    ) external view returns (uint256) {
        Distribution storage dist = distributions[_marketId];
        if (!dist.isDistributed) return 0;
        if (dist.hasClaimed[_user]) return 0;

        IMarket market = IMarket(dist.marketContract);
        uint256 userShareCount = market.userShares(_user, dist.winningOutcome);

        return (userShareCount * dist.payoutPerShare) / 1e12;
    }

    /**
     * @notice Get full distribution stats for a market
     */
    function getDistributionInfo(
        uint256 _marketId
    )
        external
        view
        returns (
            uint256 totalPool,
            uint256 winningOutcome,
            uint256 totalWinningShares,
            uint256 payoutPerShare,
            bool isDistributed
        )
    {
        Distribution storage dist = distributions[_marketId];
        return (
            dist.totalPool,
            dist.winningOutcome,
            dist.totalWinningShares,
            dist.payoutPerShare,
            dist.isDistributed
        );
    }
}
