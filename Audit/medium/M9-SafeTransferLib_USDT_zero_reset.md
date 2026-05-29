# M9: SafeTransferLib USDT zero-reset can fail on some token versions
**Severity**: MEDIUM
**Contract(s)**: SafeTransferLib.sol
**Function(s)**: safeApprove
**Category**: Arithmetic / Non-standard ERC20

## Description
safeApprove handles USDT's non-standard behavior (void return, zero-first reset) but has a gap. The zero-reset call ignores the return value check for tokens that return void:

```solidity
(bool resetSuccess,) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, 0));
if (!resetSuccess) revert TransferFailed();
```

If USDT reverts on the zero-reset (some older versions do), the function reverts even though the existing allowance may already be sufficient.

## Impact
Medium. USDT zero-reset can fail on some token versions, causing unnecessary reverts even when no approval change is needed.

## Recommendation
Wrap the zero-reset in a try/catch or check if the current allowance already meets the target before attempting the reset:
```solidity
uint256 currentAllowance = token.allowance(address(this), spender);
if (currentAllowance >= amount) return;
if (currentAllowance > 0) {
    (bool resetSuccess,) = address(token).call(
        abi.encodeWithSelector(token.approve.selector, spender, 0));
    // Optionally ignore revert — USDT may not support zero-reset
}
```
