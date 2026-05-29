# M12: CbBtcWbtcUsdtSwapper _safeGetDyThree return handling
**Severity**: MEDIUM
**Contract(s)**: CbBtcWbtcUsdtSwapper.sol
**Function(s)**: _safeGetDyThree, swapCollateralForDebt, swapDebtForCollateral
**Category**: Logic / Return Handling

## Description
_safeGetDyThree uses staticcall to query the Curve pool for estimated output:
```solidity
(bool ok, bytes memory data) = address(triCryptoPool)
    .staticcall(abi.encodeWithSelector(ICurveThreeCrypto.get_dy.selector, i, j, dx));
if (!ok || data.length < 32) return 0;
```

If the pool reverts (e.g., due to invalid indices), the function returns 0. This 0 is then used as the expected output for slippage calculation, making minOut = 0 (accepts any output). If get_dy fails on the first hop, swapCollateralForDebt returns 0 early, and the caller (Zenji._swapRemainingDebtToCollateral) sees "SwapperUnderperformed" but the root cause is ambiguous.

## Impact
Medium. A failing get_dy on the first hop causes early return with 0 output. The caller sees "SwapperUnderperformed" but the root cause could be a bad pool response, a reverted get_dy, or a genuine market slippage event.

## Recommendation
Consider adding a dedicated error for pool query failures in the swapper, or document the failure modes so the caller can distinguish between "pool returned 0" and "pool transferred 0".
