// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveThreeCrypto
/// @notice Interface for Curve TriCrypto-style pools (3-token crypto pools)
interface ICurveThreeCrypto {
    /// @notice Exchange tokens with optional ETH handling
    /// @param i Index of input coin (0..2)
    /// @param j Index of output coin (0..2)
    /// @param dx Amount of input coin
    /// @param min_dy Minimum amount of output coin
    /// @param use_eth Whether to wrap/unwrap ETH (keep false for ERC20 swaps)
    /// @return Amount of output coin received
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, bool use_eth)
        external
        returns (uint256);

    /// @notice Get expected output amount
    /// @param i Index of input coin
    /// @param j Index of output coin
    /// @param dx Amount of input coin
    /// @return Expected output amount
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);

    /// @notice Get coin address by index
    /// @param i Coin index
    /// @return Coin address
    function coins(uint256 i) external view returns (address);

    /// @notice Get pool balances
    /// @param i Coin index
    /// @return Balance of coin i
    function balances(uint256 i) external view returns (uint256);
}
