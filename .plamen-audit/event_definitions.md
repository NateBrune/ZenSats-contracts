# Event Definitions

## Zenji.sol (Main Vault)

| Event | Parameters | Trigger |
|-------|-----------|---------|
| Rebalance | oldLtv, newLtv, bool increased | rebalance() |
| RebalanceBountyPaid | indexed keeper, uint256 amount | rebalance() bounty payment |
| CapitalDeployed | collateralAmount, debtBorrowed | _deployCapital |
| CapitalUnwound | collateralNeeded, collateralReceived | _unwindPosition |
| StrategistTransferStarted | (indexed prev, indexed new, effectiveTime) | proposeStrategistTransfer |
| StrategistUpdated | indexed newStrategist | acceptStrategistTransfer |
| GovernanceTransferStarted | indexed previousGov, indexed newGov | |
| GovernanceUpdated | indexed newGov | |
| GuardianTransferStarted | indexed previousGuardian, indexed newGuardian | |
| GuardianUpdated | indexed newGuardian | |
| IdleModeEntered | — | setIdle(true) |
| IdleModeExited | — | setIdle(false) |
| ParamUpdated | indexed uint8 param, oldValue, newValue | param changes |
| FeesWithdrawn | indexed recipient, amount | withdrawFees |
| SwapperUpdated | indexed oldSwapper, indexed newSwapper | executeSwapper |
| SwapperChangeProposed | (pendingSwapper, effectiveTime) | proposeSwapper |
| SwapperChangeCancelled | indexed cancelledSwapper | cancelSwapper |
| FeeRateChangeProposed | currentFeeRate, newFeeRate, effectiveTime | |
| TargetLtvChangeProposed | currentLtv, newLtv, effectiveTime | |
| BountyRateChangeProposed | currentRate, newRate, effectiveTime | |
| DepositCapChangeProposed | currentCap, newCap, effectiveTime | |
| MaxSlippageChangeProposed | (currentSlippage, newSlippage, effectiveTime) | |
| DepositsPaused | — | pauseDeposits |
| DepositsResumed | — | resumeDeposits |
| RescueRecipientChangeProposed | (oldRecipient, newRecipient, effectiveTime) | |
| RescueRecipientUpdated | indexed oldRecipient, indexed newRecipient | |
| RescueRecipientChangeCancelled | indexed cancelledRecipient | |
| FeeRateChangeCancelled | cancelledValue | |
| TargetLtvChangeCancelled | cancelledValue | |
| BountyRateChangeCancelled | cancelledValue | |
| DepositCapChangeCancelled | cancelledValue | |
| MaxSlippageChangeCancelled | cancelledValue | |
| RoleTransferCancelled | indexed uint8 role, indexed cancelledAddress | |
| EmergencySkipStepProposed | indexed uint8 step, effectiveTime | |
| EmergencySkipCancelled | indexed uint8 step | |
| EmergencyModeCancelled | — | |
| StrategyOwnerPropagationFailed | indexed newOwner | |
| StrategyDeposit | (indexed strategy, uint256 debtAmount, uint256 depositedAmount) | |
| EmergencyModeEntered | — | enterEmergencyMode |
| LiquidationComplete | collateralRecovered, flashloanAmount | |
| EmergencyStepSkipped | indexed uint8 step | |
| AssetsRescued | indexed token, indexed recipient, amount | rescue |
| FeesAccrued | profit, fees, totalAccumulatedFees | _accrueYieldFees |
| YieldHarvested | indexed caller, rewardsValue | harvestYield |
| EmergencyCollateralTransferred | amount | emergencyStep |
| EmergencyDebtTransferred | amount | emergencyStep |
| EmergencyYieldRedeemed | debtAssetReceived | emergencyStep |
| EmergencyLoanUnwound | collateralRecovered, debtRecovered | emergencyStep |

## ZenjiCoreLib.sol

| Event | Parameters |
|-------|-----------|
| EmergencyYieldRedeemed | debtAssetReceived |
| EmergencyLoanUnwound | collateralRecovered, debtRecovered |
| LiquidationComplete | collateralRecovered, flashloanAmount |
| EmergencyCollateralTransferred | amount |
| EmergencyDebtTransferred | amount |
| AssetsRescued | indexed token, indexed recipient, amount |
| FeesWithdrawn | indexed recipient, amount |
| RebalanceBountyPaid | indexed keeper, amount |
| StrategyDeposit | indexed strategy, debtAmount, depositedAmount |

> NOTE: Duplicate event definitions between Zenji.sol and ZenjiCoreLib.sol — potential for inconsistent emission.

## AaveLoanManager.sol

| Event | Parameters |
|-------|-----------|
| SwapperUpdated | indexed oldSwapper, indexed newSwapper |
| SwapperChangeProposed | (pendingSwapper, effectiveTime) |
| SwapperChangeCancelled | indexed cancelledSwapper |
| VaultInitialized | indexed vault |

## LlamaLoanManager.sol

| Event | Parameters |
|-------|-----------|
| PositionUnwound | (collateralWithdrawn, debtRepaid) |
| CollateralSwapped | collateralIn, debtOut |
| DebtSwapped | debtIn, collateralOut |
| SwapperUpdated | indexed oldSwapper, indexed newSwapper |
| SwapperChangeProposed | (pendingSwapper, effectiveTime) |
| SwapperChangeCancelled | indexed cancelledSwapper |
| VaultInitialized | indexed vault |

## BaseYieldStrategy.sol

| Event | Parameters |
|-------|-----------|
| VaultInitialized | indexed vault |
| OwnerTransferred | indexed oldOwner, indexed newOwner |
| SlippageUpdated | oldSlippage, newSlippage |
| TokenRescued | indexed token, indexed to, amount |

## BaseLPStrategy.sol

| Event | Parameters |
|-------|-----------|
| LiquidityAdded | lpAssetAmount, lpReceived |
| LiquidityRemoved | lpBurned, lpAssetReceived |
| RewardsCompounded | lpAssetCompounded |

## BaseCurveStakeDaoStrategy.sol

| Event | Parameters |
|-------|-----------|
| RewardsHarvested | crvAmount, crvUsdReceived |
| CrvSwapDeferred | crvAmount |

## UsdtCrvUsdSwapMixin.sol

| Event | Parameters |
|-------|-----------|
| SwappedUsdtToCrvUsd | usdtAmount, crvUsdReceived |
| SwappedCrvUsdToUsdt | crvUsdAmount, usdtReceived |

## BaseSwapper.sol

| Event | Parameters |
|-------|-----------|
| GovernanceTransferStarted | indexed previousGov, indexed newGov |
| GovernanceUpdated | indexed newGov |
| GovTransferredFromVault | indexed previousGov, indexed newGov |
| SlippageUpdated | newSlippage |
| VaultSet | indexed vault_ |

## ZenjiRebalanceKeeper.sol

| Event | Parameters |
|-------|-----------|
| UpkeepPerformed | currentLtv, lowerBand, upperBand |
| OwnershipTransferred | indexed previousOwner, indexed newOwner |
| ERC20Drained | indexed token, indexed to, amount |

## CrvToCrvUsdSwapper.sol

| Event | Parameters |
|-------|-----------|
| Swapped | crvIn, crvUsdOut |
| AuthorizedCallerUpdated | indexed caller |
| TokenRescued | indexed token, indexed to, amount |
