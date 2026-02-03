// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IUniswapV2Pair
/// @notice Minimal interface for UniswapV2/SushiSwap pair contracts
interface IUniswapV2Pair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external;
}
