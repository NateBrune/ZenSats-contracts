# I03: CurveUsdtSwapLib exchange() receiver fallback pattern
**Severity**: INFO
**Contract(s)**: CurveUsdtSwapLib.sol
**Function(s)**: exchange()
**Category**: Design / Fallback

## Description
The exchange() function first tries `ICurveStableSwapWithReceiver.exchange(i, j, dx, minOut, address(this))`, and falls back to the standard `exchange(i, j, dx, minOut)`. This pattern handles both old Curve pools (no receiver parameter) and new pools (with receiver parameter).

## Impact
No functional bug. The fallback is correctly implemented.

## Recommendation
No change needed. The pattern is correct.
