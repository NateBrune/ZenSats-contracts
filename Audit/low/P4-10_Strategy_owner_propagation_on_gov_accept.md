# P4-10: Strategy owner propagation on gov accept
**Severity**: LOW (informational)
**Contract(s)**: Zenji.sol, BaseYieldStrategy.sol, BasePmUsdCrvUsdStrategy.sol
**Function(s)**: `acceptRole()`, `transferOwnerFromVault()`
**Category**: Admin Centralization / Cross-Contract Sync

## Description

When the gov role is accepted, the vault automatically propagates the new gov address to the yield strategy:

```solidity
// In acceptRole(), role == 1 (gov):
gov = msg.sender;
try yieldStrategy.transferOwnerFromVault(msg.sender) {
    // success
} catch {
    emit StrategyOwnerPropagationFailed(msg.sender);
}
```

This ensures that when the gov changes, the strategy's owner is updated to match. The strategy's owner controls:
- `setSlippage()` on the strategy's swapper
- `transferOwnerFromVault()` / `transferOwnership()` on the strategy itself
- Access to strategy-specific admin functions

### Catch-and-Continue Pattern

The propagation is wrapped in `try/catch` so a bricked or paused strategy doesn't block gov rotation. If propagation fails:
- The event `StrategyOwnerPropagationFailed` is emitted
- The gov role is still updated on the vault
- The strategy owner may be out of sync

### Recovery

- **Re-sync via strategy**: The strategy's owner can call `transferOwnership(newGov)` directly
- **Or via vault**: If the vault is registered as a caller on the strategy, it can propagate again

### Impact

- **Automatic sync**: Gov changes propagate to strategy automatically
- **Failure is non-blocking**: Strategy can be bricked without blocking gov rotation
- **Out-of-sync is recoverable**: Strategy owner can be re-synced manually

## Recommendation

1. **Add a view function**: `getStrategyOwnerSyncStatus()` to check if strategy owner matches gov
2. **Or add an auto-retry**: The next `setParam()` call could retry propagation if out of sync
3. **Or document**: Note that strategy owner propagation is best-effort

## Notes

- This is a well-designed pattern — gov rotation doesn't break if strategy is bricked
- The `transferOwnerFromVault()` function is implemented differently in different strategy types:
  - `BaseIporStrategy`: Two-step (vault initiates, strategy accepts)
  - `BasePmUsdCrvUsdStrategy`: Direct (vault sets owner immediately)
