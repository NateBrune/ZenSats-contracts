// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveTwoCrypto
/// @notice Interface for Curve TwoCrypto pool (2-token crypto pools)
/// @dev Used for WBTC/crvUSD swaps during final vault exit
interface ICurveTwoCrypto {
    /// @notice Exchange tokens with optional receiver
    /// @param i Index of input coin (0 or 1)
    /// @param j Index of output coin (0 or 1)
    /// @param dx Amount of input coin
    /// @param min_dy Minimum amount of output coin
    /// @param receiver Address to send output to (defaults to msg.sender in Vyper)
    /// @return Amount of output coin received
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);

    /// @notice Exchange tokens (using msg.sender as receiver)
    /// @param i Index of input coin (0 or 1)
    /// @param j Index of output coin (0 or 1)
    /// @param dx Amount of input coin
    /// @param min_dy Minimum amount of output coin
    /// @return Amount of output coin received
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    /// @notice Get expected output amount
    /// @param i Index of input coin
    /// @param j Index of output coin
    /// @param dx Amount of input coin
    /// @return Expected output amount
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);

    /// @notice Get coin address by index
    /// @param i Coin index (0 or 1)
    /// @return Coin address
    function coins(uint256 i) external view returns (address);

    /// @notice Get pool balances
    /// @param i Coin index
    /// @return Balance of coin i
    function balances(uint256 i) external view returns (uint256);
}
