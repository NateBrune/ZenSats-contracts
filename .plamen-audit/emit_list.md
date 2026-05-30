# Emit List — Zenji

## Zenji.sol

| Event | Trigger | Parameters |
|---|---|---|
| `Deposit` | `_deposit` | caller, receiver, assets, shares |
| `Withdraw` | `_redeemEmergency`, `_redeemStandard` | caller, receiver, owner, collateralAmount, shares |
| `Rebalance` | `rebalance` | oldLtv, newLtv, increased |
| `RebalanceBountyPaid` | `ZenjiCoreLib.processRebalanceBounty` (via rebalance) | keeper, amount |
| `CapitalDeployed` | `_deployCapital` | collateralAmount, debtBorrowed |
| `CapitalUnwound` | `_unwindPosition` | collateralNeeded, collateralReceived |
| `FeesAccrued` | `_accrueYieldFees` (internal) | profit, fees, totalAccumulatedFees |
| `FeesWithdrawn` | `ZenjiCoreLib.processWithdrawFees` (via withdrawFees) | recipient, amount |
| `YieldHarvested` | `harvestYield` | caller, rewardsValue |
| `IdleModeEntered` | `setIdle(true)` | — |
| `IdleModeExited` | `setIdle(false)` | — |
| `SwapperChangeProposed` | `proposeSwapper` | currentSwapper, newSwapper, effectiveTime |
| `SwapperUpdated` | `executeSwapper` | oldSwapper, newSwapper |
| `SwapperChangeCancelled` | `cancelSwapper`, `guardianCancelSwapper` | cancelledSwapper |
| `FeeRateChangeProposed` | `setParam(0, increase)` | current, new, effectiveTime |
| `TargetLtvChangeProposed` | `setParam(1, increase)` | current, new, effectiveTime |
| `BountyRateChangeProposed` | `setParam(3, increase)` | current, new, effectiveTime |
| `DepositCapChangeProposed` | `setParam(2, decrease)` | current, new, effectiveTime |
| `MaxSlippageChangeProposed` | `setParam(4, increase)` | current, new, effectiveTime |
| `ParamUpdated` | `setParam` (immediate) and `executeParamChange` | param index, old, new |
| `FeeRateChangeCancelled` | `cancelParamChange(0)` | cancelledValue |
| `TargetLtvChangeCancelled` | `cancelParamChange(1)` | cancelledValue |
| `BountyRateChangeCancelled` | `cancelParamChange(3)` | cancelledValue |
| `DepositCapChangeCancelled` | `cancelParamChange(2)` | cancelledValue |
| `MaxSlippageChangeCancelled` | `cancelParamChange(4)` | cancelledValue |
| `StrategistTransferStarted` | `transferRole(0)` | previousStrategist, newStrategist |
| `StrategistUpdated` | `acceptRole(0)` | newStrategist |
| `GovernanceTransferStarted` | `transferRole(1)` | previousGov, newGov |
| `GovernanceUpdated` | `acceptRole(1)` | newGov |
| `GuardianTransferStarted` | `transferRole(2)` | previousGuardian, newGuardian |
| `GuardianUpdated` | `acceptRole(2)` | newGuardian |
| `RoleTransferCancelled` | `cancelRole`, `guardianCancelRole` | role, cancelledAddress |
| `EmergencySkipStepProposed` | `emergencySkipStep` (first call) | step, effectiveTime |
| `EmergencySkipCancelled` | `cancelEmergencySkip` | step |
| `EmergencyStepSkipped` | `emergencySkipStep` (second call) | step |
| `EmergencyModeCancelled` | `cancelEmergencyMode` | — |
| `EmergencyModeEntered` | `enterEmergencyMode` | — |
| `LiquidationComplete` | emergency step 2 | collateralRecovered, flashloanAmount |
| `EmergencyCollateralTransferred` | emergency rescue action 0 | amount |
| `EmergencyDebtTransferred` | emergency rescue action 1 | amount |
| `EmergencyYieldRedeemed` | emergency step 0 / rescue action 2 | debtAssetReceived |
| `EmergencyLoanUnwound` | emergency step 1 | collateralRecovered, debtRecovered |
| `AssetsRescued` | `rescueAssets` | token, recipient, amount |
| `DepositsPaused` | `pauseDeposits` | — |
| `DepositsResumed` | `resumeDeposits` | — |
| `RescueRecipientChangeProposed` | `proposeRescueRecipient` | current, new, effectiveTime |
| `RescueRecipientUpdated` | `executeRescueRecipient` | old, new |
| `RescueRecipientChangeCancelled` | `cancelRescueRecipient` | cancelledRecipient |
| `StrategyOwnerPropagationFailed` | `acceptRole(1)` on catch | newOwner |
| `StrategyDeposit` | `ZenjiCoreLib.deployDebtToStrategy` | strategy, debtAmount, deposited |

