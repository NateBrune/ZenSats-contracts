# Audit — Arm 3 Partial Progress (M-02 follow-up)

**Date**: 2026-08-22
**Scope**: uncommitted delta to `src/libraries/ZenjiCoreLib.sol` → `rebalanceCoverageUp` only
(safe-removal binary search, `MIN_PROGRESS_BPS` floor, `CoverageDeficitTooLarge`, `IMinHealth`).
**Baseline**: `COVERAGE_REBALANCE_FIX_PLAN.md` (Plan B, shipped) + `AUDIT_CoverageRebalance_v2.md`.
**Method**: full read of the changed function, both loan managers' `healthCalculator` /
`removeCollateral` / `getCurrentCollateral`, `ISwapper.quoteCollateralForDebt` implementations,
`Zenji.rebalance()` arm dispatch, and a numeric simulation of the binary search. `forge build`
passes (only pre-existing lint warnings in test files).

## Verdict

**SHIP.** No Critical, High, or Medium findings. The change is correct, conservative in the right
direction (it can only ever under-remove, never over-remove), and it is strictly more permissive
than the code it replaces — every state in which the new code reverts is a state in which the old
code also reverted. Four Low and three Informational items follow; none are blocking, and L-01/L-02
share a single three-line fix that is worth taking before deploy.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 4 |
| Informational | 3 |

---

## Findings

### [L-01] Binary search never returns `cDesired`, so the healthy path systematically under-removes ~0.39%

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:424-441` (the 8-iteration loop and `c = min(cDesired, cSafe)`)

The search is `lo = 0`, `hi = cDesired`, `mid = lo + (hi - lo + 1) / 2`, 8 fixed iterations. The
gap `hi - lo` halves each iteration, so after 8 iterations the residual gap is `≈ cDesired / 256`.
When the predicate holds for *every* `c` in `[0, cDesired]` — i.e. the normal, healthy case where
the full deficit is safely removable and the pre-change code removed `cDesired` outright — `lo`
converges upward but never reaches `hi`. Simulated:

| `cDesired` | `cSafe` returned | shortfall |
|---|---|---|
| `1e18` | `996093750000000000` | 0.390625% |
| `1e8` (WBTC-scale) | `99609375` | 0.390625% |
| `1000` | `997` | 0.3% |

So `c = min(cDesired, cSafe) = cSafe < cDesired` on **every** arm-3 call, including ones that
previously closed the deficit exactly.

**Impact**: benign today, but it is a real behaviour change on the previously-clean path.
`quoteCollateralForDebt` grosses up by `PRECISION / (PRECISION - slippage)`; at the default
`maxSlippage = 1e16` (1%, `Zenji.sol:287`) the gross-up is ~1.01%, which absorbs the 0.39%
shortfall, so `received >= deficit` still holds and `toRepay` is still the full `deficit`. If a
swapper's slippage is ever configured below ~0.4% (`BaseSwapper.setSlippage` accepts anything in
`(0, 5e16]`, `BaseSwapper.sol:54`), the shortfall exceeds the buffer and arm 3 leaves a residual
of ~0.4% of the deficit. `DEADBAND_SPREAD = 3e16` (`ZenjiConstants.sol:14`) swallows that, so it
does not cost an extra tick — but the plan's test 5 ("no regression on the normal path: WBTC
9598 → 10000, XAUT 9596 → 9999") will show slightly different terminal coverage than the pre-change
numbers, and that difference is this, not a bug elsewhere.

**Recommendation** (also fixes L-02): probe the top of the range first and skip the loop entirely
when the full removal is safe.

```solidity
uint256 cSafe = 0;
if (loanManager.healthCalculator(0, 0) >= healthFloor) {
    if (loanManager.healthCalculator(-int256(cDesired), 0) >= healthFloor) {
        cSafe = cDesired;                 // common case: 2 view calls, exact, no shortfall
    } else {
        uint256 lo = 0;
        uint256 hi = cDesired - 1;        // cDesired already known to fail
        for (uint256 i = 0; i < 8; ++i) {
            if (lo == hi) break;          // converged — stop burning view calls
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (loanManager.healthCalculator(-int256(mid), 0) >= healthFloor) lo = mid;
            else hi = mid - 1;
        }
        cSafe = lo;
    }
}
```

Note `hi = cDesired - 1` is safe: `cDesired == 0` returned earlier at `ZenjiCoreLib.sol:400`.

---

### [L-02] Nine `healthCalculator` view calls on every arm-3 rebalance

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:423` (pre-check) + `:427-437` (8 loop iterations)

