# P4-9: Parameter changes have asymmetric timelock (only adverse changes)
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: `setParam()`
**Category**: Admin Centralization / Parameter Changes

## Description

The `setParam()` function applies timelocks only to "adverse" changes (increases), while "user-favorable" changes (decreases) take effect immediately:

```solidity
if (v > feeRate) {
    // Adverse: increasing fees → timelock
    _feeRateTimelock.propose(v, PARAM_TIMELOCK_DELAY);
} else {
    // User-favorable: decreasing or keeping fees → immediate
    feeRate = v;
}
```

### Parameters Affected

| Param | Index | Adverse (timelocked) | Favorable (immediate) |
|-------|-------|---------------------|----------------------|
| feeRate | 0 | Increase | Decrease |
| targetLtv | 1 | Increase | Decrease |
| depositCap | 2 | N/A (always immediate) | N/A |
| rebalanceBountyRate | 3 | N/A (always immediate) | N/A |
| maxSlippage | 4 | N/A (always immediate) | N/A |

### Parameters Without Timelock

- **depositCap**: Can be set to any value immediately (including 0 = no deposits)
- **rebalanceBountyRate**: Can be increased to MAX_REBALANCE_BOUNTY (50%) immediately
- **maxSlippage**: Can be set to MAX_VAULT_SLIPPAGE (5%) immediately

### Impact

- **Fee rate drain is slow**: Max timelock = 1 week for fee increases
- **Deposit freeze is instant**: Gov can set depositCap = 0 immediately
- **Bounty drain is instant**: Gov can set rebalanceBountyRate to 50% immediately
- **Slippage increase is instant**: Gov can set maxSlippage to 5% immediately

### Worst Case: Instant Full Drain

```
Gov calls setParam(3, 5e17) → rebalanceBountyRate = 50% (immediate)
Gov calls setParam(0, MAX_FEE_RATE) → feeRate at max (timelocked 1 week)
```

After 1 week, every rebalance and fee withdrawal pays 50% bounty + max fees.

## Recommendation

1. **Add timelock for depositCap**: Prevent instant deposit freezes
2. **Or cap rebalanceBountyRate**: Enforce a lower default (e.g., 5%) with timelock for increases
3. **Or document**: Note which params are "safe to change immediately"

## Notes

- The asymmetry is intentional — decreases are always user-favorable
- depositCap = 0 is a common operational tool (pause deposits during maintenance)
- rebalanceBountyRate of 50% is the theoretical maximum; typical values are much lower
