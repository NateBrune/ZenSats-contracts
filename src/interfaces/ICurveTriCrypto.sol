// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ICurveTriCrypto
/// @notice Interface for Curve TriCrypto pool (crvUSD/CRV/WETH)
/// @dev Pool address: 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14
/// @dev Coin indices: 0 = crvUSD, 1 = CRV, 2 = WETH
interface ICurveTriCrypto {
    /// @notice Exchange tokens
    /// @param i Index of input coin
    /// @param j Index of output coin
    /// @param dx Amount of input coin
    /// @param min_dy Minimum amount of output coin
    /// @param use_eth Whether to use ETH (only relevant for WETH swaps)
    /// @return Amount of output coin received
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, bool use_eth)
        external
        payable
        returns (uint256);

    /// @notice Exchange tokens with receiver
    /// @param i Index of input coin
    /// @param j Index of output coin
    /// @param dx Amount of input coin
    /// @param min_dy Minimum amount of output coin
    /// @param use_eth Whether to use ETH
    /// @param receiver Address to receive output
    /// @return Amount of output coin received
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        bool use_eth,
        address receiver
    ) external payable returns (uint256);

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

    /// @notice Get price oracle value
    /// @param k Index (0 = coin1/coin0 price, 1 = coin2/coin0 price)
    /// @return Oracle price
    function price_oracle(uint256 k) external view returns (uint256);

    /// @notice Get last price
    /// @param k Index
    /// @return Last traded price
    function last_prices(uint256 k) external view returns (uint256);

    /// @notice Get LP token price
    /// @return LP token price
    function lp_price() external view returns (uint256);

    /// @notice Get virtual price
    /// @return Virtual price
    function virtual_price() external view returns (uint256);

    /// @notice Get pool balances
    /// @param i Coin index
    /// @return Balance of coin i
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get fee
    /// @return Fee in 1e10 precision
    function fee() external view returns (uint256);
}
