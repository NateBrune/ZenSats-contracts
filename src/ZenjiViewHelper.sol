// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { IERC20 } from "./interfaces/IERC20.sol";

interface IZenjiView {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getTotalCollateral() external view returns (uint256);
    function loanManager() external view returns (ILoanManager);
    function collateralAsset() external view returns (IERC20);
    function debtAsset() external view returns (IERC20);
    function yieldEnabled() external view returns (bool);
    function targetLtv() external view returns (uint256);
    function DEADBAND_SPREAD() external view returns (uint256);
    function feeRate() external view returns (uint256);
    function PRECISION() external view returns (uint256);
    function accumulatedFees() external view returns (uint256);
    function lastStrategyBalance() external view returns (uint256);
    function yieldStrategy() external view returns (IYieldStrategy);
}

/// @title ZenjiViewHelper
/// @notice External helper for view utilities to reduce Zenji bytecode size
contract ZenjiViewHelper {
    function getUserValue(address vault, address user) external view returns (uint256 collateralValue) {
        IZenjiView v = IZenjiView(vault);
        uint256 supply = v.totalSupply();
        if (supply == 0) return 0;
        uint256 userShares = v.balanceOf(user);
        return (v.getTotalCollateral() * userShares) / supply;
    }

    function getHealth(address vault) external view returns (int256 health) {
        return IZenjiView(vault).loanManager().getHealth();
    }

    function isRebalanceNeeded(address vault) external view returns (bool needed) {
        ILoanManager lm = IZenjiView(vault).loanManager();
        if (!lm.loanExists()) return false;
        uint256 ltv = lm.getCurrentLTV();
        uint256 target = IZenjiView(vault).targetLtv();
        uint256 deadband = IZenjiView(vault).DEADBAND_SPREAD();
        return ltv < (target - deadband) || ltv > (target + deadband);
    }

    function getLtvBounds(address vault) external view returns (uint256 lowerBand, uint256 upperBand) {
        IZenjiView v = IZenjiView(vault);
        uint256 target = v.targetLtv();
        uint256 deadband = v.DEADBAND_SPREAD();
        lowerBand = target - deadband;
        upperBand = target + deadband;
    }

    function getPendingFees(address vault)
        external
        view
        returns (uint256 totalFees, uint256 pendingFees)
    {
        IZenjiView v = IZenjiView(vault);
        IYieldStrategy strategy = v.yieldStrategy();
        uint256 strategyBalance = strategy.balanceOf();
        uint256 lastBalance = v.lastStrategyBalance();
        if (strategyBalance > lastBalance) {
            uint256 delta = strategyBalance - lastBalance;
            pendingFees = (delta * v.feeRate()) / v.PRECISION();
        }

        totalFees = v.accumulatedFees() + pendingFees;
    }

    /// @notice Get total value in collateral asset units (e.g., WBTC satoshis)
    /// @dev Computes all values natively in collateral terms to avoid double conversion errors
    function getTotalCollateralValue(address vault) external view returns (uint256 totalValue) {
        IZenjiView v = IZenjiView(vault);
        ILoanManager lm = v.loanManager();

        if (!v.yieldEnabled()) {
            return v.collateralAsset().balanceOf(vault);
        }

        // Idle collateral in vault (native units)
        totalValue = v.collateralAsset().balanceOf(vault);

        // Net collateral value in loan manager (collateral - debt in collateral terms)
        totalValue += lm.getNetCollateralValue();

        // Yield strategy balance converted to collateral (excluding fees)
        IYieldStrategy strategy = v.yieldStrategy();
        if (address(strategy) != address(0)) {
            uint256 strategyBalance = strategy.balanceOf();
            uint256 accFees = v.accumulatedFees();
            if (strategyBalance > accFees) {
                totalValue += lm.getDebtValue(strategyBalance - accFees);
            }
        }

        // Idle debt asset in vault converted to collateral
        uint256 idleDebt = v.debtAsset().balanceOf(vault);
        if (idleDebt > 0) {
            totalValue += lm.getDebtValue(idleDebt);
        }

        // Raw collateral in loan manager (not yet supplied)
        totalValue += lm.getCollateralBalance();

        // Raw debt asset in loan manager converted to collateral
        uint256 lmDebt = lm.getDebtBalance();
        if (lmDebt > 0) {
            totalValue += lm.getDebtValue(lmDebt);
        }
    }

    /// @notice Get total value in debt asset units (for diagnostics/logging)
    /// @dev This is a diagnostic function - use getTotalCollateralValue for actual accounting
    function getTotalDebtValue(address vault) external view returns (uint256 totalValue) {
        IZenjiView v = IZenjiView(vault);
        ILoanManager lm = v.loanManager();

        if (!v.yieldEnabled()) {
            uint256 idleCollateral = v.collateralAsset().balanceOf(vault);
            return lm.getCollateralValue(idleCollateral);
        }

        // Idle collateral converted to debt units
        uint256 idleCollateral = v.collateralAsset().balanceOf(vault);
        totalValue = lm.getCollateralValue(idleCollateral);

        // Position value in debt terms
        if (lm.loanExists()) {
            (uint256 collateral, uint256 debt) = lm.getPositionValues();
            uint256 collateralInDebt = lm.getCollateralValue(collateral);
            if (collateralInDebt > debt) {
                totalValue += collateralInDebt - debt;
            }
        }

        // Strategy balance (already in debt units, minus fees)
        IYieldStrategy strategy = v.yieldStrategy();
        if (address(strategy) != address(0)) {
            uint256 strategyBalance = strategy.balanceOf();
            uint256 accFees = v.accumulatedFees();
            if (strategyBalance > accFees) {
                totalValue += strategyBalance - accFees;
            }
        }

        // Idle debt in vault
        totalValue += v.debtAsset().balanceOf(vault);

        // Raw collateral in loan manager converted to debt
        uint256 lmCollateral = lm.getCollateralBalance();
        if (lmCollateral > 0) {
            totalValue += lm.getCollateralValue(lmCollateral);
        }

        // Raw debt in loan manager
        totalValue += lm.getDebtBalance();
    }

    function yieldCostBasis(address vault) external view returns (uint256) {
        return IZenjiView(vault).yieldStrategy().costBasis();
    }

    function getYieldStrategyStats(address vault)
        external
        view
        returns (
            string memory strategyName,
            uint256 currentValue,
            uint256 costBasis,
            uint256 unrealizedProfit
        )
    {
        IYieldStrategy strategy = IZenjiView(vault).yieldStrategy();
        strategyName = strategy.name();
        currentValue = strategy.balanceOf();
        costBasis = strategy.costBasis();
        unrealizedProfit = strategy.unrealizedProfit();
    }

    function getYieldVaultStats(address vault)
        external
        view
        returns (
            uint256 yieldShares,
            uint256 currentValue,
            uint256 costBasis,
            uint256 unrealizedProfit
        )
    {
        IYieldStrategy strategy = IZenjiView(vault).yieldStrategy();
        return (0, strategy.balanceOf(), strategy.costBasis(), strategy.unrealizedProfit());
    }
}
