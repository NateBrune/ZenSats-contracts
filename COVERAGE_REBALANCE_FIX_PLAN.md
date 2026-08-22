# Technical Plan — Coverage Rebalance (arm 3) Convergence Fix

**Status**: design, not implemented. **Owner**: TBD. **Target**: `ZenjiCoreLib` + `LlamaLoanManager`.

---

## 1. Problem

`rebalance()` arm 3 (`coverage < 1 - DEADBAND_SPREAD`, i.e. `strategyBalance < debt`) does not converge.
It drifts further out of band on every call and eventually deadlocks `rebalance()` entirely.

Reproduced on a mainnet fork — `test_coverageUp_clearsRatioCondition`, WBTC/LlamaLend/crvUSD-USDT:

```
start:   ratio 9598 bps
pass 1:  ratio 9581 bps   -> away from parity
pass 2:  ratio 9563 bps   -> away from parity
pass 3:  rebalance() REVERTS - StrategyDebtCoverageTooLow(0.9598, 0.97)
```

Strategy balance fell 43,462 -> 41,566 crvUSD (~4.4%) burned in slippage across two passes,
plus a keeper bounty each pass, ending further out of band than it started.

**Deadlock mechanism**: arm 3 repays debt, which lowers LTV. After ~2 passes LTV leaves its band.
LTV is evaluated first in the `if/else` chain, so arm 3 becomes unreachable. Arm 1 (lever up) then
reverts on `enforceCoverageAfterIncrease` because coverage is still < 97%. Both guards are
individually correct and mutually blocking.

**Impact**: not funds-at-risk. Deposits and withdrawals continue to work. But the vault sits with
LTV and coverage both out of band, and the keeper reverts every cron tick until manually cleared.

**Current mitigation (verified, keep for production)**: `setIdle(true)` -> `setIdle(false)`.
Drives debt to 0, so `strategyToDebtRatio()` returns `type(uint256).max`, which both guards
explicitly exclude; `_deployCapital()` then re-levers at parity.
Measured: ratio 9562 -> 9998 bps, NAV cost **1 bp** at 1 WBTC
(`test_idleUnidle_recoversFromCoverageDeadlock`). Strategist-callable, no timelock.

---

## 2. Root cause — a conservation law, not a sizing bug

`D - S` is **invariant** under every operation available inside the vault:

| Operation | Effect | delta(D - S) |
|---|---|---|
| withdraw `w` from strategy, repay `w` of debt | S-w, D-w | **0** |
| borrow `b`, deposit `b` into strategy | S+b, D+b | **0** |

Arm 3 funds its repay by withdrawing from the strategy — the one source that cannot help.
The deficit is identical before and after; only the ratio degrades.

Steps 1-2 of `rebalanceCoverageUp` are **not** removable: they are the *funding* mechanism.
`LoanManager._unwindPosition` repays only `min(debtToRepay, currentDebt, debtToken.balanceOf(self))`
and cannot source debt tokens itself on a partial unwind. Deleting steps 1-2 leaves `repayNow = 0`,
degrading step 3 into a bare collateral removal that **raises** LTV and repays nothing.
(Empirically confirmed: ratio flat at 9598. Do not repeat this.)

### Why a closed-form calculation cannot fix it

Solving `(S + x) / (D + x) >= 0.97` is possible, but it is the wrong medicine: from `S=90, D=100`
it requires `x = 233`, tripling debt to paper over a 10-unit loss, and is bounded by `targetLtv`
regardless. The deficit remains 10. Closing it needs value from **outside** the S/D pair —
collateral (equity) or harvest yield. Harvest is not on demand, so: collateral.

---

## 3. Chosen approach — Plan B: collateral-funded repay, one implementation

Value must come from outside the S/D pair, and the only available source is collateral. The
convergent operation is therefore: **turn collateral into debt tokens and repay, without touching
the strategy.**

Two mechanisms can do that. Both were probed on mainnet forks:

