# M5: _claimAndCompound() double-count CRV rewards risk
**Severity**: MEDIUM
**Contract(s)**: BasePmUsdCrvUsdStrategy.sol
**Function(s)**: _claimAndCompound()
**Category**: Logic / Double Counting

## Description
`_claimAndCompound()` calls `_accountantClaim()` which claims CRV from the Stake DAO accountant. The function is called from `_deposit()`, `_withdraw()`, and `_harvest()`. Within a single transaction path, it's only called once, so double-counting is not a risk.

However, the claim() function may transfer CRV to the reward vault rather than directly to the strategy. The function reads `crv.balanceOf(address(this))` after claiming, which may not include CRV that ended up in the reward vault.

## Impact
- CRV rewards may end up in the reward vault instead of the strategy's direct balance
- The strategy's CRV balance check after claiming may not include CRV already in the reward vault
- On the next compound cycle, `_claimAndCompound()` will claim again from the accountant (which may have no more pending rewards), but the CRV in the reward vault is not directly accessible

## Recommendation
- Add a state flag to prevent re-entrant claims within the same transaction
- Or check the reward vault's balanceOf for CRV rewards in addition to the strategy's direct balance
- Consider claiming only in `_harvest()` and compounding in `_deposit()`
