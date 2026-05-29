# I01: Harvest function compounds rather than transfers
**Severity**: INFO
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _harvest()
**Category**: Naming / Design

## Description
The _harvest() function claims CRV, swaps to crvUSD, compounds into LP, and then reports the rewardsValue. The emitted Harvested event reports this value. This is correct behavior — the harvest function compounds rewards rather than transferring them out.

## Impact
No functional bug. The behavior matches the interface contract.

## Recommendation
No change needed. The behavior is correct and matches the IYieldStrategy interface.