| | Uniform impl? | Fee | New lender code | Probed |
|---|---|---|---|---|
| **B — `removeCollateral` + swap + `repayDebt`** | **yes, one impl** | **none** | **none** | both venues OK |
| A — deficit-sized flash loan | yes | 5 bps of deficit on Aave; 0 on Curve | LlamaLend trigger | Aave OK |
| ~~C — per-venue split~~ | no | none | LlamaLend trigger | rejected |

**Plan B is chosen.** Every primitive it needs already exists on `ILoanManager`
(`removeCollateral`, `transferCollateral`, `repayDebt`) and `ISwapper`
(`quoteCollateralForDebt`, `swapCollateralForDebt`), each already implemented per venue with
venue-correct internals. So the fix is a **single venue-agnostic implementation in `ZenjiCoreLib`**
— no loan-manager changes, no interface changes, no flash-loan fees, and it works for any venue
added later. Divergence stays where it belongs: inside the adapters, behind `ILoanManager`.

**Plan A is the documented fallback**, needed only if B's intermediate health dip proves too tight
for a venue. A repays *before* removing collateral, so health strictly improves first.

### 3.1 Algorithm

`ZenjiCoreLib` external functions run under DELEGATECALL, so `address(this)` is the vault.

```
debt = loanManager.getCurrentDebt();          if (debt == 0)  return S;
S    = yieldStrategy.balanceOf();             if (S >= debt)  return S;
deficit = debt - S;

// 1. Size the collateral, buffered for swap slippage.
c = swapper.quoteCollateralForDebt(deficit);
c = (c * precision) / (precision - maxSlippage);
c = min(c, loanManager.getCurrentCollateral());

// 2. Free the collateral. Health is enforced by the venue adapter:
//    Aave reverts on MIN_HEALTH; LlamaLend reverts internally.
loanManager.removeCollateral(c);
loanManager.transferCollateral(address(this), c);

// 3. Convert. NOTE: the swappers do NOT carry an end-to-end oracle floor -- they document the
//    loan manager's SwapperUnderperformed check as the hard floor. A direct ISwapper call from
//    the vault bypasses it, so it MUST be re-applied here (audit C-01).
expectedDebt = loanManager.getCollateralValue(c) * MIN_SWAP_OUT_BPS / 10000;
collateralAsset.safeTransfer(address(swapper), c);
received = swapper.swapCollateralForDebt(c);
if (received < expectedDebt) revert SwapperUnderperformed(expectedDebt, received);

// 4. Repay, capped at the deficit so coverage cannot overshoot the +spread bound.
toRepay = min(received, deficit);
debtAsset.safeTransfer(address(loanManager), toRepay);
loanManager.repayDebt(toRepay);

// 5. Redeploy any surplus into the strategy: raises S, strictly improving coverage.
//    (Alternative: leave in vault. See S 11.)

// 6. POSTCONDITION - the guard that makes the old bug class unrepresentable.
newCoverage = yieldStrategy.balanceOf() * precision / loanManager.getCurrentDebt();
if (newCoverage <= startCoverage) revert CoverageDidNotImprove();

return yieldStrategy.balanceOf();
```

Step 6 is the important one. The original defect was an operation that *looked* corrective while
moving the ratio backwards. A monotonicity postcondition makes that state unreachable regardless of
future refactors — a bleed becomes a revert.

### 3.2 Signature change

```solidity
function rebalanceCoverageUp(
    ILoanManager loanManager,
    IYieldStrategy yieldStrategy,
    IERC20 debtAsset,
    IERC20 collateralAsset,   // new
    ISwapper swapper,         // new
    uint256 maxSlippage,
    uint256 precision
) external returns (uint256 newLastStrategyBalance);
```
`ZenjiCoreLib` already imports `ISwapper`. One call site in `Zenji.sol`. Dispatch order unchanged —
with arm 3 convergent the deadlock cannot form (arm 3 restores parity, arm 1 re-levers, its
`enforceCoverageAfterIncrease` guard passes). Convergence is two keeper ticks.

---

## 4. Evidence

### 4.1 Aave — the flash path already converges unfunded (Plan A viability)
XAUT/Aave fork, 5 XAUT, 6% induced strategy loss. `unwindPosition(collateralNeeded)` with ZERO
funding:

