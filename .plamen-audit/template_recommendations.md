# Template Recommendations + BINDING MANIFEST — Zenji (Light Mode)

## BINDING MANIFEST

All templates marked **Required: YES** MUST be instantiated for this audit. Templates marked NO are optional or excluded.

---

## Standard Skill Templates

### ORACLE_ANALYSIS
- **Required**: YES
- **Trigger**: ORACLE flag (Chainlink feeds in every major flow path)
- **Used By**: breadth agents, depth-external, depth-edge-case
- **Instantiation Parameters**:
  - `ORACLE_CONTRACTS`: OracleLib (src/libraries/OracleLib.sol), WstEthOracle (src/WstEthOracle.sol), UsdtCrvUsdSwapMixin (staleness check), BaseCurveStakeDaoStrategy.pendingRewards (CRV oracle with fallback)
  - `STALENESS_WINDOWS`: collateral 1h–2h, debt 25h, crvUSD 25h, stETH/ETH 25h, CRV 25h
  - `PRICE_PATHS`: single-feed (BTC, ETH, USDT, crvUSD); composite chain (WstEthOracle: stETH/ETH × ETH/USD × stEthPerToken())
- **Protocol-Specific Questions**:
  1. Can a stale stETH/ETH Chainlink feed (24h heartbeat) independently block all wstETH vault operations, and does the WstEthOracle's `updatedAt` passthrough (using ETH/USD's updatedAt, not stETH/ETH's) create a gap where the composite oracle appears fresh while the stETH/ETH component is actually stale?
  2. Does the CRV oracle fallback path (`_pendingRewardsFallback` → swapper quote) in `BaseCurveStakeDaoStrategy.pendingRewards` understate rewards if the swapper has large CRV at a bad price, and can this be manipulated to suppress harvest-time rebalance?

---

### TOKEN_FLOW_TRACING
- **Required**: YES
- **Trigger**: BALANCE_DEPENDENT flag (share price depends on multiple balance reads across vault, LM, and strategy)
- **Used By**: depth-token-flow, breadth agents
- **Instantiation Parameters**:
  - `BALANCE_SOURCES`: `collateralAsset.balanceOf(vault)`, `aToken.balanceOf(lm)`, `variableDebtToken.balanceOf(lm)`, `strategy.balanceOf()` (LP: `stakingVault.balanceOf(strategy)` → convertToAssets → `_getSafeUnitValue()`), `yieldVault.balanceOf(strategy)` (IPOR)
  - `FEE_FLOW`: `lastStrategyBalance` checkpoint → delta × feeRate → `accumulatedFees` → subtracted from strategy balance in `getTotalCollateralValue`
  - `TOKEN_PATH_LP`: USDT/crvUSD → Curve add_liquidity → LP → stakingVault.deposit → shares; reverse on withdraw via `_stakedLpBalance` → `_getSafeUnitValue` → `calc_withdraw_one_coin` min
- **Protocol-Specific Questions**:
  1. During a partial `redeem()`, the shares are burned BEFORE `_unwindPosition` executes. The slippage re-pricing then uses `getTotalCollateral()` (which includes oracle-priced strategy balance) to compute `realizedCollateral`. If the oracle-priced `getNetCollateralValue` overestimates recovered collateral relative to what `_unwindPosition` actually returns (e.g., because strategy.balanceOf uses cached VP), can the withdrawer receive more collateral than was actually unrolled — effectively socializing the gap?
  2. Is there a scenario where `feesAtLastRebalance` being updated in `withdrawFees()` (to `accumulatedFees` post-withdrawal) creates a window where the next `rebalance()` incorrectly sees zero fee delta and pays no bounty, suppressing keeper incentive?

---

### FLASH_LOAN_INTERACTION
- **Required**: YES
- **Trigger**: FLASH_LOAN flag (both Aave flashLoanSimple and ERC3156 are active code paths)
- **Used By**: breadth agents, depth-token-flow, depth-edge-case
- **Instantiation Parameters**:
  - `FLASH_LENDERS`: Aave V3 Pool (AaveLoanManager), crvUSD ERC3156 `0x26dE7861...` (LlamaLoanManager)
  - `FLASH_CALLBACKS`: `executeOperation` (AaveLoanManager), `onFlashLoan` (LlamaLoanManager)
  - `FLASH_AMOUNT_CALC`: `(remainingDebt * 10300) / 10000` in both LMs; 3% buffer above debt
  - `REPAYMENT_PATH`: flashloan → repay Aave/Llama → withdraw collateral → swap residual debt → repay flashloan
