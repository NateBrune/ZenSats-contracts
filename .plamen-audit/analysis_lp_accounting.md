# Breadth Agent #1: LP Strategy Accounting & State Correctness
# Scope: CrvUsdLpStakeDaoStrategy + BaseCurveStakeDaoStrategy + BaseLPStrategy + BaseYieldStrategy
# Finding IDs: [LP-1] through [LP-7]

---

## Finding [LP-1]: VP Staleness Bypass Opens Same-Block Anchor Manipulation Window

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5 | ✗6(depressed anchor not feasible for monotonic StableSwap VP) | ✓7
**Rules Applied**: [R4:✓, R5:✗(N/A), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✓, R13:✗, R14:✗, R15:✓, R16:✓]
**Severity**: Low
**Location**: src/strategies/lp/BaseLPStrategy.sol:130-142 (_getSafeUnitValue), src/strategies/lp/BaseLPStrategy.sol:111-113 (updateCachedVirtualPrice)

**Description**:
_getSafeUnitValue() bypasses the clamping mechanism when block.timestamp - lastVpUpdate > MAX_VP_STALENESS (1 day), returning the raw unclamped live pool get_virtual_price(). The permissionless updateCachedVirtualPrice() (callable by anyone) then writes this unclamped value into cachedVirtualPrice. An attacker who (a) waits until the cache is stale, (b) flash-manipulates get_virtual_price() upward in the same tx, and (c) calls updateCachedVirtualPrice() before repaying the flash loan can set an elevated anchor permanently. After the flash loan repays, the pool VP returns to normal but cachedVirtualPrice is now anchored high — the +/-0.5%/day clamp re-engages from this elevated baseline.

**Impact**:
Primarily mitigated by BaseCurveStakeDaoStrategy.balanceOf() which computes min(vpBased, exitBased) where exitBased = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex) is a live unmanipulated spot value post-flash-loan. If vpBased is inflated, the min picks the real exit value. Residual damage: over subsequent days, _getSafeUnitValue() clamps at lowerBound = anchor - 0.5% which may still exceed the true VP, causing balanceOf() to overstate by up to 0.5% per day. This inflates lastStrategyBalance, suppresses rebalance triggers, and may generate phantom fee accruals. A depressed anchor via flash loan is NOT feasible for Curve StableSwap because get_virtual_price() is monotonically non-decreasing.

**Evidence**:
```solidity
// BaseLPStrategy.sol:130-142
function _getSafeUnitValue() internal view returns (uint256) {
    uint256 cached = cachedVirtualPrice;
    uint256 current = _lpUnitValue();
    if (cached == 0) return current;
    if (block.timestamp - lastVpUpdate > MAX_VP_STALENESS) return current; // unclamped bypass
    uint256 maxDeviation = (cached * MAX_VP_DEVIATION) / PRECISION;
    ...
}
// updateCachedVirtualPrice() is permissionless:
function updateCachedVirtualPrice() external override { _updateCachedUnitValue(); }
```

### Precondition Analysis
**Missing Precondition**: Strategy must be idle for >1 day (no deposits, withdrawals, harvests, rebalances — all of which call _updateCachedUnitValue and reset the staleness clock). Also requires meaningful VP manipulation of a Curve StableSwap pool.
**Precondition Type**: STATE (staleness) + EXTERNAL (pool manipulability)
**Why This Blocks**: Under normal operation with daily activity, the staleness condition never triggers. Flash-loan VP manipulation of Curve StableSwap is bounded by fee impact and D-invariant; attainable manipulation magnitude is small (~0.1% or less).

### Postcondition Analysis
**Postconditions Created**: Elevated cachedVirtualPrice anchor; _getSafeUnitValue() returns up to 0.5%/day above true VP without clamp correction.
**Postcondition Types**: STATE
**Who Benefits**: Attacker could inflate reported balanceOf() to suppress rebalance detection, but min(vpBased, exitBased) limits the actual inflation.

---

## Finding [LP-2]: Dual balanceOf() VP Divergence Causes _costBasis Skew on VP Update During Withdraw

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6,7
**Rules Applied**: [R4:✓, R5:✗(N/A), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✓]
**Severity**: Low
**Location**: src/strategies/BaseYieldStrategy.sol:182-188 (withdraw), src/strategies/lp/BaseLPStrategy.sol:165-177 (_withdraw)

**Description**:
BaseYieldStrategy.withdraw() at L182 calls balanceOf() for currentValue used in the basisReduction formula. Then _withdraw(amount) is called which, inside BaseLPStrategy._withdraw() at L166, immediately calls _updateCachedUnitValue() before computing its own currentValue at L170. If _updateCachedUnitValue() changes cachedVirtualPrice (e.g., VP was previously clamped at ±0.5% and now advances), the two balanceOf() calls return different values. The basisReduction uses the PRE-update value while sharesToRedeem uses the POST-update value.

