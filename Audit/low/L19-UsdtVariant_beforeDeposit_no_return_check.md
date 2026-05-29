# L19: USDT variant _beforeDeposit() doesn't check swap return value
**Severity**: LOW
**Contract(s)**: UsdtPmUsdCrvUsdStrategy.sol
**Function(s)**: _beforeDeposit()
**Category**: Logic / Return Check

## Description
The _beforeDeposit() hook swaps USDT → crvUSD but the function is declared as returning void. The swap result (crvUsdReceived) is emitted in an event but not stored or returned. If the swap fails or returns less than expected, the function silently continues. The _addLiquidity() function later checks CRVUSD.balanceOf which will include the swapped amount.

## Impact
If the Curve swap fails entirely (e.g., slippage), the USDT remains in the contract but no crvUSD is produced. The _addLiquidity() function will find zero crvUSD/pmUSD and return 0, effectively losing the deposit.

## Recommendation
Add a check that crvUsdReceived > 0 after the swap. Or revert if the swap returned zero.