| | before | after |
|---|---|---|
| coverage | 9395 bps | **10019 bps** (in band) |
| strategy S | 12,813,333,711 | **unchanged** |
| debt D | 13,637,186,958 | 12,788,616,111 |
| collateral | 5.000000 XAUT | 4.697938 XAUT |
| NAV cost | — | **1 bp** |

Converged in one call. Confirms Plan A needs no Aave lender changes, and confirms the economics of
collateral-funded repay generally.

### 4.2 LlamaLend — small `removeCollateral` is safe (Plan B viability)
WBTC/Llama fork, 1 WBTC, deadband-sized (3% of debt) removal:

```
debt 49,855 crvUSD | collateral 1.00000000 WBTC | LTV 6500 bps
remove 0.01969697 WBTC (196 bps of collateral)  -> OK, LTV 6630 bps
```

No band/dust assertion (`_calculate_debt_n1` / `y_effective > 0`). The 130 bps LTV dip is
transient — step 4's repay returns LTV to roughly its starting value — and it stays inside the LTV
deadband, so it cannot itself trigger arm 2.

### 4.3 Venue mechanics behind `ILoanManager.removeCollateral`
- **Aave**: `aavePool.withdraw(...)`, then explicit `health < MIN_HEALTH` revert.
- **LlamaLend**: `llamaLend.remove_collateral(...)`, health enforced by LlamaLend.

Both fail safe. Neither can silently produce an unsound position.

---

## 5. Failure modes

| # | Risk | Guard |
|---|---|---|
| 1 | Intermediate health dip rejected by venue | Adapter reverts (Aave `MIN_HEALTH`, LlamaLend internal). Whole rebalance reverts; idle/unidle remains the escape. Deadband-sized dip measured at 130 bps against a ~1500 bps buffer. |
| 2 | Collateral->debt swap breaches oracle floor | Swapper enforces its own Chainlink floor. Surface the revert; never widen the floor here. |
| 3 | Swap returns less than the deficit | `toRepay = min(received, deficit)`; step 6 still requires strict improvement, so a partial repay is acceptable but a regression is not. |
| 4 | Overshoot past the +spread bound triggers arm 4 | Repay capped at `deficit`; surplus redeployed to strategy rather than repaid. |
| 5 | LlamaLend band/dust assertion on removal | Probed clean at deadband size (S 4.2). Do NOT auto-escalate to full close — revert. |
| 6 | Deficit is dust | Floor it: skip below a dust threshold and let the deadband absorb it. |
| 7 | Repeated no-op calls / oscillation | Step 6 postcondition reverts rather than bleeding. |
| 8 | Keeper bounty paid for no progress | Bounty only on a call that satisfies step 6. |
| 9 | Large deficit = real insolvency, not drift | See S 11 — open decision on a refusal threshold. |
| 10 | `emergencyMode` interaction | Arm 3 unreachable; `rebalance()` already reverts. No change. |

## 6. Code size

Vaults have ~1.5 KB of EIP-170 margin (`ZenjiXautAaveUsdtStakeDao` 23,063 B, margin 1,513 B), so
this matters.

| Component | Deployed as | Margin | Net effect |
|---|---|---|---|
| `ZenjiCoreLib` | separate library, delegatecalled | 13,667 B | roughly neutral: deletes steps 1-2, adds sizing + swap + postcondition |
| `LlamaLoanManager` | own contract | — | **0 — unchanged under Plan B** |
| `AaveLoanManager` | own contract | — | **0 — unchanged under Plan B** |
| `Zenji` / vaults | 23.0-23.1 KB | ~1.5 KB | **0** — call-site arity only |

Plan B touches exactly one delegatecalled library, so it costs the vaults nothing and leaves both
loan managers untouched. `forge build --sizes` gate before/after; no vault may lose margin.

---

## 7. Failure modes to design against

