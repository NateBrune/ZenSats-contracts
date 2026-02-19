// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveStableSwapNG
/// @notice Interface for Curve StableSwapNG pools (e.g., pmUSD/crvUSD)
/// @dev Uses uint256 indices instead of int128 (NG pools use uint256)
interface ICurveStableSwapNG {
    /// @notice Add liquidity to the pool
    /// @param amounts Array of token amounts to deposit [coin0, coin1]
    /// @param min_mint_amount Minimum LP tokens to mint
    /// @return LP tokens minted
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount) external returns (uint256);

    /// @notice Remove liquidity in a single coin
    /// @param burn_amount Amount of LP tokens to burn
    /// @param i Index of coin to withdraw
    /// @param min_received Minimum amount of coin to receive
    /// @return Amount of coin received
    function remove_liquidity_one_coin(uint256 burn_amount, int128 i, uint256 min_received)
        external
        returns (uint256);

    /// @notice Calculate expected LP tokens from deposit
    /// @param amounts Array of token amounts [coin0, coin1]
    /// @param is_deposit True for deposit, false for withdrawal
    /// @return Expected LP token amount
    function calc_token_amount(uint256[] calldata amounts, bool is_deposit) external view returns (uint256);

    /// @notice Calculate expected output from removing liquidity in one coin
    /// @param burn_amount Amount of LP tokens to burn
    /// @param i Index of coin to withdraw
    /// @return Expected amount of coin received
    function calc_withdraw_one_coin(uint256 burn_amount, int128 i) external view returns (uint256);

    /// @notice Get the virtual price of the LP token
    /// @return Virtual price scaled by 1e18
    function get_virtual_price() external view returns (uint256);

    /// @notice Get coin address by index
    /// @param i Coin index
    /// @return Coin address
    function coins(uint256 i) external view returns (address);

    /// @notice Get pool balances
    /// @param i Coin index
    /// @return Balance of coin at index
    function balances(uint256 i) external view returns (uint256);

    /// @notice Exchange tokens
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @param min_dy Minimum amount of output token
    /// @return Amount of output token received
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);

    /// @notice Get expected output amount for exchange
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @return Expected output amount
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}
