// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IStakeDaoVault
/// @notice Interface for StakeDAO crvfrxUSD vault
interface IStakeDaoVault {
    /// @notice Deposit assets into the vault
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Deposit assets with referrer
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @param referrer Referrer address
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver, address referrer)
        external
        returns (uint256 shares);

    /// @notice Withdraw assets from the vault
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive assets
    /// @param owner Owner of the shares
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Redeem shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive assets
    /// @param owner Owner of the shares
    /// @return assets Amount of assets received
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Get the underlying asset
    /// @return Asset address
    function asset() external view returns (address);

    /// @notice Get total assets in the vault
    /// @return Total assets
    function totalAssets() external view returns (uint256);

    /// @notice Get balance of shares for an account
    /// @param account Account address
    /// @return Share balance
    function balanceOf(address account) external view returns (uint256);

    /// @notice Get total supply of shares
    /// @return Total shares
    function totalSupply() external view returns (uint256);

    /// @notice Convert shares to assets
    /// @param shares Amount of shares
    /// @return assets Equivalent assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Convert assets to shares
    /// @param assets Amount of assets
    /// @return shares Equivalent shares
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Get max deposit amount
    /// @param receiver Receiver address
    /// @return Max deposit
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Get max withdraw amount
    /// @param owner Owner address
    /// @return Max withdraw
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice Get max redeem amount
    /// @param owner Owner address
    /// @return Max redeem
    function maxRedeem(address owner) external view returns (uint256);

    /// @notice Preview deposit
    /// @param assets Amount of assets
    /// @return shares Shares that would be minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview withdraw
    /// @param assets Amount of assets
    /// @return shares Shares that would be burned
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview redeem
    /// @param shares Amount of shares
    /// @return assets Assets that would be received
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Get reward tokens
    /// @return Array of reward token addresses
    function getRewardTokens() external view returns (address[] memory);

    /// @notice Claim rewards
    /// @param tokens Reward tokens to claim
    /// @param receiver Address to receive rewards
    /// @return amounts Amounts claimed per token
    function claim(address[] calldata tokens, address receiver)
        external
        returns (uint256[] memory amounts);

    /// @notice Get earned rewards for an account
    /// @param account Account address
    /// @param token Reward token address
    /// @return Amount of rewards earned
    function earned(address account, address token) external view returns (uint128);

    /// @notice Get claimable rewards
    /// @param token Reward token address
    /// @param account Account address
    /// @return Claimable amount
    function getClaimable(address token, address account) external view returns (uint128);

    /// @notice Approve spending
    /// @param spender Spender address
    /// @param value Amount to approve
    /// @return Success
    function approve(address spender, uint256 value) external returns (bool);

    /// @notice Get allowance
    /// @param owner Owner address
    /// @param spender Spender address
    /// @return Allowance amount
    function allowance(address owner, address spender) external view returns (uint256);
}
