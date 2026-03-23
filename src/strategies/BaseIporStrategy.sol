// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "./BaseYieldStrategy.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IYieldVault } from "../interfaces/IYieldVault.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

/// @title BaseIporStrategy
/// @notice Abstract base for IPOR PlasmaVault strategies
/// @dev Provides shared deposit/redeem/balance helpers for IPOR vault interactions
abstract contract BaseIporStrategy is BaseYieldStrategy {
    // ============ Constants ============

    uint256 public constant MIN_SLIPPAGE = 1e15;      // 0.1%
    uint256 public constant DEFAULT_SLIPPAGE = 1e16;  // 1%
    uint256 public constant MAX_SLIPPAGE = 5e16;      // 5%
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17; // 10%

    // ============ Immutables ============

    /// @notice IPOR PlasmaVault
    IYieldVault public immutable iporVault;

    // ============ State ============

    address public owner;
    uint256 public slippageTolerance;

    // ============ Events ============

    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    // ============ Constructor ============

    constructor(address _debtAsset, address _vault, address _iporVault)
        BaseYieldStrategy(_debtAsset, _vault)
    {
        if (_iporVault == address(0)) revert InvalidAddress();
        iporVault = IYieldVault(_iporVault);
        owner = msg.sender;
        slippageTolerance = DEFAULT_SLIPPAGE;
    }

    // ============ Admin ============

    /// @notice Transfer strategy ownership directly, initiated by the vault upon gov transfer.
    /// @dev Bypasses any timelock. Only callable by the vault.
    function transferOwnerFromVault(address newOwner) external override {
        if (msg.sender != vault) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Update strategy slippage tolerance.
    /// @dev Callable by vault or owner.
    function setSlippage(uint256 newSlippage) external virtual override {
        if (msg.sender != vault && msg.sender != owner) revert Unauthorized();
        if (newSlippage < MIN_SLIPPAGE || newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 old = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(old, newSlippage);
    }

    // ============ IPOR Helpers ============

    /// @notice Deposit amount into IPOR vault, returns shares minted
    function _depositToIpor(uint256 amount) internal returns (uint256 sharesMinted) {
        _ensureApprove(address(debtAsset), address(iporVault), amount);
        sharesMinted = iporVault.deposit(amount, address(this));
    }

    /// @notice Redeem specific number of shares from IPOR vault
    function _redeemFromIpor(uint256 shares) internal returns (uint256 received) {
        received = iporVault.redeem(shares, address(this), address(this));
    }

    /// @notice Redeem all shares from IPOR vault
    function _redeemAllFromIpor() internal returns (uint256 received) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares < 1) return 0;
        received = iporVault.redeem(shares, address(this), address(this));
    }

    /// @notice Get total value in IPOR vault (in underlying asset terms)
    function _iporBalance() internal view returns (uint256) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares < 1) return 0;
        return iporVault.convertToAssets(shares);
    }

    // ============ Default Implementations ============

    /// @inheritdoc BaseYieldStrategy
    function _harvest() internal virtual override returns (uint256) {
        return 0; // IPOR auto-compounds
    }

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external pure virtual override returns (uint256) {
        return 0; // IPOR auto-compounds
    }
}
