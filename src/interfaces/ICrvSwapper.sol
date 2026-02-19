// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICrvSwapper
/// @notice Minimal interface for CRV -> crvUSD swapper contracts
interface ICrvSwapper {
    /// @notice Swap CRV into crvUSD
    /// @param amount CRV amount to swap
    /// @return crvUsdReceived Amount of crvUSD received
    function swap(uint256 amount) external returns (uint256 crvUsdReceived);
}
