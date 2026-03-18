// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "./BaseYieldStrategy.sol";
import { IStakeDaoRewardVault } from "../interfaces/IStakeDaoRewardVault.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

/// @title BaseCurveRewardVaultStrategy
/// @notice Abstract base for strategies that stake Curve LP tokens in ERC4626 reward vaults
/// @dev Provides shared deposit/redeem/balance helpers for Stake DAO-style reward vaults
abstract contract BaseCurveRewardVaultStrategy is BaseYieldStrategy {
    // ============ Immutables ============

    /// @notice Stake DAO ERC4626 reward vault
    IStakeDaoRewardVault public immutable rewardVault;

    /// @notice The Curve LP token staked in the reward vault
    IERC20 public immutable lpToken;

    // ============ Constructor ============

    constructor(address _debtAsset, address _vault, address _rewardVault)
        BaseYieldStrategy(_debtAsset, _vault)
    {
        if (_rewardVault == address(0)) revert InvalidAddress();
        rewardVault = IStakeDaoRewardVault(_rewardVault);
        lpToken = IERC20(rewardVault.asset());
    }

    // ============ Reward Vault Helpers ============

    /// @notice Deposit LP tokens into the reward vault
    /// @param lpAmount Amount of LP tokens to deposit
    /// @return shares Vault shares minted
    function _depositToRewardVault(uint256 lpAmount) internal returns (uint256 shares) {
        _ensureApprove(address(lpToken), address(rewardVault), lpAmount);
        shares = rewardVault.deposit(lpAmount, address(this));
    }

    /// @notice Redeem specific number of shares from reward vault
    /// @param shares Number of shares to redeem
    /// @return lpReceived Amount of LP tokens received
    function _redeemFromRewardVault(uint256 shares) internal returns (uint256 lpReceived) {
        lpReceived = rewardVault.redeem(shares, address(this), address(this));
    }

    /// @notice Redeem all shares from reward vault
    /// @return lpReceived Amount of LP tokens received
    function _redeemAllFromRewardVault() internal returns (uint256 lpReceived) {
        uint256 shares = rewardVault.balanceOf(address(this));
        if (shares < 1) return 0;
        lpReceived = rewardVault.redeem(shares, address(this), address(this));
    }

    /// @notice Claim all pending rewards from the reward vault
    /// @return amounts Array of reward amounts claimed
    function _claimRewards() internal returns (uint256[] memory amounts) {
        amounts = rewardVault.claim();
    }

    /// @notice Get total LP token balance in reward vault
    /// @return LP token amount (converted from shares)
    function _rewardVaultBalance() internal view returns (uint256) {
        uint256 shares = rewardVault.balanceOf(address(this));
        if (shares < 1) return 0;
        return rewardVault.convertToAssets(shares);
    }
}
