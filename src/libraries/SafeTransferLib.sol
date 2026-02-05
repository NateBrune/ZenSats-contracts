// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Gas-efficient safe transfer functions for ERC20 tokens
library SafeTransferLib {
    error TransferFailed();

    /// @notice Safe transfer that reverts on failure
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Safe transferFrom that reverts on failure
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Ensure approval is sufficient, set to max if not
    /// @dev Uses safeApprove pattern for USDT compatibility (non-standard ERC20)
    function ensureApproval(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            safeApprove(token, spender, type(uint256).max);
        }
    }

    /// @notice Safe approve that handles non-standard ERC20 tokens like USDT
    /// @dev USDT requires setting allowance to 0 first before setting a new non-zero value
    ///      and returns void instead of bool
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        // For USDT: first reset to 0 if there's existing allowance and we're setting non-zero
        if (amount > 0 && token.allowance(address(this), spender) > 0) {
            (bool resetSuccess, ) = address(token).call(
                abi.encodeWithSelector(token.approve.selector, spender, 0)
            );
            // Ignore return value for void-returning tokens like USDT
            if (!resetSuccess) revert TransferFailed();
        }

        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
        // Handle both standard (returns bool) and non-standard (returns nothing) ERC20
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}
