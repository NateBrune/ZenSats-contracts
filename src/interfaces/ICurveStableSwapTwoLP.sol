// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ICurveStableSwap } from "./ICurveStableSwap.sol";

/// @title ICurveStableSwapTwoLP
/// @notice Liquidity surface for legacy 2-coin Curve StableSwap pools (fixed-size arrays,
///         int128 coin indices). Extends ICurveStableSwap with add/remove/calc helpers.
interface ICurveStableSwapTwoLP is ICurveStableSwap {
    /// @notice Add liquidity to the pool.
    function add_liquidity(uint256[2] memory _amounts, uint256 _min_mint_amount)
        external
        returns (uint256);

    /// @notice Remove liquidity single-sided to coin `i`.
    function remove_liquidity_one_coin(uint256 _burn_amount, int128 i, uint256 _min_received)
        external
        returns (uint256);

    /// @notice Estimate LP tokens minted/burned for a given balanced add/remove.
    function calc_token_amount(uint256[2] memory _amounts, bool _is_deposit)
        external
        view
        returns (uint256);

    /// @notice Estimate single-sided withdrawal amount.
    function calc_withdraw_one_coin(uint256 _burn_amount, int128 i)
        external
        view
        returns (uint256);
}
