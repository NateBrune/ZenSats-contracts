# L05: Timelock expiry window — 7 days after delay
**Severity**: LOW
**Contract(s)**: TimelockLib.sol
**Function(s)**: execute (both value and address variants)
**Category**: Governance / Timelock

## Description
TimelockLib enforces a 7-day expiry window after the timelock delay. For swapper changes:
- Proposal made at T
- Ready at T + 1 week
- Expires at T + 8 weeks

If the guardian is unavailable during the expiry window, the proposal is lost. There is no way to extend the expiry once set.

## Impact
Low. A compromised gov could propose a swapper, and if the guardian is unavailable for 8 weeks total, the change goes through.

## Recommendation
Consider adding an extend() function or making the expiry configurable per proposal.
