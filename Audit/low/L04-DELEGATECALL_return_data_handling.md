# L04: DELEGATECALL return data handling in ZenjiCoreLib
**Severity**: LOW
**Contract(s)**: ZenjiCoreLib.sol
**Function(s)**: All external functions
**Category**: Infrastructure / DELEGATECALL

## Description
ZenjiCoreLib functions are called via DELEGATECALL. The caller reads returned values directly from the calldata return area. If a future function is added that does not use named returns or uses a different return layout, the caller could silently read garbage values.

Specifically, `processWithdrawFees` returns `(0, yieldStrategy.balanceOf())` when strategyBalance == 0 but fees > 0. If the strategy is later replaced with one that reverts on balanceOf(), this would fail mid-call.

## Impact
Low risk in current code. Potential for silent data corruption if function signatures diverge between library and caller in future upgrades.

## Recommendation
Add a check in Zenji that validates the library address hasn't changed between calls.
