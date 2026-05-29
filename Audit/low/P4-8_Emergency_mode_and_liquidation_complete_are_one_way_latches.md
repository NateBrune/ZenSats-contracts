# P4-8: Emergency mode and liquidationComplete are one-way latches
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: `enterEmergencyMode()`, `emergencyStep()`, `cancelEmergencyMode()`
**Category**: Admin Centralization / Emergency Response

## Description

The vault has two one-way state latches:

### `emergencyMode` — One-way (with cancellation window)

```solidity
function enterEmergencyMode() external onlyGuardian {
    if (emergencyMode) revert EmergencyModeActive();
    emergencyMode = true;
    emit EmergencyModeEntered();
}

function cancelEmergencyMode() external onlyGov {
    if (!emergencyMode) revert EmergencyModeNotActive();
    if (emergencyStepsCompleted != 0) revert EmergencyStepInProgress();
    if (liquidationComplete) revert LiquidationAlreadyComplete();
    emergencyMode = false;
    pendingSkipTimestamp[0] = 0;
    pendingSkipTimestamp[1] = 0;
    emit EmergencyModeCancelled();
}
```

- **Entry**: Guardian-only, one-way
- **Cancellation**: Gov-only, only if NO steps have been executed or skipped
- **Once steps begin**: Cannot cancel — state is "too dirty to safely return to normal"

### `liquidationComplete` — True One-Way

```solidity
if (setLiq) liquidationComplete = true;
```

Once set to `true`, it can never be reset. After this:
- Users can redeem vault collateral (via `_unwindPosition` with `liquidationComplete` path)
- Guardian cannot rescue collateral (blocked by check)
- Guardian can rescue debtAsset and call `emergencyRescue(2)` for strategy

### Impact

- **Guardian can permanently lock the vault**: Once emergency mode starts and steps execute, the vault is in a semi-permanent state
- **Users can still withdraw**: After liquidation, users can redeem their collateral share
- **Strategy assets are trapped**: Only guardian can access strategy assets after liquidation
- **No automatic recovery**: The vault doesn't automatically exit emergency mode

### Attack Scenario

```
1. Guardian enters emergency mode
2. Guardian executes all 3 steps (or skips + liquidates)
3. Guardian drains strategy via emergencyRescue(2)
4. Guardian drains debtAsset via rescueAssets()
5. Vault is now in liquidationComplete state
6. Users can only redeem vault collateral (still there)
7. Vault cannot exit emergency mode (steps already executed)
8. Vault cannot accept new deposits (emergencyMode = true)
```

## Recommendation

1. **Add a max emergency duration**: After N days, auto-cancel emergency mode if no steps executed
2. **Or add a "force exit"**: Gov can cancel after N days even if steps executed
3. **Or document**: The one-way latch is intentional — emergency mode is a "fire wall"

## Notes

- This is by design — emergency mode is meant to be a "fire wall" to protect users
- The tradeoff is that a malicious guardian can permanently disable the vault
- The 4-week guardian transfer delay provides a defense window
