# P4-4: Keeper ownership transfers immediately (no timelock)
**Severity**: LOW
**Contract(s)**: ZenjiRebalanceKeeper.sol
**Function(s)**: `transferOwnership()`
**Category**: Admin Centralization / Key Management

## Description

The Chainlink Automation keeper contract allows immediate ownership transfer:

```solidity
function transferOwnership(address newOwner) external onlyOwner {
    if (newOwner == address(0)) revert InvalidAddress();
    address oldOwner = owner;
    owner = newOwner;
    emit OwnershipTransferred(oldOwner, newOwner);
}
```

No timelock, no two-step acceptance. The new owner can immediately call `drainERC20()` on any token held by the keeper.

### Keeper's Balance

The keeper typically holds minimal or no tokens (it's an automation contract that calls `vault.rebalance()`). However, if the keeper ever holds tokens (e.g., rebalance bounties, dust), the owner can drain them immediately.

### Impact

- **Immediate drain**: If keeper holds any tokens, new owner can drain them immediately
- **Low risk**: Keeper typically has no significant balance
- **Mitigated**: Keeper's `performUpkeep()` is permissionless — anyone can trigger rebalance

## Recommendation

1. **Add a timelock**: Require a 1-week delay before new owner can call `drainERC20()`
2. **Or document**: Note that keeper ownership transfer is safe because the keeper holds no significant assets
3. **Consider removing `drainERC20()`**: If keeper never holds tokens, this function is unnecessary

## Notes

- This is standard for Chainlink Automation keepers (immediate ownership is expected)
- The keeper's main function (`performUpkeep`) is permissionless, so owner only affects `drainERC20()`
