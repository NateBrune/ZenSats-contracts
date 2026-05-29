# I05: Health factor thresholds — Aave vs Llama comparison
**Severity**: INFO
**Contract(s)**: AaveLoanManager.sol, LlamaLoanManager.sol
**Function(s)**: createLoan, borrowMore
**Category**: Configuration / Health

## Description
Aave uses MIN_HEALTH = 1.1e18 (110% of liquidation threshold). Llama uses MIN_HEALTH = 1e17 (10% absolute health). Both are conservative enough for the vault's risk profile but use very different scales due to the different health calculation models.

## Impact
No issue. Both thresholds are conservative for their respective protocols.

## Recommendation
Document the rationale for each threshold in NatSpec.
