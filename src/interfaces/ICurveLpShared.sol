// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveLpShared
/// @notice Minimal Curve pool interface covering the three methods that are identical across
///         legacy 2-coin StableSwap pools and StableSwapNG pools: virtual price, single-coin
///         withdrawal quote, and single-coin removal. Used by BaseCurveStakeDaoStrategy for the
///         pool-type-agnostic hooks (balanceOf, _lpUnitValue, _removeLiquidity). Add-liquidity
///         differs between pool types (fixed vs dynamic array), so it is NOT included here —
///         each strategy casts to its full-typed interface for _addLiquidity.
interface ICurveLpShared {
    function get_virtual_price() external view returns (uint256);
    function calc_withdraw_one_coin(uint256 burnAmount, int128 i) external view returns (uint256);
    function remove_liquidity_one_coin(uint256 burnAmount, int128 i, uint256 minReceived)
        external
        returns (uint256);
}
