# Technical Plan — Arm 3 Partial Progress + Distinct Error (M-02 follow-up)

**Status**: design, not implemented.
**Follows**: `COVERAGE_REBALANCE_FIX_PLAN.md` (Plan B, shipped) and `AUDIT_CoverageRebalance_v2.md`
(M-02 marked PARTIAL).
**Scope**: `ZenjiCoreLib.rebalanceCoverageUp` only. No interface change, no loan-manager change.

---

## 1. Problem

Arm 3 sizes `c` for the FULL deficit and calls `removeCollateral`, which runs BEFORE the repay, so
health dips. When the deficit is large the dip breaches `MIN_HEALTH` and the whole `rebalance()`
reverts — arm 3 makes **no progress at all** and the keeper reverts every tick until an operator
runs `setIdle(true)/setIdle(false)`.

`DeficitExceedsCollateral` (added for M-02) does NOT cover this: it needs `deficit > 1.45·D`, but
`deficit <= D` by construction, so it is unreachable in normal operation. The real failure is the
health revert, and M-01 made it fire earlier on LlamaLend.

### The threshold is computable and tighter than it looks

For Aave, `healthCalculator` returns `(collateralUsd * liquidationThresholdBps * 1e14) / debtUsd`
and `MIN_HEALTH = 1.1e18`. With target LTV `L`, liquidation threshold `T`, removing collateral worth
`deficit`:

```
health' = T/L - T * (deficit/D)  >=  MIN_HEALTH
    =>   deficit/D  <=  (T/L - MIN_HEALTH) / T
```

XAUT/Aave (`T = 0.75`, `MIN_HEALTH = 1.1`):

| LTV | max deficit/D | equivalent coverage floor |
|---|---|---|
| 0.60 (target) | 20.0% | 80.0% |
| 0.63 (top of deadband) | 12.0% | 88.0% |

So the gold vault's usable arm-3 range is coverage ~88%–97% at the top of its LTV band, not the
80%–97% a naive reading gives. LlamaLend vaults tolerate more (band health, `MIN_HEALTH = 1e17`) —
the 25% loss sweep passes there today.

**Goal**: below the threshold, do as much as is safe (converging over several keeper ticks) instead
of reverting. When even a meaningful partial step is impossible, fail with a distinct, actionable
error rather than an opaque `HealthTooLow`.

---

## 2. Design

### 2.1 Safe-removal cap (option 2)

`ILoanManager.healthCalculator(int256 dCollateral, int256 dDebt) -> int256` already exists and is
implemented on both venues (Aave projects from oracle values; LlamaLend delegates to
`llamaLend.health_calculator(..., full=true)`). Health is monotonically decreasing in removed
collateral, so binary-search the largest `c` whose PROJECTED health clears the floor:

```
cDesired = swapper.quoteCollateralForDebt(deficit)      // unchanged
cSafe    = largest c in [0, cDesired] such that
           loanManager.healthCalculator(-int256(c), 0) >= healthFloor
c        = min(cDesired, cSafe)
```

- `dDebt = 0` deliberately: the venue's own check runs after removal and before the repay, so the
  projection must model that exact intermediate state.
- **Fixed iteration count: 8.** Gives 1/256 precision on `cDesired`, bounded gas, no unbounded loop.
- **`healthFloor` carries a safety margin above `MIN_HEALTH`** (proposal: `MIN_HEALTH * 105 / 100`).
  Rationale: on LlamaLend, `llamaLend.remove_collateral` can revert with its own `"Debt too high"`
  band bound BEFORE our `MIN_HEALTH` check — observed in
  `test_llamaRemoveCollateral_healthTooLow_reverts`. A projection that only just clears `MIN_HEALTH`
  is not proof the venue will accept. The margin absorbs that and oracle drift between projection
  and execution.
- Read `MIN_HEALTH` from the loan manager rather than hardcoding — it differs per venue
  (Aave `1.1e18`, LlamaLend `1e17`). Add `MIN_HEALTH()` to `ILoanManager` ONLY if it is not already
  reachable; check first, prefer no interface change.

### 2.2 Minimum-progress floor + distinct error (option 4)

Partial progress must be worth its cost: every tick pays swap fees plus a keeper bounty. If the safe
step is too small, grinding is worse than stopping.

```
if (c < (cDesired * MIN_PROGRESS_BPS) / 10000)
    revert CoverageDeficitTooLarge(deficit, maxRepayableNow);
```

