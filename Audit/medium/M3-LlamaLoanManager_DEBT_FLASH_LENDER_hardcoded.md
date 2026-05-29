# M3: LlamaLoanManager DEBT_FLASH_LENDER hardcoded address staleness
**Severity**: MEDIUM
**Contract(s)**: LlamaLoanManager.sol
**Function(s)**: unwindPosition, onFlashLoan
**Category**: Infrastructure / Hardcoded Address

## Description
The flash loan lender address is hardcoded as a constant:
```solidity
address public constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
```

This is the crvUSD FlashLender (ERC3156). If this contract is deprecated or its implementation is replaced, all flashloan-based unwinds will revert:
```solidity
IERC3156FlashLender(DEBT_FLASH_LENDER)
    .flashLoan(IERC3156FlashBorrower(address(this)), ...);
```

Recovery paths exist (emergencySkipStep(1), emergencyRescue(2)), but a governance proposal to update the swapper does NOT affect this address.

## Impact
If the crvUSD FlashLender is deprecated, full close unwinds will fail until emergency step is used. The vault remains partially functional with collateral locked but no flashloan-based unwinding.

## Recommendation
Consider making `DEBT_FLASH_LENDER` mutable (governance-controlled) or add a fallback lender address. Document the staleness risk in the contract NatSpec.
