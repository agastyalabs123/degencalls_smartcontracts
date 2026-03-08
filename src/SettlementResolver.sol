// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// // Interfaces for market contracts
// interface IMarket {
//     function resolve(uint256 winningOutcome) external;
//     function outcomeCount() external view returns (uint256);
// }

// /**
//  * @title SettlementLogic
//  * @notice Multi-modal resolution system: DAO, Oracle, or AI Agent
//  */
// contract SettlementLogic is Ownable, ReentrancyGuard {
//     enum ResolutionMode {
//         DAO,
//         ORACLE,
//         AI_AGENT
//     }

//     struct ResolutionRequest {
//         uint256 marketId;
//         address marketContract;
//         ResolutionMode mode;
//         bool isResolved;
//         uint256 outcome;
//         uint256 requestTime;
//         uint256 resolutionTime;
//         bytes32 oracleRequestId;
//         address resolver;
//     }

//     // State
//     mapping(uint256 => ResolutionRequest) public resolutions;
//     mapping(uint256 => mapping(address => uint256)) public daoVotes; // marketId => voter => outcome
//     mapping(uint256 => uint256[]) public outcomeVoteCounts; // marketId => outcomeIndex => votes
//     mapping(address => bool) public authorizedOracles;
//     mapping(address => bool) public authorizedAIAgents;

//     uint256 public daoVotingPeriod = 3 days;
//     uint256 public constant MIN_VOTES_FOR_DAO = 10;

//     // Events
//     event ResolutionRequested(uint256 indexed marketId, ResolutionMode mode);
//     event OracleResolution(
//         uint256 indexed marketId,
//         uint256 outcome,
//         address oracle
//     );
//     event DAOVote(uint256 indexed marketId, address voter, uint256 outcome);
//     event DAOResolution(uint256 indexed marketId, uint256 outcome);
//     event AIResolution(
//         uint256 indexed marketId,
//         uint256 outcome,
//         address aiAgent,
//         bytes32 proofHash
//     );
//     event MarketResolved(
//         uint256 indexed marketId,
//         uint256 outcome,
//         ResolutionMode mode
//     );

//     modifier onlyOracle() {
//         require(authorizedOracles[msg.sender], "Not authorized oracle");
//         _;
//     }

//     modifier onlyAIAgent() {
//         require(authorizedAIAgents[msg.sender], "Not authorized AI agent");
//         _;
//     }

//     // ═══════════════════════════════════════════════════════════════════════
//     // RESOLUTION ENTRY POINTS
//     // ═══════════════════════════════════════════════════════════════════════

//     /**
//      * @notice Request resolution for a market (anyone can call after resolution time)
//      */
//     function requestResolution(
//         uint256 _marketId,
//         address _marketContract,
//         ResolutionMode _mode
//     ) external {
//         IMarket market = IMarket(_marketContract);
//         require(resolutions[_marketId].requestTime == 0, "Already requested");

//         resolutions[_marketId] = ResolutionRequest({
//             marketId: _marketId,
//             marketContract: _marketContract,
//             mode: _mode,
//             isResolved: false,
//             outcome: 0,
//             requestTime: block.timestamp,
//             resolutionTime: 0,
//             oracleRequestId: 0,
//             resolver: address(0)
//         });

//         emit ResolutionRequested(_marketId, _mode);
//     }

//     // ═══════════════════════════════════════════════════════════════════════
//     // MODE 1: ORACLE RESOLUTION
//     // ═══════════════════════════════════════════════════════════════════════

//     /**
//      * @notice Submit resolution from authorized oracle (Chainlink, Pyth, etc.)
//      */
//     function submitOracleResolution(
//         uint256 _marketId,
//         uint256 _outcome,
//         bytes32 _requestId
//     ) external onlyOracle nonReentrant {
//         ResolutionRequest storage req = resolutions[_marketId];
//         require(req.requestTime > 0, "Not requested");
//         require(!req.isResolved, "Already resolved");
//         require(req.mode == ResolutionMode.ORACLE, "Wrong mode");

//         uint256 outcomeCount = IMarket(req.marketContract).outcomeCount();
//         require(_outcome < outcomeCount, "Invalid outcome");

//         req.outcome = _outcome;
//         req.isResolved = true;
//         req.resolutionTime = block.timestamp;
//         req.oracleRequestId = _requestId;
//         req.resolver = msg.sender;

//         // Call market contract to finalize
//         IMarket(req.marketContract).resolve(_outcome);

//         emit OracleResolution(_marketId, _outcome, msg.sender);
//         emit MarketResolved(_marketId, _outcome, ResolutionMode.ORACLE);
//     }

//     // ═══════════════════════════════════════════════════════════════════════
//     // MODE 2: DAO RESOLUTION
//     // ═══════════════════════════════════════════════════════════════════════

