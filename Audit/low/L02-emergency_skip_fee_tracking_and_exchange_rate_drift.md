# L02: Emergency step 0 skip sets feesAtLastRebalance = 0
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: emergencyStep(0), emergencySkipStep(0)
**Category**: Logic / Fee Tracking

## Description
When emergencyStep(0) is called (or skipped), the function sets `feesAtLastRebalance = 0`. If step 0 is skipped (yield strategy is bricked), the strategy balance remains unchanged. The first post-skip rebalance will pay a potentially inflated bounty (bounty on all fees since the last actual rebalance).

## Impact
Minor: inflated keeper bounty on the first post-skip rebalance.

## Recommendation
Consider setting `feesAtLastRebalance = yieldStrategy.balanceOf()` in emergencySkipStep(0) instead of 0.

---

# L02b: PmUsdCrvUsdStrategy _withdraw exchange rate drift
**Severity**: LOW
**Contract(s)**: PmUsdCrvUsdStrategy.sol
**Function(s)**: _withdraw()
**Category**: Logic / Exchange Rate

## Description
The `_withdraw()` function calculates shares to redeem based on `balanceOf()` which uses a cached virtual price with ±0.5% bounds. If the Stake DAO reward vault's exchange rate has changed since the cache was last updated, the actual redeem could yield less than `debtAmount`. This is inherent to yield strategies — the vault absorbs the variance.

## Impact
The vault receives a different amount than requested on each partial withdraw. Limited to ±0.5% by the VP cache bounds. No cumulative drift — each withdraw is independent.

## Recommendation
Use `rewardVault.previewRedeem(shares)` or `rewardVault.convertToAssets(sharesToRedeem)` for the actual received amount. Document the expected variance in the function's NatSpec.
