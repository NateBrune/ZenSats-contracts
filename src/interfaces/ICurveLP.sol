// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface ICurveLP {
    /// @notice Add liquidity to the pool
    /// @param _amounts Array of amounts of coins to add
    /// @param _min_mint_amount Minimum amount of LP tokens to mint
    /// @return Amount of LP tokens minted
    function add_liquidity(uint256[] calldata _amounts, uint256 _min_mint_amount)
        external
        returns (uint256);

    /// @notice Add liquidity to the pool with a receiver
    /// @param _amounts Array of amounts of coins to add
    /// @param _min_mint_amount Minimum amount of LP tokens to mint
    /// @param _receiver Address to receive LP tokens
    /// @return Amount of LP tokens minted
    function add_liquidity(uint256[] calldata _amounts, uint256 _min_mint_amount, address _receiver)
        external
        returns (uint256);

    /// @notice Remove liquidity from the pool in a single coin
    /// @param _burn_amount Amount of LP tokens to burn
    /// @param i int128 Index of the coin to receive
    /// @param _min_received Minimum amount of coin to receive
    /// @return Amount of coin received
    function remove_liquidity_one_coin(uint256 _burn_amount, int128 i, uint256 _min_received)
        external
        returns (uint256);

    /// @notice Remove liquidity from the pool in a single coin with a receiver
    /// @param _burn_amount Amount of LP tokens to burn
    /// @param i int128 Index of the coin to receive
    /// @param _min_received Minimum amount of coin to receive
    /// @param _receiver Address to receive coin
    /// @return Amount of coin received
    function remove_liquidity_one_coin(
        uint256 _burn_amount,
        int128 i,
        uint256 _min_received,
        address _receiver
    ) external returns (uint256);

    /// @notice Calculate the amount of LP tokens minted for a given set of amounts
    /// @param _amounts Array of amounts of coins
    /// @param _is_deposit Whether it's a deposit or withdrawal
    /// @return Amount of LP tokens
    function calc_token_amount(uint256[] calldata _amounts, bool _is_deposit)
        external
        view
        returns (uint256);

    /// @notice Calculate the amount of coin received for burning a given amount of LP tokens
    /// @param _burn_amount Amount of LP tokens
    /// @param i Index of the coin
    /// @return Amount of coin
    function calc_withdraw_one_coin(uint256 _burn_amount, int128 i) external view returns (uint256);

    /// @notice Get the address of a coin in the pool
    /// @param i Index of the coin
    /// @return Address of the coin
    function coins(uint256 i) external view returns (address);

    /// @notice Get the balance of a coin in the pool
    /// @param i Index of the coin
    /// @return Balance of the coin
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get the virtual price of the LP token
    /// @return Virtual price
    function get_virtual_price() external view returns (uint256);
}
