# Security Audit — Coverage Rebalance (arm 3) Collateral-Funded Repay

**Date**: 2026-08-21
**Scope**: uncommitted working-tree change to
`src/libraries/ZenjiCoreLib.sol::rebalanceCoverageUp` (rewritten, L233–336) and the single call site
`src/Zenji.sol::rebalance()` (L686–690) + NatSpec.
**Reference**: `COVERAGE_REBALANCE_FIX_PLAN.md` (Plan B).
**Build**: `forge build` clean.
**Method**: static read of every path reachable from the new code (both loan managers, all six
base swappers, both LP strategy bases, view helper, fee accrual). No tests executed.

---

## Verdict

The *convergence* logic is correct: funding the repay from collateral is the right fix, the
`D - S` conservation argument holds, and the algorithm matches the plan.

However, the change moves a collateral→debt swap **out from behind the loan managers' end-to-end
oracle floor** and gates it with a postcondition that is arithmetically almost vacuous. On the
LlamaLend deployments (WBTC and wstETH, which use `UniswapMixedCurveSwapper`) the swapper itself
carries **no** end-to-end oracle floor — it explicitly documents that the loan manager's 95% guard
is the hard floor. The result is a permissionless, sandwichable collateral sale.

**Do not ship as-is.** C-01 + C-02 together are a drain. Both are cheap to fix (≈6 lines).

| ID | Sev | Title |
|----|-----|-------|
| C-01 | Critical | Collateral→debt swap bypasses the loan manager's 95%-of-oracle end-to-end floor; `UniswapMixedCurveSwapper` runs the V3 hop with `amountOutMin = 0` |
| C-02 | Critical | `CoverageDidNotImprove` is satisfied by a ~10⁻¹³-unit repay — it cannot bound value loss |
| H-01 | High | `deficit` is derived from a spot-manipulable `calc_withdraw_one_coin`; an attacker can manufacture the out-of-band state that triggers the collateral sale |
| M-01 | Medium | `LlamaLoanManager.removeCollateral` has no vault-side `MIN_HEALTH` check (newly load-bearing — it had zero callers before this change) |
| M-02 | Medium | A deficit larger than health headroom makes arm 3 revert, reinstating the keeper deadlock the fix targets |
| M-03 | Medium | Double slippage buffer over-sizes the collateral removal by ~3.6% every call |
| M-04 | Medium | On the Curve-quote swappers, `quoteCollateralForDebt` is a spot pool quote, so `c` itself is inflatable |
| L-01 | Low | Surplus debt asset is idle-but-counted: no leak, but yield drag + a swap round trip |
| L-02 | Low | Postcondition re-reads a spot strategy balance → possible spurious revert / arm-3 liveness |

Cleared (checked, found sound): oracle-floor adequacy on the *Uniswap-family* swappers; `maxSlippage`
bounds; the `getCurrentCollateral()` cap; Aave's intermediate-health guard; surplus recoverability
and `totalAssets()` accounting; fee-accrual / `lastStrategyBalance` interaction; reentrancy;
withdrawal-path isolation; the dust floor. Details in §"Focus areas cleared".

---

## C-01 — Collateral→debt swap bypasses the loan managers' end-to-end oracle floor

**Severity**: Critical
**Location**: `src/libraries/ZenjiCoreLib.sol:315-316`
**Introduced by**: this change.

### What the code does

```solidity
// ZenjiCoreLib.sol:315-316
collateralAsset.safeTransfer(address(swapper), c);
uint256 received = swapper.swapCollateralForDebt(c);
```

This is the **first and only** call site in `src/` that invokes `ISwapper.swapCollateralForDebt`
directly from the vault. Every pre-existing collateral→debt swap in the protocol goes through a
loan-manager wrapper that enforces an end-to-end oracle floor:

```solidity
// src/lenders/LlamaLoanManager.sol:836-848
uint256 expectedDebt = (_getCollateralValue(collateralAmount) * MIN_SWAP_OUT_BPS) / 10000; // 9500
...
if (debtDelta < expectedDebt) revert SwapperUnderperformed(expectedDebt, debtDelta);
```

(the same guard exists at `src/lenders/AaveLoanManager.sol:479-492`, `MIN_SWAP_OUT_BPS = 9500`).

The new path skips it entirely and relies on the swapper's own floor. That floor is not uniform:

