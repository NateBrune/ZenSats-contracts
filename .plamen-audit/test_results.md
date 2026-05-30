# Test Results

## Unit Tests (no fork)

**Command**: `forge test --no-match-path "*.fork.t.sol"`

| Metric | Value |
|--------|-------|
| Tests passed | 698 |
| Tests failed | 0 |
| Tests skipped | 0 |
| Total suites | 34 |
| Wall time | 118.83s |
| CPU time | 1021.30s (parallel) |

**TEST HEALTH**: PASSING — 698/698 unit tests pass with 0 failures.

## Included Test Suites (non-fork)

Notable suites run (from output):
- PmUsdHandler invariants (256 runs, 128k calls, 0 reverts) — `invariant_totalCollateralNonNegative()`
- Multiple handler-based invariant tests for deposit/harvest/rebalance/redeem/withdraw

## Fork Tests (NOT RUN)

Files matching `*.fork.t.sol` require MAINNET_RPC_URL and were excluded. These cover:
- CbBtcAaveExtensive.fork.t.sol
- AC3_StaleOracle_WithdrawFreeze.fork.t.sol  
- CbBtcUsdtIporAaveStrategy.fork.t.sol
- H1_H4_EmergencyUSDTStranding.t.sol (partially — has fork deps)
- H5_ATokenDonation.fork.t.sol
- M1 through M11 fork tests
- ProtocolSmokeTests.fork.t.sol
- SlippageSocialization.fork.t.sol
- VaultInvariants.fork.t.sol
- And others

## Notes
- Medusa (v1.5.1) available for stateful fuzzing but requires medusa.json config
- No medusa.json found in project root — would need to be created