- **Protocol-Specific Questions**:
  1. In `AaveLoanManager.executeOperation`: if `collateralNeeded` is sized from an oracle-priced position but the actual Aave `withdraw` returns less collateral (due to rounding), can the vault end up holding insufficient collateral to repay the flash loan premium, causing a revert that strands the position mid-unwind?
  2. In `LlamaLoanManager.onFlashLoan`: the `DEBT_FLASH_LENDER` is hardcoded. If a crvUSD emergency (e.g., depeg freeze) pauses the flash lender, emergency step 1 (`unwindLoan`) fails. The comment says `emergencySkipStep(1)` recovers — but after skipping, `liquidationComplete` can only be reached via step 2. What collateral is actually recoverable in that path?

---

### SEMI_TRUSTED_ROLES
- **Required**: YES
- **Trigger**: SEMI_TRUSTED_ROLE flag (Strategist, Guardian, Strategy.owner, Swapper.gov, Keeper.owner)
- **Used By**: breadth agents, depth-state-trace
- **Instantiation Parameters**:
  - `ROLES`: Strategist (setIdle, withdrawFees), Guardian (emergency ops), Strategy.owner (rescueERC20, setSlippage), Swapper.gov (setSlippage uncapped, setAuthorizedCaller, rescueToken), Keeper.owner (drainERC20 unrestricted)
  - `TRUST_ASSUMPTIONS`: See design_context.md Trust Assumption Table
  - `VETO_MECHANISMS`: Guardian can cancel role transfers and swapper proposals; Gov can cancel emergency skip and emergency mode
- **Protocol-Specific Questions**:
  1. `withdrawFees(recipient)` is Strategist-only with an arbitrary recipient address. If the Strategist is compromised, they can drain all `accumulatedFees` (potentially large) to any address in a single tx. What is the maximum fees that could be extracted, and is there a timelock or cap?
  2. `BaseYieldStrategy.rescueERC20` is owner-only and excludes protected tokens. `_isProtectedToken` guards debtAsset, lpToken, lpAsset, stakingVault, and CRV. Is there any intermediate token (e.g., crvUSD held transiently after a partial swap, or USDT in UsdtNgCrvUsdLpStakeDaoStrategy) that is NOT in the protected set but has material value that `rescueERC20` could extract?

---

### TEMPORAL_PARAMETER_STALENESS
- **Required**: YES
- **Trigger**: TEMPORAL flag (timelocks, oracle staleness windows, VP cache age)
- **Used By**: breadth agents, depth-state-trace
- **Instantiation Parameters**:
  - `TIMELOCKED_PARAMS`: swapper (1w), feeRate increase (1w), targetLtv increase (1w), bountyRate increase (1w), depositCap decrease (1w), maxSlippage increase (1w), role transfers (1w/4w), emergencySkip (3d)
  - `VP_CACHE`: MAX_VP_STALENESS = 1 day, MAX_VP_DEVIATION = 0.5%
  - `ORACLE_WINDOWS`: collateral 1h–2h, debt/crvUSD 25h, CRV 25h, stETH/ETH 25h
- **Protocol-Specific Questions**:
  1. The VP cache clamp is bypassed when `block.timestamp - lastVpUpdate > MAX_VP_STALENESS` (1 day). After a long idle period, the NEXT `updateCachedVirtualPrice()` call sets `cachedVirtualPrice` to the unclamped current live VP. If an attacker manipulates the pool's VP in the same block as the first update after staleness, can they set a permanently elevated VP before subsequent operations are clamped to the new (inflated) anchor?
  2. `setParam(1, targetLtv)` that DECREASES targetLtv is immediate (user-favorable). If the vault is at LTV 64% with targetLtv=65%, and gov immediately decreases targetLtv to 15%, the next `rebalance()` will attempt to unwind a massive position (LTV drop from 64% to 12%). Is there any size check or max-unwind-per-call to prevent a single rebalance call from attempting an economically infeasible position close?

---

### ECONOMIC_DESIGN_AUDIT
- **Required**: YES
- **Trigger**: MONETARY_PARAMETER flag (feeRate, bountyRate, LTV, slippage, depositCap)
- **Used By**: breadth agents
- **Instantiation Parameters**:
  - `FEE_MECHANISM`: feeRate (max 20%) on yield delta, accrued to `accumulatedFees`, withdrawn via `withdrawFees`. Bounty = `(feesSinceLastRebalance × bountyRate)` paid from accumulated fees at rebalance.
  - `LTV_MECHANISM`: Target LTV with 3% deadband; rebalance pays bounty; slippage socialized on withdrawer post-unwind re-pricing.
  - `CARRY_TRADE`: Borrow debt (USDT or crvUSD) → deploy to yield strategy. Net yield = strategy APR − borrowing rate.