Every arm-3 rebalance now makes 1 + 8 = 9 external view calls, unconditionally, with no early exit
once `lo == hi` (once converged, `mid == lo`, the predicate re-passes, and the remaining iterations
are pure waste — but they still make the external call).

Cost per call is venue-dependent and not trivial:
- **Aave** (`AaveLoanManager.sol:607-634`): `aToken.balanceOf` + `variableDebtToken.balanceOf` +
  `_getCollateralUsdValue` + `_getDebtUsdValue`, i.e. two rebasing-token balance reads and two
  oracle reads per iteration.
- **LlamaLend** (`LlamaLoanManager.sol:677-683`): `llamaLend.health_calculator(..., full=true)`,
  which walks the AMM band math in Vyper — materially more expensive than the Aave path.

This is not a block-gas or griefing concern (`rebalance()` does one arm and returns; there is no
attacker-controlled multiplier on the iteration count — it is a compile-time `8`). It is a keeper
cost regression that the plan itself flagged as failure mode 5 and asked to be measured. The L-01
fix collapses the common case to 2 calls and adds the `lo == hi` break for the partial case.

**Recommendation**: apply the L-01 patch; report the measured gas delta per plan S 5.6.

---

### [L-03] `healthFloor` margin is relative (×1.05) but the risk it is sized against is absolute — it is 11× thinner on LlamaLend

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:44` (`HEALTH_FLOOR_MARGIN_PCT = 105`), `:417-418`

The NatSpec justifies the margin specifically by LlamaLend behaviour: *"LlamaLend's
`remove_collateral` can revert on its own band bound BEFORE our `MIN_HEALTH` check fires (observed
in `test_llamaRemoveCollateral_healthTooLow_reverts`)"*. But the margin is applied as a percentage
of `MIN_HEALTH`, and the two venues' `MIN_HEALTH` differ by 11×:

| Venue | `MIN_HEALTH` | `healthFloor` | absolute margin |
|---|---|---|---|
| Aave (`AaveLoanManager.sol:46`) | `1.1e18` | `1.155e18` | `0.055e18` |
| LlamaLend (`LlamaLoanManager.sol:41`) | `1e17` | `1.05e17` | `0.005e18` |

So the venue whose band-bound behaviour motivated the margin gets an absolute cushion of 0.005
health units, while the venue that does not need it gets 0.055. Curve's `health_calculator` and its
internal removal bound are not related to `MIN_HEALTH` by a fixed ratio, so there is no reason to
believe 0.005 covers the gap.

**Concrete failure**: if `cSafe` clears `healthFloor` but `llamaLend.remove_collateral(cSafe)`
still reverts on its own bound, `ZenjiCoreLib.sol:449` reverts and the entire `rebalance()`
reverts — the exact no-progress failure mode this change exists to eliminate, in the exact scenario
(large deficit on a LlamaLend vault) it was built for.

**Not a regression.** The pre-change code reverted in that state too, so the worst case is that the
fix does not help on LlamaLend, not that anything got worse. That is why this is Low and not Medium.

**Recommendation**: two options, ideally both.
1. Treat a reverting projection as a failed predicate rather than letting it bubble, by making the
   probe a low-level `staticcall` (or `try`/`catch` over an `IMinHealth`-style external call) and
   mapping any revert to `hi = mid - 1`. This makes the search robust to *any* venue-side revert in
   the projection, not just the band bound, and costs ~2 lines.
2. Calibrate the margin empirically per plan S 8 ("is 5% enough for LlamaLend's band bound? Test 1
   will show") and, if it is not, add an absolute floor component
   (`max(MIN_HEALTH * 105 / 100, MIN_HEALTH + ABS_MARGIN)`) rather than raising the percentage,
   which would over-tighten Aave.

---

### [L-04] `IMinHealth` bypasses `ILoanManager`, so a future loan manager compiles and deploys but bricks arm 3 at runtime

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:14-22` (interface), `:417-418` (call site);
`src/interfaces/ILoanManager.sol` has no `MIN_HEALTH`

