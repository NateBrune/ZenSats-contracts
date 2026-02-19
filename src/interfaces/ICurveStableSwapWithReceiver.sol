// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveStableSwapWithReceiver
/// @notice Optional Curve exchange variant that supports specifying a receiver
interface ICurveStableSwapWithReceiver {
    /// @notice Exchange tokens to a receiver
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @param min_dy Minimum amount of output token
    /// @param receiver Address to receive the output token
    /// @return Amount of output token received
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);
}