- **Protocol-Specific Questions**:
  1. The rebalance bounty is `(feesSinceLastRebalance × bountyRate) / PRECISION`, paid from `accumulatedFees`. If `bountyRate = 50%` (maximum) and a single large yield event pushes `accumulatedFees` very high, a keeper calling `rebalance()` extracts half the accumulated fees. Is there a cooldown or cap on bounty per rebalance to prevent repeated keeper griefing via rapid rebalance calls?
  2. The fee-rate increase is timelocked but decreases are immediate. A gov-compromised scenario: gov immediately decreases feeRate to 0 → accrues zero fees → waits → increases feeRate (timelocked 1w) → new fees accrue at higher rate. Does the `executeParamChange(0)` path call `_accrueYieldFees()` to checkpoint at the old rate before the increase takes effect? (Per ARCHITECTURE.md: YES, but verify implementation.)

---

### EXTERNAL_PRECONDITION_AUDIT
- **Required**: YES
- **Trigger**: Multiple external protocol dependencies (Aave, LlamaLend, Curve, IPOR, Stake DAO, Chainlink)
- **Used By**: breadth agents
- **Protocol-Specific Questions**:
  1. The Curve `calc_withdraw_one_coin` is called live (not cached) in `BaseCurveStakeDaoStrategy.balanceOf()`. If the pmUSD/crvUSD pool is heavily imbalanced (pmUSD depeg), `calc_withdraw_one_coin` returns a very low value, causing `strategy.balanceOf()` to understate the vault's collateral value, triggering a rebalance that forces a large LP exit at a depressed price. Is this an unavoidable design choice or is there a missing floor?
  2. IPOR PlasmaVault has a per-address deposit cooldown. After `deposit()`, the strategy cannot immediately `redeem()` from IPOR. Does `emergencyStep(0)` (which calls `yieldStrategy.withdrawAll()`) fail if the IPOR cooldown is active? The `try/catch` in `ZenjiCoreLib.executeEmergencyStep` falls back to `emergencyWithdraw()` — does that also use IPOR redeem?

---

### ZERO_STATE_RETURN
- **Required**: YES
- **Trigger**: ERC4626 first-depositor / empty-vault edge cases
- **Used By**: depth-edge-case
- **Protocol-Specific Questions**:
  1. At vault deployment, `totalSupply() = 0` and `getTotalCollateral() = 0`. The first depositor calls `deposit(assets)`. `_calculateSharesForDeposit(assets)` returns `assets × VIRTUAL_SHARE_OFFSET() / VIRTUAL_SHARE_OFFSET() = assets`. After deploying capital, if the strategy instantly accrues yield (e.g., from `_compoundRewards` on deposit), `lastStrategyBalance = 0` still, so `_accrueYieldFees()` on the next deposit could compute a phantom profit for the first depositor. Is this handled?
  2. When the last user redeems (`isFinalWithdraw = true`), `_unwindPosition(type(uint256).max, ...)` is called. After full unwind, `collateralAmount = collateralAsset.balanceOf(address(this))`. If there is residual debt in the vault that could not be swapped (e.g., `debtBal <= oneDebtUnit` and `force=false` in `_swapRemainingDebtToCollateral`), the last redeemer receives less collateral than expected. Is the threshold correct for all debt token decimals?

---

## Injectable Skill Templates

### VAULT_ACCOUNTING
- **Required**: YES (protocol type = vault, ERC4626)
- **Inject Into**: Core state or economic design agent
- **Instantiation Parameters**:
  - `SHARE_MATH`: `(assets × (supply + offset)) / (totalCollateral + offset)` for mint; same formula reversed for redeem
  - `TOTAL_ASSETS_FORMULA`: `getTotalCollateral()` = vault_idle + lm.getNetCollateralValue() + lm.getDebtValue(strategy.balanceOf() − fees) + lm.getDebtValue(vaultIdleDebt) + lm.getCollateralBalance() + lm.getDebtValue(lmDebt)
  - `FEE_CHECKPOINT`: `lastStrategyBalance` updated on: `_accrueYieldFees` (deposit/withdraw/rebalance/harvestYield path), rebalance bounty payment, emergency step 0
- **Protocol-Specific Questions**:
  1. After `emergencyStep(0)` (withdraw all from strategy), `lastStrategyBalance = 0` and `accumulatedFees = 0`. Then `emergencyStep(1)` (unwind loan). At `emergencyStep(2)`, `liquidationComplete = true` and users redeem pro-rata of `collateralAsset.balanceOf(vault)` + `debtAsset.balanceOf(vault)`. But accumulated fees are zeroed in step 0 — does this mean the fee recipient loses all unaccrued fees, or were they already extracted? Trace the fee state through all emergency steps.

---

