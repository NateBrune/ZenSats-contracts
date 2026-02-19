// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveRewardVault
/// @notice Interface for Stake DAO ERC4626 reward vaults
/// @dev These vaults wrap Curve LP tokens and distribute CRV/SDT rewards
interface ICurveRewardVault {
    // ============ ERC4626 Functions ============

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ============ ERC20 Functions ============

    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);

    // ============ Reward Functions ============

    /// @notice Claim all pending rewards for the caller
    /// @return Array of reward amounts claimed (ordered by rewardTokens())
    function claim() external returns (uint256[] memory);

    /// @notice Get pending rewards for an account
    /// @param account Address to check
    /// @param token Reward token address
    /// @return Pending reward amount
    function earned(address account, address token) external view returns (uint256);

    /// @notice Get all reward token addresses
    /// @return Array of reward token addresses
    function rewardTokens(uint256 index) external view returns (address);

    /// @notice Get the number of reward tokens
    /// @return Number of reward tokens
    function rewardTokensLength() external view returns (uint256);
}
