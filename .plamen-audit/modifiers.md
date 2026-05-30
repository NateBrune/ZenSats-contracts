# Modifiers

| Contract | Modifier | File:Line | Description |
|----------|----------|-----------|-------------|
| Zenji | onlyStrategist | src/Zenji.sol:251 | msg.sender == strategist |
| Zenji | onlyGov | src/Zenji.sol:256 | msg.sender == gov |
| Zenji | onlyGuardian | src/Zenji.sol:261 | msg.sender == guardian |
| Zenji | nonReentrant | src/Zenji.sol:266 | reentrancy guard (_status) |
| BaseSwapper | onlyGov | src/swappers/base/BaseSwapper.sol:27 | msg.sender == gov |
| LlamaLoanManager | onlyVault | src/lenders/LlamaLoanManager.sol:143 | msg.sender == vault |
| AaveLoanManager | onlyVault | src/lenders/AaveLoanManager.sol:91 | msg.sender == vault |
| AaveLoanManager | nonReentrant | src/lenders/AaveLoanManager.sol:96 | reentrancy guard (_status) |
| BaseYieldStrategy | onlyVault | src/strategies/BaseYieldStrategy.sol:62 | msg.sender == vault |
| BaseYieldStrategy | onlyOwner | src/strategies/BaseYieldStrategy.sol:67 | msg.sender == owner |
| ZenjiRebalanceKeeper | onlyOwner | src/keepers/ZenjiRebalanceKeeper.sol:34 | msg.sender == owner |

## Notes
- LlamaLoanManager does NOT have a nonReentrant modifier (unlike AaveLoanManager)
- BaseYieldStrategy uses `onlyOwner` for slippage/rescue ops; `onlyVault` for deposit/withdraw/harvest
- Zenji's nonReentrant only guards deposit/withdraw flows in the vault itself
- No nonReentrant in strategy-level deposit/withdraw (relies on vault-level guard)
