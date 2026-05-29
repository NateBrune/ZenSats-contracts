# L01: isFinalWithdraw detection uses totalSupply() instead of balanceOf(owner_)
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: _redeemStandard
**Category**: Logic / Final Withdraw

## Description
In `_redeemStandard`, the final withdrawal detection uses:
```solidity
bool isFinalWithdraw = (totalSupply() == shareAmount);
```
This compares against totalSupply() which includes the virtual share offset. If a user holds all real shares but totalSupply() is inflated by the virtual offset, the check may fail to detect a final withdrawal, leaving residual collateral stranded.

## Impact
A full-position withdrawer may not trigger the final unwind path, leaving residual collateral stranded in the loan manager and yield strategy.

## Recommendation
Replace with: `bool isFinalWithdraw = (shareAmount >= balanceOf(owner_));`

---

# L01b: _deposit return value mismatch (shares delta vs underlying)
**Severity**: LOW
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _deposit()
**Category**: Logic / Return Value

## Description
The `_deposit()` function returns `rewardVault.balanceOf(this) - sharesBefore` — a Stake DAO reward vault shares delta, NOT the actual amount of debt asset deposited. The BaseYieldStrategy parent class updates `_costBasis` from `amount` (the parameter), but the return value is misleading.

## Impact
- The vault receives a return value that does not match the cost basis update
- Dashboard and UI displays may show incorrect deposit amounts
- No critical math is affected — cost basis is set from `amount`

## Recommendation
Either rename the return variable to clarify it's a shares delta (e.g., `sharesMinted`), or compute the actual underlying deposited amount by converting the shares delta back through the reward vault's `convertToAssets()`.
