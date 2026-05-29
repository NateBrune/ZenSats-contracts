# M13: UniswapMixedCurveSwapper minOut = 0 on both hops
**Severity**: MEDIUM
**Contract(s)**: UniswapMixedCurveSwapper.sol
**Function(s)**: swapCollateralForDebt, swapDebtForCollateral
**Category**: Slippage / No Protection

## Description
In swapCollateralForDebt (wstETH → WETH → crvUSD):
- Hop 1 (V3): wstETH → WETH with amountOutMin = 0 (Curve step enforces floor)
- Hop 2 (Curve): WETH → crvUSD with minCrvUsd = 0

Both hops use minOut = 0. The swapper itself provides NO slippage protection — it relies entirely on the caller (LlamaLoanManager) to validate the output.

In swapDebtForCollateral (crvUSD → WETH → wstETH):
- Hop 1 (Curve): crvUSD → WETH with minOut = 0
- Hop 2 (V3): WETH → wstETH with minOut = oracle floor (not slippage-based)

The oracle floor on hop 2 uses DUST_SWAP_THRESHOLD (1000) — if expected output is below 1000, minOut = 0.

## Impact
Medium. The swapper accepts any output from both hops. If the Curve pool is manipulated between hop 1 and hop 2 (unlikely in same tx but possible with flash loans), the output could be significantly below expected.

## Recommendation
Consider adding a minimum output check on hop 1 for swapCollateralForDebt, or document that the LlamaLoanManager's SwapperUnderperformed check is the primary slippage guarantee.
