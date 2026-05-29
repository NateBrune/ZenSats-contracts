# L07: CurveTwoCryptoSwapper SlippageExceeded revert on both directions
**Severity**: LOW
**Contract(s)**: CurveTwoCryptoSwapper.sol
**Function(s)**: swapCollateralForDebt, swapDebtForCollateral
**Category**: Slippage / Revert

## Description
CurveTwoCryptoSwapper applies MAX_ORACLE_DEVIATION (10%) as a hard floor on the pool quote. If the pool's get_dy output is more than 10% below the oracle price, it reverts with SlippageExceeded(). This check is applied to BOTH directions independently.

## Impact
Low. The 10% deviation is generous for major pairs (USDT/WBTC). Less liquid pairs may experience frequent revert-on-quote.

## Recommendation
Consider making MAX_ORACLE_DEVIATION configurable per-pair or per-vault.
