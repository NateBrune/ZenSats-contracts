# Setter List — Zenji

## Vault (Zenji.sol) — Gov-Only Setters

| Function | Access | Timelock? | Emits Event? | Notes |
|---|---|---|---|---|
| `setParam(0, feeRate)` | onlyGov | YES (increase only — PARAM_TIMELOCK_DELAY 1w) | YES (`FeeRateChangeProposed` / `ParamUpdated`) | Max 20%. Decrease immediate. |
| `setParam(1, targetLtv)` | onlyGov | YES (increase only) | YES (`TargetLtvChangeProposed` / `ParamUpdated`) | 15%–65% (per-vault). Decrease immediate. |
| `setParam(2, depositCap)` | onlyGov | YES (decrease only — adverse = cap reduction) | YES (`DepositCapChangeProposed` / `ParamUpdated`) | Increase immediate. Zero immediate. |
| `setParam(3, bountyRate)` | onlyGov | YES (increase only) | YES (`BountyRateChangeProposed` / `ParamUpdated`) | Max 50%. |
| `setParam(4, maxSlippage)` | onlyGov | YES (increase only) | YES (`MaxSlippageChangeProposed` / `ParamUpdated`) | Max 5%. Propagates to strategy + swapper on execute. |
| `executeParamChange(p)` | onlyGov | N/A | YES (all via `ParamUpdated`) | Executes after PARAM_TIMELOCK_DELAY. |
| `cancelParamChange(p)` | onlyGov | N/A | YES (Cancel events per param) | |
| `proposeSwapper(addr)` | onlyGov | YES (TIMELOCK_DELAY 1w) | YES (`SwapperChangeProposed`) | Also calls loanManager.proposeSwapper. |
| `executeSwapper()` | onlyGov | N/A | YES (`SwapperUpdated`) | Also calls loanManager.executeSwapper. |
| `cancelSwapper()` | onlyGov | N/A | YES (`SwapperChangeCancelled`) | Also calls loanManager.cancelSwapper. |
| `transferRole(0, addr)` | onlyGov | YES (1w strategist, 4w gov/guardian) | YES (`StrategistTransferStarted` etc.) | Guardian veto possible. |
| `acceptRole(role)` | pending address | After delay | YES (`StrategistUpdated` etc.) | For gov: propagates strategy ownership. |
| `cancelRole(role)` | onlyGov | N/A | YES (`RoleTransferCancelled`) | |
| `proposeRescueRecipient(addr)` | onlyGov | YES (TIMELOCK_DELAY 1w) | YES (`RescueRecipientChangeProposed`) | |
| `executeRescueRecipient()` | onlyGov | N/A | YES (`RescueRecipientUpdated`) | |
| `cancelRescueRecipient()` | onlyGov | N/A | YES (`RescueRecipientChangeCancelled`) | |
| `resumeDeposits()` | onlyGov | No | YES (`DepositsResumed`) | Gov-only resumption. |
| `cancelEmergencySkip(step)` | onlyGov | N/A | YES (`EmergencySkipCancelled`) | Gov veto on guardian skip. |
| `cancelEmergencyMode()` | onlyGov | N/A | YES (`EmergencyModeCancelled`) | Only before any step executes. |
| `setStrategySlippage(v)` | onlyGov | No | Not checked in code — **SILENT SETTER** | Calls `yieldStrategy.setSlippage(v)` directly. No vault-level event. |

> **SILENT SETTER**: `setStrategySlippage` — if present in the code without an event, flag. Review Zenji.sol for this function.

*Note: `setParam(4)` (maxSlippage decrease) is immediate and propagates to strategy and swapper via `yieldStrategy.setSlippage()` and `ISwapperSlippageConfig.setSlippage()`.*

---

## Vault (Zenji.sol) — Strategist-Only Setters

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `setIdle(bool)` | onlyStrategist | YES (`IdleModeEntered` / `IdleModeExited`) | Enters/exits carry trade. Triggers full unwind or deploy. |
| `withdrawFees(recipient)` | onlyStrategist | YES (`FeesWithdrawn`) | Accrues fees first. `recipient` is arbitrary address — no whitelist. |

---

## Vault (Zenji.sol) — Guardian-Only Setters

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `enterEmergencyMode()` | onlyGuardian | YES (`EmergencyModeEntered`) | One-way. Gov can `cancelEmergencyMode` before any step. |
| `emergencyStep(step)` | onlyGuardian | YES (per-step events) | 3-step process. |
| `emergencySkipStep(step)` | onlyGuardian | YES (`EmergencySkipStepProposed`, then `EmergencyStepSkipped`) | 3-day delay, gov veto. |
| `emergencyRescue(action)` | onlyGuardian | YES (per-action events) | Action 2 requires step 0 resolved. |
| `rescueAssets(token, recipient)` | onlyGuardian | YES (`AssetsRescued`) | Emergency mode only. `recipient` must equal `rescueRecipient`. |
| `pauseDeposits()` | onlyGuardian | YES (`DepositsPaused`) | |
| `guardianCancelRole(role)` | onlyGuardian | YES (`RoleTransferCancelled`) | Guardian veto on any role transfer. |
| `guardianCancelSwapper()` | onlyGuardian | YES (`SwapperChangeCancelled`) | Guardian veto on swapper change. |

