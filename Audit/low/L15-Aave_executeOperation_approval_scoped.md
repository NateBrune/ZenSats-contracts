# L15: AaveLoanManager executeOperation step 4 approval scope
**Severity**: LOW
**Contract(s)**: AaveLoanManager.sol
**Function(s)**: executeOperation (step 4)
**Category**: Logic / Approval

## Description
Step 4 approves `repaymentNeeded` for the Aave pool. If the swapper in step 3 received more debt than expected, the balance could be > repaymentNeeded, and the approval would be set to repaymentNeeded. The remaining debt sits in the contract.

## Impact
No functional issue. The approval is correctly scoped.

## Recommendation
No change needed.
