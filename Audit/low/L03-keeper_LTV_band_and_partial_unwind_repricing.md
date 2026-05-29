# L03: Keeper checkUpkeep safe subtraction vs rebalance mismatch
**Severity**: LOW
**Contract(s)**: ZenjiRebalanceKeeper.sol
**Function(s)**: checkUpkeep
**Category**: Logic / Band Calculation

## Description
The keeper uses safe subtraction for lower band:
```solidity
uint256 lowerBand = target > spread ? target - spread : 0;
```
While rebalance uses direct subtraction:
```solidity
uint256 lowerBand = targetLtv - DEADBAND_SPREAD;
```
If targetLtv < DEADBAND_SPREAD, the keeper's lowerBand = 0 (always satisfied) while rebalance's lowerBand could underflow.

## Impact
Rare edge case with very low target LTV. Keeper would trigger but rebalance would not consider it out of band.

## Recommendation
Add safe subtraction in checkUpkeep to match rebalance, or add: `if (targetLtv < spread) lowerBand = 0;`

---

# L03b: Partial unwind re-pricing — withdrawers absorb slippage
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: _redeemStandard (partial unwind path)
**Category**: ERC4626 / Repricing

## Description
In the partial unwind path, the code re-prices the collateral:
```solidity
uint256 realizedCollateral = (actualShareAmount * (postUnwindTotal + VIRTUAL_SHARE_OFFSET())) / virtualSupply;
if (realizedCollateral < collateralAmount) {
    collateralAmount = realizedCollateral;
}
```
This correctly reduces the withdrawer's payout when unwind slippage exceeds expectations. The MAX_USER_SLIPPAGE cap (20%) bounds the blast radius.

## Impact
Withdrawers may receive less collateral than initially calculated. This is the intended behavior — the withdrawer absorbs strategy unwind slippage proportionally rather than socializing it onto remaining shareholders.

## Recommendation
No change needed. For users who want full withdrawal, they should use the final withdraw path (burn all shares).
