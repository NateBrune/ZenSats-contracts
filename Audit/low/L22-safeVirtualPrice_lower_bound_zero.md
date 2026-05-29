# L22: _getSafeVirtualPrice() lower bound can be zero
**Severity**: LOW
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _getSafeVirtualPrice()
**Category**: Edge Case / Cache

## Description
The lower bound calculation:
```solidity
uint256 lowerBound = cached > maxDeviation ? cached - maxDeviation : 0;
```
If cached is less than maxDeviation (0.5% of PRECISION = 5e15), the lower bound is 0. This means any current VP below 5e15 will be clamped to the current value. Since LP virtual prices are typically ~1e18 or higher, this edge case is unlikely but possible for very new pools.

## Impact
Very new LP pools with low virtual prices won't benefit from the cache upper bound protection.

## Recommendation
Consider a minimum cached VP floor (e.g., 1e18) to ensure the cache is always meaningful.
