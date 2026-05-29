# L16: OracleLib _validatedPrice staleness check is correct
**Severity**: LOW
**Contract(s)**: OracleLib.sol
**Function(s)**: _validatedPrice
**Category**: Oracle / Staleness

## Description
The staleness check uses:
```solidity
if (answeredInRound < roundId) revert StaleOracle();
```
This checks that the current answer was computed in the current or a later round. Combined with the maxStaleness timestamp check, this provides adequate protection for Chainlink feeds.

## Impact
No issue. The staleness check is correct for Chainlink feeds.

## Recommendation
No change needed.
