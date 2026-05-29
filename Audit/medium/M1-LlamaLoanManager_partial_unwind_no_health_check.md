# M1: LlamaLoanManager partial unwind — no health check before remove_collateral
**Severity**: MEDIUM
**Contract(s)**: LlamaLoanManager.sol
**Function(s)**: unwindPosition (partial path)
**Category**: Logic / Health Check

## Description
In the partial unwind path (when `needFlashloan` is false), the code calls `_checkOracleFreshness()` at the top, then proceeds to `llamaLend.remove_collateral()` without checking whether the position is healthy at the current oracle price:

```solidity
// Between freshness check and remove_collateral, oracle price could drop
llamaLend.remove_collateral(toRemove);
```

LlamaLend's `remove_collateral` checks health internally and reverts if the position is underwater.

## Impact
Partial unwind reverts unexpectedly during price drops, forcing the caller to retry at a lower price or fall back to a full close via flashloan.

## Recommendation
Add a pre-check health factor before calling `remove_collateral` in the partial path. Compare `llamaLend.health(address(this), true)` against `MIN_HEALTH` (or 0) to ensure the removal is safe. Alternatively, wrap the `remove_collateral` call in a try/catch and fall back to flashloan on revert.
