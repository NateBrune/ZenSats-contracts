// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../interfaces/ILoanManager.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import { SafeTransferLib } from "./SafeTransferLib.sol";

/// @title ZenjiCoreLib
/// @notice External library for Zenji admin and emergency operations
/// @dev Functions are `external` so they deploy separately and reduce Zenji bytecode.
///      Called via DELEGATECALL, so `address(this)` is the vault and token transfers work correctly.
library ZenjiCoreLib {
    using SafeTransferLib for IERC20;

    error InvalidAddress();
    error InsufficientWithdrawal();
    error InsufficientDeposit();
    error StrategyDebtCoverageTooLow(uint256 actual, uint256 minimum);

    event EmergencyYieldRedeemed(uint256 debtAssetReceived);
    event EmergencyLoanUnwound(uint256 collateralRecovered, uint256 debtRecovered);
    event LiquidationComplete(uint256 collateralRecovered, uint256 flashloanAmount);
    event EmergencyCollateralTransferred(uint256 amount);
    event EmergencyDebtTransferred(uint256 amount);
    event AssetsRescued(address indexed token, address indexed recipient, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);
    event StrategyDeposit(address indexed strategy, uint256 debtAmount, uint256 depositedAmount);

    /// @notice Execute emergency step: 0=withdrawYield, 1=unwindLoan, 2=completeLiquidation
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return setLiquidationComplete Whether to set liquidationComplete = true
    function executeEmergencyStep(
        uint8 step,
        IYieldStrategy yieldStrategy,
        ILoanManager loanManager,
        IERC20 collateralAsset,
        IERC20 debtAsset,
        ISwapper swapper,
        uint256 lastStrategyBalance,
        uint256 accumulatedFees
    )
        external
        returns (
            uint256 newLastStrategyBalance,
            uint256 newAccumulatedFees,
            bool setLiquidationComplete
        )
    {
        newLastStrategyBalance = lastStrategyBalance;
        newAccumulatedFees = accumulatedFees;

        if (step == 0) {
            uint256 withdrawn = 0;
            if (address(yieldStrategy) != address(0)) {
                try yieldStrategy.withdrawAll() returns (uint256 r) {
                    withdrawn = r;
                } catch {
                    try yieldStrategy.emergencyWithdraw() returns (uint256 r) {
                        withdrawn = r;
                    } catch { }
                }
            }
            newLastStrategyBalance = 0;
            newAccumulatedFees = 0;
            emit EmergencyYieldRedeemed(withdrawn);
        } else if (step == 1) {
            if (!loanManager.loanExists()) {
                _recoverLoanManagerFunds(loanManager);
                _swapRemainingDebtToCollateral(debtAsset, swapper);
                emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
                return (newLastStrategyBalance, newAccumulatedFees, false);
            }
            uint256 totalDebt = loanManager.getCurrentDebt();
            uint256 availableDebt = debtAsset.balanceOf(address(this));
            if (availableDebt >= totalDebt) {
                if (totalDebt > 0) {
                    debtAsset.safeTransfer(address(loanManager), totalDebt);
                    loanManager.repayDebt(totalDebt);
                }
                // Debt is fully repaid; withdraw collateral (e.g. aTokens) from the lending protocol.
                // unwindPosition handles zero-debt by skipping the flashloan and calling withdraw directly.
                loanManager.unwindPosition(type(uint256).max);
            } else {
                if (availableDebt > 0) {
                    debtAsset.safeTransfer(address(loanManager), availableDebt);
                }
                loanManager.unwindPosition(type(uint256).max);
            }
            _recoverLoanManagerFunds(loanManager);
            _swapRemainingDebtToCollateral(debtAsset, swapper);
            emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
        } else {
            setLiquidationComplete = true;
            emit LiquidationComplete(collateralAsset.balanceOf(address(this)), 0);
        }
    }

    /// @notice Emergency rescue: 0=transferCollateral, 1=transferDebt, 2=redeemYield
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    function executeEmergencyRescue(
        uint8 action,
        IERC20 collateralAsset,
        IERC20 debtAsset,
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        ISwapper swapper,
        uint256 accumulatedFees,
        uint256 lastStrategyBalance
    ) external returns (uint256 newAccumulatedFees, uint256 newLastStrategyBalance) {
        newAccumulatedFees = accumulatedFees;
        newLastStrategyBalance = lastStrategyBalance;
        if (action == 0) {
            uint256 amount = collateralAsset.balanceOf(address(loanManager));
            loanManager.transferCollateral(address(this), amount);
            emit EmergencyCollateralTransferred(amount);
        } else if (action == 1) {
            uint256 amount = debtAsset.balanceOf(address(loanManager));
            loanManager.transferDebt(address(this), amount);
            emit EmergencyDebtTransferred(amount);
        } else {
            uint256 withdrawn = yieldStrategy.emergencyWithdraw();
            newAccumulatedFees = 0;
            newLastStrategyBalance = 0;
            _swapRemainingDebtToCollateral(debtAsset, swapper);
            emit EmergencyYieldRedeemed(withdrawn);
        }
    }

    /// @notice Rescue stuck tokens (not collateral/debt) from the vault
    function executeRescueAssets(
        address token,
        address recipient,
        IERC20 collateralAsset,
        IERC20 debtAsset
    ) external {
        if (recipient == address(0)) revert InvalidAddress();
        if (token == address(collateralAsset) || token == address(debtAsset)) {
            revert InvalidAddress();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
        emit AssetsRescued(token, recipient, balance);
    }

    /// @notice Withdraw accumulated fees from yield strategy
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    function processWithdrawFees(
        address recipient,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 accumulatedFees
    ) external returns (uint256 newAccumulatedFees, uint256 newLastStrategyBalance) {
        uint256 fees = accumulatedFees;
        if (fees == 0) return (0, yieldStrategy.balanceOf());

        newAccumulatedFees = 0;

        uint256 strategyBalance = yieldStrategy.balanceOf();
        uint256 debtBefore = debtAsset.balanceOf(address(this));
        if (strategyBalance > 0 && fees > 0) {
            uint256 toWithdraw = fees > strategyBalance ? strategyBalance : fees;
            if (toWithdraw > 0) {
                uint256 received = yieldStrategy.withdraw(toWithdraw);
                debtBefore += received;
            }
        }
        newLastStrategyBalance = yieldStrategy.balanceOf();

        uint256 toTransfer = fees > debtBefore ? debtBefore : fees;
        if (toTransfer > 0) {
            debtAsset.safeTransfer(recipient, toTransfer);
        }

        emit FeesWithdrawn(recipient, toTransfer);
    }

    /// @notice Process rebalance keeper bounty payment
    /// @dev Keeper gets bountyRate% of fees accrued since last rebalance. Admin fees stay in strategy.
    /// @return newFeesAtLastRebalance Updated feesAtLastRebalance value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    /// @return bountyPaid Actual bounty amount withdrawn and paid to keeper (must be deducted from accumulatedFees)
    function processRebalanceBounty(
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 accumulatedFees,
        uint256 feesAtLastRebalance,
        uint256 rebalanceBountyRate,
        uint256 precision,
        address keeper
    )
        external
        returns (uint256 newFeesAtLastRebalance, uint256 newLastStrategyBalance, uint256 bountyPaid)
    {
        newFeesAtLastRebalance = feesAtLastRebalance;

        if (rebalanceBountyRate > 0 && accumulatedFees > feesAtLastRebalance) {
            uint256 feesSinceLastRebalance = accumulatedFees - feesAtLastRebalance;
            uint256 bounty = (feesSinceLastRebalance * rebalanceBountyRate) / precision;

            if (bounty > 0) {
                uint256 strategyBalance = yieldStrategy.balanceOf();
                uint256 toWithdraw = bounty > strategyBalance ? strategyBalance : bounty;
                if (toWithdraw > 0) {
                    uint256 withdrawn = yieldStrategy.withdraw(toWithdraw);
                    bountyPaid = withdrawn > bounty ? bounty : withdrawn;
                    if (bountyPaid > 0) {
                        debtAsset.safeTransfer(keeper, bountyPaid);
                        emit RebalanceBountyPaid(keeper, bountyPaid);
                    }
                }
            }

            newFeesAtLastRebalance = accumulatedFees;
        }

        newLastStrategyBalance = yieldStrategy.balanceOf();
    }

    /// @notice Increase strategy/debt coverage when strategy assets fall below debt.
    /// @dev Withdraws from strategy, repays debt, then does a simplified partial unwind
    ///      (triggering the loan manager flashloan path) if a deficit still remains.
    ///      NOTE: _accrueYieldFees is intentionally skipped — rebalance() already called it.
    /// @return newLastStrategyBalance Updated strategy balance for vault to store.
    function rebalanceCoverageUp(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 maxSlippage,
        uint256 precision
    ) external returns (uint256 newLastStrategyBalance) {
        uint256 debt = loanManager.getCurrentDebt();
        if (debt == 0) return yieldStrategy.balanceOf();

        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance >= debt) return strategyBalance;

        uint256 deficit = debt - strategyBalance;

        // Step 1: withdraw from strategy toward the deficit
        if (strategyBalance > 0) {
            uint256 toWithdraw = deficit > strategyBalance ? strategyBalance : deficit;
            uint256 minReceived = (toWithdraw * (precision - maxSlippage)) / precision;
            uint256 received = yieldStrategy.withdraw(toWithdraw);
            if (received < minReceived) revert InsufficientWithdrawal();
        }

        // Step 2: repay as much debt as possible
        uint256 debtBalance = debtAsset.balanceOf(address(this));
        uint256 repayAmount = debtBalance < deficit ? debtBalance : deficit;
        if (repayAmount > 0) {
            debtAsset.safeTransfer(address(loanManager), repayAmount);
            loanManager.repayDebt(repayAmount);
        }

        // Step 3: simplified partial unwind if deficit remains
        uint256 remainingDeficit = deficit > repayAmount ? deficit - repayAmount : 0;
        if (remainingDeficit > 0 && loanManager.loanExists()) {
            (uint256 positionCollateral, uint256 positionDebt) = loanManager.getPositionValues();
            if (positionCollateral > 0 && positionDebt > 0) {
                uint256 collateralNeeded =
                    (positionCollateral * remainingDeficit + positionDebt - 1) / positionDebt;
                if (collateralNeeded > positionCollateral) collateralNeeded = positionCollateral;

                debtBalance = debtAsset.balanceOf(address(this));
                if (debtBalance > 0) debtAsset.safeTransfer(address(loanManager), debtBalance);
                loanManager.unwindPosition(collateralNeeded);

                uint256 lmDebt = loanManager.getDebtBalance();
                if (lmDebt > 0) loanManager.transferDebt(address(this), lmDebt);
            }
        }

        return yieldStrategy.balanceOf();
    }

    /// @notice Decrease strategy/debt coverage when strategy assets are too far above debt.
    /// @dev Borrows additional debt bounded by LTV upper deadband and deploys to strategy.
    ///      NOTE: _accrueYieldFees is intentionally skipped — rebalance() already called it.
    /// @return newLastStrategyBalance Updated strategy balance for vault to store.
    function rebalanceCoverageDown(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 maxStrategyToDebtRatioForBorrow,
        uint256 maxLtvTarget,
        uint256 maxSlippage,
        uint256 precision
    ) external returns (uint256 newLastStrategyBalance) {
        uint256 debt = loanManager.getCurrentDebt();
        if (debt == 0) return yieldStrategy.balanceOf();

        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance <= debt) return strategyBalance;

        uint256 targetDebtAtMaxRatio = (strategyBalance * precision) / maxStrategyToDebtRatioForBorrow;
        if (targetDebtAtMaxRatio <= debt) return strategyBalance;

        (uint256 collateral,) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);
        uint256 maxDebtByLtv = (collateralValue * maxLtvTarget) / precision;
        if (maxDebtByLtv <= debt) return strategyBalance;

        uint256 requiredBorrow = targetDebtAtMaxRatio - debt;
        uint256 ltvRoom = maxDebtByLtv - debt;
        uint256 borrowAmount = requiredBorrow < ltvRoom ? requiredBorrow : ltvRoom;
        if (borrowAmount == 0) return strategyBalance;

        loanManager.borrowMore(0, borrowAmount);
        uint256 debtBalance = loanManager.getDebtBalance();
        if (debtBalance == 0) return yieldStrategy.balanceOf();

        loanManager.transferDebt(address(this), debtBalance);

        // Inline _deployDebtToYield without re-accruing fees
        debtAsset.ensureApproval(address(yieldStrategy), debtBalance);
        uint256 balBefore = yieldStrategy.balanceOf();
        yieldStrategy.deposit(debtBalance);
        uint256 balAfter = yieldStrategy.balanceOf();
        uint256 deposited = balAfter > balBefore ? balAfter - balBefore : 0;
        if (deposited < (debtBalance * (precision - maxSlippage)) / precision) {
            revert InsufficientDeposit();
        }

        return balAfter;
    }

    /// @notice Adjust LTV toward target by borrowing more or repaying debt.
    /// @dev Inlines the strategy deposit/withdraw logic without re-accruing fees because
    ///      `rebalance()` already accrued them before calling into the library.
    function adjustLtv(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 targetLtv,
        uint256 minStrategyToDebtRatioForBorrow,
        uint256 maxSlippage,
        uint256 precision,
        bool increase,
        bool enforceCoverageAfterIncrease
    ) external returns (uint256 newLastStrategyBalance) {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);
        uint256 targetDebt = (collateralValue * targetLtv) / precision;

        if (increase) {
            if (targetDebt <= currentDebt) return yieldStrategy.balanceOf();

            uint256 additionalBorrow = targetDebt - currentDebt;
            loanManager.borrowMore(0, additionalBorrow);
            uint256 debtBalance = loanManager.getDebtBalance();
            if (debtBalance == 0) return yieldStrategy.balanceOf();

            loanManager.transferDebt(address(this), debtBalance);
            debtAsset.ensureApproval(address(yieldStrategy), debtBalance);

            uint256 balBefore = yieldStrategy.balanceOf();
            yieldStrategy.deposit(debtBalance);
            uint256 balAfter = yieldStrategy.balanceOf();
            uint256 deposited = balAfter > balBefore ? balAfter - balBefore : 0;
            if (deposited < (debtBalance * (precision - maxSlippage)) / precision) {
                revert InsufficientDeposit();
            }
            emit StrategyDeposit(address(yieldStrategy), debtBalance, deposited);

            if (enforceCoverageAfterIncrease) {
                uint256 debt = loanManager.getCurrentDebt();
                if (debt > 0) {
                    uint256 ratio = (balAfter * precision) / debt;
                    if (ratio < minStrategyToDebtRatioForBorrow) {
                        revert StrategyDebtCoverageTooLow(ratio, minStrategyToDebtRatioForBorrow);
                    }
                }
            }

            return balAfter;
        }

        if (targetDebt >= currentDebt) return yieldStrategy.balanceOf();

        uint256 toRepay = currentDebt - targetDebt;
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance > 0) {
            uint256 toWithdraw = toRepay > strategyBalance ? strategyBalance : toRepay;
            if (toWithdraw > 0) {
                uint256 received = yieldStrategy.withdraw(toWithdraw);
                uint256 minReceived = (toWithdraw * (precision - maxSlippage)) / precision;
                if (received < minReceived) revert InsufficientWithdrawal();
            }
        }

        newLastStrategyBalance = yieldStrategy.balanceOf();
        uint256 availableDebtBalance = debtAsset.balanceOf(address(this));
        uint256 repayAmount = toRepay < availableDebtBalance ? toRepay : availableDebtBalance;
        if (repayAmount > 0) {
            debtAsset.safeTransfer(address(loanManager), repayAmount);
            loanManager.repayDebt(repayAmount);
        }
    }

    // ============ Internal Helpers ============

    function _recoverLoanManagerFunds(ILoanManager loanManager) private {
        uint256 lmCollateral = loanManager.getCollateralBalance();
        if (lmCollateral > 0) {
            loanManager.transferCollateral(address(this), lmCollateral);
        }
        uint256 lmDebt = loanManager.getDebtBalance();
        if (lmDebt > 0) loanManager.transferDebt(address(this), lmDebt);
    }

    function _swapRemainingDebtToCollateral(IERC20 debtAsset, ISwapper swapper) private {
        uint256 debtBal = debtAsset.balanceOf(address(this));
        if (debtBal > 10 ** debtAsset.decimals() && address(swapper) != address(0)) {
            debtAsset.safeTransfer(address(swapper), debtBal);
            swapper.swapDebtForCollateral(debtBal);
        }
    }
}
