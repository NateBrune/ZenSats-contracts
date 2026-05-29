# Phase 2: Attack Chain Analysis

**Date**: 2026-04-28
**Scope**: Combined vulnerability chains from Phase 1 findings (M1–M14, L01–L26)
**Focus**: Multi-step exploitation scenarios where individual findings compound into higher-severity outcomes

---

## AC-1: VP Cache Manipulation → Socialized Withdrawal Loss

**Severity**: MEDIUM → HIGH (combined)
**Components**: M4 (VP cache staleness) + Curve LP pool manipulation + `remove_liquidity_one_coin`
**Contracts**: `BasePmUsdCrvUsdStrategy.sol` → `_removeLiquidity()`, `_getSafeVirtualPrice()`

### Prerequisites
- Keeper has not updated `cachedVirtualPrice` recently (stale cache)
- pmUSD/crvUSD pool has meaningful liquidity depth for manipulation
- Strategy holds significant LP position in the reward vault

### Attack Steps

1. **Attacker prepares**: Acquires large pmUSD or crvUSD off-chain (or flash loans)
2. **Attacker manipulates pool**: Adds massive one-sided liquidity to pmUSD/crvUSD pool (e.g., 10M pmUSD with minimal crvUSD), inflating the pool's `get_virtual_price()`
3. **VP spike is clamped**: `_getSafeVirtualPrice()` sees the spike but clamps to `cachedVirtualPrice ± 0.5%`. The clamped value becomes the *oracle floor* (minimum output), not the actual price
4. **Attacker withdraws LP from pool**: Removes their manipulated pmUSD, causing VP to drop back. This is a standard Curve LP exit — the attacker absorbs some loss
5. **Legitimate user withdraws**: 
   - `withdraw()` → `_withdraw()` → `_removeLiquidity(lpReceived, slippage)`
   - `remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut)` returns the **actual pool output** at current (post-manipulation) prices
   - The oracle floor `minOut` is based on the stale cached VP ± 0.5%, which is now **lower** than the inflated pool state
   - Wait — the oracle floor is a *minimum*, not a price. The pool returns the actual proportional share, which reflects post-manipulation prices
   - **Key insight**: If the attacker's LP addition temporarily inflated the pool value, the strategy's LP tokens are worth MORE crvUSD than before. The withdrawer gets more than fair value
   - The remaining LP token holders (and thus remaining vault shareholders) absorb the dilution

### Impact Analysis

- **Maximum loss**: Bounded by ±0.5% from the cached VP. The attacker must inject enough capital to move the pool within the 0.5% window
- **Attacker cost**: Must hold pmUSD/crvUSD at inflated ratio — if pmUSD is cheap relative to crvUSD, the attacker profits from the spread
- **Socialization**: The withdrawer gets a slight premium; remaining shareholders bear the dilution on their next interaction

### Mitigation
- Call `updateCachedVirtualPrice()` immediately before `_removeLiquidity()` (adds gas but eliminates staleness window)
- Or use a TWAP-based VP oracle instead of instantaneous `get_virtual_price()`

### Verdict: **Real but bounded** — the 0.5% clamp limits blast radius, but the socialization mechanism (withdrawer wins, remaining shareholders lose) is real

---

## AC-2: Flash Loan → LlamaLend Band Shift → Keeper LTV Blindness

**Severity**: LOW (combined)
**Components**: M1 (Llama partial unwind no health check) + L03 (keeper LTV band) + LlamaLend band model
**Contracts**: `LlamaLoanManager.sol`, `Zenji.sol` → `rebalance()`

### Prerequisites
- LlamaLend band-based pricing model (discrete price bands, not continuous AMM)
- Keeper is not running on every block

### Attack Steps

1. **Attacker flashes debt asset**: Takes flash loan of crvUSD (or strategy debt token)
2. **Attacker creates LlamaLend loan**: Deposits the flash loan as collateral and borrows in the same market as the vault's position
3. **Band shift**: The new large loan pushes the LlamaLend price band, changing the effective LTV for ALL positions in that market
4. **Vault's LTV drifts**: The vault's `getCurrentLTV()` now reflects the new band-based collateral value
5. **Keeper doesn't catch it**: If the keeper's LTV check is between bands, the 3% deadband may not trigger a rebalance
6. **Attacker repays flash loan**: Cleans up their position, but the band may remain shifted due to other market activity
7. **Partial unwind fails**: When the vault eventually tries to partially unwind (via a user withdraw), `remove_collateral()` reverts because the position is underwater at the new band price (M1 — no health check before `remove_collateral`)

