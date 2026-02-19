// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { TimelockLib } from "../../libraries/TimelockLib.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";

/// @title BaseSwapper
/// @notice Shared governance + timelocked slippage for all swappers
abstract contract BaseSwapper {
    using TimelockLib for TimelockLib.TimelockData;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public slippage;

    address public gov;
    address public pendingGov;
    TimelockLib.TimelockData private _slippageTimelock;

    event GovernanceTransferStarted(address indexed previousGov, address indexed newGov);
    event GovernanceUpdated(address indexed newGov);
    event SlippageProposed(uint256 newSlippage, uint256 executeAfter);
    event SlippageExecuted(uint256 newSlippage);
    event SlippageCancelled();

    error Unauthorized();
    error InvalidSlippage();

    modifier onlyGov() {
        if (msg.sender != gov) revert Unauthorized();
        _;
    }

    constructor(address _gov) {
        if (_gov == address(0)) revert ISwapper.InvalidAddress();
        gov = _gov;
        slippage = 5e16; // 5% initial slippage
    }

    /// @notice Propose new slippage tolerance
    /// @param newSlippage New slippage in 1e18 precision (e.g., 5e16 = 5%)
    function proposeSlippage(uint256 newSlippage) external onlyGov {
        if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
        _slippageTimelock.propose(newSlippage, TIMELOCK_DELAY);
        emit SlippageProposed(newSlippage, block.timestamp + TIMELOCK_DELAY);
    }

    /// @notice Execute slippage change after timelock
    function executeSlippage() external onlyGov {
        uint256 newSlippage = _slippageTimelock.execute();
        slippage = newSlippage;
        emit SlippageExecuted(newSlippage);
    }

    /// @notice Cancel pending slippage change
    function cancelSlippage() external onlyGov {
        _slippageTimelock.cancel();
        emit SlippageCancelled();
    }

    /// @notice Start governance transfer
    function transferGovernance(address newGov_) external onlyGov {
        if (newGov_ == address(0)) revert ISwapper.InvalidAddress();
        pendingGov = newGov_;
        emit GovernanceTransferStarted(gov, newGov_);
    }

    /// @notice Accept governance transfer
    function acceptGovernance() external {
        if (msg.sender != pendingGov) revert Unauthorized();
        gov = msg.sender;
        pendingGov = address(0);
        emit GovernanceUpdated(msg.sender);
    }
}
