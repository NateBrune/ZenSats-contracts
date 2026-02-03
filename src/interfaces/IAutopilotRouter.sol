// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./IERC20.sol";
import { ITokemakAutopool } from "./ITokemakAutopool.sol";
import { IMainRewarder } from "./IMainRewarder.sol";

/// @title IAutopilotRouter
/// @notice Minimal interface for Tokemak's AutopilotRouter used for staking/unstaking autopool shares
interface IAutopilotRouter {
    /// @notice Approve a token for a spender from the router's balance.
    /// @dev Required before stakeVaultToken — the MainRewarder pulls vault tokens
    ///      from the router via transferFrom, so the router must approve the rewarder.
    /// @param token Token to approve.
    /// @param to Spender address (typically the MainRewarder).
    /// @param amount Approval amount.
    function approve(IERC20 token, address to, uint256 amount) external payable;

    /// @notice Stakes vault token to corresponding rewarder.
    /// @param vault IERC20 instance of an Autopool to stake to.
    /// @param maxAmount Maximum amount for user to stake. Amount > balanceOf(user) will stake all present tokens.
    /// @return staked Returns total amount staked.
    function stakeVaultToken(IERC20 vault, uint256 maxAmount)
        external
        payable
        returns (uint256 staked);

    /// @notice Unstakes vault token from corresponding rewarder.
    /// @param vault Autopool instance of the vault token to withdraw.
    /// @param rewarder Rewarder to withdraw from.
    /// @param maxAmount Amount of vault token to withdraw. Amount > balanceOf(user) will withdraw all owned tokens.
    /// @param claim Claiming rewards or not on unstaking.
    /// @return withdrawn Amount of vault token withdrawn.
    function withdrawVaultToken(
        ITokemakAutopool vault,
        IMainRewarder rewarder,
        uint256 maxAmount,
        bool claim
    ) external payable returns (uint256 withdrawn);
}
