# L11: AaveLoanManager executeOperation second sweep pattern inconsistency
**Severity**: LOW
**Contract(s)**: AaveLoanManager.sol
**Function(s)**: executeOperation (step 3, second sweep)
**Category**: Code Quality / Pattern

## Description
The first swap block guards with `if (toSwap > 0)`. The second defensive sweep guards on `remainingCollateral > 0` without computing `toSwap` first. If `remainingCollateral` is non-zero but the swapper's swap function reverts on very small amounts, the error message is less informative.

## Impact
Minor — the second sweep works correctly but lacks the same defensive calculation pattern as the first sweep.

## Recommendation
For consistency, compute `toSwap` explicitly in the second sweep and guard on `toSwap > 0`.