- Proposal: `MIN_PROGRESS_BPS = 1000` (a step must close >=10% of the deficit).
- `maxRepayableNow` is the debt-denominated value of `cSafe` — it tells the operator how far the
  vault *can* get, which is exactly what they need to decide between waiting and `setIdle/unIdle`.
- This error is the actionable signal M-02 asked for. It must be distinguishable from
  `SwapperUnderperformed` (transient, retry) and `HealthTooLow` (opaque, venue-level).

### 2.3 Everything else is unchanged

`MIN_SWAP_OUT_BPS` floor (C-01), repay capped at `deficit`, surplus left at the vault, the
`CoverageDidNotImprove` postcondition, and the dust floor all stay exactly as they are. In
particular the postcondition still guarantees monotonic convergence — a partial step that does not
improve coverage still reverts.

---

## 3. Convergence

A partial step repays `r < deficit`. Coverage rises (postcondition enforces it), LTV falls, and the
health headroom for the NEXT step grows because debt is lower. So successive ticks take larger
bites: convergence is monotone and accelerating, not asymptotic.

The keeper re-evaluates each tick and `strategyDebtRebalanceNeeded()` stays true until the band is
reached, so no new triggering mechanism is required.

**Must be measured, not assumed** (see S 5): the number of ticks to converge from a 25% / 40% loss,
and the total fees paid across them versus a single `setIdle/unIdle` round trip (measured at 1 bp).
If multi-tick grinding costs materially more than the mitigation, raise `MIN_PROGRESS_BPS` so the
vault stops and asks for a human instead.

---

## 4. Failure modes

| # | Risk | Guard |
|---|---|---|
| 1 | Binary search returns `cSafe` the venue still rejects | `healthFloor` margin above `MIN_HEALTH`; a revert is still safe (no state change) |
| 2 | Oracle moves between projection and execution | Same margin; both use the same oracle basis |
| 3 | Grinding: many small steps, fees each time | `MIN_PROGRESS_BPS` floor + `CoverageDeficitTooLarge` |
| 4 | Bounty farmed per partial tick | Bounty is `(accumulatedFees - feesAtLastRebalance) * rate`; the first tick zeroes it, so later ticks pay ~0 |
| 5 | 8 iterations of `healthCalculator` is too much gas | Each is a view; measure and report. Reduce iterations or cache if material |
| 6 | `cSafe = 0` (no headroom at all) | Falls under `MIN_PROGRESS_BPS` -> distinct error |
| 7 | Interaction with H-01 (manufactured deficit) | Unchanged: a manufactured deficit now yields a bounded partial sale rather than a revert. Re-check the accepted-risk analysis holds |

---

## 5. Test plan

1. **Partial progress happens**: induce a loss above the venue threshold (>20% on XAUT/Aave), assert
   `rebalance()` SUCCEEDS, coverage strictly improves, and the condition is still flagged.
2. **Multi-tick convergence**: loop `rebalance()` and assert coverage reaches the band; report the
   number of ticks and total NAV cost.
3. **Cost comparison**: total NAV cost of multi-tick convergence vs `setIdle/unIdle` (1 bp baseline).
   This decides whether `MIN_PROGRESS_BPS` is calibrated correctly.
4. **Distinct error**: construct a state with insufficient headroom, assert
   `CoverageDeficitTooLarge` with sensible arguments (not `HealthTooLow`, not a silent success).
5. **No regression on the normal path**: all existing arm-3 tests still converge in ONE call
   (WBTC 9598 -> 10000, XAUT 9596 -> 9999, sweep 4/10/25%).
6. **Gas**: report the gas delta on a normal arm-3 rebalance from the 8 `healthCalculator` calls.
7. Full regression: 661 unit, three fork suites, `forge build --sizes` (no vault may lose margin;
   current 1,536 / 1,468 / 1,489).

---

## 6. Size budget

Lands entirely in `ZenjiCoreLib` (delegatecalled, 13,631 B margin). Vaults should see **zero**
change — no new call-site arguments. If a vault loses any margin, something is wrong.

---

## 7. Audit scope

`ZenjiCoreLib.rebalanceCoverageUp` only. Focus: the binary search (termination, off-by-one,
`int256` casts of collateral amounts), whether `healthCalculator` can be manipulated within the tx
to inflate `cSafe`, whether partial progress can be induced repeatedly to bleed fees (interaction
with H-01), and confirmation that C-01's floor and the `CoverageDidNotImprove` postcondition still
bind on the partial path.

---

## 8. Open decisions

