# L17: OracleLib decimal handling correct for all combinations
**Severity**: LOW
**Contract(s)**: OracleLib.sol
**Function(s)**: getCollateralValue, getDebtValue
**Category**: Arithmetic / Decimals

## Description
Both getCollateralValue and getDebtValue correctly handle decimal conversions for any combination of:
- WBTC (8 dec) / cbBTC (8 dec) / wstETH (18 dec) as collateral
- USDT (6 dec) as debt
- BTC/USD, ETH/USD, stETH/ETH oracles (8 dec)
- USDT/USD oracle (6 dec)

Intermediate numerator values are all well within uint256 range.

## Impact
No issue. Decimal handling is correct for all vault configurations.

## Recommendation
No change needed.
