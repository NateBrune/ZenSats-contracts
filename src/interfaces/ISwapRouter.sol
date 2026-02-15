// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ISwapRouter
/// @notice Minimal Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
