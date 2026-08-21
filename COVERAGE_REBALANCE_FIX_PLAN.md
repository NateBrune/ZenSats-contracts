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

## 3. Approach — deficit-sized flash loan

A flash loan adds no value; it is the *mechanism* that lets collateral value reach the loan manager
as debt tokens atomically.

```
1. flash-borrow  deficit (+ buffer)
2. repay         deficit of debt        -> D -= deficit; position now over-collateralised
3. remove        freed collateral        -> health check passes BECAUSE step 2 preceded it
4. swap          collateral -> debt via swapper (oracle-floored)
5. repay         flash loan
net: D -= deficit, C -= ~deficit worth, S untouched
     coverage = S / (D - deficit) = S / S = 1.0
```

Step ordering matters: repay **before** removing collateral, so LTV never spikes intra-transaction.

### Why the existing "no flashloan on partial" rule does not block this

`LlamaLoanManager` documents:

> "For partial: never flashloan — ... Flashing the entire remaining debt (other depositors' share)
> causes unnecessarily large collateral swaps that routinely breach the oracle floor check."

That objection is about **size**. Coverage-up needs only `deficit`, bounded at roughly the deadband
(~3-5% of debt), not 100% of it. At the WBTC vault's advised 18 WBTC cap that is a few thousand
dollars of collateral swap against pools doing millions. The oracle-floor risk that motivated the
rule is absent at deficit scale. The fix is a **third case**, not a reversal of the rule.

---

## 4. Current state per loan manager (KEY FINDING)

The two managers are **not** symmetric, which changes the cost of this work substantially.

### AaveLoanManager — mechanism already exists

`_unwindPosition` already computes `unrepaidDebt = debtToRepay - repayNow` and sets
`needFlashloan = true` for a partial unwind whenever that is not dust, flashing
`unrepaidDebt * 10300 / 10000`. `executeOperation` already handles the partial case
(`abi.decode(data, (uint256 collateralNeeded, bool fullyClose))`).

**CONFIRMED by spike (XAUT/Aave fork, 5 XAUT position, 6% induced strategy loss).** Calling
`unwindPosition(collateralNeeded)` with **zero** funding already performs the convergent
collateral-funded repay:

| | before | after |
|---|---|---|
| coverage | 9395 bps | **10019 bps** (in band) |
| strategy S | 12,813,333,711 | **12,813,333,711** (untouched) |
| debt D | 13,637,186,958 | 12,788,616,111 |
| collateral | 5.000000 XAUT | 4.697938 XAUT |
| NAV cost | — | **1 bp** |

Converged in ONE call. Repaid 848.6 against a deficit of 823.9 — the overshoot is the existing 3%
flash buffer, and landing slightly above parity is inside the band.

=> **AaveLoanManager needs NO change.** The XAUT/Aave "gold" vault fix is purely the `ZenjiCoreLib`
arm-3 rewrite: stop pre-funding from the strategy, size `collateralNeeded` from the deficit, call
`unwindPosition`.

### LlamaLoanManager — needs the new case

`needFlashloan = fullyClose && (remainingDebt > 0)` — a partial unwind never flashes. The callback
`onFlashLoan` already supports partial (`ctx.fullyClose ? collAvail : ctx.collateralNeeded`), so the
missing piece is only the **trigger**, not the machinery.

---

## 5. Proposed changes

### 5.1 `ILoanManager` — new function
```solidity
/// @notice Repay `debtAmount` funded by collateral (flash-loan mediated), leaving any
///         vault/strategy balances untouched. Used by coverage rebalancing.
function repayFromCollateral(uint256 debtAmount) external;
```
Explicit and narrow, rather than overloading `unwindPosition`'s semantics. Keeps the existing
partial-unwind contract (used by withdrawals) untouched — important, this is the path that broke in
`256de80`.

### 5.2 `LlamaLoanManager.repayFromCollateral`
- `onlyVault`, `nonReentrant`, `_checkOracleFreshness()`.
- Compute `collateralNeeded` from `debtAmount` pro-rata on `_getPositionValues()`.
- Flash `debtAmount * 10300 / 10000` via the existing `DEBT_FLASH_LENDER`, reusing `onFlashLoan`
  with `UnwindContext{ collateralNeeded, fullyClose: false }`.
