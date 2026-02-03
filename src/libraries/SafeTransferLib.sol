// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Gas-efficient safe transfer functions for ERC20 tokens
library SafeTransferLib {
    error TransferFailed();

    /// @notice Safe transfer that reverts on failure
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    /// @notice Safe transferFrom that reverts on failure
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (!token.transferFrom(from, to, amount)) revert TransferFailed();
    }

    /// @notice Ensure approval is sufficient, set to max if not
    function ensureApproval(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.approve(spender, type(uint256).max);
        }
    }
}
