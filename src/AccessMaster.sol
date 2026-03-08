// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @dev This Contract Module helps to deploy the
 * base Roles for the other flow contracts .
 * Every other Flow contract will retrieve the roles of the
 * ADMIN, OPERATOR, CREATOR, etc. from this.
 */
contract AccessMaster is AccessControlEnumerable {
    string public name = "My AccessMaster";
    string public symbol = "AM";
    uint8 public version = 1;

    address private payoutAddress;
    address public settlementResolver;
    uint256 public creator_stake_amount;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    constructor(uint256 _creatorStakeAmount) {
        _grantRole(ADMIN_ROLE, _msgSender());

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(CREATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);

        grantRole(ADMIN_ROLE, _msgSender());
        grantRole(CREATOR_ROLE, _msgSender());
        grantRole(OPERATOR_ROLE, _msgSender());

        payoutAddress = _msgSender();
        creator_stake_amount = _creatorStakeAmount;
    }

    /// @dev to check if the address {User} is the ADMIN
    function isAdmin(address user) external view returns (bool) {
        return hasRole(ADMIN_ROLE, user);
    }

    /// @dev to check if the address {User} is the CREATOR
    function isCreator(address user) external view returns (bool) {
        return hasRole(CREATOR_ROLE, user);
    }

    /// @dev to check if the address {User} is an OPERATOR
    function isOperator(address user) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, user);
    }

    /// @dev Admin grants operator role to an address.
    function addOperator(address operator) external onlyRole(ADMIN_ROLE) {
        grantRole(OPERATOR_ROLE, operator);
    }

    /// @dev Admin revokes operator role from an address.
    function removeOperator(address operator) external onlyRole(ADMIN_ROLE) {
        revokeRole(OPERATOR_ROLE, operator);
    }

    /// @dev Sets the stake amount required to become a creator.
    /// @param _amount The new stake amount in wei.
    function setCreatorStakeAmount(
        uint256 _amount
    ) external onlyRole(ADMIN_ROLE) {
        creator_stake_amount = _amount;
    }

    /// @dev Pay the stake amount to become a creator. Anyone can call this.
    function becomeCreator() external payable {
        require(
            msg.value >= creator_stake_amount,
            "AccessMaster: Insufficient stake"
        );
        require(
            !hasRole(CREATOR_ROLE, _msgSender()),
            "AccessMaster: Already a creator"
        );
        _grantRole(CREATOR_ROLE, _msgSender());
    }

    /// @dev Admin removes a creator (e.g. for misconduct). Stake is forfeited.
    /// @param creator The address to remove from creators.
    function removeCreator(address creator) external onlyRole(ADMIN_ROLE) {
        require(hasRole(CREATOR_ROLE, creator), "AccessMaster: Not a creator");
        revokeRole(CREATOR_ROLE, creator);
    }

    /// @dev Admin sets the settlement resolver contract (e.g. SettlementLogic).
    function setSettlementResolverManual(
        address _resolver
    ) external onlyRole(ADMIN_ROLE) {
        settlementResolver = _resolver;
    }

    /// @dev Slash creator's stake and send to recipient. Only callable by settlement resolver.
    ///      Used when challenger wins a dispute — creator forfeits stake to challenger.
    /// @param creator The creator whose stake is slashed.
    /// @param recipient Address to receive the slashed stake (e.g. challenger).
    function slashCreatorStake(address creator, address recipient) external {
        require(
            msg.sender == settlementResolver,
            "AccessMaster: Only settlement resolver"
        );
        require(hasRole(CREATOR_ROLE, creator), "AccessMaster: Not a creator");
        require(recipient != address(0), "AccessMaster: Zero recipient");
        require(
            address(this).balance >= creator_stake_amount,
            "AccessMaster: Insufficient balance"
        );

        revokeRole(CREATOR_ROLE, creator);
        (bool ok, ) = recipient.call{value: creator_stake_amount}("");
        require(ok, "AccessMaster: ETH transfer failed");
    }

    /// @dev Sets the payout address.
    /// @param _payoutAddress The new address to receive funds from multiple contracts.
    /// @notice Only the admin can set the payout address.
    function setPayoutAddress(address _payoutAddress) external {
        require(
            hasRole(ADMIN_ROLE, _msgSender()),
            "AccessMaster: User is not authorized"
        );
        payoutAddress = _payoutAddress;
    }

    /**
     * @notice Retrieves the payout address defined by the admin.
     * @return The payout address for receiving funds.
     */
    function getPayoutAddress() external view returns (address) {
        return payoutAddress;
    }
}
