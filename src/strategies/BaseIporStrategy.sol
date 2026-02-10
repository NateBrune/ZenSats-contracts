// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseYieldStrategy} from "./BaseYieldStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";
import {IYieldVault} from "../interfaces/IYieldVault.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title BaseIporStrategy
/// @notice Abstract base for IPOR PlasmaVault strategies
/// @dev Provides shared deposit/redeem/balance helpers for IPOR vault interactions
abstract contract BaseIporStrategy is BaseYieldStrategy {
    // ============ Immutables ============

    /// @notice IPOR PlasmaVault
    IYieldVault public immutable iporVault;

    // ============ Constructor ============

    constructor(address _debtAsset, address _vault, address _iporVault)
        BaseYieldStrategy(_debtAsset, _vault)
    {
        if (_iporVault == address(0)) revert InvalidAddress();
        iporVault = IYieldVault(_iporVault);
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
