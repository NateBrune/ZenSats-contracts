# L06: CrvToCrvUsdSwapper authorizedCaller can set slippage independently
**Severity**: LOW
**Contract(s)**: CrvToCrvUsdSwapper.sol
**Function(s)**: setSlippage
**Category**: Access Control / Slippage

## Description
setSlippage allows three callers: gov, vault, and authorizedCaller. The authorizedCaller (typically the yield strategy) can change the swapper's slippage independently of the vault's maxSlippage. If the strategy's slippage is set higher than the vault's, the vault's `_swapRemainingDebtToCollateral` check uses `max(swapperSlippage, baseSlip*2)`, widening the floor.

## Impact
Low. The authorizedCaller is trusted to set reasonable slippage. The vault's floor is widened but not removed.

## Recommendation
Consider capping authorizedCaller-set slippage at the vault's maxSlippage or requiring it within a band of the vault's setting.
