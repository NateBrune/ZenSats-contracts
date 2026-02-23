// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Chainlink Automation-compatible interface
interface AutomationCompatibleInterface {
    /// @notice Simulated by automation nodes to determine if upkeep is needed
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Called by automation nodes (or anyone) to perform upkeep
    function performUpkeep(bytes calldata performData) external;
}
