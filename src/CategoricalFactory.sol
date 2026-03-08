// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CategoricalMarket.sol";

contract PredictionMarketFactory {
    using Math for uint256;

    address public owner;

    // State variables
    mapping(uint256 => MarketInfo) public markets;
    mapping(address => bool) public authorizedCreators;
    mapping(address => uint256) public userBalance;
    uint256 public marketCount;

    // Platform parameters
    uint256 public creationFee = 1 ether;
    uint256 public minSeedAmount = 0.01 ether;
    bool public permissionlessCreation = true;

    struct MarketInfo {
        address marketAddress;
        MarketType marketType;
        MarketStatus status;
        address creator;
        string question;
        uint256 resolutionTime;
        address settlementContract;
    }
    // Market status
    enum MarketStatus {
        ACTIVE,
        RESOLVED,
        SETTLED
    }
    // Market types
    enum MarketType {
        BINARY,
        CATEGORICAL
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    // Events
    event MarketCreated(
        uint256 indexed marketId,
        address indexed marketAddress,
        MarketType marketType,
        address creator,
        string question
    );

    // ═══════════════════════════════════════════════════════════════════════
    // MARKET CREATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════
    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Create categorical market with multiple outcomes
     * @param _question The market question
     * @param _outcomeNames Array of outcome names (3-8 outcomes recommended)
     * @param _resolutionTime Timestamp when market can be resolved
     * @param _initialB Initial liquidity parameter
     * @param _settlementLogic Address of settlement resolver contract
     */
    function createCategoricalMarket(
        string calldata _question,
        string[] calldata _outcomeNames,
        uint256 _resolutionTime,
        uint256 _initialB,
        address _settlementLogic
    ) external payable returns (uint256 marketId, address marketAddress) {
        require(msg.value >= creationFee, "Insufficient creation fee");
        require(_outcomeNames.length >= 2, "Min 2 outcomes");
        require(_outcomeNames.length <= 10, "Max 10 outcomes");
        require(_resolutionTime > block.timestamp, "Resolution must be future");
        require(
            permissionlessCreation || authorizedCreators[msg.sender],
            "Unauthorized creator"
        );

        marketId = marketCount++;

        CategoricalMarket newMarket = new CategoricalMarket(
            marketId,
            _question,
            _outcomeNames,
            _resolutionTime,
            Math.max(_initialB, minSeedAmount),
            _outcomeNames.length,
            _settlementLogic,
            msg.sender,
            owner
        );

        marketAddress = address(newMarket);

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress,
            marketType: MarketType.CATEGORICAL,
            status: MarketStatus.ACTIVE,
            creator: msg.sender,
            question: _question,
            resolutionTime: _resolutionTime,
            settlementContract: _settlementLogic
        });

        emit MarketCreated(
            marketId,
            marketAddress,
            MarketType.CATEGORICAL,
            msg.sender,
            _question
        );

        return (marketId, marketAddress);
    }

    // TO change the  owner
    function setOwner(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }

    // TO change the permissionless creation
    function setPermissionlessCreation(
        bool _permissionless
    ) external onlyOwner {
        permissionlessCreation = _permissionless;
    }

    // TO change the min seed amount
    function updateMinSeedAmount(uint256 _newMinSeedAmount) external onlyOwner {
        minSeedAmount = _newMinSeedAmount;
    }

    // Admin functions for creator authorization
    function setAuthorizedCreator(
        address _creator,
        bool _authorized
    ) external onlyOwner {
        // Only owner/governance
        authorizedCreators[_creator] = _authorized;
    }

    function updateCreationFee(uint256 _newFee) external onlyOwner {
        creationFee = _newFee;
    }

    receive() external payable {
        require(msg.value >= creationFee, "Insufficient creation fee");
        userBalance[msg.sender] += msg.value;
    }
}
