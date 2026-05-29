# L20: CRV stuck at swapper contract not reclaimed
**Severity**: LOW
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _claimAndCompound()
**Category**: Logic / Token Recovery

## Description
The function transfers all CRV to the swapper:
```solidity
crv.safeTransfer(address(crvSwapper), crvBalance);
```
If the swap fails, the CRV is stuck at the swapper contract and the function continues without it. The next compound cycle will claim more CRV (if any) but won't recover the CRV already at the swapper.

## Impact
CRV stuck at the swapper contract is not reclaimed. The strategy's CRV balance check after claiming may not include CRV already at the swapper.

## Recommendation
Check the swapper's balance of CRV before transferring. Or add a function to sweep CRV from the swapper back to the strategy.
