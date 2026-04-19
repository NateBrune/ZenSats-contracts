// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ISwapper } from "../../interfaces/ISwapper.sol";

/// @title BaseSwapper
/// @notice Shared governance + direct slippage for all swappers.
///         Slippage can be set immediately by gov or by the registered vault.
abstract contract BaseSwapper {
    uint256 public constant PRECISION = 1e18;
    uint256 public slippage;

    address public gov;
    address public pendingGov;
    /// @notice Vault address authorised to call setSlippage (set once via setVault)
    address public vault;

    event GovernanceTransferStarted(address indexed previousGov, address indexed newGov);
    event GovernanceUpdated(address indexed newGov);
    event GovTransferredFromVault(address indexed previousGov, address indexed newGov);
    event SlippageUpdated(uint256 newSlippage);
    event VaultSet(address indexed vault_);

    error Unauthorized();
    error InvalidSlippage();

    modifier onlyGov() {
        if (msg.sender != gov) revert Unauthorized();
        _;
    }

    constructor(address _gov) {
        if (_gov == address(0)) revert ISwapper.InvalidAddress();
        gov = _gov;
        slippage = 1e16; // 1% initial slippage
    }

    /// @notice Register the vault that is allowed to call setSlippage
    /// @dev Called once during deployment by gov. Only gov can call this.
    function setVault(address vault_) external onlyGov {
        if (vault_ == address(0)) revert ISwapper.InvalidAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice Set slippage tolerance directly
    /// @dev Callable by gov or the registered vault (vault propagates from setParam).
    /// @param newSlippage New slippage in 1e18 precision (e.g. 5e16 = 5%)
    function setSlippage(uint256 newSlippage) external virtual {
        if (msg.sender != gov && msg.sender != vault) revert Unauthorized();
        if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
        slippage = newSlippage;
        emit SlippageUpdated(newSlippage);
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

    /// @notice Transfer governance directly — callable only by the registered vault.
    /// @dev Mirrors transferOwnerFromVault in strategies. Bypasses two-step to match
    ///      vault-initiated ownership handoffs during protocol migrations.
    function transferGovFromVault(address newGov_) external {
        if (msg.sender != vault) revert Unauthorized();
        if (newGov_ == address(0)) revert ISwapper.InvalidAddress();
        emit GovTransferredFromVault(gov, newGov_);
        gov = newGov_;
        pendingGov = address(0);
    }
}
