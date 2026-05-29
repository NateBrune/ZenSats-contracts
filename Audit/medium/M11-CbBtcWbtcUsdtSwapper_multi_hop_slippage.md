# M11: CbBtcWbtcUsdtSwapper multi-hop compounding slippage
**Severity**: MEDIUM
**Contract(s)**: CbBtcWbtcUsdtSwapper.sol
**Function(s)**: swapCollateralForDebt, swapDebtForCollateral
**Category**: Slippage / Multi-hop

## Description
CbBtcWbtcUsdtSwapper performs two swaps: cbBTC→WBTC then WBTC→USDT. Each hop applies slippage independently. The effective end-to-end slippage is approximately:
```
1 - (1 - slippage)^2 ≈ 2 * slippage (for small slippage values)
```

For a 1% configured slippage, the effective end-to-end slippage is ~2%. The oracle floor is applied only to the second hop and doesn't account for the compounding slippage from hop 1.

Example: 1% slippage, hop 1 returns 99% of expected WBTC.
Hop 2 oracle floor = oracleExpected * 0.99
But actual expected from hop 1 = expectedWbtc * 0.99
So the effective floor is oracleExpected * 0.99^2 ≈ oracleExpected * 0.9801

## Impact
Medium. The oracle floor on the second hop is slightly optimistic relative to the worst-case compounded slippage. In extreme cases, the vault's final check could pass while the actual output is below the oracle floor.

## Recommendation
Apply the oracle floor to the second hop using the reduced expected output from hop 1, or document that the effective end-to-end slippage is approximately 2× the configured slippage.
