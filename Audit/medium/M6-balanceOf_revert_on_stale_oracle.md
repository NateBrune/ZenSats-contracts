# M6: balanceOf reverts on stale oracle (USDT variant only)
**Severity**: MEDIUM
**Contract(s)**: UsdtPmUsdCrvUsdStrategy.sol, CurveUsdtSwapLib.sol
**Function(s)**: balanceOf() → _convertCrvUsdValueToDebt() → convertCrvUsdToUsdt()
**Category**: Oracle / Revert

## Description
The balanceOf() function in UsdtPmUsdCrvUsdStrategy calls `_convertCrvUsdValueToDebt()`, which calls CurveUsdtSwapLib.convertCrvUsdToUsdt(). This function reverts with StaleOrInvalidOracle() if either oracle is stale:

```solidity
if (crvUsdPrice <= 0 || crvAnswered < crvRoundId
    || block.timestamp - crvUsdUpdatedAt > maxStaleness) {
    revert StaleOrInvalidOracle();
}
```

In contrast, the base PmUsdCrvUsdStrategy's balanceOf() calls `_convertCrvUsdValueToDebt()` which defaults to a no-op (1:1). If the USDT variant's oracle is stale, balanceOf() reverts entirely.

## Impact
- Any external caller that queries balanceOf() during oracle staleness will see a revert, breaking dashboards, indexers, and other consumers
- The Zenji vault itself calls balanceOf() in withdraw() and emergencyWithdraw() paths, which could revert if the oracle is stale during a withdrawal

## Recommendation
- Add a fallback in convertCrvUsdToUsdt() that uses a stale-price multiplier instead of reverting
- Or handle the revert in balanceOf() by returning a conservative estimate
- Consider using the same staleness check as pendingRewards() (which falls back to crvSwapper.quote())
