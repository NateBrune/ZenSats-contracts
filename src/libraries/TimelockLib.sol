// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title TimelockLib
/// @notice Library for managing timelocked parameter changes
library TimelockLib {
    struct TimelockData {
        uint256 pendingValue;
        uint256 timestamp;
    }

    /// @notice Expiry window after timelock becomes ready (7 days)
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;

    error NoTimelockPending();
    error TimelockNotReady();
    error TimelockExpired();

    /// @notice Propose a new value with timelock delay
    function propose(TimelockData storage data, uint256 newValue, uint256 delay) internal {
        data.pendingValue = newValue;
        data.timestamp = block.timestamp + delay;
    }

    /// @notice Execute pending value change after timelock
    /// @return newValue The new value that was set
    function execute(TimelockData storage data) internal returns (uint256 newValue) {
        if (data.timestamp == 0) revert NoTimelockPending();
        if (block.timestamp < data.timestamp) revert TimelockNotReady();
        if (block.timestamp > data.timestamp + TIMELOCK_EXPIRY) revert TimelockExpired();

        newValue = data.pendingValue;
        data.pendingValue = 0;
        data.timestamp = 0;
    }

    /// @notice Cancel pending value change
    /// @return cancelledValue The value that was cancelled
    function cancel(TimelockData storage data) internal returns (uint256 cancelledValue) {
        if (data.timestamp == 0) revert NoTimelockPending();
        cancelledValue = data.pendingValue;
        data.pendingValue = 0;
        data.timestamp = 0;
    }

    /// @notice Check if timelock is pending
    function isPending(TimelockData storage data) internal view returns (bool) {
        return data.timestamp != 0;
    }

    /// @notice Check if timelock is ready to execute
    function isReady(TimelockData storage data) internal view returns (bool) {
        return data.timestamp != 0 && block.timestamp >= data.timestamp;
    }

    // ============ Address Timelock Functions ============

    struct AddressTimelockData {
        address pendingValue;
        uint256 timestamp;
    }

    /// @notice Propose a new address value with timelock delay
    function proposeAddress(AddressTimelockData storage data, address newValue, uint256 delay)
        internal
    {
        data.pendingValue = newValue;
        data.timestamp = block.timestamp + delay;
    }

    /// @notice Execute pending address change after timelock
    /// @return newValue The new address that was set
    function executeAddress(AddressTimelockData storage data) internal returns (address newValue) {
        if (data.timestamp == 0) revert NoTimelockPending();
        if (block.timestamp < data.timestamp) revert TimelockNotReady();
        if (block.timestamp > data.timestamp + TIMELOCK_EXPIRY) revert TimelockExpired();

        newValue = data.pendingValue;
        data.pendingValue = address(0);
        data.timestamp = 0;
    }

    /// @notice Cancel pending address change
    /// @return cancelledValue The address that was cancelled
    function cancelAddress(AddressTimelockData storage data)
        internal
        returns (address cancelledValue)
    {
        if (data.timestamp == 0) revert NoTimelockPending();
        cancelledValue = data.pendingValue;
        data.pendingValue = address(0);
        data.timestamp = 0;
    }
}
