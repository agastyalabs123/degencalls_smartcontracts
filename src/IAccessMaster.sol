// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @dev Interface for AccessMaster contract.
 * Provides role checks and payout address management for flow contracts.
 */
interface IAccessMaster {
    function creator_stake_amount() external view returns (uint256);

    function ADMIN_ROLE() external view returns (bytes32);

    function CREATOR_ROLE() external view returns (bytes32);

    function isAdmin(address user) external view returns (bool);

    function addOperator(address operator) external;

    function isCreator(address user) external view returns (bool);

    function isOperator(address user) external view returns (bool);

    function setPayoutAddress(address _payoutAddress) external;

    function slashCreatorStake(address creator, address recipient) external;

    function getPayoutAddress() external view returns (address);

    function setCreatorStakeAmount(uint256 _amount) external;
}