Result: _costBasis is reduced by a fraction computed from the stale pre-update value (slightly more or less reduction than the true share of value withdrawn). Over many VP-ratchet-coincident withdrawals this creates a systematic drift — if VP is consistently rising, basisReduction is repeatedly slightly over-large, causing _costBasis to decay faster than the true principal basis. This inflates unrealizedProfit() and causes slight over-accrual of fees.

**Impact**:
- Precision drift in _costBasis of up to MAX_VP_DEVIATION (0.5%) per withdrawal that coincides with a VP ratchet step.
- Fees are slightly over-accrued over time. Users receive correct asset amounts; the distortion is accounting-level only.
- Not directly exploitable by a third party. The effect is self-correcting if VP stabilizes.

**Evidence**:
```solidity
// BaseYieldStrategy.sol:182-188
uint256 currentValue = balanceOf();                              // Call 1: uses current cachedVP
uint256 basisReduction = (_costBasis * amount) / currentValue;  // uses pre-update value
received = _withdraw(amount);                                    // enters BaseLPStrategy._withdraw

// BaseLPStrategy.sol:166-177
function _withdraw(uint256 debtAmount) {
    _updateCachedUnitValue();                          // may change cachedVirtualPrice
    uint256 currentValue = balanceOf();                // Call 2: uses UPDATED cachedVP (may differ)
    uint256 sharesToRedeem = (shares * debtAmount) / currentValue;  // post-update denominator
}
```

### Postcondition Analysis
**Postconditions Created**: _costBasis systematically over-/under-reduced relative to true proportional cost.
**Postcondition Types**: STATE
**Who Benefits**: Protocol fee recipient may over-collect fees over time (if VP trends upward).

---

## Finding [LP-3]: Pre-Compound sharesToRedeem Snapshot Causes Under-Delivery Relative to Requested debtAmount

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4 | ✗5(by design per code comment) | ✓6,7
**Rules Applied**: [R4:✗(consistent behavior), R5:✗(N/A), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✓, R14:✗, R15:✗, R16:✗]
**Severity**: Low
**Location**: src/strategies/lp/BaseLPStrategy.sol:165-187 (_withdraw)

**Description**:
_withdraw() computes sharesToRedeem = (shares * debtAmount) / currentValue where shares is snaphotted from stakingVault.balanceOf(address(this)) BEFORE _compoundRewards(). The subsequent _compoundRewards() call claims CRV, swaps to crvUSD, and adds it to the pool via _addLiquidityAndStake(), increasing the total staked shares. After compounding, sharesToRedeem has been computed on a now-smaller proportion of the pool. The actual realized LP value from unstaking sharesToRedeem is: (sharesToRedeem / total_shares_post_compound) * total_pool_value_post_compound, which is LESS than debtAmount.

This means received < debtAmount even when pool slippage is zero. The code comment acknowledges this ("Snapshot share ratio BEFORE _compoundRewards inflates the pool, keeping it consistent with the basisReduction computed from the outer balanceOf() call"). However, the vault's slippage check in _withdrawFromYieldStrategy (floorBase calculation) consumes part of the effectiveSlippage budget for this compounding shortfall.

**Impact**:
- Under normal conditions: compounding rewards are small vs position, shortfall is negligible.
- Edge case: strategy unused for weeks, large CRV accumulation. On first withdrawal, _compoundRewards() compounds significant CRV. If compounded amount / total position > effectiveSlippage, the slippage check in _withdrawFromYieldStrategy reverts with InsufficientWithdrawal. User withdrawal is bricked until someone calls harvest separately to compound CRV first.
- R13: terminal user consequence — withdrawal reverts until a separate harvestYield() is called to clear accumulated CRV.

**Evidence**:
```solidity
// BaseLPStrategy.sol:172-180
uint256 shares = stakingVault.balanceOf(address(this));  // snapshotted BEFORE compound
uint256 sharesToRedeem = (shares * debtAmount) / currentValue;
// ...
_compoundRewards();  // adds newly claimed CRV as LP, increases total shares
// sharesToRedeem is now a smaller fraction of the larger total
uint256 lpReceived = _unstakeLp(sharesToRedeem);  // redeems the pre-compound snapshot
```

### Precondition Analysis
**Missing Precondition**: Large accumulated CRV position (no harvest/compound for weeks + significant CRV emission rate) making the compounding shortfall exceed effectiveSlippage.
**Precondition Type**: STATE (accumulated reward size)
**Why This Blocks**: Under normal operations with weekly harvests, the shortfall is <<1% and far within slippage tolerance.

