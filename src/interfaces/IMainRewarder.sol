// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IMainRewarder
/// @notice Interface for Tokemak MainRewarder (Synthetix-style staking rewards)
/// @dev stake/withdraw are restricted to onlyStakingToken on-chain; use the AutopilotRouter instead.
interface IMainRewarder {
    /// @notice Claim accumulated TOKE rewards
    function getReward() external;

    /// @notice Returns unclaimed rewards for an account
    function earned(address account) external view returns (uint256);

    /// @notice Returns staked balance for an account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns the reward token address (TOKE)
    function rewardToken() external view returns (address);
}
