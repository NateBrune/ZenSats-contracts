# L08: UniversalRouterV3SingleHopSwapper no slippage on dust quotes
**Severity**: LOW
**Contract(s)**: UniversalRouterV3SingleHopSwapper.sol
**Function(s)**: quoteCollateralForDebt
**Category**: Slippage / Dust

## Description
quoteCollateralForDebt returns the oracle-based collateral value divided by (1 - slippage), adding a slippage buffer for quoting. However, the actual swap uses a DUST_SWAP_THRESHOLD of 1000, below which minOut = 0.

## Impact
Low. Expected behavior for dust swaps.

## Recommendation
No change needed. Document that dust swaps have no slippage guarantee.
