# M4: Virtual Price Cache can be stale between updates
**Severity**: MEDIUM
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _updateCachedVirtualPrice(), updateCachedVirtualPrice()
**Category**: Oracle / Cache Staleness

## Description
The cached virtual price is updated via `_updateCachedVirtualPrice()`, which calls `_getSafeVirtualPrice()` that bounds the new value within ±0.5% of the current on-chain value. However, there's a window between when a keeper calls `updateCachedVirtualPrice()` and when the next deposit/withdraw/harvest reads the cache via `_getSafeVirtualPrice()`.

If the LP pool's virtual price spikes between cache updates, the next `_getSafeVirtualPrice()` call will clamp to the cached value ±0.5%, but the cache is already stale. The oracle floor in `_addLiquidity()` and `_removeLiquidity()` uses this clamped value, which could be significantly off from the true current VP if the cache hasn't been updated recently.

## Impact
- The oracle floor can be stale by up to the cache update interval, potentially allowing suboptimal LP add/remove prices within the 0.5% bounds
- A keeper could be incentivized to update the cache just before a large deposit to lock in a favorable floor

## Recommendation
- Consider making the cache update more frequent (e.g., on every deposit/withdraw)
- Or document the expected maximum staleness and set keeper expectations
- Alternatively, use a time-weighted approach for the cache
