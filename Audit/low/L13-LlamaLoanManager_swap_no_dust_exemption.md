# L13: LlamaLoanManager _swapCollateralForDebt always checks slippage (no dust exemption)
**Severity**: LOW
**Contract(s)**: LlamaLoanManager.sol
**Function(s)**: _swapCollateralForDebt
**Category**: Slippage / Dust

## Description
Unlike AaveLoanManager.executeOperation which skips slippage checks for dust swaps (below DUST_SWAP_THRESHOLD = 1000 sat), LlamaLoanManager's `_swapCollateralForDebt` always checks slippage. For very small collateral amounts, the oracle-based expected debt may round to 0, making the check pass. But for amounts where the expected debt is non-zero, the check may fail due to pool fee rounding.

## Impact
Small collateral swaps may fail in Llama but succeed in Aave. Inconsistent behavior between the two loan managers.

## Recommendation
Add a dust threshold check to `_swapCollateralForDebt` matching the pattern in AaveLoanManager.executeOperation.
