// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IUniversalRouter
/// @notice Minimal interface for Uniswap Universal Router execute entrypoints
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}
