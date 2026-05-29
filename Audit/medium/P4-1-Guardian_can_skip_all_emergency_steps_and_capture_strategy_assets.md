# P4-1: Guardian can skip all emergency steps and capture strategy assets
**Severity**: MEDIUM
**Contract(s)**: Zenji.sol
**Function(s)**: `emergencySkipStep()`, `emergencyStep()`, `rescueAssets()`, `emergencyRescue()`
**Category**: Admin Centralization / Emergency Response

## Description

The guardian has full unilateral control over the emergency exit sequence. Through a series of `emergencySkipStep()` calls, the guardian can:

1. **Skip step 0** (yield withdraw): 3-day delay → execute skip → `emergencyStepsCompleted |= 0x1`
2. **Skip step 1** (loan unwind): 3-day delay → execute skip → `emergencyStepsCompleted |= 0x2`
3. **Execute step 2** (complete liquidation): Both bits set → `liquidationComplete = true`
4. **Rescue strategy assets**: After liquidation, `emergencyRescue(2)` redeems all yield from the strategy

After step 2, the vault collateral (WBTC, wstETH, etc.) remains in the vault for users to redeem. But the **strategy assets** (LP tokens in reward vault, any remaining debt asset) are accessible only via `emergencyRescue(2)` which is guardian-only.

Additionally, before step 2, the guardian can call `rescueAssets(token, recipient)` for any non-collateral token (debtAsset + any ERC20 in the vault).

### Attack Scenario

```
Day 0:  Guardian calls enterEmergencyMode()
Day 0:  Guardian calls emergencySkipStep(0) — proposes skip with 3-day delay
Day 3:  Guardian calls emergencySkipStep(0) again — executes, step 0 skipped
Day 3:  Guardian calls emergencySkipStep(1) — proposes skip with 3-day delay
Day 6:  Guardian calls emergencySkipStep(1) again — executes, step 1 skipped
Day 6:  Guardian calls emergencyStep(2) — liquidationComplete = true
Day 6:  Guardian calls emergencyRescue(2) — redeems all yield from strategy
Day 6:  Guardian calls rescueAssets(debtAsset, guardian) — takes remaining USDT from vault
```

### Gov Defense

The gov has a 3-day veto window on each skip via `cancelEmergencySkip(step)`. If the gov is compromised at the same time, or if the gov is slow to act, the guardian can complete the full exit.

### Impact

- **Strategy principal at risk**: The LP tokens in the reward vault represent the original deposited stablecoins + accumulated yield. After step 2, only the guardian can access these.
- **Bounded by 6-day window**: Gov has up to 6 days to veto all skips.
- **Vault collateral safe**: Users can still redeem vault collateral via normal `redeem()` path.
- **No double-dip**: Guardian cannot take vault collateral (blocked by `liquidationComplete` check in `rescueAssets`).

## Proof of Concept / Steps to Reproduce

1. Deploy vault with all components
2. Guardian calls `enterEmergencyMode()`
3. Guardian calls `emergencySkipStep(0)`, waits 3 days, calls `emergencySkipStep(0)` again
4. Guardian calls `emergencySkipStep(1)`, waits 3 days, calls `emergencySkipStep(1)` again
5. Guardian calls `emergencyStep(2)` → liquidationComplete
6. Guardian calls `emergencyRescue(2)` → reaps strategy assets

## Recommendation

Consider one of:
1. **Add a guardian cooldown**: After skip-execution, require a delay before `rescueAssets()` can be called on strategy tokens.
2. **Require gov acknowledgment**: Add a `govAckEmergencySkip` that must be called within the 3-day window, or the skip auto-executes.
3. **Document the risk**: The 6-day window is reasonable for most use cases. Add monitoring dashboards for `EmergencyModeEntered` events.

## Notes

- The 3-day `EMERGENCY_SKIP_DELAY` is intentional (see code comment: "Funds in bricked components are still recoverable on the gov side during this window")
- This is the same finding as AC-8 from Phase 2 attack chains
- The risk is mitigated by the fact that strategy assets are still productive (earning yield) during the 6-day window
