# Static Analysis

> Source: Slither 0.11.5 (93 contracts analyzed, 101 detectors, 335 total findings)
> Scope filter: src/ only (excluding test/, lib/, script/)

## Summary

| Check | src/ Count | Severity |
|-------|-----------|---------|
| reentrancy-no-eth | 13 | Medium |
| reentrancy-balance | 21 | High |
| reentrancy-events | 37 | Low |
| divide-before-multiply | 2 | Medium |
| incorrect-equality | 29 | Medium |
| unchecked-transfer | 0 | — |
| calls-loop | 0 | — |

---

## Reentrancy (reentrancy-no-eth) — 13 findings in src/

State written after external call (no ETH sent). Protected by `nonReentrant` in most entry points but some internal functions are noted.

### Key findings:

**1. Zenji.rebalance() — multiple external calls before state writes**
- `yieldStrategy.updateCachedVirtualPrice()` called, then `processRebalanceBounty()`, then state update
- `lastStrategyBalance` and `feesAtLastRebalance` written after external calls
- `rebalance()` does NOT have `nonReentrant` modifier
- Location: src/Zenji.sol:585-664

**2. Zenji._withdrawFromYieldStrategy() — lastStrategyBalance written after withdraw**
- `yieldStrategy.withdraw()` called, then `lastStrategyBalance = yieldStrategy.balanceOf()`
- Location: src/Zenji.sol:1556-1582

**3. Zenji.withdrawFees() — feesAtLastRebalance written after external processWithdrawFees**
- Location: src/Zenji.sol:867-874

**4. Zenji.setIdle(true) — lastStrategyBalance=0 written after yieldStrategy.withdrawAll()**
- Location: src/Zenji.sol:687-721

**5. Zenji.emergencyStep() — accumulatedFees written after executeEmergencyStep()**
- Location: src/Zenji.sol:887-915

**6. Zenji.harvestYield() — accumulatedFees updated after yieldStrategy.harvest()**
- Location: src/Zenji.sol:674-681

**7. Zenji._deployDebtToYield() — lastStrategyBalance written after yieldStrategy.deposit()**
- Location: src/Zenji.sol:1535-1551

**8. Zenji._unwindPosition() — lastStrategyBalance=0 after yieldStrategy.withdrawAll()**
- Location: src/Zenji.sol:1589-1638

---

## Divide-Before-Multiply — 2 findings in src/

**1. CurveUsdtSwapLib._oracleFloor6to18()**
```
oracleExpected = (amountIn * inPrice * 1e12) / outPrice  // divide
(oracleExpected * (PRECISION - slippage)) / PRECISION     // multiply on result
```
- Location: src/libraries/CurveUsdtSwapLib.sol:146-159

**2. CurveUsdtSwapLib._oracleFloor18to6()**
```
oracleExpected = (amountIn * inPrice) / (outPrice * 1e12)  // divide
(oracleExpected * (PRECISION - slippage)) / PRECISION       // multiply on result
```
- Location: src/libraries/CurveUsdtSwapLib.sol:162-174

> Note: These are precision issues in oracle floor calculations for min-out slippage checks. May cause slightly inaccurate slippage floors.

---

## Incorrect-Equality — 29 findings in src/

Strict equality on variables that may not reach exact values. Notable:

1. `crvUsdAmount == 0` — CrvUsdLpStakeDaoStrategy._addLiquidity (src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol:67)
2. `collateral == 0 || debt == 0` — AaveLoanManager.getCurrentLTV (src/lenders/AaveLoanManager.sol:494)
3. `sharesToMint == 0` — Zenji._deposit (src/Zenji.sol:1297)
4. `debtUsd == 0` — AaveLoanManager.getHealth (src/lenders/AaveLoanManager.sol:529)
5. `lpAssetBal == 0` — BaseLPStrategy._addLiquidityAndStake (src/strategies/lp/BaseLPStrategy.sol:251)

---

## Reentrancy-Balance — 21 findings in src/

Balance reads after external calls (higher risk than no-eth):

1. **AaveLoanManager.executeOperation()** — multiple: `collateralToken.safeTransfer()` then balance checks
   - Location: src/lenders/AaveLoanManager.sol:343-466
2. **Zenji._swapRemainingDebtToCollateral()** — `swapper.swapDebtForCollateral()` then balance reads
   - Location: src/Zenji.sol:1241-1273

---

## Low-Level .call Usage

All in SafeTransferLib.sol and swapper safeTransfer helpers — standard pattern for USDT compatibility:
- `src/libraries/SafeTransferLib.sol` — token.transfer, token.transferFrom, token.approve
- `src/swappers/base/UniswapV3TwoHopSwapper.sol` — safeTransfer wrapper
- `src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol` — safeTransfer wrapper
- `src/swappers/base/CurveThreeCryptoSwapper.sol` — safeTransfer wrapper
- `src/swappers/base/UniswapMixedTwoHopSwapper.sol` — safeTransfer wrapper

---

## Grep Checks

### External calls in loops
- **None found** in src/ (calls-loop: 0 from slither)

### Division before multiplication (additional grep)
Notable patterns in oracle math:
- `src/WstEthOracle.sol:72` — `(ratio * uint256(stEthEthPrice) * uint256(ethUsdPrice)) / (1e18 * 1e18)` — ordered correctly (mul then div)
- `src/libraries/OracleLib.sol:160` — `(collateralAmount * price * 1e18) / (oracleScale * tokenScale)` — ordered correctly