---

## Finding [LP-4]: withdrawFees() Missing VP Update Before Fee Accrual — Inconsistent With rebalance()

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(low magnitude; bounded by VP deviation window)
**Rules Applied**: [R4:✓, R5:✗(N/A), R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✗, R13:✗, R14:✗, R15:✗, R16:✗]
**Severity**: Low
**Location**: src/Zenji.sol:867-874 (withdrawFees), src/Zenji.sol:609-616 (rebalance VP update comment)

**Description**:
Zenji.withdrawFees() calls _accrueYieldFees() then processWithdrawFees() without first calling yieldStrategy.updateCachedVirtualPrice(). By contrast, rebalance() explicitly calls yieldStrategy.updateCachedVirtualPrice() before _accrueYieldFees() with the comment: "Advance the strategy's cached virtual price before fee accrual so _accrueYieldFees() sees an up-to-date strategy balance. This prevents VP drift from causing phantom fee accrual during catch-up steps."

The same concern applies to withdrawFees(): if cachedVirtualPrice is stale-low, _accrueYieldFees() underestimates the current strategy balance, potentially missing accrued fees that should be charged before the withdrawal. The strategist thus withdraws fees based on an underestimated fee baseline.

**Impact**:
- Bounded by MAX_VP_DEVIATION (0.5%) since operations between fee withdrawals (deposit, withdraw, harvest, rebalance) each call _updateCachedUnitValue. Effect is only material if the ONLY call between fee accruals is withdrawFees itself.
- In theory: strategist could time withdrawFees when cachedVP is stale-high to withdraw more fees than earned; but this requires knowing/controlling the VP staleness pattern, which is low likelihood.
- No fund loss to depositors beyond the bounded 0.5% VP deviation.

**Evidence**:
```solidity
// Zenji.sol:867-874
function withdrawFees(address recipient) external nonReentrant onlyStrategist {
    _accrueYieldFees();  // NO VP update before this
    (accumulatedFees, lastStrategyBalance) =
        ZenjiCoreLib.processWithdrawFees(recipient, yieldStrategy, debtAsset, accumulatedFees);
    feesAtLastRebalance = accumulatedFees;
}

// Zenji.sol:609-616 (rebalance — correct pattern):
yieldStrategy.updateCachedVirtualPrice();  // advance VP first
_accrueYieldFees();                        // then accrue with fresh balance
```

---

## Finding [LP-5]: CRV Permanently Stranded at crvSwapper on Repeated Swap Failures

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6
**Rules Applied**: [R4:✓, R5:✗(N/A), R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✗, R13:✗, R14:✗, R15:✗, R16:✓]
**Severity**: Low
**Location**: src/strategies/lp/BaseCurveStakeDaoStrategy.sol:136-149 (_claimAndSwapRewards)

**Description**:
_claimAndSwapRewards() unconditionally transfers CRV from the strategy to address(crvSwapper) at L141, then calls try crvSwapper.swap(crvBalance). On swap revert (CRV oracle stale, slippage floor breach, pool liquidity), the CRV stays at the crvSwapper address — not at the strategy. The code comment says "CRV stays at swapper; retried next compound cycle." But the retry does NOT work: the next _claimAndSwapRewards() call checks crv.balanceOf(address(this)) at L138 — the strategy address. Since CRV is at the SWAPPER, not the strategy, the check returns 0 and the swap is never retried. The CRV accumulates at the swapper address indefinitely.

Recovery: CrvToCrvUsdSwapper.rescueToken(crv, gov, amount) is callable by gov, but rescued CRV goes to governance, NOT back into the strategy compound cycle.

**Impact**:
- CRV yield permanently lost from compounding if CRV oracle goes stale (>25h, common during oracle provider incidents) or CRV price drops cause slippage floor failures.
- pendingRewards() queries the Stake DAO accountant for pending gauge rewards — it does NOT reflect CRV already transferred to the swapper (off-chain monitoring blind spot).
- The emit CrvSwapDeferred(crvBalance) provides on-chain signal but misidentifies the problem as a deferral (implying future retry) when it's actually permanent.

**Evidence**:
```solidity
// BaseCurveStakeDaoStrategy.sol:136-149
uint256 crvBalance = crv.balanceOf(address(this));  // checks strategy — NOT swapper
if (crvBalance < MIN_HARVEST_THRESHOLD) return 0;

crv.safeTransfer(address(crvSwapper), crvBalance);   // CRV leaves strategy here
try crvSwapper.swap(crvBalance) returns (uint256 received) {
    lpAssetReceived = received;
} catch {
    // CRV is now at crvSwapper. Next cycle: crv.balanceOf(strategy) == 0 → NOT retried.
    emit CrvSwapDeferred(crvBalance);  // misleadingly implies deferred retry
}
```

