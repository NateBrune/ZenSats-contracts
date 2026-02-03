// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveStableSwap
/// @notice Interface for Curve StableSwap pools (used for crvUSD/USDC swaps)
interface ICurveStableSwap {
    /// @notice Exchange tokens
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @param min_dy Minimum amount of output token
    /// @return Amount of output token received
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);

    /// @notice Get expected output amount
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @return Expected output amount
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Get coin address by index
    /// @param i Coin index
    /// @return Coin address
    function coins(uint256 i) external view returns (address);

    /// @notice Get pool balances
    /// @param i Coin index
    /// @return Balance of coin at index
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get virtual price of LP token
    /// @return Virtual price scaled by 1e18
    function get_virtual_price() external view returns (uint256);
}
