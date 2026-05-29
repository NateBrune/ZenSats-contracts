# L24: CrvToCrvUsdSwapper quote() no staleness check
**Severity**: LOW
**Contract(s)**: CrvToCrvUsdSwapper.sol
**Function(s)**: quote()
**Category**: Oracle / Quote

## Description
The quote() function uses `triCryptoPool.get_dy()` which is a view function on the Curve pool. It does not check oracle staleness. If the pool's internal reserves are stale (e.g., after a long period of no trades), the quote may be inaccurate.

## Impact
Low. The quote is used for display and fallback calculations. The actual swap uses both pool and oracle floors.

## Recommendation
Consider adding an optional staleness check parameter or documenting that quote() is for display purposes only.