| Swapper | End-to-end floor on `swapCollateralForDebt` | Adequate? |
|---|---|---|
| `UniversalRouterV3SingleHopSwapper` (XAUT/Aave) | oracle-based `minOut` (`:81-99`) | yes |
| `UniswapV3TwoHopSwapper` | oracle-based `minOut` (`:80-95`) | yes |
| `UniswapMixedTwoHopSwapper` | oracle `minOut` enforced on the terminal V4 hop (`:173-190`) | yes |
| `CbBtcUniswapV3TwoHopSwapper` | oracle-based `minOut` (`:72-88`) | yes |
| `CurveThreeCryptoSwapper` | `max(pool get_dy, oracle) * (1 - slippage)` (`:78-88`) | yes |
| `CurveTwoCryptoSwapper` | pool `get_dy` floor + a **10%** `MAX_ORACLE_DEVIATION` sanity check (`:70-95`) | weak |
| **`UniswapMixedCurveSwapper`** | **none** | **no** |

### The broken one is in production use

`script/DeployWbtcLlamaUsdtStakeDao.s.sol:68-81` deploys `UniswapMixedCurveSwapper` with
**WBTC** as collateral; `script/DeployWstEthLlamaUsdtStakeDao.s.sol` does the same for wstETH.

`UniswapMixedCurveSwapper.swapCollateralForDebt` (`:118-192`):

* **Hop 1, collateral → WETH (Uniswap V3)**: `v3MinOut` is only set when the collateral token
  answers `stEthPerToken()` (`:129-140`). **WBTC does not**, so `v3MinOut = 0` — the hop executes
  with `amountOutMin = 0`.
* **Hop 2, WETH → crvUSD (Curve TriCRV)**: `minCrvUsd` is derived from `get_dy` read in the *same
  transaction* (`:167-177`), i.e. after the attacker's front-run has already moved the pool. It is
  sandwich-invariant and provides essentially no protection.

The contract says so itself, at `:164-170`:

> *"the hard end-to-end floor is the loan manager's `SwapperUnderperformed` check (95% of the
> oracle-implied value), which covers a sandwich on the amountOutMin=0 V3 hop."*

`CurveTwoCryptoSwapper:30-33` carries the identical caveat
(*"LlamaLoanManager enforces a tighter 95% output guard post-swap, which is the primary
manipulation barrier"*).

The new code removes that barrier from the path.

### Exploit

`rebalance()` is permissionless (`Zenji.sol:625`). Preconditions: `coverage < 97%` and LTV inside
its deadband (arms 1/2 have priority). That state is exactly the one this feature exists to
service, and H-01 shows it can also be manufactured.

WBTC/LlamaLend/crvUSD, using the plan's own fork numbers (§1): `D = 49,855 crvUSD`,
`S = 47,851 crvUSD`, coverage 9598 bps, collateral 1.0 WBTC, LTV 65%.

1. `deficit = 2,004 crvUSD`. `c = quote(deficit) × 1/(1 − maxSlippage) ≈ 0.0208 WBTC` (~$2,080).
2. Attacker, in one transaction: buy WBTC in the Uniswap V3 WBTC/WETH 0.05% pool to push the price
   far off, call `vault.rebalance()`, then sell back.
3. Arm 3 removes 0.0208 WBTC and pushes it through the swapper. Hop 1 has `amountOutMin = 0`; the
   attacker's front-run takes essentially all of it. Say the vault receives 1 crvUSD instead of
   ~2,000.
4. `toRepay = 1 crvUSD`. Postcondition (see C-02) passes trivially. `rebalance()` succeeds and the
   attacker is also paid the keeper bounty.
5. **Net**: ~$2,080 of vault collateral converted into ~$1 of debt repayment. ≈2% of NAV per call.

The loop is throttled only by the LTV deadband: each theft raises LTV (65% → 66.3% → 67.7%), so
after ~2 arm-3 calls LTV leaves the +3% band and arm 2 takes priority. Arm 2 is also permissionless
and restores LTV headroom by shrinking the position, after which arm 3 is reachable again. The
attacker alternates arms and bleeds collateral until `remove_collateral` finally hits LlamaLend's
health floor. `nonReentrant` does not help — the calls are sequential, not nested, so the whole
sequence fits in one attacker transaction.

### Fix

Re-impose an end-to-end floor at the new call site. `ILoanManager.getCollateralValue` (`:91`) is the
same oracle pricing the loan managers use for `MIN_SWAP_OUT_BPS`:

```solidity
uint256 expected = loanManager.getCollateralValue(c);
uint256 received = swapper.swapCollateralForDebt(c);
if (received < (expected * (precision - maxSlippage)) / precision) {
    revert SwapperUnderperformed(...);
}
```

Measure `received` as a balance delta rather than trusting the swapper's return value (this is what
both loan managers do). Alternatively, add an `ILoanManager` entry point that performs the
collateral→debt swap so the existing, already-audited 95% guard applies unchanged — that also fixes
`CurveTwoCryptoSwapper`'s weak 10% band for free.