### Impact Analysis

- **Temporary**: Band shifts revert when other borrowers adjust
- **Unwind blockage**: Partial unwinds revert, forcing full close via flashloan (more expensive)
- **No direct fund loss**: The vault's position is just harder to manage, not exploitable for extraction

### Mitigation
- Add health factor pre-check before `remove_collateral()` in partial unwind path (fixes M1)
- Lower the deadband for LlamaLend-based vaults to catch band shifts faster

### Verdict: **Real but nuisance-level** — causes operational friction, not fund loss

---

## AC-3: Stale Oracle → balanceOf Revert → Withdrawal Freeze

**Severity**: MEDIUM (combined)
**PoC**: `Audit/POC/AC3_StaleOracle_WithdrawFreeze.fork.t.sol` (4 tests, all PASS)
**Components**: M6 (balanceOf reverts on stale oracle, USDT variant only) + M2 (stuck crvUSD) + Zenji withdraw path
**Contracts**: `UsdtPmUsdCrvUsdStrategy.sol` → `balanceOf()`, `Zenji.sol` → `_accrueYieldFees()`, `_unwindPosition()`

### Prerequisites
- Chainlink crvUSD/USD or USDT/USD oracle goes stale (heartbeat miss, aggregator failure)
- Affects USDT variant only (crvUSD variant's `_convertCrvUsdValueToDebt` is 1:1 pass-through)

### Attack Steps

1. **Oracle goes stale**: Chainlink aggregator stops updating (e.g., USDT/USD heartbeat miss after 25 hours)
2. **`balanceOf()` reverts**: 
   - `_convertCrvUsdValueToDebt()` → `CurveUsdtSwapLib.convertCrvUsdToUsdt()` → `StaleOrInvalidOracle()`
   - This is called by `_accrueYieldFees()` (via `yieldStrategy.balanceOf()`)
3. **`_accrueYieldFees()` reverts**: Called by `_unwindPosition()` step 1, and by every deposit/withdraw/rebalance
4. **Withdrawals freeze**: 
   - Standard `withdraw()` → `_redeem()` → `_redeemStandard()` → `_accrueYieldFees()` → **reverts**
   - Users cannot withdraw through normal path
5. **Deposits freeze**: Same `_accrueYieldFees()` call in `_deposit()`
6. **Rebalance freezes**: `rebalance()` → `yieldStrategy.balanceOf()` via fee processing → **reverts**

### Impact Analysis (Verified by PoC)

- **Total withdrawal freeze**: No user can deposit, withdraw, or rebalance ✅ verified
- **Guardian can enter emergency mode**: `enterEmergencyMode()` works (no balanceOf call)
- **But `emergencyStep(0)` is MASKED, not fixed**: The `try/catch` in `executeEmergencyStep()` catches the `StaleOrInvalidOracle()` error from `withdrawAll()`, but BOTH `withdrawAll()` and `emergencyWithdraw()` fail silently — yield is NOT recovered
- **`emergencySkipStep(0)` succeeds**: Does NOT call `balanceOf()`, but step 1 (unwind loan) would fail at `_swapRemainingDebtToCollateral()` because the oracle is stale
- **Net result**: Guardian can enter emergency mode but cannot recover funds. Vault is permanently frozen until oracle is restored or code is patched.

### Mitigation
- **Fix M6**: Add fallback in `_convertCrvUsdValueToDebt()` for stale oracles (use last known price or crvSwapper.quote())
- **Emergency bypass**: Add a guardian-only `emergencyWithdrawYield()` that skips `balanceOf()` entirely
- **Reduce staleness window**: Lower `MAX_ORACLE_STALENESS` to 2 hours instead of 25 hours

### Verdict: **Real and impactful** — causes a full withdrawal freeze until oracle recovers or guardian intervenes. Not a fund-loss vector but a significant DoS.

---

## AC-4: Multi-Hop Slippage Accumulation → Partial Unwind Repricing → Socialized Loss

**Severity**: LOW (combined)
**Components**: M10 (slippage floor), M11 (CbBTC multi-hop ~2× slippage), M12 (safeGetDyThree return 0), L08 (UniversalRouter no slippage on quote)
**Contracts**: `CbBtcWbtcUsdtSwapper.sol`, `Zenji.sol` → `_redeemStandard()` repricing

### Prerequisites
- cbBTC vault with `CbBtcWbtcUsdtSwapper` (multi-hop: cbBTC → wbtc → USDT)
- High volatility period (slippage hits configured limits)
- Partial withdrawal (not final, so repricing logic applies)

### Attack Steps

1. **Market moves against vault**: Collateral price drops sharply
2. **User withdraws**: Triggers `_redeemStandard()` → `_unwindPosition()` → `loanManager.unwindPosition()`
3. **Swapper executes multi-hop**: Each hop has 1% slippage tolerance → effective ~2% total
4. **`_swapRemainingDebtToCollateral()`**: The effective slippage floor is `max(swapperSlippage, slippageOverride * 2)`. With multi-hop, the actual slippage can exceed the floor
5. **Partial unwind repricing**: 
   - `postUnwindTotal = getTotalCollateral()` (reflects realized value after swap losses)
   - `realizedCollateral = (actualShareAmount * (postUnwindTotal + VSO)) / virtualSupply`
   - If `realizedCollateral < collateralAmount` (oracle-priced), withdrawer gets less
   - **The withdrawer absorbs the slippage, not remaining shareholders** (by design)
6. **But**: If the slippage exceeds the effective floor AND the repricing formula has rounding issues, the withdrawer could get LESS than `minAcceptable`, triggering `InsufficientCollateral()` revert
7. **Attacker advantage**: MEV bot sandwiches the user's withdraw → swapper hops execute at worst prices → user's withdraw reverts or gets minimal output

### Impact Analysis

- **User-level**: Individual withdrawer absorbs slippage (as intended by repricing)
- **Vault-level**: No socialization — repricing protects remaining shareholders
- **MEV potential**: Sandwich attack on the multi-hop swap can extract ~1-2% from the withdrawer

### Mitigation
- Use `slippageOverride` parameter in user-supplied `minAssetsOut` to set realistic expectations
- Consider single-hop swappers where possible (less slippage accumulation)
- Add per-hop slippage tracking in multi-hop swappers

### Verdict: **Low severity** — repricing correctly socializes slippage onto the withdrawer, but MEV can still extract value

---

## AC-5: Cost Basis Over-Reduction → Fee Calculation Distortion

**Severity**: LOW (combined)
**Components**: M7 (cost basis over-reduction) + M4 (VP cache staleness) + `_accrueYieldFees()`
**Contracts**: `BaseYieldStrategy.sol` → `withdraw()`, `Zenji.sol` → `_accrueYieldFees()`

### Prerequisites
- VP drops significantly (pool losses, or oracle reports lower value)
- Large partial withdrawal occurs at the same time

### Attack Steps

1. **VP drops**: Pool loses value (e.g., Curve exploit, depeg event) — `balanceOf()` reports lower value
2. **User withdraws**: `BaseYieldStrategy.withdraw()` → 
   - `currentValue = this.balanceOf()` (underreported due to VP drop)
   - `basisReduction = (_costBasis * amount) / currentValue` — **this is too large** since `currentValue` is lower
   - `_costBasis -= basisReduction` — cost basis drops more than it should
3. **Fee calculation**: `_accrueYieldFees()` uses `yieldStrategy.balanceOf()` for current balance vs. `lastStrategyBalance`. Cost basis is NOT directly used for fee calculation (fees use the balance delta), but `unrealizedProfit()` is distorted
4. **Subsequent deposits**: New deposits add to the reduced cost basis. Fee accrual on future gains is calculated correctly (uses `lastStrategyBalance` delta), but the cost basis metric is wrong for reporting

### Impact Analysis

- **Cosmetic**: `unrealizedProfit()` shows negative while assets still exist — dashboard/reporting confusion
- **Fee calculation**: NOT affected (uses `lastStrategyBalance` checkpoint, not cost basis)
- **No fund loss**: The actual tokens in the pool are unaffected

### Mitigation
- Use `balanceOf()` value for cost basis reduction instead of proportional share
- Or accept as cosmetic-only and document in monitoring dashboards

### Verdict: **Cosmetic only** — cost basis is a reporting metric, not used for fee calculation or fund management

---

## AC-6: Aave Swapper Reentrancy (Future Swapper Attack)

**Severity**: MEDIUM (combined)
**Components**: M14 (Aave executeOperation swapper reentrancy) + L10 (BaseSwapper governance transfer via vault)
**Contracts**: `AaveLoanManager.sol` → `executeOperation()`, `Zenji.sol` → swapper governance

### Prerequisites
- A new swapper is deployed that includes re-entrant calls (e.g., a DeFi aggregator swapper)
- Gov proposes and executes the new swapper (1-week timelock)

### Attack Steps

1. **Malicious swapper deployed**: Implements `ISwapper` but `swapCollateralForDebt()` calls back into the vault
2. **Gov swaps swapper**: `proposeSwapper()` → 1 week → `executeSwapper()` (guardian can veto)
3. **Flash loan callback**: 
   - `executeOperation()` → `swapper.swapCollateralForDebt()` → **re-enters vault** → `vault.deposit()` → `loanManager.createLoan()`
4. **State corruption**: 
   - During flashloan, `variableDebtToken.balanceOf(address(this))` includes the flashloan debt
   - `createLoan()` calls `aavePool.supply()` (adds more collateral) and `aavePool.borrow()` (adds more debt)
   - The flashloan repayment calculation is now wrong — debt is higher than expected
5. **Flashloan underpayment**: The `repaymentNeeded = amount + premium` is based on the original flashloan, but additional debt from re-entry means the balance check `debtToken.balanceOf(address(this)) < repaymentNeeded` passes incorrectly

### Impact Analysis

- **Flashloan underpayment**: If the re-entrant borrow provides enough debt tokens, the flashloan might be underpaid
- **Guardian veto**: The 1-week timelock + guardian veto on swapper changes gives a defense window
- **Current swappers**: All current implementations (Curve, Uniswap V3) are non-re-entrant

### Mitification
- Add `ReEntrancyGuard` to `executeOperation()` (simple and effective)
- Or document that swappers must not re-enter the vault

### Verdict: **Real but requires swapper change** — only exploitable if a re-entrant swapper is deployed. Guardian veto + timelock provides defense.

---

## AC-7: USDT safeApprove Failure → Strategy Lockup

**Severity**: LOW (combined)
**Components**: M9 (SafeTransferLib USDT zero-reset gap) + M2 (stuck crvUSD on swap failure)
**Contracts**: `SafeTransferLib.sol` → `ensureApproval()`, `UsdtPmUsdCrvUsdStrategy.sol`

### Prerequisites
- USDT contract version that doesn't support zero-to-zero approval updates (older versions)
- Approval is already at the needed amount (no change needed)

### Attack Steps

1. **Strategy needs approval**: `_ensureApprove(address(debtAsset), address(pool), amount)` — debtAsset is USDT
2. **Current approval is sufficient**: `IERC20(token).allowance(address(this), spender) >= amount`
3. **Zero-reset attempt**: `ensureApproval()` tries to set approval to 0 first (to avoid `increaseAllowance` issues)
4. **USDT reverts**: On some USDT versions, `approve(0)` when current is 0 reverts
5. **All subsequent operations fail**: 
   - `_beforeDeposit()` → `_ensureApprove()` → **reverts**
   - `_addLiquidity()` → `_ensureApprove()` → **reverts**
   - `_removeLiquidity()` → `_ensureApprove()` → **reverts**
   - Strategy is effectively bricked

### Impact Analysis

- **Operational freeze**: Strategy can't deposit, withdraw, or manage LP
- **Not permanent**: Fixable by calling `safeApprove()` with a non-zero amount first
- **Recovery**: Guardian can `emergencySkipStep(0)` to bypass the strategy

### Mitigation
- **Fix M9**: Add try/catch around the zero-reset in `ensureApproval()`
- Or skip zero-reset when current approval is already sufficient

### Verdict: **Operational nuisance** — causes a freeze but is recoverable. Not a fund-loss vector.

---

## AC-8: Emergency Skip Window → Guardian Misuse

**Severity**: LOW (combined)
**Components**: L02 (emergency skip fee tracking + exchange rate drift) + `cancelEmergencySkip` (gov veto)
**Contracts**: `Zenji.sol` → `emergencySkipStep()`, `cancelEmergencySkip()`

### Prerequisites
- Guardian is compromised or acts maliciously
- Emergency mode is active

### Attack Steps

1. **Guardian enters emergency mode**: `enterEmergencyMode()` — blocks deposits
2. **Guardian skips step 0** (yield withdraw): `emergencySkipStep(0)` — proposes with 3-day delay
3. **During the 3-day window**:
   - Gov can `cancelEmergencySkip(0)` to veto
   - Normal `emergencyStep(0)` can still be executed (skip is optional, not mandatory)
4. **After 3 days**: Guardian executes the skip — `emergencyStepsCompleted |= 0x1`
5. **Guardian skips step 1** (loan unwind): Same 3-day process
6. **Step 2 (complete liquidation)**: Both bits set → `liquidationComplete = true`
7. **Users can only redeem vault collateral**: Strategy assets and loan position remain untouched
8. **Guardian recovers**: `rescueAssets()` or `emergencyRescue(2)` to collect strategy assets

### Impact Analysis

- **User loss**: Users redeem only direct vault collateral; yield strategy profits are captured by guardian
- **Governance defense**: Gov has 3-day veto window on each skip
- **Magnitude**: Bounded by strategy yield profits (not principal)

### Mitigation
- **Already robust**: 3-day delay + gov veto + guardian-only (limited power)
- **Monitor**: On-chain alert for `EmergencyModeEntered` events

### Verdict: **Real but bounded** — compromised guardian can capture yield profits, but 3-day veto window gives gov a chance to intervene. Principal is protected.

---

## AC-9: DELEGATECALL Attack (Implementation Swap)

**Severity**: LOW (combined)
**Components**: L04 (DELEGATECALL return data handling) + L09 (implementation MIN_DEPOSIT mismatch)
**Contracts**: `Zenji.sol` (proxy), implementation contracts

### Prerequisites
- Vault uses a proxy pattern (EIP-1967 or similar) with DELEGATECALL
- New implementation has different storage layout

### Attack Steps

1. **Gov proposes new implementation**: Via proxy admin
2. **New implementation has different storage**: Missing or reordered storage slots
3. **DELEGATECALL executes**: Reads/writes wrong storage slots
4. **State corruption**: `vault`, `loanManager`, `yieldStrategy` pointers corrupted
5. **Attacker exploits**: Sends transactions that write to corrupted slots (e.g., sets `gov` to attacker address)

### Impact Analysis

- **Requires gov compromise**: Gov controls the proxy admin
- **Storage layout**: Current implementation is well-structured with clear ordering
- **Recovery**: Roll back to previous implementation (if proxy admin supports it)

### Mitigation
- **Already robust**: Implementation contracts use `virtual` functions, not storage changes
- **Verify**: Run storage layout diff before any implementation swap

### Verdict: **Low risk** — standard proxy risk, mitigated by governance controls

---

## AC-10: Harvest Timing + Double-Count CRV → Reward Theft

**Severity**: LOW (combined)
**Components**: M5 (_claimAndCompound double-count risk) + M2 (stuck crvUSD)
**Contracts**: `BasePmUsdCrvUsdStrategy.sol` → `_claimAndCompound()`

### Prerequisites
- CRV rewards accumulate in the accountant for the strategy
- `_swapCrv()` fails (crvSwapper oracle floor) → CRV stays at swapper
- Next `_claimAndCompound()` cycle

### Attack Steps

1. **CRV accumulates**: Strategy earns CRV from Stake DAO accountant
2. **First `_claimAndCompound()`**: 
   - `_accountantClaim()` claims CRV
   - `_swapCrv(amount)` sends CRV to swapper
   - Swapper fails → CRV stuck at swapper address (emits `CrvSwapDeferred`)
3. **Next `_claimAndCompound()`**:
   - `_accountantClaim()` claims new CRV (but previous CRV is still at swapper)
   - `crv.balanceOf(address(this))` reads 0 for the stuck CRV
   - New CRV is swapped successfully
4. **Stuck CRV is recoverable**: `rescueERC20()` can recover from swapper address (since swapper is controlled by the strategy owner)

### Impact Analysis

- **Temporary**: CRV is stuck at the swapper, not lost
- **No double-count**: The stuck CRV is simply not re-claimed; only new CRV is processed
- **Recovery**: Owner can call `rescueERC20()` on the strategy

### Verdict: **Cosmetic** — CRV is temporarily stuck but recoverable. No double-counting of rewards.

---

## Summary: Attack Chain Severity Matrix

| # | Attack Chain | Combined Severity | Fund Loss? | DoS? | Exploit Complexity |
|---|-------------|-------------------|------------|------|-------------------|
| AC-1 | VP Cache Manipulation | MEDIUM→HIGH | Bounded (±0.5%) | No | Medium (requires capital) |
| AC-2 | Flash Loan → Band Shift | LOW | No | Partial | Medium |
| AC-3 | Stale Oracle → Withdraw Freeze | MEDIUM | No | **Yes** ✅ | Low (oracle failure) |
| AC-4 | Multi-Hop Slippage + MEV | LOW | Bounded (1-2%) | No | Low (MEV bot) |
| AC-5 | Cost Basis Over-Reduction | LOW | No | No | N/A (cosmetic) |
| AC-6 | Swapper Reentrancy (Future) | MEDIUM | Possible | No | Medium (requires new swapper) |
| AC-7 | USDT Approval Lockup | LOW | No | Yes (strategy only) | Low |
| AC-8 | Emergency Skip Misuse | LOW | Bounded (yield only) | No | Medium (requires guardian) |
| AC-9 | DELEGATECALL Attack | LOW | Possible | No | Medium (requires gov) |
| AC-10 | Harvest Double-Count | LOW | No | No | N/A (cosmetic) |

---

## Top 3 Actionable Attack Chain Fixes

### 1. Fix AC-3 (Stale Oracle → Withdraw Freeze) — **HIGHEST PRIORITY**
- **Change**: Add fallback in `_convertCrvUsdValueToDebt()` for stale oracles
- **File**: `UsdtPmUsdCrvUsdStrategy.sol` / `CurveUsdtSwapLib.sol`
- **Impact**: Eliminates full withdrawal freeze during oracle outages
- **Effort**: Low (add try/catch with stale-price fallback)

### 2. Fix AC-1 (VP Cache Manipulation) — **HIGH PRIORITY**
- **Change**: Call `_updateCachedVirtualPrice()` before `_removeLiquidity()` in `_withdraw()`
- **File**: `BasePmUsdCrvUsdStrategy.sol`
- **Impact**: Eliminates staleness window for LP removal pricing
- **Effort**: Low (one additional line before the liquidity removal)

### 3. Fix AC-6 (Swapper Reentrancy) — **MEDIUM PRIORITY**
- **Change**: Add reentrancy guard to `AaveLoanManager.executeOperation()`
- **File**: `AaveLoanManager.sol`
- **Impact**: Prevents state corruption from re-entrant swapper callbacks
- **Effort**: Low (add `_status` check pattern)

---

## Ready for Phase 3: PoC Fork Tests

Based on the attack chain analysis, the following PoCs are recommended:

1. **test/AC1_VP_cache_manipulation.fork.t.sol** — Verify ±0.5% bound limits socialized loss
2. **test/AC3_StaleOracle_WithdrawFreeze.fork.t.sol** — Reproduce USDT variant withdrawal freeze
3. **test/AC4_multi_hop_slippage_MEV.fork.t.sol** — Measure effective slippage on CbBTC swapper
4. **test/AC6_swapper_reentrancy.fork.t.sol** — Simulate re-entrant swapper in flashloan callback