//     /**
//      * @notice Vote on market outcome (token-weighted voting in production)
//      */
//     function submitDAOVote(uint256 _marketId, uint256 _outcome) external {
//         ResolutionRequest storage req = resolutions[_marketId];
//         require(req.requestTime > 0, "Not requested");
//         require(!req.isResolved, "Already resolved");
//         require(req.mode == ResolutionMode.DAO, "Wrong mode");
//         require(
//             block.timestamp < req.requestTime + daoVotingPeriod,
//             "Voting ended"
//         );

//         uint256 outcomeCount = IMarket(req.marketContract).outcomeCount();
//         require(_outcome < outcomeCount, "Invalid outcome");

//         // Prevent double voting (simplified - use token weight in production)
//         require(daoVotes[_marketId][msg.sender] == 0, "Already voted");

//         daoVotes[_marketId][msg.sender] = _outcome;
//         outcomeVoteCounts[_marketId][_outcome]++;

//         emit DAOVote(_marketId, msg.sender, _outcome);
//     }

//     /**
//      * @notice Finalize DAO resolution after voting period
//      */
//     function finalizeDAOResolution(uint256 _marketId) external nonReentrant {
//         ResolutionRequest storage req = resolutions[_marketId];
//         require(req.mode == ResolutionMode.DAO, "Wrong mode");
//         require(!req.isResolved, "Already resolved");
//         require(
//             block.timestamp >= req.requestTime + daoVotingPeriod,
//             "Voting ongoing"
//         );

//         uint256 outcomeCount = IMarket(req.marketContract).outcomeCount();

//         // Find outcome with most votes
//         uint256 winningOutcome = 0;
//         uint256 maxVotes = 0;
//         uint256 totalVotes = 0;

//         for (uint256 i = 0; i < outcomeCount; i++) {
//             uint256 votes = outcomeVoteCounts[_marketId][i];
//             totalVotes += votes;
//             if (votes > maxVotes) {
//                 maxVotes = votes;
//                 winningOutcome = i;
//             }
//         }

//         require(totalVotes >= MIN_VOTES_FOR_DAO, "Insufficient participation");

//         req.outcome = winningOutcome;
//         req.isResolved = true;
//         req.resolutionTime = block.timestamp;
//         req.resolver = address(this);

//         IMarket(req.marketContract).resolve(winningOutcome);

//         emit DAOResolution(_marketId, winningOutcome);
//         emit MarketResolved(_marketId, winningOutcome, ResolutionMode.DAO);
//     }

//     // ═══════════════════════════════════════════════════════════════════════
//     // MODE 3: AI AGENT RESOLUTION
//     // ═══════════════════════════════════════════════════════════════════════

//     /**
//      * @notice Submit AI-verified resolution with cryptographic proof
//      * @param _proofHash Hash of off-chain AI analysis proof (IPFS or similar)
//      */
//     function submitAIResolution(
//         uint256 _marketId,
//         uint256 _outcome,
//         bytes32 _proofHash,
//         bytes calldata _signature
//     ) external onlyAIAgent nonReentrant {
//         ResolutionRequest storage req = resolutions[_marketId];
//         require(req.requestTime > 0, "Not requested");
//         require(!req.isResolved, "Already resolved");
//         require(req.mode == ResolutionMode.AI_AGENT, "Wrong mode");

//         uint256 outcomeCount = IMarket(req.marketContract).outcomeCount();
//         require(_outcome < outcomeCount, "Invalid outcome");

//         // Verify AI agent signature (simplified - implement proper verification)
//         // require(verifyAIProof(_marketId, _outcome, _proofHash, _signature), "Invalid proof");

//         req.outcome = _outcome;
//         req.isResolved = true;
//         req.resolutionTime = block.timestamp;
//         req.oracleRequestId = _proofHash;
//         req.resolver = msg.sender;

//         IMarket(req.marketContract).resolve(_outcome);

//         emit AIResolution(_marketId, _outcome, msg.sender, _proofHash);
//         emit MarketResolved(_marketId, _outcome, ResolutionMode.AI_AGENT);
//     }

//     // ═══════════════════════════════════════════════════════════════════════
//     // ADMIN FUNCTIONS
//     // ═══════════════════════════════════════════════════════════════════════

//     function setAuthorizedOracle(
//         address _oracle,
//         bool _authorized
//     ) external onlyOwner {
//         authorizedOracles[_oracle] = _authorized;
//     }

//     function setAuthorizedAIAgent(
//         address _agent,
//         bool _authorized
//     ) external onlyOwner {
//         authorizedAIAgents[_agent] = _authorized;
//     }

//     function setDAOVotingPeriod(uint256 _period) external onlyOwner {
//         daoVotingPeriod = _period;
//     }
// }