The stated reason for the local `IMinHealth` cast is test-mock convenience: *"this lets
`rebalanceCoverageUp` read it without adding `MIN_HEALTH()` to `ILoanManager` (which would force
every `ILoanManager` mock in the test suite to implement it)"*. That is a test-suite cost being paid
for with a production interface weakness.

`ILoanManager` is the contract that defines what a loan manager must provide. A new loan manager
that implements `ILoanManager` completely will compile, deploy, and pass every interface check —
and then `IMinHealth(...).MIN_HEALTH()` returns empty returndata, ABI-decoding of `int256` from
empty returndata reverts, and arm 3 is permanently bricked with an undebuggable revert. The
compiler can no longer tell you this, which is precisely what the interface is for. Both current
managers (`AaveLoanManager.sol:46`, `LlamaLoanManager.sol:41`) do declare it, so this is latent, not
live.

The plan anticipated this (S 2.1: *"Add `MIN_HEALTH()` to `ILoanManager` ONLY if it is not already
reachable; check first, prefer no interface change"*) — but "reachable via a hand-rolled cast" is
not the same as "declared in the interface", and the mock burden is the wrong tiebreaker.

**Recommendation**: add `function MIN_HEALTH() external view returns (int256);` to `ILoanManager`
and delete `IMinHealth`. The mock churn is a one-line addition per mock and is a one-time cost; the
alternative is a permanent silent coupling. If the mock churn is genuinely prohibitive right now,
at minimum add a deployment-time assertion that the call succeeds.

---

### [I-01] `c == 0` can slip past the minimum-progress floor when `cDesired < 10`

**Severity**: Informational
**Location**: `src/libraries/ZenjiCoreLib.sol:446-449`

```solidity
if (c < (cDesired * MIN_PROGRESS_BPS) / 10000) { ... revert CoverageDeficitTooLarge(...); }
```

For `cDesired < 10`, `(cDesired * 1000) / 10000 == 0`, so the guard becomes `c < 0` — always false.
A `cSafe == 0` state (no health headroom at all) then falls through with `c == 0` to
`loanManager.removeCollateral(0)` at `:449`, which reverts `ZeroAmount` in both managers
(`AaveLoanManager.sol:241`, `LlamaLoanManager.sol:282`) instead of the intended
`CoverageDeficitTooLarge`.

**Unreachable today.** The dust floor at `:293` requires `deficit > 10 ** debtAsset.decimals()`
(≈ $1 for every debt asset in use), and `cDesired` is the collateral-equivalent of at least $1:
~1,000 wei for WBTC at 8 decimals, ~333 wei for XAUT at 6 decimals, ~3e14 wei for wstETH. All are
≫ 10. Reported for completeness because the guard's correctness currently depends on a numeric
coincidence in an unrelated constant.

**Recommendation**: `if (c == 0 || c < (cDesired * MIN_PROGRESS_BPS) / 10000)`.

---

### [I-02] `AUDIT_CoverageRebalance_v2.md` residual-risk and monitoring notes for H-01 are now stale

**Severity**: Informational
**Location**: `AUDIT_CoverageRebalance_v2.md:625-627` and `:630-633`

Two statements attached to the accepted H-01 risk no longer describe the deployed behaviour:

1. *"M-01 introduced a transient interaction: a large manufactured deficit now trips `MIN_HEALTH`
   inside `removeCollateral`, so `rebalance()` reverts instead of transacting … arguably the guard
   working."* That revert no longer fires — the safe-removal cap converts it into a bounded partial
   sale. The incidental guard credited there is gone by design.
2. *"Alert on repeated reverting `rebalance()` calls: that is the signature of both this and the
   M-02 liveness gap."* The signature has changed: the M-02 gap now manifests as **repeated
   succeeding arm-3 rebalances that each move coverage only partway**, plus
   `CoverageDeficitTooLarge` reverts.

**Recommendation**: update both bullets, and add to `monitor/`: (a) an alert on
`CoverageDeficitTooLarge`, which is the "wake a human" signal the error was built to be, and
(b) an alert on N consecutive arm-3 rebalances without reaching the band, which is the new
grinding signature.

---

### [I-03] `maxSlippage` parameter is unused in `rebalanceCoverageUp` (pre-existing)

**Severity**: Informational
**Location**: `src/libraries/ZenjiCoreLib.sol:377`

The parameter is accepted and never read; the value bound comes from `MIN_SWAP_OUT_BPS` at `:463`.
Pre-existing, not introduced by this change. Noted only so it is not mistaken for a dropped guard
when reviewing the partial path.

---

## Verified sound

Everything below was checked against the code, not assumed.

**Binary search (focus 1) — sound.**
- **Termination**: fixed `for (uint256 i = 0; i < 8; ++i)`, no data-dependent bound, no
  attacker-controlled iteration count.
- **Invariant "`lo` only ever holds a value that passed the predicate" — holds.** `lo` starts at 0,
  and `predicate(0)` is established by the pre-check at `:423`. That pre-check calls
  `healthCalculator(0, 0)`, which is bit-identical to the loop's `healthCalculator(-int256(0), 0)`
  (`-int256(0) == 0`), so the pre-check genuinely establishes the loop's predicate and not a
  near-miss variant. Thereafter `lo = mid` executes only inside the `projectedHealth >= healthFloor`
  branch. Therefore `cSafe` has *always* been directly evaluated and passed — it is never
  interpolated or inferred.
- **This invariant survives non-monotonic health.** If `healthCalculator` were not monotone in
  removed collateral (LlamaLend band effects being the plausible source), the search could return a
  suboptimal `cSafe`, but never an unsafe one, because `cSafe` is always a directly-tested value.
  Monotonicity is a precision assumption here, not a safety assumption. That is the right way round.
- **`hi = mid - 1` underflow is genuinely unreachable.** When `hi > lo`, `mid = lo + (hi-lo+1)/2 >=
  lo + 1 >= 1`, so `mid - 1 >= 0`. When `hi == lo`, `(hi-lo+1)/2 == 0` so `mid == lo`, and
  `predicate(lo)` holds by the invariant, so the `else` branch is not taken at all. The two cases
  are exhaustive (`hi >= lo` is preserved: `hi` is only ever set to `mid - 1 >= lo`). Confirmed by
  simulation across all-pass, all-fail, and boundary splits.
- **No overshoot into a venue revert.** Because `cSafe` always passed the predicate directly,
  imprecision can only make `cSafe` *smaller* than the true maximum (measured: up to 2.34% under at
  a 10% safe fraction, 0.17% under at a 90% safe fraction). It cannot be larger. 8 iterations is
  therefore a precision knob, not a safety knob — the correct design. The one cost of that
  imprecision is L-01.

**Casts (focus 2) — sound.**
- `-int256(mid)`: `mid <= hi = cDesired`, and `cDesired > currentCollateral` already reverted
  `DeficitExceedsCollateral` at `:406`. `currentCollateral` is a real ERC-20 balance
  (`aToken.balanceOf` / `user_state[0]`), ~1e8–1e21 in practice, versus `type(int256).max ≈ 5.8e76`.
  No wrap.
- `IMinHealth(...).MIN_HEALTH() * int256(105) / 100`: `1.1e18 * 105 = 1.155e20` (Aave),
  `1e17 * 105 = 1.05e19` (LlamaLend). Both ~56 orders of magnitude below `int256` max. No overflow,
  and both divide exactly by 100 so there is no truncation surprise.
- **`currentCollateral` and `healthCalculator`'s collateral source are the same variable.** Verified
  per venue: Aave `getCurrentCollateral` returns `aToken.balanceOf(this)` (`:548-550`) and
  `healthCalculator` reads `aToken.balanceOf(this)` (`:614`); LlamaLend returns `user_state[0]`
  (`:632-636`) and delegates to `health_calculator` over the same AMM position. This matters: it is
  what makes the checked subtraction `collateral -= uint256(-dCollateral)` at `AaveLoanManager.sol:619`
  provably non-underflowing for every `mid` the search probes. Had `getCurrentCollateral` included
  any idle collateral held outside the venue, the search would panic instead of reverting cleanly.

**`healthCalculator` manipulation (focus 3) — sound, no new lever.**
An attacker who could inflate projected health would get a larger `cSafe` and force a larger
collateral sale. Two independent reasons this yields nothing new:
1. **The value bound does not run through `healthCalculator`.** Step 3 (`:463`) computes
   `expectedDebt = getCollateralValue(c) * MIN_SWAP_OUT_BPS / 10000` from the *Chainlink* oracle via
   `OracleLib` (`AaveLoanManager.sol:765`, `LlamaLoanManager.sol:773`), with the freshness gate
   already run by `rebalance()` → `loanManager.checkOracleFreshness()` (`Zenji.sol:642`). Whatever
   `c` turns out to be, the vault receives ≥ 95% of Chainlink-implied value for it. An inflated
   `cSafe` changes the *size* of the sale, not its *price*.
2. **The size is bounded above by `cDesired` regardless.** `c = min(cDesired, cSafe)`, and
   `cDesired = quoteCollateralForDebt(deficit)`. So the only size lever is `deficit` — which is the
   already-accepted H-01 vector, not a new one. `cSafe` can only ever *reduce* the sale below what
   the pre-change code would have attempted.
3. Aave's projection reads Aave's own Chainlink feeds (not in-tx manipulable); LlamaLend's reads the
   EMA-smoothed Curve AMM oracle. In both cases the venue's own post-removal check at
   `AaveLoanManager.sol:246` / `LlamaLoanManager.sol:287` reads the *same* basis, so the backstop
   moves with any manipulation — it is not independent, and should not be relied on as an
   independent check. It is not: the independent check is the Chainlink floor in (1).

**Partial-progress economics and H-01 (focus 4) — the accepted-risk analysis still holds; the change
narrows it slightly.**
- **Per-call damage bound is strictly tighter than before.** Pre-change, the maximum collateral a
  manufactured deficit could extract in one call was the largest `c` satisfying
  `health(c) >= MIN_HEALTH` — reachable because the attacker chooses `deficit` and can size it
  precisely off-chain. Post-change it is the largest `c` satisfying
  `health(c) >= 1.05 * MIN_HEALTH`, which is strictly smaller. The change removes the attacker's
  need to size precisely (a convenience), not their reach (a capability).
- **Bounty is not farmable per tick.** `processRebalanceBounty` sets
  `feesAtLastRebalance = accumulatedFees` on every rebalance (`Zenji.sol:661-665`), so the first
  tick drains the pool and subsequent partial ticks pay ~0. Plan failure mode 4 is correctly
  discharged. `withdrawFees` deliberately does not reset the checkpoint (M-05 comment,
  `Zenji.sol:786-789`), so there is no side channel to re-arm it.
- **Multi-tick fee bleed does not compound.** Total collateral sold across N partial ticks is
  bounded by what closes the deficit (repay capped at `deficit`, `:471`), so swap-fee volume is
  approximately the same whether it is taken in one bite or N. The extra ticks cost the *attacker*
  gas, not the vault fees. The one unbounded-count vector — repeated just-above-dust deficits —
  is bounded by the `$1` dust floor at `:293` and is pre-existing, not introduced here.
- **`MIN_PROGRESS_BPS` is a relative floor** (10% of `cDesired`, itself attacker-influenced via
  `deficit`), so it is not a defence against grinding — it is a keeper-economics guard. That is what
  it is documented as, and the actual grinding bound remains the dust floor plus H-01's cost
  asymmetry. No misrepresentation in the NatSpec.
- **Conclusion**: the doc-comment claim at `:342-344` — *"the safe-removal cap does not change this
  analysis: a manufactured deficit now yields a bounded partial sale (still floored at
  `MIN_SWAP_OUT_BPS`) rather than a revert"* — is accurate. The stale part is in the audit file, not
  the code (see I-02). None of the four revisit conditions in `AUDIT_CoverageRebalance_v2.md` are
  tripped by this change.

**`CoverageDeficitTooLarge` as a DoS surface (focus 5) — sound, strictly more permissive than before.**
- The new revert fires iff `cSafe < 0.1 * cDesired`. The **pre-change** code reverted (`HealthTooLow`
  from the venue) whenever `cSafe < cDesired` — a strictly larger set of states. So every state that
  now reverts already reverted, and a wide band of states that used to revert now succeed. There is
  no new denial surface; the change is a net liveness improvement.
- **Arm dispatch limits the blast radius.** `Zenji.rebalance()` (`:676-702`) is an if/else-if chain:
  arm 3 runs only when `!ltvOutOfBand && ratioTooLow`. An arm-3 revert therefore cannot block LTV
  rebalancing (arms 1/2 take priority and would have run instead). The only work denied is arm-3
  work that, by construction, could not safely proceed.
- **`setIdle`/`unIdle` still recovers from every reachable state.** The states this revert can
  produce are exactly the pre-existing "insufficient health headroom" states, for which the
  operational mitigation was already `setIdle(true)/setIdle(false)`; nothing about the new code path
  mutates state before reverting (`:446-449` precedes `removeCollateral` at `:449`), so the recovery
  path is untouched.
- **The revert is atomic and state-free.** Both the `CoverageDeficitTooLarge` path and any venue
  revert occur before the first state mutation, so a failed rebalance leaves no partial state — plan
  failure mode 1's *"a revert is still safe (no state change)"* is confirmed, not assumed.

**Preserved guards (focus 6) — all confirmed to bind on the PARTIAL path, not just the full path.**
- **C-01 `MIN_SWAP_OUT_BPS` floor** (`:463-466`): computed as
  `getCollateralValue(c) * 9500 / 10000` using the *actual* `c` that was removed, not `cDesired`.
  It therefore scales down correctly with a partial step and binds identically. This is the one that
  most easily could have been left keyed to `cDesired`; it was not.
- **`CoverageDidNotImprove` postcondition** (`:478-484`): unchanged and unconditional — it runs on
  every path that reaches step 5, partial or full. A partial step that fails to raise the ratio
  still reverts, which is what makes the multi-tick convergence argument sound rather than a hope.
- **Repay cap at `deficit`** (`:471`): `toRepay = received < deficit ? received : deficit`,
  unchanged. On a partial step `received < deficit` naturally, so the cap is inert but harmless.
- **Dust floor** (`:293`): unchanged, still `deficit <= 10 ** debtAsset.decimals()`.
- **Surplus handling** (`:471-476`): unchanged — surplus stays at the vault, not redeployed, so the
  `lastStrategyBalance` fee-accrual baseline is untouched on the partial path exactly as on the full
  path.
- **`DeficitExceedsCollateral`** (`:405-407`): unchanged, and still ordered *before* the search,
  which is what bounds every `mid` the search probes.

**Gas / griefing (focus 7) — no block-gas or griefing concern.** The iteration count is a
compile-time constant with no attacker-controlled multiplier, `rebalance()` executes exactly one arm
per call, and all 9 added calls are `view`. The concern is keeper cost, not availability — see L-02.

---

## Summary

The core of this change — the binary search — is correct, and correct for the right reason: safety
rests on the directly-tested invariant *"`cSafe` always passed the predicate"* rather than on an
assumed monotonicity property of an external venue's health function. That makes it robust to
LlamaLend band effects, and it means every error in the search degrades toward under-removal.

The four Low findings are all "make the good design fully realise its intent" items rather than
defects: L-01/L-02 recover the exact common case and 7 of 9 view calls with one patch, L-03 asks the
margin to be sized against the risk it names (and to fail soft if a projection reverts), and L-04
asks the production interface to state a production requirement.

**Ship it.** Take the L-01/L-02 patch first — it is three lines, removes the only behaviour
regression on the previously-clean path, and cuts the gas cost the plan asked to be measured.
