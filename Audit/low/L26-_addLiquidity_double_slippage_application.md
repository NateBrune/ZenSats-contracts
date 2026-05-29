# L26: _addLiquidity() double slippage application
**Severity**: LOW
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _addLiquidity()
**Category**: Slippage / Design

## Description
The _addLiquidity() function applies slippage twice:
1. On the Curve calc_token_amount result: `minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION`
2. On the oracle floor: `oracleMinLp = (totalValue * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION)`

Both use LP_SLIPPAGE (0.5%), and the max of the two is used as minLp. This is not a double-application in the final tx, but it means the effective slippage floor is 0.5% in both directions.

## Impact
No functional bug, but the effective slippage could be higher than 0.5% if the oracle floor exceeds the Curve quote by more than 0.5%.

## Recommendation
Document the oracle floor behavior clearly. Consider capping the oracle floor at a reasonable multiple above the Curve quote.
