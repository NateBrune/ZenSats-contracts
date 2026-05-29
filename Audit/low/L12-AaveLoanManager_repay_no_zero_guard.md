# L12: AaveLoanManager executeOperation fullyClose branch repay without zero guard
**Severity**: LOW
**Contract(s)**: AaveLoanManager.sol
**Function(s)**: executeOperation (step 1, fullyClose branch)
**Category**: Code Quality / Gas

## Description
Both branches in the fullyClose path call `aavePool.repay()` unconditionally (no `if (toRepay > 0)` guard). Since `debt > 0` is guaranteed by the outer `if` and `debtBal >= 0`, `toRepay` is always > 0 when `debt > 0`. However, if `debtBal == 0` and `debt > 0`, then `toRepay = 0` and `aavePool.repay(address(debtToken), 0, ...)` is a no-op.

## Impact
No functional issue. Repaying 0 is a valid no-op in Aave.

## Recommendation
For clarity and gas efficiency, add `if (toRepay > 0)` around the repay calls.
