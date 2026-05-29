# L25: Oracle staleness check uses block.timestamp
**Severity**: LOW
**Contract(s)**: Multiple contracts
**Function(s)**: Multiple view functions
**Category**: Oracle / L2 Safety

## Description
All oracle staleness checks use `block.timestamp - updatedAt > MAX_ORACLE_STALENESS`. On L2s (like Arbitrum), block.timestamp can be manipulated by miners/validators within a small window. This is a minor risk for Chainlink oracles which update on a fixed interval (24h heartbeat) rather than per-block.

## Impact
Very low risk on L2s. Chainlink oracles are updated by off-chain relayers on a fixed schedule.

## Recommendation
No change needed for L2 deployments. Consider using a safety buffer in the staleness check if deploying on L1.
