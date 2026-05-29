# L09: Implementation MIN_DEPOSIT below VIRTUAL_SHARE_OFFSET
**Severity**: LOW
**Contract(s)**: ZenjiWbtc.sol, ZenjiWstEth.sol, ZenjiCbBtc.sol
**Function(s)**: MIN_DEPOSIT, VIRTUAL_SHARE_OFFSET
**Category**: Configuration / Inflation Attack

## Description
The base contract documentation states "MIN_DEPOSIT should be >= VIRTUAL_SHARE_OFFSET to preserve inflation-attack economics." Current mismatches:
- ZenjiWbtc: MIN_DEPOSIT=1e4 < VIRTUAL_SHARE_OFFSET=1e5
- ZenjiWstEth: MIN_DEPOSIT=1e4 << VIRTUAL_SHARE_OFFSET=3e16
- ZenjiCbBtc: MIN_DEPOSIT=1e4 < VIRTUAL_SHARE_OFFSET=1e5

## Impact
Low. A deposit of 1e4 tokens would pass the deposit check but would be diluted by the virtual offset.

## Recommendation
Add MIN_DEPOSIT overrides to ZenjiWbtc, ZenjiWstEth, and ZenjiCbBtc to match their VIRTUAL_SHARE_OFFSET values.
