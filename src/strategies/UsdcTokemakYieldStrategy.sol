// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTokemakStrategy} from "./BaseTokemakStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

/// @title UsdcTokemakYieldStrategy
/// @notice Deposits USDC directly into Tokemak autoUSD vault and stakes shares via AutopilotRouter.
///         No Curve swap needed — USDC is the native asset of the Tokemak autoUSD vault.
///         Harvesting TOKE rewards is deferred to a future implementation.
contract UsdcTokemakYieldStrategy is BaseTokemakStrategy {
    constructor(address _usdc, address _vault, address _tokemakVault, address _router, address _rewarder)
        BaseTokemakStrategy(_usdc, _vault, _tokemakVault, _router, _rewarder)
    {}

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(debtAsset);
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        return _tokemakBalance();
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDC Tokemak autoUSD Strategy";
    }

    // ============ Internal Functions ============

    function _deposit(uint256 usdcAmount) internal override returns (uint256 underlyingDeposited) {
        _depositAndStake(usdcAmount);
        underlyingDeposited = usdcAmount;
    }

    function _withdraw(uint256 usdcAmount) internal override returns (uint256 usdcReceived) {
        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;

        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares < 1) return 0;

        uint256 sharesToRedeem = (stakedShares * usdcAmount) / currentValue;
        if (sharesToRedeem > stakedShares) sharesToRedeem = stakedShares;
        if (sharesToRedeem < 1) return 0;

        usdcReceived = _unstakeAndRedeem(sharesToRedeem);
    }

    function _withdrawAll() internal override returns (uint256 usdcReceived) {
        usdcReceived = _unstakeAndRedeemAll();
    }

    function _emergencyWithdraw() internal override returns (uint256 usdcReceived) {
        usdcReceived = _unstakeAndRedeemAll();
    }

    function _harvest() internal override returns (uint256) {
        return 0;
    }
}
