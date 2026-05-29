# M10: _swapRemainingDebtToCollateral slippage floor — multi-hop gaps
**Severity**: MEDIUM
**Contract(s)**: Zenji.sol
**Function(s)**: _swapRemainingDebtToCollateral
**Category**: Slippage / Multi-hop

## Description
The effective slippage floor is:
```solidity
effectiveSlippage = max(swapperSlippage, baseSlip * 2)
```

For multi-hop swappers (CbBtcWbtcUsdtSwapper, UniswapMixedCurveSwapper, UniswapMixedTwoHopSwapper), the oracle check is end-to-end (collateral → debt), but the per-hop slippage is applied independently. If hop 1 loses more than the configured slippage but hop 2 compensates, the vault's final check passes but the intermediate hop could have failed silently.

Additionally, `_safeGetDyThree` in CbBtcWbtcUsdtSwapper uses staticcall and decodes the return without checking for revert. If the pool returns 0 for get_dy, the minOut passed to exchange() becomes 0, effectively allowing any output.

## Impact
Medium. Multi-hop swappers can have per-hop slippage gaps that aren't independently validated. The vault's end-to-end check is the primary safety net, but intermediate hops with minOut=0 could return less than expected.

## Recommendation
For multi-hop swappers, consider applying the oracle deviation check at each hop (not just end-to-end) or document that the vault's final check is the only slippage guarantee.
