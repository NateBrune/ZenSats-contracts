// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveTwoCryptoInt128
/// @notice Legacy TwoCrypto interface using int128 indices
interface ICurveTwoCryptoInt128 {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);
}
