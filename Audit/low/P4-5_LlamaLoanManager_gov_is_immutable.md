# P4-5: LlamaLoanManager gov address is immutable
**Severity**: LOW
**Contract(s)**: LlamaLoanManager.sol
**Function(s)**: `constructor()`
**Category**: Admin Centralization / Key Management

## Description

The LlamaLoanManager sets its `gov` address in the constructor and provides no ownership transfer mechanism:

```solidity
constructor(address _gov) {
    gov = _gov;
}
```

This means:
1. The gov address cannot be changed after deployment
2. If the original gov is compromised, the attacker controls the loan manager forever
3. If the original gov is lost (key lost), the loan manager is permanently bricked

### Functions Controlled by `onlyGov`

- `setSlippage()` — changes collateral swap slippage tolerance
- `setDebtFlashLender()` — changes the flash lender address (for underwater unwinding)

### Impact

- **No rotation**: Gov cannot be rotated without deploying a new loan manager
- **Migration required**: To change gov, vault must:
  1. Set idle (stop new deposits)
  2. Unwind existing position
  3. Deploy new LlamaLoanManager with new gov
  4. Redeploy strategy pointing to new loan manager
  5. Exit idle (redeposit)
- **Single point of failure**: Compromised gov can change slippage (affecting unwind costs) and flash lender

## Recommendation

1. **Add ownership transfer**: Implement a two-step `transferGov()` / `acceptGov()` pattern
2. **Or add a proxy**: Use a minimal proxy or delegatecall pattern for the gov address
3. **Or document**: Note that loan manager gov is expected to be long-lived

## Notes

- AaveLoanManager has the same pattern (immutable gov)
- This is acceptable if the loan manager is expected to be a long-lived infrastructure component
- The vault's swapper timelock (1 week) provides some defense if the loan manager gov is compromised
