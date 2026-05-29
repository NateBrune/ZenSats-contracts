# M14: AaveLoanManager executeOperation — swapper callback reentrancy
**Severity**: MEDIUM
**Contract(s)**: AaveLoanManager.sol
**Function(s)**: executeOperation (step 3)
**Category**: Reentrancy

## Description
The swapper's `swapCollateralForDebt` function could potentially call back into the vault (e.g., via a deposit or rebalance callback). While the current swapper implementations do not re-enter the vault, the interface does not guarantee this. If a new swapper is deployed that calls back into the vault, and the vault's deposit function calls the loan manager, this could create a re-entrancy path:

```
executeOperation → swapper.swapCollateralForDebt → vault.deposit → loanManager.createLoan
```

The LoanManager's `createLoan` calls `_checkOracleFreshness()` and then `aavePool.supply()`. If this happens mid-flashloan, the aToken balance and variableDebtToken balance are both modified, potentially causing inconsistent state.

## Impact
If a malicious or buggy new swapper re-enters the vault, the flashloan's debt balance tracking could become inconsistent, potentially underpaying the flash loan.

## Recommendation
Add a re-entrancy guard to `executeOperation`, or add a re-entrancy guard to the LoanManager's state-changing functions to prevent re-entry during a flashloan callback.