- `MIN_PROGRESS_BPS = 1000` — calibrate against the S 5.3 cost comparison.
- `healthFloor` margin of 5% — is that enough for LlamaLend's band bound? Test 1 will show.
- Should `CoverageDeficitTooLarge` also fire when `cSafe` is healthy but the resulting coverage
  would still be far below band — i.e. an explicit "this is insolvency, wake a human" threshold
  rather than a pure progress test?

---

# OUTCOME — partial progress REJECTED; feasibility probe + distinct error shipped

**Decision date**: 2026-08-24. Superseded S 2.1 (safe-removal cap) and S 2.2's minimum-progress
floor. S 2.2's *distinct error* shipped.

## Why partial progress was rejected

Implemented, tested on a live fork, and it **reintroduced the deadlock arm 3 exists to fix.**
XAUT/Aave, 35% strategy loss:

```
tick 1: rebalance() SUCCEEDS   coverage 6496 -> 7424 bps,  LTV 60.00% -> 56.78%
tick 2: rebalance() REVERTS    StrategyDebtCoverageTooLow
```

A single safe-capped step moves LTV ~3.2pp, past `lowerBand` (57%). The next call therefore
dispatches to **arm 1**, whose `enforceCoverageAfterIncrease` guard refuses while coverage is still
~74%. Permanent: a 30-day warp moved LTV only to 56.97%, so interest accrual never rescues it. Only
`setIdle/unIdle` recovers.

This falsified an explicit premise of the shipped Plan B, stated in `rebalance()`'s NatSpec: *arm 3
restores parity in ONE call, so arm 1 re-levers and its guard passes.* Partial progress breaks
exactly that premise. **Do not reintroduce partial steps without also changing dispatch order.**

**Cost data condemned it independently**: the partial tick cost ~5 bps AND `setIdle/unIdle` (3-13 bps)
was still required afterwards — cost ON TOP OF the escape it was meant to replace, not instead of it.
`MIN_PROGRESS_BPS` was not miscalibrated; the feature was net-negative whenever it triggered.

**And it was inert on LlamaLend.** Curve's `health_calculator` is near-insensitive to `d_collateral`
(removing 1% vs 5% moved health by ~1e-11 relative), so the search admitted the full removal there
regardless. Value delivered on zero of three vaults.

## What shipped instead (S 2.2 only)

Arm 3 is **all-or-nothing**. A single `healthCalculator(-int256(cDesired), 0)` probe against
`MIN_HEALTH * 105 / 100`; on failure it reverts
`CoverageDeficitTooLarge(deficit, collateralRequired)` — an actionable signal naming the operator's
next move (`setIdle`/`unIdle`), distinguishable from `SwapperUnderperformed` (transient, retry) and
the venue's opaque `HealthTooLow`. One view call instead of nine.

Also removed the now-unused `maxSlippage` parameter (dead since audit M-03 dropped the double
buffer), which shrank the call site.

## Two bugs found and fixed en route (kept as cautionary record)

1. **`healthCalculator(0, 0)` is not a current-health proxy.** Curve's is built for CHANGES: it
   returns **-1e18** on a zero-delta call while `health(user, true)` reports **+0.449e18** on the
   same position. A degenerate-case guard using it short-circuited every LlamaLend rebalance and
   broke all WBTC tests. Use `getHealth()`. XAUT passed throughout — this was only caught by
   testing both venues.
2. **Bisection over `[0, cDesired]` never reaches its upper bound** — 8 iterations under-removed
   0.3906% on EVERY call, including the common case where full removal was always safe (audit L-01).

## Results

661/661 unit. Fork: 60 + 78 + 68 = 206 passing, 2 environmental skips, 0 failures.
Vault margins **improved** to 1,548 / 1,480 / 1,501 (from 1,536 / 1,468 / 1,489).
`ZenjiCoreLib` 11,198 B. No loan-manager or interface changes.

## Still open

- **M-02's liveness gap remains by design**: a deficit past the venue threshold reverts and needs
  the operator escape. The gain is that it now says so clearly instead of failing opaquely.
- **Option 2 (reorder dispatch: coverage before LTV)** is the only route that makes partial progress
  converge — health headroom GROWS as LTV falls, so successive steps get easier. Deliberately not
  taken: it changes `rebalance()` semantics for every vault and needs a full re-audit.
- Audit L-03 (health-floor margin is relative, so LlamaLend gets 0.005 units of cushion vs Aave's
  0.055) and L-04 (`IMinHealth` bypasses `ILoanManager`, so a future manager compiles but bricks
  arm 3 at runtime). Both Low, both unaddressed.
