// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IUniswapV2Router
/// @notice Minimal interface for SushiSwap/Uniswap V2 Router
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
