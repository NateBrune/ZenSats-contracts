// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "../interfaces/IERC20.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";
import {ILoanManager} from "../interfaces/ILoanManager.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {SafeTransferLib} from "./SafeTransferLib.sol";

/// @title ZenjiCoreLib
/// @notice External library for Zenji admin and emergency operations
/// @dev Functions are `external` so they deploy separately and reduce Zenji bytecode.
///      Called via DELEGATECALL, so `address(this)` is the vault and token transfers work correctly.
library ZenjiCoreLib {
    using SafeTransferLib for IERC20;

    error InvalidAddress();

    event EmergencyYieldRedeemed(uint256 debtAssetReceived);
    event EmergencyLoanUnwound(
        uint256 collateralRecovered,
        uint256 debtRecovered
    );
    event LiquidationComplete(
        uint256 collateralRecovered,
        uint256 flashloanAmount
    );
    event EmergencyCollateralTransferred(uint256 amount);
    event EmergencyDebtTransferred(uint256 amount);
    event AssetsRescued(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);

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
                    } catch {}
                }
            }
            newLastStrategyBalance = 0;
            newAccumulatedFees = 0;
            emit EmergencyYieldRedeemed(withdrawn);
        } else if (step == 1) {
            if (!loanManager.loanExists()) {
                _recoverLoanManagerFunds(loanManager);
                _swapRemainingDebtToCollateral(debtAsset, swapper);
                emit EmergencyLoanUnwound(
                    collateralAsset.balanceOf(address(this)),
                    0
                );
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
            emit EmergencyLoanUnwound(
                collateralAsset.balanceOf(address(this)),
                0
            );
        } else {
            setLiquidationComplete = true;
            emit LiquidationComplete(
                collateralAsset.balanceOf(address(this)),
                0
            );
        }
    }

    /// @notice Emergency rescue: 0=transferCollateral, 1=transferDebt, 2=redeemYield
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    function executeEmergencyRescue(
        uint8 action,
        IERC20 collateralAsset,
        IERC20 debtAsset,
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        ISwapper swapper,
        uint256 lastStrategyBalance
    ) external returns (uint256 newLastStrategyBalance) {
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
    )
        external
        returns (uint256 newAccumulatedFees, uint256 newLastStrategyBalance)
    {
        uint256 fees = accumulatedFees;
        if (fees == 0) return (0, yieldStrategy.balanceOf());

        newAccumulatedFees = 0;

        uint256 strategyBalance = yieldStrategy.balanceOf();
        uint256 debtBefore = debtAsset.balanceOf(address(this));
        if (strategyBalance > 0 && fees > 0) {
            uint256 toWithdraw = fees > strategyBalance
                ? strategyBalance
                : fees;
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

    // ============ Internal Helpers ============

    function _recoverLoanManagerFunds(ILoanManager loanManager) private {
        uint256 lmCollateral = loanManager.getCollateralBalance();
        if (lmCollateral > 0) {
            loanManager.transferCollateral(address(this), lmCollateral);
        }
        uint256 lmDebt = loanManager.getDebtBalance();
        if (lmDebt > 0) loanManager.transferDebt(address(this), lmDebt);
    }

    function _swapRemainingDebtToCollateral(
        IERC20 debtAsset,
        ISwapper swapper
    ) private {
        uint256 debtBal = debtAsset.balanceOf(address(this));
        if (debtBal > 10 ** debtAsset.decimals() && address(swapper) != address(0)) {
            debtAsset.safeTransfer(address(swapper), debtBal);
            swapper.swapDebtForCollateral(debtBal);
        }
    }
}