---

## Vault (Zenji.sol) — Permissionless State Modifiers

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `rebalance()` | Anyone | YES (`Rebalance`, `RebalanceBountyPaid`) | Adjusts LTV if outside deadband. Accrues fees. Pays bounty from accumulated fees. |
| `accrueYieldFees()` | Anyone (internal call too) | YES (`FeesAccrued`) if profit | Checkpoints strategy balance. |
| `harvestYield()` | Anyone | YES (`YieldHarvested`) | Calls strategy.harvest(). |
| `deposit/mint` | Anyone | YES (`Deposit`) | Triggers `_deployCapital` if not idle. |
| `withdraw/redeem` | Anyone (with allowance) | YES (`Withdraw`) | May trigger `_unwindPosition`. |
| `acceptRole(role)` | Pending address only | YES | Permissionless for the designated pending address. |

---

## AaveLoanManager

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `initializeVault(addr)` | initializer (once) | YES (`VaultInitialized`) | Sets vault, clears initializer. |
| `proposeSwapper(addr)` | onlyVault | YES (`SwapperChangeProposed`) | Timelocked 1w. |
| `executeSwapper()` | onlyVault | YES (`SwapperUpdated`) | |
| `cancelSwapper()` | onlyVault | YES (`SwapperChangeCancelled`) | |
| `transferCollateral/Debt` | onlyVault | NO | No event. |

---

## LlamaLoanManager

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `initializeVault(addr)` | initializer (once) | YES (`VaultInitialized`) | |
| `proposeSwapper(addr)` | onlyVault | YES (`SwapperChangeProposed`) | |
| `executeSwapper()` | onlyVault | YES (`SwapperUpdated`) | |
| `cancelSwapper()` | onlyVault | YES (`SwapperChangeCancelled`) | |
| `transferCollateral/Debt` | onlyVault | NO for transferDebt (YES via PositionUnwound for unwindPosition) | **SILENT SETTER** for transferDebt/transferCollateral |

---

## BaseYieldStrategy (Strategies)

| Function | Access | Emits Event? | Notes |
|---|---|---|---|
| `initializeVault(addr)` | initializer (once) | YES (`VaultInitialized`) | |
| `transferOwnerFromVault(addr)` | onlyVault | YES (`OwnerTransferred`) | |
| `transferOwner(addr)` | onlyOwner (only before vault deployed) | YES (`OwnerTransferred`) | Locked once vault code exists. |
| `setSlippage(v)` | vault or owner | YES (`SlippageUpdated`) | Range: MIN_SLIPPAGE (0.1%) to MAX_SLIPPAGE (5%). |
| `rescueERC20(token, to, amount)` | onlyOwner | YES (`TokenRescued`) | Cannot rescue protected tokens. |

---

## BaseSwapper / CrvToCrvUsdSwapper

| Function | Contract | Access | Emits? | Notes |
|---|---|---|---|---|
| `setVault(addr)` | BaseSwapper | onlyGov | YES (`VaultSet`) | Sets authorized vault for setSlippage. |
| `setSlippage(v)` | BaseSwapper | gov or vault | YES (`SlippageUpdated`) | No timelock at swapper level. |
| `transferGovernance(addr)` | BaseSwapper | onlyGov | YES (`GovernanceTransferStarted`) | Two-step: pending + acceptGovernance. |
| `acceptGovernance()` | BaseSwapper | pendingGov | YES (`GovernanceUpdated`) | |
| `transferGovFromVault(addr)` | BaseSwapper | onlyVault | YES (`GovTransferredFromVault`) | Immediate, no two-step. |
| `setAuthorizedCaller(addr)` | CrvToCrvUsdSwapper | onlyGov | YES (`AuthorizedCallerUpdated`) | Only strategy can call swap(). |
| `setSlippage(v)` | CrvToCrvUsdSwapper | gov or authorizedCaller | YES (`SlippageUpdated`) | |
| `rescueToken(token, to, amt)` | CrvToCrvUsdSwapper | onlyGov | YES (`TokenRescued`) | No protected-token guard visible. |

---

## ZenjiRebalanceKeeper

| Function | Access | Emits? | Notes |
|---|---|---|---|
| `transferOwnership(addr)` | onlyOwner | YES (`OwnershipTransferred`) | |
| `drainERC20(token, to, amt)` | onlyOwner | YES (`ERC20Drained`) | Any ERC20, any address. No guard. |

---

## SILENT SETTERS Summary

| Contract | Function | Risk |
|---|---|---|
| Zenji | `setStrategySlippage(v)` (if present — verify) | No vault-level event if missing |
| AaveLoanManager | `transferCollateral`, `transferDebt` | No emit — state changes silently |
| LlamaLoanManager | `transferDebt` | No emit |
| ZenjiRebalanceKeeper | `drainERC20` (no protected-token guard) | Can drain any ERC20 including strategy tokens if keeper holds them |