---

## C-02 — The `CoverageDidNotImprove` postcondition is arithmetically vacuous

**Severity**: Critical (as the sole guard on a value-moving operation)
**Location**: `src/libraries/ZenjiCoreLib.sol:329-334`
**Introduced by**: this change.

The plan (§3.1 step 6, §5 rows 3/6/7/8) treats this postcondition as the safety property that makes
the bug class unrepresentable and that ensures the bounty is only paid "on a call that satisfies
step 6". It does bound *ratio regression*. It does **not** bound *value loss*, for two reasons.

**1. Coverage is a ratio whose denominator this function shrinks.** The numerator `S` is untouched
by arm 3. So `newCoverage > startCoverage` reduces to `newDebt < debt`, i.e. `toRepay ≥ 1` modulo
floor division. The collateral leg — the only place value can leave — is not in the expression at
all.

**2. The required repay is dust.** With `startCoverage = ⌊S·P/D⌋`, a one-unit increase needs

```
toRepay ≥ D² / (S·P)
```

For the numbers above (`D = 4.9855e22`, `S = 4.7851e22`, `P = 1e18`):

```
toRepay ≥ 2.4855e45 / 4.7851e40 ≈ 5.2e4 wei ≈ 0.000000000000052 crvUSD
```

So a swap that returns **5×10⁻¹⁴ crvUSD** out of a ~$2,000 collateral sale satisfies the
postcondition. Answering the plan's §9 question directly: *yes, the postcondition is trivially
satisfiable while value leaks*, and it is the mechanism that lets C-01 succeed rather than revert.

### Fix

Keep the monotonicity check (it is a good invariant), but add a value-conservation check. Either of
these is sufficient on its own; both is better:

* the oracle floor from C-01 (`received ≥ oracleValue(c) · (1 − maxSlippage)`), and/or
* require meaningful progress, e.g. `toRepay ≥ deficit · MIN_PROGRESS_BPS / 10_000` (say 50%), so a
  partially-filled swap reverts instead of burning collateral for a token improvement.

Note the interaction with §5 row 8 ("bounty only on a call that satisfies step 6"): as written, the
bounty is payable on a call that moved coverage by one wei-unit while losing 2% of NAV.

---

## H-01 — `deficit` is derived from a spot-manipulable strategy balance

**Severity**: High
**Location**: `src/libraries/ZenjiCoreLib.sol:294` (consumer);
`src/strategies/lp/BaseCurveStakeDaoStrategy.sol:110-120` (source)
**Nature**: pre-existing measurement weakness, **newly weaponised** by this change.

```solidity
// BaseCurveStakeDaoStrategy.sol:113-119
uint256 vpBased   = (lpTokens * _getSafeUnitValue()) / PRECISION;   // clamped ±0.5% to the VP cache
uint256 exitBased = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex); // RAW SPOT, unclamped
uint256 lpAssetValue = exitBased < vpBased ? exitBased : vpBased;
```

`_getSafeUnitValue()` is ratchet-clamped (`BaseLPStrategy.sol:146-158`, `MAX_VP_DEVIATION = 0.5%`),
but `calc_withdraw_one_coin` is a raw spot read of the LP pool and the `min()` means **any downward
manipulation of it flows straight into `balanceOf()`**. The strategy's own L-03 note reasons about
`get_virtual_price()` being un-manipulable in one transaction; that reasoning does not extend to the
`exitBased` leg.

Before this change, that only affected *which arm* ran, and arm 3 was a wash between `S` and `D`
(the conservation law in the plan §2 — it moved no equity). **Now a depressed `balanceOf()`
translates directly into collateral being sold.**

### Exploit

Single transaction, no reentrancy needed:

1. Flash-borrow crvUSD, swap it into the USDT/crvUSD (or pmUSD/crvUSD) pool to skew the balance so
   the single-sided crvUSD exit rate drops by N%.
2. `vault.rebalance()` — `strategyToDebtRatio()` (`Zenji.sol:894-899`) now reads below 97%,
   `ratioTooLow` is true, arm 3 runs, and `deficit` is **the attacker's chosen size** (bounded only
   by the health/collateral cap). The vault sells that much collateral.
3. Unwind the pool skew, repay the flash loan. Cost ≈ two-way pool fees on the imbalancing trade;
   revenue = the C-01 sandwich on the forced collateral sale, plus the bounty.

The postcondition does not help: `startCoverage` and `newCoverage` are both measured under the same
manipulated state, and the repay still shrinks `D`.

Even with C-01 fixed, this remains a griefing/bleed vector: the attacker can force the vault to pay
real swap costs (collateral → debt now, debt → collateral later on withdrawal) on demand.

### Fix (pick one)

* Clamp `exitBased` with the same ratchet used for `vpBased` (`_getSafeUnitValue`-style bounds), so
  a single-transaction pool skew cannot move the reported balance by more than `MAX_VP_DEVIATION`.
* Or require the out-of-band condition to persist: record `coverageBelowBandSince` and refuse arm 3
  until it has held for N blocks. This defeats same-transaction manufacture cleanly.
* Or gate arm 3 (not the whole `rebalance()`) behind the keeper/strategist role. Cheapest, but gives
  up permissionlessness for the arm that now spends equity.

---

## M-01 — `LlamaLoanManager.removeCollateral` has no vault-side `MIN_HEALTH` check

**Severity**: Medium
**Location**: `src/lenders/LlamaLoanManager.sol:277-282`
**Nature**: pre-existing gap, **newly reachable** — before this change `removeCollateral` had
**zero** callers in `src/` (verified by grep; the only call site is now `ZenjiCoreLib.sol:311`).

```solidity
function removeCollateral(uint256 amount) external onlyVault {
    if (amount == 0) revert ZeroAmount();
    _checkOracleFreshness();
    llamaLend.remove_collateral(amount);      // <- no health assertion afterwards
    emit CollateralRemoved(amount);
}
```

Compare the sibling functions in the same contract, which all enforce the vault's own buffer:
`createLoan` (`:237-238`), `borrowMore` (`:260-262`), and the unwind path (`:455`) all do
`if (this.getHealth() < MIN_HEALTH) revert HealthTooLow();` with `MIN_HEALTH = 1e17`. And the Aave
adapter does exactly this on the equivalent call (`AaveLoanManager.sol:244-247`, `MIN_HEALTH = 1.1e18`).

So on LlamaLend vaults, arm 3 is the *only* vault-initiated position change that can drive health
down to LlamaLend's bare internal floor (the soft-liquidation edge) with no 10% buffer. The plan's
§4.3 claim that "LlamaLend enforces health internally" is true but is enforcement at a materially
looser threshold than the protocol applies everywhere else.

Worst case is bounded by the arm ordering — LTV must be inside `targetLtv ± 3%` for arm 3 to run at
all, so the starting point is at most `targetLtv + 3%` (68% for WBTC/Llama). With a 25% strategy
loss, `c ≈ 0.25 × 0.68 = 17%` of collateral and the intermediate LTV is `68/83 ≈ 81.9%` — inside
LLAMMA's band range for the WBTC market, but with no margin left and no vault-side rejection.

**Fix**: mirror the Aave adapter — append the `MIN_HEALTH` assertion to
`LlamaLoanManager.removeCollateral`. Note this is a loan-manager change, which the plan (§6, §10)
claims Plan B avoids; it is nonetheless the right place for it.

---

## M-02 — A deficit larger than health headroom re-creates the keeper deadlock

**Severity**: Medium (liveness)
**Location**: `src/libraries/ZenjiCoreLib.sol:305-312`

`c` is capped only at `getCurrentCollateral()` — the **total** position collateral, not the amount
that can be removed while staying solvent:

```solidity
uint256 currentCollateral = loanManager.getCurrentCollateral();
if (c > currentCollateral) c = currentCollateral;
...
loanManager.removeCollateral(c);   // reverts if health is breached
```

If the deficit is large (real strategy insolvency, or an induced one per H-01), `removeCollateral`
reverts — Aave on `HealthTooLow` (`AaveLoanManager.sol:246`) or inside `aavePool.withdraw`, LlamaLend
inside `remove_collateral`. The revert propagates out of `rebalance()`.