- Return leftover debt token to the vault as the existing paths do.

### 5.3 `AaveLoanManager.repayFromCollateral`
- Spike confirms the behaviour already exists. Implement as a thin wrapper over
  `_unwindPosition(collateralNeeded, false)` with no pre-funding, purely to satisfy the shared
  `ILoanManager` interface and keep `ZenjiCoreLib` venue-agnostic. No new flash logic.
- Open detail: verify no debt tokens are left stranded at the loan manager after the call when
  invoked from inside `rebalance()` (the spike called it directly, pranked as the vault).

### 5.4 `ZenjiCoreLib.rebalanceCoverageUp`
Replace steps 1-3 with:
```
deficit = debt - strategyBalance
loanManager.repayFromCollateral(deficit)
return yieldStrategy.balanceOf()
```
Strategy is never touched. Params `maxSlippage` / `precision` become unused — remove them and
update the single caller in `Zenji.sol`.

### 5.5 Dispatch order — DO NOT change
Leave arm 1 (LTV) ahead of arm 3. With arm 3 convergent, the deadlock cannot form: arm 3 restores
coverage to ~1.0, then arm 1 re-levers and its `enforceCoverageAfterIncrease` guard passes.
Convergence is two keeper ticks. Re-ordering would be a larger semantic change for no benefit.

---

## 6. Code size

Vaults have ~1.5 KB of EIP-170 margin (`ZenjiXautAaveUsdtStakeDao` 23,063 B, margin 1,513 B), so
this matters.

| Component | Deployed as | Margin | Net effect |
|---|---|---|---|
| `ZenjiCoreLib` | separate library, delegatecalled | 13,667 B | **shrinks** (deletes steps 1-2) |
| `LlamaLoanManager` | own contract | check before/after | small growth |
| `AaveLoanManager` | own contract | check before/after | ~0 if spike confirms |
| `Zenji` / vaults | 23.0-23.1 KB | ~1.5 KB | **0** — call-site arity only |

The fix lands almost entirely in a delegatecalled library, so it costs the vaults nothing.
`forge build --sizes` gate before/after; no vault may lose margin.

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

Changed surface: `ZenjiCoreLib.rebalanceCoverageUp`, `LlamaLoanManager.repayFromCollateral`
(+ `onFlashLoan` reuse), `AaveLoanManager.repayFromCollateral`, `ILoanManager`, one `Zenji.sol`
call site.

Focus areas: flash-loan callback reentrancy and initiator/token validation on the new entry point;
oracle-floor sizing on the collateral swap; health-check ordering; interaction with the withdrawal
partial-unwind path (must be provably untouched); keeper-bounty accounting on the new path;
donation/dust griefing of `deficit`.

---

## 10. Sequencing

1. ~~**Spike** the Aave hypothesis (S 4.1)~~ — **DONE, confirmed.** Aave needs no new flash logic.
2. Implement `ILoanManager` + `LlamaLoanManager.repayFromCollateral`.
3. Implement `AaveLoanManager.repayFromCollateral` (or confirm not needed).
4. Rewrite `ZenjiCoreLib.rebalanceCoverageUp`; update the `Zenji.sol` call site.
5. Tests (S 8), then size gate.
6. Audit (S 9).
7. Ship. Production runs on idle/unidle until then.

---

## 11. Open questions

- ~~Does the Aave partial-unwind path already converge unfunded?~~ **Yes — confirmed by spike, 1 bp,
  one call.**
- Sizing overshoots parity slightly via the 3% flash buffer. Acceptable (lands in band), but confirm
  it cannot overshoot past the +3% upper bound and immediately trigger arm 4.
- Should arm 3 refuse to run when `deficit` exceeds some fraction of debt (a real insolvency
  signal) and instead surface it for manual handling rather than auto-selling collateral?
- Should coverage drift emit an event so the keeper/monitor can alert before the deadband trips?
