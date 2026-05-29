# L21: setSlippage() has no timelock
**Severity**: LOW
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: setSlippage()
**Category**: Governance / Timelock

## Description
The setSlippage() function allows both the vault and the owner to update slippage without a timelock. The vault enforces a 2-day timelock on role transfers, but the owner can update slippage directly without a timelock.

## Impact
The owner (vault gov) can change slippage without timelock, which is intentional but different from how other gov parameters work.

## Recommendation
Document that setSlippage is an immediate admin action, not timelocked. Consider adding a timelock check if desired.
