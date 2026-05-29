# M7: Cost basis over-reduction in withdraw
**Severity**: MEDIUM
**Contract(s)**: BaseYieldStrategy.sol
**Function(s)**: withdraw()
**Category**: Arithmetic / Cost Basis

## Description
The withdraw() function reduces cost basis proportionally:
```solidity
uint256 basisReduction = (_costBasis * amount) / currentValue;
received = _withdraw(amount);
_costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;
```

The `amount` parameter is capped at `currentValue` (the balanceOf() result). However, balanceOf() in BasePmUsdCrvUsdStrategy uses the cached virtual price with ±0.5% bounds, while `_withdraw()` actually redeems from the reward vault at the current rate. If the VP has dropped since the cache was last updated, the actual redeem could yield less than `amount`, and the cost basis reduction would be too large.

## Impact
- Cost basis could be reduced below the actual remaining value, showing negative unrealized profit
- Over time, this could cause the cost basis to reach 0 while assets still exist in the strategy

## Recommendation
- After `_withdraw()`, recalculate the actual received amount and adjust the cost basis reduction accordingly
- Or use the actual received amount as the basis for cost basis reduction
