// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "../BaseYieldStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";
import { IYieldVault } from "../../interfaces/IYieldVault.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";

/// @title BaseVaultStrategy
/// @notice Abstract base for "vault strategies" — strategies that deposit ONE asset into an
///         external ERC4626 vault and let the vault auto-compound. No LP, no rewards loop.
/// @dev When the debt asset already equals the vault's accepted asset, subclasses inherit the
///      defaults verbatim (1:1 swaps + 1:1 value conversion). When a swap layer is needed
///      (e.g. USDT → crvUSD before depositing into an IPOR PlasmaVault), subclasses override:
///        - _swapDebtToVaultAsset(amount, slippage)         — actual entry swap
///        - _swapVaultAssetToDebt(amount, slippage)         — actual exit swap
///        - _convertVaultAssetValueToDebt(amount) view      — oracle-based valuation
///      Withdrawals may transiently revert when oracles are stale or pool slippage spikes;
///      no funds are stuck because all state changes revert atomically.
abstract contract BaseVaultStrategy is BaseYieldStrategy {
    // ============ Immutables ============

    /// @notice External ERC4626 vault holding the strategy's deployed assets.
    IYieldVault public immutable yieldVault;

    // ============ Constructor ============

    /// @param _debtAsset  Token accepted from the vault.
    /// @param _vault      Zenji vault (or zero for deferred initialization).
    /// @param _owner      Initial admin (or zero to default to msg.sender).
    /// @param _yieldVault External ERC4626 yield vault address.
    constructor(address _debtAsset, address _vault, address _owner, address _yieldVault)
        BaseYieldStrategy(_debtAsset, _vault, _owner)
    {
        if (_yieldVault == address(0)) revert InvalidAddress();
        yieldVault = IYieldVault(_yieldVault);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view virtual override returns (address) {
        return yieldVault.asset();
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view virtual override returns (uint256) {
        uint256 vaultAssetValue = _vaultBalance();
        if (vaultAssetValue < 1) return 0;
        return _convertVaultAssetValueToDebt(vaultAssetValue);
    }

    /// @inheritdoc IYieldStrategy
    /// @dev External vaults that auto-compound have no separately-claimable rewards. Override
    ///      if a derived strategy wraps a vault that pays out external incentives.
    function pendingRewards() external view virtual override returns (uint256) {
        return 0;
    }

    // ============ Core Flow ============

    /// @dev 1) Optionally swap debt → vault asset. 2) Deposit into the vault.
    function _deposit(uint256 debtAmount) internal virtual override returns (uint256 underlyingDeposited) {
        uint256 vaultAssetAmount = _swapDebtToVaultAsset(debtAmount, slippageTolerance);
        if (vaultAssetAmount == 0) return 0;
        underlyingDeposited = _depositToVault(vaultAssetAmount);
    }

    /// @dev 1) Compute share-proportional redeem amount. 2) Redeem from vault.
    ///      3) Optionally swap vault asset → debt.
    function _withdraw(uint256 debtAmount) internal virtual override returns (uint256 received) {
        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;

        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares < 1) return 0;

        uint256 sharesToRedeem = (shares * debtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem < 1) return 0;

        uint256 vaultAssetReceived = _redeemFromVault(sharesToRedeem);
        if (vaultAssetReceived == 0) return 0;
        received = _swapVaultAssetToDebt(vaultAssetReceived, slippageTolerance);
    }

    /// @dev Redeem all, then optionally swap vault asset → debt at the normal slippage.
    function _withdrawAll() internal virtual override returns (uint256 received) {
        uint256 vaultAssetReceived = _redeemAllFromVault();
        if (vaultAssetReceived == 0) return 0;
        received = _swapVaultAssetToDebt(vaultAssetReceived, slippageTolerance);
    }

    /// @dev Same as _withdrawAll but at EMERGENCY_SLIPPAGE.
    function _emergencyWithdraw() internal virtual override returns (uint256 received) {
        uint256 vaultAssetReceived = _redeemAllFromVault();
        if (vaultAssetReceived == 0) return 0;
        received = _swapVaultAssetToDebt(vaultAssetReceived, EMERGENCY_SLIPPAGE);
    }

    /// @dev External ERC4626 vaults auto-compound; no claimable rewards by default.
    function _harvest() internal virtual override returns (uint256) {
        return 0;
    }

    // ============ Vault Helpers ============

    /// @notice Deposit `vaultAssetAmount` into the external vault.
    /// @return vaultAssetDeposited Vault-asset value of the shares minted (for event metadata).
    function _depositToVault(uint256 vaultAssetAmount) internal returns (uint256 vaultAssetDeposited) {
        _ensureApprove(yieldVault.asset(), address(yieldVault), vaultAssetAmount);
        uint256 sharesMinted = yieldVault.deposit(vaultAssetAmount, address(this));
        vaultAssetDeposited = yieldVault.convertToAssets(sharesMinted);
    }

    /// @notice Redeem `shares` from the external vault.
    function _redeemFromVault(uint256 shares) internal returns (uint256 vaultAssetReceived) {
        vaultAssetReceived = yieldVault.redeem(shares, address(this), address(this));
    }

    /// @notice Redeem all shares from the external vault.
    function _redeemAllFromVault() internal returns (uint256 vaultAssetReceived) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares < 1) return 0;
        vaultAssetReceived = yieldVault.redeem(shares, address(this), address(this));
    }

    /// @notice Vault-asset value of all shares currently held by this strategy.
    function _vaultBalance() internal view returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares < 1) return 0;
        return yieldVault.convertToAssets(shares);
    }

    // ============ Swap / Conversion Hooks ============

    /// @notice Convert a vault-asset-denominated amount into debt-asset terms (oracle, no swap).
    /// @dev Default: 1:1 (use when debt asset == vault asset).
    function _convertVaultAssetValueToDebt(uint256 vaultAssetAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        return vaultAssetAmount;
    }

    /// @notice Actual debt → vault-asset swap before depositing into the vault.
    /// @dev Default: 1:1 pass-through (no swap needed when debt asset == vault asset).
    function _swapDebtToVaultAsset(uint256 debtAmount, uint256 /*slippage*/)
        internal
        virtual
        returns (uint256)
    {
        return debtAmount;
    }

    /// @notice Actual vault-asset → debt swap after redeeming from the vault.
    /// @dev Default: 1:1 pass-through.
    function _swapVaultAssetToDebt(uint256 vaultAssetAmount, uint256 /*slippage*/)
        internal
        virtual
        returns (uint256)
    {
        return vaultAssetAmount;
    }

    // ============ Protected Tokens ============

    /// @dev Protect the vault shares (yieldVault is itself an ERC20) on top of the debt asset.
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(yieldVault)
            || token == yieldVault.asset();
    }
}