That is the same operational state the fix exists to eliminate: `rebalance()` reverts on every cron
tick and the keeper is bricked until a strategist runs `setIdle(true)/setIdle(false)`. The NatSpec
now advertises single-call convergence and reserves idle/unidle for "a degenerate case (e.g. no
swapper configured)", which understates this.

This is the plan's §11 open question ("should arm 3 refuse to run when `deficit` exceeds some
fraction of debt") — it is not currently answered in code.

**Fix**: size `c` against the maximum safe removal rather than total collateral — e.g. derive the
collateral that leaves LTV at `targetLtv + DEADBAND_SPREAD` (or health at `MIN_HEALTH`), take
`min(c, thatBound)`, and let successive keeper ticks converge. With C-02's progress floor, a call
that cannot make meaningful progress still reverts loudly rather than bleeding — but the *common*
large-deficit case should partially converge instead of hard-reverting.

---

## M-03 — Double slippage buffer over-sizes every removal

**Severity**: Medium (value leak, ~3.6% of each swap's size, every call)
**Location**: `src/libraries/ZenjiCoreLib.sol:303-304`

```solidity
uint256 c = swapper.quoteCollateralForDebt(deficit);
c = (c * precision) / (precision - maxSlippage);
```

**All six** `ISwapper` implementations already apply a slippage buffer inside the quote. Identical
line in each (`UniversalRouterV3SingleHopSwapper:77`, `UniswapV3TwoHopSwapper:76`,
`UniswapMixedCurveSwapper:114`, `UniswapMixedTwoHopSwapper:168`, `CurveTwoCryptoSwapper:66`,
`CurveThreeCryptoSwapper:66`, `CbBtcUniswapV3TwoHopSwapper:69`):

```solidity
return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
```

The library then buffers the buffered quote. With `swapper.slippage = 1.5%` (`CurveThreeCryptoSwapper`
constructor default) and `maxSlippage = 2%`, `c` is `1/(0.985 × 0.98) ≈ 3.6%` larger than the
deficit requires. That excess collateral is sold, the proceeds above `deficit` are **not** repaid
(step 4 caps at `deficit`) and sit idle as debt asset until a withdrawal swaps them back to
collateral (`Zenji.sol:915-950`) — paying the round-trip swap cost on the over-amount, twice, on
every arm-3 call.

This is the plan's §11 open question ("should the slippage buffer on `c` be `maxSlippage` or the
swapper's own `slippage()`?"). The answer the code needs is *neither, again*: the quote already
contains it.

**Fix**: drop line 304, or explicitly document that the quote's buffer is being deliberately doubled
and size it as `max(quote, quote_unbuffered / (1 - maxSlippage))`.

---

## M-04 — `c` sizing uses a spot pool quote on the Curve swappers

**Severity**: Medium
**Location**: `src/libraries/ZenjiCoreLib.sol:303`;
`src/swappers/base/CurveTwoCryptoSwapper.sol:62-67`, `CurveThreeCryptoSwapper.sol:62-67`

The audit brief asks whether `quoteCollateralForDebt` is manipulable. For the four Uniswap-family
swappers it is oracle-derived (`OracleLib.getDebtValue`) — sound. For the two pure-Curve swappers it
is `pool.get_dy(...)`, a raw spot read:

```solidity
uint256 collateralOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
```

An attacker who skews that pool so the debt→collateral direction quotes poorly inflates `c`,
forcing the vault to remove and sell more collateral than the deficit warrants. The over-sold
proceeds land as idle debt asset (no direct theft), but combined with C-01's weak floor on
`CurveTwoCryptoSwapper` (10% deviation band) it amplifies the extractable amount, and it makes the
`getCurrentCollateral()` cap / health revert (M-02) reachable on demand.

Neither Curve-only swapper appears in the three deploy scripts currently in `script/`, so this is
latent rather than live — but the vault's swapper is mutable via timelock, so it is a real
configuration.

**Fix**: size `c` from `loanManager.getDebtValue(deficit)` (oracle) rather than the swapper quote,
which is also the value the C-01 floor should be measured against. That makes the sizing uniform
across all swappers.

---

## L-01 — Surplus debt asset: correct accounting, but idle and round-tripped

**Severity**: Low / Informational (this is the answer to focus area 5 — **no leak found**)
**Location**: `src/libraries/ZenjiCoreLib.sol:320-327`

Checked all three concerns:

* **Stranded?** No. The surplus sits at the vault and is swept by
  `Zenji._swapRemainingDebtToCollateral` on the withdrawal paths (`Zenji.sol:1323`, `:1336`) and on
  `setIdle(true)` (`:755`).
* **Double-counted in `totalAssets()`?** No. `ZenjiViewHelper.getTotalCollateralValue` counts idle
  vault debt asset exactly once, at `:116-119`, separately from the strategy balance at `:101-114`.
  Shareholders are correctly credited.
* **Fee accrual / `lastStrategyBalance`?** No interaction. `_accrueYieldFees` (`Zenji.sol:1194-1212`)
  keys only on `yieldStrategy.balanceOf()`, and arm 3 never touches the strategy, so the returned
  `newStrategyBalance` (`ZenjiCoreLib.sol:335`) equals the value already established by
  `processRebalanceBounty` (`Zenji.sol:661`). No phantom yield, no phantom loss.

Residual: the surplus earns nothing while idle (`_deployCapital` deploys idle **collateral** only,
`Zenji.sol:884-886` — it will never redeploy idle debt asset), and it pays a second swap on the way
back to collateral. With M-03 fixed the surplus is normally ~0, which is the cleanest resolution.
The NatSpec's claim that the surplus is "swept up ... on a subsequent deposit/rebalance cycle" is
inaccurate for the deposit/rebalance paths — only withdrawal and `setIdle(true)` sweep it.

---

## L-02 — Postcondition re-reads a spot strategy balance

**Severity**: Low (liveness)
**Location**: `src/libraries/ZenjiCoreLib.sol:329-334`

`newStrategyBalance = yieldStrategy.balanceOf()` re-reads the same spot-varying
`min(vp, calc_withdraw_one_coin)` used for `startCoverage`. Arm 3 does not touch the strategy's LP
pool, so in the normal case the two reads are equal. But for the USDT-variant strategies
`_convertYieldAssetValueToDebt` prices crvUSD→USDT through the crvUSD/USDT oracles and pool
(`UsdtCrvUsdSwapMixin`), and the collateral→debt swap on the LlamaLend vaults routes through the
TriCRV crvUSD pool — so a large arm-3 swap can nudge the strategy's reported balance downward
between the two reads. If that dip exceeds the (tiny) repay-driven coverage gain, the call reverts
`CoverageDidNotImprove` and arm 3 becomes unavailable for that block.

Low impact (retry succeeds), but worth a comment: `newStrategyBalance` should arguably be pinned to
the pre-swap `strategyBalance`, since the function provably does not touch the strategy.

---

## Focus areas cleared

Each of these was traced end to end and found sound. Listing them explicitly per the brief.

**1. Collateral sizing / `maxSlippage` bound.** `maxSlippage` is bounded by
`MAX_VAULT_SLIPPAGE = 5e16` (`ZenjiConstants.sol:20`, enforced through `setParam`/`executeParam` with
a timelock on increases, `Zenji.sol:798-870`), so `precision / (precision - maxSlippage) ≤ 1.0526` —
the buffer cannot blow up or divide by zero. The `getCurrentCollateral()` cap is safe *as a cap*
(it can only shrink `c`; both adapters read the live position — `AaveLoanManager.sol:548-550` aToken
balance, `LlamaLoanManager.sol:624-628` `user_state[0]`). Over-removal risk comes from M-03 and M-04,
not from the cap. `c == 0` early-returns without mutating state.

**2. Aave intermediate health.** `AaveLoanManager.removeCollateral` (`:240-249`) explicitly reverts
`HealthTooLow` below `MIN_HEALTH = 1.1e18` whenever debt is outstanding, on top of Aave's own HF≥1
check inside `aavePool.withdraw`. Sound. (LlamaLend is M-01.)

**3. Intermediate health dip, worst case.** Confirmed the dip is real but structurally bounded:
arms are evaluated LTV-first (`Zenji.sol:673-700`), so arm 3 is unreachable while LTV is outside
`targetLtv ± 3%`. Worst starting point is `targetLtv + 3%`. Final LTV after the repay is slightly
*below* the start (removing equal value from numerator and denominator of a ratio < 1 lowers it):
for `D=65, C=100, x=2`, `65/98 = 66.3%` intermediate → `63/98 = 64.3%` final. The plan's measured
130 bps transient dip reproduces analytically. Aave rejects an unsafe dip; LlamaLend rejects a
*technically insolvent* one but not an imprudent one (M-01).

**4. `transferCollateral` ordering.** `removeCollateral(c)` then `transferCollateral(this, c)` is
correct on both venues. Aave's `transferCollateral` (`:672-690`) takes the idle balance first — which
`removeCollateral` just created — and only falls through to `aavePool.withdraw` if short, so it
cannot double-withdraw. LlamaLend's (`:728-731`) is a plain transfer of the just-freed collateral.

**5. Reentrancy / ordering.** `rebalance()` is `nonReentrant` (`Zenji.sol:625`) via the shared vault
guard in `ZenjiStorage`, which covers the whole delegatecall into `ZenjiCoreLib` since the guard slot
is vault storage. `LlamaLoanManager.repayDebt` carries its own `nonReentrant` (`:267`) — no conflict,
different contract. The external calls made mid-operation are to the vault-configured swapper (change
gated by a 1-week timelock) and, transitively, Uniswap V3/V4/Universal Router and Curve. None of the
tokens involved (WBTC, wstETH, XAUT, crvUSD, USDT, WETH) have transfer hooks, so there is no callback
into the vault. **The attacks in C-01/H-01 do not require reentrancy** — they are sequential external
calls in one transaction — so `nonReentrant` is correctly scoped but simply not the relevant control.

**6. Withdrawal-path isolation.** Confirmed clean. `rebalanceCoverageUp` has exactly one caller in
the whole repo (`Zenji.sol:687`). The deleted step 3 was the only place arm 3 touched
`unwindPosition`/`transferDebt`, so the partial-unwind path that regressed in 256de80 is now
strictly *less* entangled than before. `_swapRemainingDebtToCollateral`, `_deployDebtToYield`,
`withdraw`/`redeem` and both loan managers' unwind code are untouched by this diff.

**7. Dust floor.** `deficit <= 10 ** debtAsset.decimals()` (`ZenjiCoreLib.sol:298`) cannot strand the
vault out of band. The band is `3%` of debt; the floor is 1 whole debt unit (~$1). They only overlap
when total debt is below ~33 units (~$33), which is far under both loan managers' own
`DUST_THRESHOLD` and not a reachable operating state for a live vault. No way to "sit just under the
floor". Also correctly placed *before* any state mutation, so the early return is a true no-op.

**8. Bounty accounting.** `processRebalanceBounty` (`ZenjiCoreLib.sol:198-233`) runs before the arm
dispatch, so an arm-3 revert unwinds the bounty too — §5 row 8's intent holds for the *revert* case.
It does not hold for the C-02 case (bounty paid on a one-wei-unit "improvement"). The bounty is
capped at `rebalanceBountyRate × (fees accrued since last rebalance)`, so bounty farming alone is
self-limiting; the profit in C-01/H-01 is the swap extraction, not the bounty.

**9. Build.** `forge build` compiles clean with the new 7-arg signature; the single call site
(`Zenji.sol:686-690`) passes `collateralAsset` and `swapper` in the declared order, matching
`ZenjiCoreLib.sol:277-285`. No other caller to update.

---

## Recommended minimum before ship

1. **C-01** — add the oracle floor at `ZenjiCoreLib.sol:316`, measured as a balance delta against
   `loanManager.getCollateralValue(c)`. (≈4 lines.)
2. **C-02** — add a progress floor (`toRepay ≥ deficit × MIN_PROGRESS`) alongside the existing
   monotonicity check. (≈2 lines.)
3. **H-01** — clamp `exitBased` in `BaseCurveStakeDaoStrategy.balanceOf`, or require the
   below-band condition to persist across blocks before arm 3 may run.
4. **M-01** — add the `MIN_HEALTH` assertion to `LlamaLoanManager.removeCollateral`.
5. **M-03** — remove the second slippage buffer.

Suggested additions to the plan's §8 test list:
* a mock swapper that returns 1 wei of debt asset for the full `c` — must revert, not succeed;
* a fork test that skews the LP pool, calls `rebalance()`, unwinds the skew in one transaction, and
  asserts NAV is unchanged;
* an arm-3 loop test asserting collateral is monotonically non-decreasing in value terms across
  repeated permissionless `rebalance()` calls.
