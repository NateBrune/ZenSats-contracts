// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IYieldVault
/// @notice Minimal ERC4626 interface for yield vaults (StakeDao, Yearn, etc.)
interface IYieldVault {
    // ERC4626 standard functions
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
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    // ERC20 functions needed
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
