# P4-11: CrvToCrvUsdSwapper authorizedCaller bypasses gov for setSlippage
**Severity**: LOW
**Contract(s)**: CrvToCrvUsdSwapper.sol
**Function(s)**: `setSlippage()`, `setAuthorizedCaller()`
**Category**: Admin Centralization / Access Control

## Description

The CrvToCrvUsdSwapper has an `authorizedCaller` that can call `setSlippage()` in addition to gov and vault:

```solidity
function setSlippage(uint256 newSlippage) external override {
    if (msg.sender != gov && msg.sender != vault && msg.sender != authorizedCaller) {
        revert Unauthorized();
    }
    // ...
}
```

The `authorizedCaller` is set during deployment and cannot be changed afterward (no `setAuthorizedCaller()` function).

### Impact

- **Three callers can change slippage**: gov, vault, and authorizedCaller
- **authorizedCaller is the strategy**: During deployment, the strategy is set as authorizedCaller
- **No timelock**: Any of the three can change slippage immediately
- **Cannot rotate authorizedCaller**: Once set, the authorizedCaller is immutable

### Why This Exists

The strategy needs to call `setSlippage()` on the CrvToCrvUsdSwapper during harvest operations. Since the vault's `setParam(MAX_SLIPPAGE, value)` calls `setSlippage` on all swappers, the strategy also needs direct access to set its own slippage independently.

### Impact Analysis

- **Strategy controls its own harvest slippage**: This is intentional and useful
- **No additional risk**: The authorizedCaller is the strategy itself, which is already trusted
- **Immutable**: Cannot be changed to a malicious contract after deployment

## Recommendation

1. **Add a `setAuthorizedCaller()` function**: Allow the strategy to rotate its authorizedCaller if needed
2. **Or document**: Note that authorizedCaller is set at deployment and is immutable
3. **Or add a guard**: Require the authorizedCaller to be a contract (not an EOA)

## Notes

- This is a design choice to allow the strategy to manage its harvest slippage independently
- The CrvToCrvUsdSwapper is used by the pmUSD/crvUSD strategy to swap CRV rewards → crvUSD
- Other swappers (Curve, Uniswap) don't have this authorizedCaller pattern
