# I06: Dust swap threshold comparison — Aave vs Llama
**Severity**: INFO
**Contract(s)**: AaveLoanManager.sol, LlamaLoanManager.sol
**Function(s)**: executeOperation, _swapCollateralForDebt
**Category**: Configuration / Dust

## Description
Aave uses DUST_SWAP_THRESHOLD = 1000 (sat) for WBTC, below which oracle-based minOut checks are waived. Llama doesn't have an equivalent dust swap threshold in _swapCollateralForDebt.

## Impact
Minor inconsistency between the two loan managers' dust handling patterns.

## Recommendation
Consider adding a dust swap threshold to Llama's _swapCollateralForDebt for consistency.
