# P4-7: Strategy setSlippage has no timelock
**Severity**: LOW
**Contract(s)**: BaseSwapper.sol
**Function(s)**: `setSlippage()`
**Category**: Admin Centralization / Parameter Changes

## Description

The `setSlippage()` function on BaseSwapper (and all concrete swapper implementations) can be called immediately by gov or the registered vault:

```solidity
function setSlippage(uint256 newSlippage) external virtual {
    if (msg.sender != gov && msg.sender != vault) revert Unauthorized();
    if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
    slippage = newSlippage;
    emit SlippageUpdated(newSlippage);
}
```

No timelock, no two-step acceptance. The change takes effect immediately.

### Impact

- **Gov can increase slippage**: A malicious gov can set slippage to 5% (or higher, up to 99%)
- **Affects all operations**: Higher slippage means worse prices for:
  - Deposits (collateral → debt swap)
  - Rebalances (collateral → debt swap)
  - Partial unwinds (debt → collateral swap)
- **Bounded by vault maxSlippage**: The vault has `maxSlippage` (default 5%) which is used as a floor in `_computeEffectiveSlippage()`
- **Vault can also set**: The registered vault calls `setSlippage()` during `setParam(MAX_SLIPPAGE, value)`

### Comparison with Other Parameters

| Parameter | Timelock | Who Changes |
|-----------|----------|-------------|
| `feeRate` increase | 1 week | Gov |
| `targetLtv` increase | 1 week | Gov |
| `maxSlippage` | Immediate | Gov |
| `slippage` (swapper) | Immediate | Gov |
| Strategy `setSlippage` | Immediate | Gov + vault |

### Impact Analysis

- **Adverse changes are instant**: Both fee rate AND slippage can be increased immediately
- **User impact**: Higher slippage = worse exchange rates on all swaps
- **Maximum damage**: If gov sets slippage to 5% and fee rate to max, every deposit/unwind pays 5% slippage + fees

## Recommendation

1. **Add timelock for adverse slippage increases**: Similar to `setParam()`, only timelock increases
2. **Or add a cap**: Enforce a maximum slippage (e.g., 10%) that cannot be exceeded
3. **Or document**: Note that slippage changes are intended to be immediate for operational flexibility

## Notes

- The vault's `maxSlippage` (5% default) is a separate parameter from the swapper's `slippage`
- `_computeEffectiveSlippage()` uses `max(swapperSlippage, vaultMaxSlippage)` as the floor
- Setting swapper slippage below the vault's maxSlippage has no effect