## AaveLoanManager

| Event | Trigger |
|---|---|
| `VaultInitialized` | `initializeVault` |
| `LoanCreated` | `createLoan` |
| `CollateralAdded` | `addCollateral` |
| `LoanBorrowedMore` | `borrowMore` |
| `LoanRepaid` | `repayDebt` |
| `CollateralRemoved` | `removeCollateral` |
| `SwapperChangeProposed` | `proposeSwapper` |
| `SwapperUpdated` | `executeSwapper` |
| `SwapperChangeCancelled` | `cancelSwapper` |

## LlamaLoanManager

| Event | Trigger |
|---|---|
| `VaultInitialized` | `initializeVault` |
| `LoanCreated`, `CollateralAdded`, `LoanBorrowedMore`, `LoanRepaid`, `CollateralRemoved` | Standard ops |
| `PositionUnwound` | `unwindPosition` |
| `CollateralSwapped` | `_swapCollateralToDebt` |
| `DebtSwapped` | `_swapDebtToCollateral` |
| `SwapperChangeProposed`, `SwapperUpdated`, `SwapperChangeCancelled` | Swapper management |

## BaseYieldStrategy (shared by all strategies)

| Event | Trigger |
|---|---|
| `VaultInitialized` | `initializeVault` |
| `OwnerTransferred` | `transferOwner`, `transferOwnerFromVault` |
| `SlippageUpdated` | `setSlippage` |
| `TokenRescued` | `rescueERC20` |
| `Deposited` | `deposit` |
| `Withdrawn` | `withdraw`, `withdrawAll` |
| `Harvested` | `harvest` |
| `EmergencyWithdrawn` | `emergencyWithdraw` |

## BaseLPStrategy

| Event | Trigger |
|---|---|
| `LiquidityAdded` | `_addLiquidityAndStake` |
| `LiquidityRemoved` | `_removeLiquidity` calls |
| `RewardsCompounded` | `_compoundRewards` (only when > 0) |

## BaseCurveStakeDaoStrategy

| Event | Trigger |
|---|---|
| `RewardsHarvested` | `_claimAndSwapRewards` (success) |
| `CrvSwapDeferred` | `_claimAndSwapRewards` (swap failure) |

## UsdtCrvUsdSwapMixin

| Event | Trigger |
|---|---|
| `SwappedUsdtToCrvUsd` | `_usdtToCrvUsd` |
| `SwappedCrvUsdToUsdt` | `_crvUsdToUsdt` |

## BaseSwapper

| Event | Trigger |
|---|---|
| `GovernanceTransferStarted` | `transferGovernance` |
| `GovernanceUpdated` | `acceptGovernance` |
| `GovTransferredFromVault` | `transferGovFromVault` |
| `SlippageUpdated` | `setSlippage` |
| `VaultSet` | `setVault` |

## ZenjiRebalanceKeeper

| Event | Trigger |
|---|---|
| `OwnershipTransferred` | constructor, `transferOwnership` |
| `UpkeepPerformed` | `performUpkeep` |
| `ERC20Drained` | `drainERC20` |
