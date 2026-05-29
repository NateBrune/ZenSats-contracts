# M2: UsdtPmUsdCrvUsdStrategy _withdraw temporarily stuck crvUSD on swap failure
**Severity**: MEDIUM
**Contract(s)**: UsdtPmUsdCrvUsdStrategy.sol
**Function(s)**: _withdraw()
**Category**: Logic / Silent Loss

## Description
The `_withdraw()` function in UsdtPmUsdCrvUsdStrategy performs a multi-step withdrawal:
1. Redeem LP from Stake DAO reward vault → receives pmUSD/crvUSD LP
2. Remove liquidity from pmUSD/crvUSD pool → receives crvUSD
3. Swap crvUSD → USDT via Curve USDT/crvUSD pool

If step 2 succeeds but step 3 fails (slippage, oracle floor, or pool issue), the function returns 0:
```solidity
if (crvUsdReceived > 0) {
    usdtReceived = _swapCrvUsdToUsdt(...);
}
// Implicit return 0 if crvUsdReceived > 0 but swap fails
```

The crvUSD remains in the strategy contract but is never transferred back to the vault.

## Impact
- Silent loss of crvUSD to the strategy contract on every failed USDT swap
- Over time, significant value can accumulate at the strategy and become unrecoverable
- The vault's `balanceOf()` may show assets but the actual USDT received is 0

## Recommendation
- Add a fallback: if `crvUsdReceived > 0` but swap fails, transfer the crvUSD directly to the vault
- Or use the swap without slippage as a fallback: `_swapCrvUsdToUsdt(crvUsdReceived, 0)`
- Or store the crvUSD and emit an event for manual recovery
