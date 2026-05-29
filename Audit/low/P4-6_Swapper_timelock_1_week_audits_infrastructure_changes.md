# P4-6: Swapper timelock (1 week) audits infrastructure changes
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: `proposeSwapper()`, `executeSwapper()`, `guardianCancelSwapper()`
**Category**: Admin Centralization / Timelock Effectiveness

## Description

The swapper change flow uses a 1-week timelock:

```solidity
function proposeSwapper(address newSwapper) external onlyGov {
    _swapperTimelock.set(address(swapper), newSwapper, block.timestamp + TIMELOCK_DELAY);
}

function executeSwapper() external onlyGov {
    _swapperTimelock.execute();
}

function guardianCancelSwapper() external onlyGuardian {
    _swapperTimelock.cancel();
}
```

### Defense Layers

1. **Gov-only proposal**: Only gov can propose a new swapper
2. **1-week timelock**: 7 days for community/guardian to react
3. **Guardian veto**: Guardian can cancel at any time during the 1-week window
4. **Gov-only execution**: Only gov can execute (not the new swapper itself)

### Potential Concerns

- **1 week may be short** for a major infrastructure change. Community analysis, audit of new swapper, and governance voting typically take longer
- **No governance vote**: The swapper change is controlled by a single multisig (gov), not a governance vote
- **Guardian is the only check**: If guardian is also compromised or inactive, the 1-week timelock is the only defense

### Comparison with Other Timelocks

| Change | Timelock | Veto |
|--------|----------|------|
| Strategist transfer | 1 week | Guardian |
| Gov transfer | 4 weeks | Guardian |
| Guardian transfer | 4 weeks | Guardian |
| Swapper change | 1 week | Guardian |
| Fee rate increase | 1 week | None (gov-only) |
| LTV increase | 1 week | None (gov-only) |
| Emergency skip | 3 days | Gov |

### Impact

- **1-week window is reasonable** for swapper changes since:
  - Swappers are typically simple, well-audted contracts
  - Slippage is configurable (1% default)
  - The old swapper can still be used for `swapDebtForCollateral()` (no timelock)
- **Asymmetric**: Swapper can be changed in 1 week, but can also be changed back in 1 week (gov proposes again)

## Recommendation

1. **Consider extending to 2 weeks** for the swapper timelock, especially if new swapper types are added (e.g., multi-hop, aggregator)
2. **Document the rationale**: Note that 1 week was chosen because swappers are simple and the guardian veto provides additional safety
3. **Monitor swapper changes**: Set up on-chain alerts for `SwapperChangeProposed` events

## Notes

- The `swapDebtForCollateral()` function (used for user withdrawals) does NOT require timelock — any gov-set swapper works immediately
- Only `swapCollateralForDebt()` (used for deposits and rebalances) is timelocked