### Postcondition Analysis
**Postconditions Created**: CRV balance at crvSwapper grows; strategy never retries the stuck amount; depositors lose compounding yield.
**Postcondition Types**: STATE (asset stranding at external address)
**Who Benefits**: No attacker benefit; pure yield leakage.

---

## Finding [LP-6]: _harvest() Event Value Understates Actual Yield When Residual lpAsset Exists

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✗, R5:✗(N/A), R6:✗, R8:✗(N/A), R10:✓, R11:✗, R12:✗, R13:✓, R14:✗, R15:✗, R16:✗]
**Severity**: Info
**Location**: src/strategies/lp/BaseLPStrategy.sol:207-211 (_harvest), src/strategies/lp/BaseLPStrategy.sol:217-221 (_compoundRewards)

**Description**:
_harvest() returns _convertYieldAssetValueToDebt(lpAssetCompounded) where lpAssetCompounded is the return value of _claimAndSwapRewards() — the crvUSD received from the CRV swap only. However, _compoundRewards() also calls _addLiquidityAndStake() which adds ALL residual lpAsset balance in the contract (including any donated crvUSD or dust from previous partial operations). The total value compounded exceeds lpAssetCompounded. The Harvested event and YieldHarvested event emit this understated value. On-chain fee accrual is correct (driven by _accrueYieldFees before and after harvest), so this is a monitoring/event accuracy issue only.

**Evidence**:
```solidity
// BaseLPStrategy.sol:207-211
function _harvest() internal virtual override returns (uint256 rewardsValue) {
    _updateCachedUnitValue();
    uint256 lpAssetCompounded = _compoundRewards();     // only CRV swap proceeds
    rewardsValue = _convertYieldAssetValueToDebt(lpAssetCompounded);
}
// _compoundRewards adds ALL lpAsset.balanceOf(address(this)) — CRV proceeds + any residuals
```

---

## Finding [LP-7]: _removeLiquidity Lacks Oracle Floor — Asymmetric Protection vs _addLiquidity

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✗, R5:✗(N/A), R6:✗, R8:✗(N/A), R10:✓, R11:✗, R12:✗, R13:✓, R14:✗, R15:✗, R16:✓]
**Severity**: Info
**Location**: src/strategies/lp/BaseCurveStakeDaoStrategy.sol:122-133 (_removeLiquidity), src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol:66-83 (_addLiquidity)

**Description**:
_addLiquidity() (CrvUsdLpStakeDaoStrategy.sol:77-80) applies two floors on the minimum LP out: a spot-based calc_token_amount floor AND an oracle-based floor using _getSafeUnitValue(). This dual protection prevents deposit exploitation via VP manipulation or pool imbalance.

_removeLiquidity() (BaseCurveStakeDaoStrategy.sol:122-133) applies only a spot-based calc_withdraw_one_coin floor (slippage %). No oracle-based floor is applied. Under pool imbalance (the exact scenario driving emergency/stressed exits), calc_withdraw_one_coin can be very low, and slippage% of a very low value provides minimal protection. The design is intentional (always allowing exit), but creates an asymmetry: deposits get oracle protection; withdrawals do not.

**Evidence**:
```solidity
// _addLiquidity: oracle floor applied (CrvUsdLpStakeDaoStrategy.sol:77-80)
uint256 safeVP = _getSafeUnitValue();
uint256 oracleMinLp = (crvUsdAmount * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
if (oracleMinLp > minLp) minLp = oracleMinLp;

// _removeLiquidity: no oracle floor (BaseCurveStakeDaoStrategy.sol:127-132)
uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);
uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;
// No oracle-based minOut; spot-based only
```

---

## Chain Summary

| Finding ID | Precondition Type | Postcondition Created | Chain Lead |
|---|---|---|---|
| LP-1 | STATE (staleness) + EXTERNAL | Elevated cachedVP anchor | Can chain with any finding requiring inflated balanceOf |
| LP-2 | STATE (VP ratchet during withdraw) | _costBasis drift | Chain with fee accrual findings |
| LP-3 | STATE (accumulated CRV) | received < debtAmount | Withdrawal revert under large CRV accumulation |
| LP-4 | STATE (VP staleness at withdrawFees time) | Underestimated fee accrual | Chain with strategist timing behavior |
| LP-5 | EXTERNAL (CRV oracle failure) | CRV stranded at swapper | Yield leakage |
| LP-6 | STATE (residual lpAsset) | Event underreports | Monitoring only |
| LP-7 | EXTERNAL (pool imbalance) | Spot-only minOut on exit | High-stress exit scenario |