| # | Risk | Guard |
|---|---|---|
| 1 | Flash lender lacks liquidity / reverts | Arm 3 reverts; keeper reverts; idle/unidle remains the escape. Must not silently no-op. |
| 2 | Collateral->debt swap breaches oracle floor | Deficit-sized swap keeps this small; surface the revert, never widen the floor. |
| 3 | Health check rejects the collateral removal | Repay precedes removal (step 2 before 3), so health strictly improves first. |
| 4 | LlamaLend dust assertion ("Amount too low") | Reuse the existing `_DUST_REVERT_HASH` escalation; do NOT auto-escalate to full close from a coverage rebalance — revert instead. |
| 5 | Deficit smaller than flash minimum / dust | Add a floor: skip if `deficit` is dust, let the deadband absorb it. |
| 6 | Repeated arm-3 calls (oscillation) | Post-condition assert: coverage strictly increased, else revert. |
| 7 | Interaction with `emergencyMode` | Arm 3 unreachable in emergency (`rebalance()` already reverts). No change. |
| 8 | Keeper bounty paid on a no-op | Only pay when coverage actually moved. |

---

## 8. Test plan

**Must pass before merge:**
1. `test_coverageUp_clearsRatioCondition` (exists, currently red) — must go green on WBTC/Llama.
2. Same test ported to XAUT/Aave — the gold vault must be proven directly, not by inheritance.
3. Convergence: coverage in band after **one** arm-3 call; LTV back in band after the following call.
4. `test_idleUnidle_recoversFromCoverageDeadlock` stays green (mitigation must survive the fix).
5. Loss-size sweep: 4%, 10%, 25% strategy loss — assert convergence or clean revert, never drift.
6. Flash-lender-unavailable: mock a reverting lender, assert clean revert and no state change.
7. Full regression: 661 unit tests + all 3 target fork suites.
8. `forge build --sizes` — no vault loses margin.

---

## 9. Audit scope

Changed surface under Plan B is deliberately small: `ZenjiCoreLib.rebalanceCoverageUp` and one
`Zenji.sol` call site. No loan manager, no interface, no flash-loan callback.

Focus areas: collateral sizing and the slippage buffer (over-removal risk); oracle-floor behaviour
on the collateral->debt swap; the intermediate health dip across both venues and at the top of the
LTV deadband; the step-6 postcondition (can it be satisfied while value leaks?); surplus handling in
step 5; keeper-bounty accounting; donation/dust griefing of `deficit`; and confirmation that the
withdrawal partial-unwind path is provably untouched.

---

## 10. Sequencing

1. ~~Probe Aave unfunded partial unwind~~ — **DONE** (S 4.1). Plan A viable, no Aave changes.
2. ~~Probe LlamaLend small `removeCollateral`~~ — **DONE** (S 4.2). **Plan B viable on both venues.**
3. Add `CoverageDidNotImprove` error; rewrite `ZenjiCoreLib.rebalanceCoverageUp` per S 3.1.
4. Update the single `Zenji.sol` call site for the new signature (S 3.2).
5. Tests (S 8), then `forge build --sizes` gate.
6. Audit (S 9).
7. Ship. Production runs on idle/unidle until then.

No loan-manager or interface work is required. Plan A stays documented as the fallback if a future
venue cannot tolerate the intermediate health dip.

---

## 11. Open questions

- ~~Does the Aave partial-unwind path already converge unfunded?~~ **Yes — confirmed by spike, 1 bp,
  one call.**
- Step 5 surplus: redeploy into the strategy (raises S, strictly improves coverage) or leave in the
  vault for `_swapRemainingDebtToCollateral` to handle on withdrawal? Redeploy is preferred; confirm
  it cannot fight the fee-accrual baseline (`lastStrategyBalance`).
- Should the slippage buffer on `c` be `maxSlippage` or the swapper's own `slippage()`? Over-removing
  collateral is the main waste vector under Plan B.
- Should arm 3 refuse to run when `deficit` exceeds some fraction of debt (a real insolvency
  signal) and instead surface it for manual handling rather than auto-selling collateral?
- Should coverage drift emit an event so the keeper/monitor can alert before the deadband trips?
