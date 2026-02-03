// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ITokemakAutopool
/// @notice Interface for Tokemak autoUSD vault (ERC4626 compliant)
interface ITokemakAutopool {
    // ============ ERC4626 Standard Functions ============

    /// @notice Returns the underlying asset address
    function asset() external view returns (address);

    /// @notice Returns total assets under management
    function totalAssets() external view returns (uint256);

    /// @notice Convert assets to shares
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Maximum deposit for receiver
    function maxDeposit(address receiver) external returns (uint256);

    /// @notice Maximum withdrawal for owner
    function maxWithdraw(address owner) external returns (uint256);

    /// @notice Maximum redeem for owner
    function maxRedeem(address owner) external returns (uint256);

    /// @notice Preview deposit
    function previewDeposit(uint256 assets) external returns (uint256);

    /// @notice Preview withdrawal
    function previewWithdraw(uint256 assets) external returns (uint256);

    /// @notice Preview redeem
    function previewRedeem(uint256 shares) external returns (uint256);

    /// @notice Deposit assets and receive shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraw assets by burning shares
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Redeem shares for assets
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    // ============ ERC20 Functions ============

    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    // ============ Tokemak-Specific Functions ============

    /// @notice Returns the address of the main rewarder contract
    function rewarder() external view returns (address);
}