### LENDING_PROTOCOL_SECURITY
- **Required**: YES (protocol interacts with Aave V3 and LlamaLend)
- **Inject Into**: Breadth agents, depth-token-flow, depth-edge-case
- **Instantiation Parameters**:
  - `LENDING_PROTOCOLS`: Aave V3 (AaveLoanManager), LlamaLend LLAMMA (LlamaLoanManager)
  - `HEALTH_CHECKS`: `MIN_HEALTH = 1.1e18` (Aave), `MIN_HEALTH = 1e17` (Llama) — checked post-borrow
  - `LIQUIDATION_THRESHOLD_BPS`: Immutable per-deployment
  - `LTV_CALC`: `(debt * PRECISION) / collateralValue(aToken)` — uses Chainlink oracle
- **Protocol-Specific Questions**:
  1. In `AaveLoanManager.getCurrentLTV()`, `collateral = aToken.balanceOf(address(this))` is used in the numerator of the LTV calculation. A direct donation of aTokens to the loan manager would decrease the reported LTV (more collateral = lower LTV ratio), potentially suppressing the rebalance trigger even when the vault is actually overleveraged. Trace the impact on rebalance logic.
  2. In `LlamaLoanManager._partialUnwind` (during unwindPosition for partial close), the comment says "For partial: never flashloan — a proportional debt repay maintains the LTV ratio." Verify that the proportional calculation in the unwind path correctly maintains the LTV and does not leave the position in a soft-liquidation band.

---

### DEX_INTEGRATION_SECURITY
- **Required**: YES (all swappers integrate Curve pools and/or Uniswap V3; protocol is NOT a DEX itself)
- **Inject Into**: Breadth agents, depth-external, depth-edge-case
- **Instantiation Parameters**:
  - `DEX_INTEGRATIONS`: Curve TriCrypto (CurveThreeCryptoSwapper), Curve TwoCrypto (CurveTwoCryptoSwapper), Uniswap V3 two-hop (UniswapV3TwoHopSwapper, CbBtcUniswapV3TwoHopSwapper), Universal Router (UniversalRouterV3SingleHopSwapper), Curve NG (strategy LP add/remove), TriCrypto (CrvToCrvUsdSwapper)
  - `SLIPPAGE_PROTECTION`: Oracle-based min-out floor in all swappers; `effectiveSlippage = max(swapper.slippage, baseSlip×2)` in `_swapRemainingDebtToCollateral`
  - `MUTABLE_SWAPPER`: 1-week timelock; vault + LM updated atomically
- **Protocol-Specific Questions**:
  1. `_swapRemainingDebtToCollateral` computes `oracleExpected = loanManager.getDebtValue(debtBal)` and then applies `effectiveSlippage = max(swapperSlippage, baseSlip × 2)`. The `× 2` is explained as a divergence buffer between the oracle path and the multi-hop swap path. Can a MEV sandwich attack use this 2× buffer to extract up to `2 × maxSlippage` (up to 10% of the swap) from each unwind, and does the `swapper.slippage()` term provide adequate protection for multi-hop swappers like CbBtcUniswapV3TwoHopSwapper?
  2. For `CrvToCrvUsdSwapper.rescueToken`: the function has no protected-token check. If CRV accumulates at the swapper (deferred from a failed swap cycle) and the swapper.gov calls `rescueToken(CRV, gov, balance)`, are those CRV rewards lost to the strategy? Is `authorizedCaller` (the strategy) the only protection against this?

---

## Niche Agents

### SEMANTIC_CONSISTENCY_AUDIT
- **Trigger**: `HAS_MULTI_CONTRACT` flag — ZenjiViewHelper.sol and Zenji.sol both compute fee accrual independently using the same formula
- **Recommended**: YES (1 slot)
- **Focus**: Verify that `ZenjiViewHelper.getTotalCollateralValue` fee calculation exactly matches `Zenji._accrueYieldFees` formula; check for drift in truncation/rounding between the two.

---

## Summary

| Template | Type | Required |
|---|---|---|
| ORACLE_ANALYSIS | Standard skill | YES |
| TOKEN_FLOW_TRACING | Standard skill | YES |
| FLASH_LOAN_INTERACTION | Standard skill | YES |
| SEMI_TRUSTED_ROLES | Standard skill | YES |
| TEMPORAL_PARAMETER_STALENESS | Standard skill | YES |
| ECONOMIC_DESIGN_AUDIT | Standard skill | YES |
| EXTERNAL_PRECONDITION_AUDIT | Standard skill | YES |
| ZERO_STATE_RETURN | Standard skill | YES |
| VAULT_ACCOUNTING | Injectable | YES |
| LENDING_PROTOCOL_SECURITY | Injectable | YES |
| DEX_INTEGRATION_SECURITY | Injectable | YES |
| SEMANTIC_CONSISTENCY_AUDIT | Niche agent | RECOMMENDED |
