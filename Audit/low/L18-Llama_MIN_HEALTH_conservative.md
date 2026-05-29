# L18: LlamaLoanManager MIN_HEALTH threshold — potentially too conservative
**Severity**: LOW
**Contract(s)**: LlamaLoanManager.sol
**Function(s)**: createLoan, borrowMore
**Category**: Configuration / Health

## Description
LlamaLoanManager uses MIN_HEALTH = 1e17 (10% health factor). LlamaLend's health function is band-based, and a 10% minimum is very conservative — most of the band-based model's safety margin is below this threshold.

## Impact
Loans may revert as "HealthTooLow" even though the position is well within LlamaLend's acceptable risk range. This could prevent optimal capital deployment.

## Recommendation
Consider lowering MIN_HEALTH to a value closer to LlamaLend's liquidation threshold (e.g., 0 or a small positive value). Or document why 1e17 was chosen.
