// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "./BaseYieldStrategy.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IYieldVault } from "../interfaces/IYieldVault.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

/// @title IporYieldStrategy
/// @notice Yield strategy that deposits crvUSD directly into IPOR PlasmaVault
/// @dev No swaps required - IPOR vault accepts crvUSD directly
contract IporYieldStrategy is BaseYieldStrategy {
    // ============ Immutables ============

    /// @notice IPOR PlasmaVault (Llamarisk crvUSD vault)
    IYieldVault public immutable iporVault;

    // ============ Constructor ============

    /// @param _crvUSD crvUSD token address
    /// @param _vault Zenji address
    /// @param _iporVault IPOR PlasmaVault address
    constructor(address _crvUSD, address _vault, address _iporVault)
        BaseYieldStrategy(_crvUSD, _vault)
    {
        if (_iporVault == address(0)) revert InvalidAddress();
        iporVault = IYieldVault(_iporVault);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(crvUSD); // IPOR vault uses crvUSD directly
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;
        return iporVault.convertToAssets(shares);
    }

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external pure override returns (uint256) {
        // IPOR vault auto-compounds, no separate rewards
        return 0;
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "IPOR PlasmaVault Strategy";
    }

    // ============ Internal Functions ============

    /// @inheritdoc BaseYieldStrategy
    function _deposit(uint256 crvUsdAmount)
        internal
        override
        returns (uint256 underlyingDeposited)
    {
        _ensureApprove(address(crvUSD), address(iporVault), crvUsdAmount);
        iporVault.deposit(crvUsdAmount, address(this));
        underlyingDeposited = crvUsdAmount;
    }

    /// @inheritdoc BaseYieldStrategy
    function _withdraw(uint256 crvUsdAmount) internal override returns (uint256 crvUsdReceived) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        uint256 sharesToRedeem = iporVault.convertToShares(crvUsdAmount);
        if (sharesToRedeem > shares) {
            sharesToRedeem = shares;
        }

        if (sharesToRedeem > 0) {
            crvUsdReceived = iporVault.redeem(sharesToRedeem, address(this), address(this));
        }
    }

    /// @inheritdoc BaseYieldStrategy
    function _withdrawAll() internal override returns (uint256 crvUsdReceived) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        crvUsdReceived = iporVault.redeem(shares, address(this), address(this));
    }

    /// @inheritdoc BaseYieldStrategy
    function _harvest() internal pure override returns (uint256 rewardsValue) {
        // IPOR vault auto-compounds, nothing to harvest
        return 0;
    }

    /// @inheritdoc BaseYieldStrategy
    function _emergencyWithdraw() internal override returns (uint256 crvUsdReceived) {
        return _withdrawAll();
    }
}
