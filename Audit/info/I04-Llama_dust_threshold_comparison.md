# I04: Llama DUST_THRESHOLD vs Aave DUST_THRESHOLD
**Severity**: INFO
**Contract(s)**: LlamaLoanManager.sol, AaveLoanManager.sol
**Function(s)**: _isDustDebt
**Category**: Configuration / Dust

## Description
Aave uses DUST_THRESHOLD = 1e6 (1 USDT), while Llama uses DUST_THRESHOLD = 1e18 (1 crvUSD). The different thresholds reflect the different debt assets (USDT 6-dec vs crvUSD 18-dec). Both are appropriate for their respective debt assets.

## Impact
No issue. The thresholds are appropriate for each debt asset.

## Recommendation
No change needed. Document the rationale in NatSpec.
