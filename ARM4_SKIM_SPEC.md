# Spec — Arm 4 rewrite: skim the surplus into collateral

**Status**: spec, not implemented.
**Replaces**: the borrow-and-deploy design in `ZenjiCoreLib.rebalanceCoverageDown`.
**Context**: `ARM4_VERIFICATION_PLAN.md` (the bug), `AUDIT_Branch_Full.md` L-01, and
`COVERAGE_REBALANCE_FIX_PLAN.md` (the symmetric arm-3 fix this mirrors).
**Scope**: `ZenjiCoreLib.rebalanceCoverageDown` + its one call site. No interface change, no
loan-manager change.

---

## 1. Why the current design cannot work

Arm 4 fires when `coverage = S/D > 1 + DEADBAND_SPREAD` (103%) — the strategy is worth more than the
debt, i.e. the vault made money. Today it borrows more and **deposits the proceeds into the same
strategy**, raising `S` by exactly what it raised `D`. Post-call coverage is `(S+X)/(D+X)`, not the
intended `S/(D+X)`. The recurrence `c' = 2.03 - 1.03/c` has fixed points 1.00 and 1.03, so it
converges asymptotically TO the band edge and never crosses it.

Measured on live forks: WBTC/Llama 105.82% -> 103.28% after **60** `rebalance()` calls, still out of
band. XAUT/Aave sawtooths against arm 2 and never clears either.

Correct sizing alone does not rescue it: `X = (S - r·D)/(r-1)` implies borrowing **2.33x** current
debt at 110% coverage and **10.7x** at 135%, so the LTV ceiling always binds. **A coverage surplus
cannot be closed by levering up.** The amount that is actually wrong is the surplus itself, so that
is what should move.

**This bug is pre-existing and live on `main`** — `rebalanceCoverageDown` is byte-identical between
`main` and the feature branch. The deployed fleet has it today.

## 2. The design

Skim the surplus out of the strategy, convert it to collateral, and post it to the lender.

This is the exact mirror of the shipped arm-3 fix: arm 3 funds from collateral to reduce `D`;
arm 4 skims to collateral to reduce `S`. Both move the smallest sufficient amount.

### 2.1 Target PARITY (1.00), never the band edge

| Target | X at the moment of trigger | Result |
|---|---|---|
| Band edge 1.03 | `S - 1.03·D` = **0** | **DEGENERATE** — skims nothing, re-triggers immediately. Same class as the bug being fixed. |
| **Parity 1.00** | `S - D` = **0.03·D** | Lands at 1.00 in ONE call, maximum headroom before re-trigger |

Targeting the edge is the trap. At the trigger point the surplus above the edge is zero by
definition. Arm 3 already targets parity for the same reason (it repays the full deficit, not down
to the band edge) — keep them symmetric.

At the trigger this skims exactly 3% of debt value, which is the "sell 3%" rule of thumb; the
formula generalises correctly for larger surpluses (110% -> skim 0.10·D, 135% -> skim 0.35·D), all
landing at 1.00 in a single call.

### 2.2 Algorithm

`ZenjiCoreLib` runs under DELEGATECALL, so `address(this)` is the vault.

```
debt = loanManager.getCurrentDebt();            if (debt == 0)  return S;
S    = yieldStrategy.balanceOf();               if (S <= debt)  return S;
surplus = S - debt;                             // debt-denominated
if (surplus <= dust) return S;                  // same dust convention as arm 3

startCoverage = S * precision / debt;

// 1. Skim the surplus out of the strategy (debt asset out).
received = yieldStrategy.withdraw(surplus);
//    Slippage-check the withdrawal the way arm 3 checks its own legs.

// 2. Convert debt -> collateral, ORACLE-FLOORED. See S 2.3.
debtAsset.safeTransfer(address(swapper), received);
collateralOut = swapper.swapDebtForCollateral(received);
if (collateralOut < floor) revert SwapperUnderperformed(floor, collateralOut);

// 3. Post it as collateral.
collateralAsset.safeTransfer(address(loanManager), collateralOut);
loanManager.addCollateral(collateralOut);

// 4. POSTCONDITION — arm 4 has never had one. This is the check whose absence let the
//    current bug survive three audits.
newCoverage = yieldStrategy.balanceOf() * precision / loanManager.getCurrentDebt();
if (newCoverage >= startCoverage) revert CoverageDidNotImprove();
```

### 2.3 The oracle floor is mandatory (audit C-01, do not repeat it)

This is a DIRECT `ISwapper` call from the vault, so it bypasses the loan managers'
`SwapperUnderperformed` check — exactly the Critical found on arm 3. The swappers carry no
end-to-end floor of their own and document the loan manager's check as the hard floor.

Reuse the pattern already in `Zenji._swapRemainingDebtToCollateral`, including its subtlety:
the floor is `max(swapper.slippage(), slippageOverride * 2)` because `loanManager.getDebtValue`
reads a direct oracle while the swapper traverses a multi-hop path, so the two can legitimately
diverge by ~2x slippage on a fair swap. A naive floor rejects good swaps.

## 3. Convergence and the arm-1 handoff

Post-skim: `S = D` (coverage 1.00, in band), `D` unchanged, `C` up by the swapped value. So **LTV
falls**, and the next tick typically dispatches to arm 1 (LTV-low), which re-levers to target.

Arm 1's `enforceCoverageAfterIncrease` guard **passes**, because coverage is now ~1.00, not the
0.74 that deadlocked arm-3 partial progress. That deadlock is the thing to check for explicitly in
testing, not assume away.

Two calls total: skim, then re-lever. Both bounded, neither iterative.

## 4. Economic note

Skimming realises profit into the **collateral asset** — the denomination the vault's shares are
priced in. NAV per share is unchanged (less swap cost); the composition moves from the yield leg to
the collateral leg, which is the safer leg. If arm 1 then re-levers, the value is redeployed.

The round trip costs a debt->collateral swap now and a borrow+deposit later. **This must be measured,
not assumed** — the arm-3 partial-progress attempt died on exactly this kind of unmeasured cost.

## 5. Failure modes

| # | Risk | Guard |
|---|---|---|
| 1 | Swap sandwiched / underperforms | `SwapperUnderperformed` floor (S 2.3). Revert; no state change. |
| 2 | **Aave supply cap** — `addCollateral` reverts. XAUT cap is 25,000 with ~14,320 supplied; a large skim could breach it | Cap the skim at remaining supply headroom, or surface a distinct error. **Must be handled — a revert here bricks arm 4 exactly when the vault is most profitable.** |
| 3 | Strategy cannot withdraw `surplus` (LP liquidity) | Slippage check on the withdrawal; revert rather than accept a bad exit |
| 4 | LlamaLend band/dust assertion on `addCollateral` | Probe as we did for `removeCollateral`; revert, never auto-escalate |
| 5 | Skim pushes LTV below `lowerBand`, arm 1 then blocked | Expected and fine — arm 1's coverage guard passes at ~1.00. **Verify on a fork.** |
| 6 | Repeated skim/re-lever cycling burns fees | Measure the round trip (S 4). If material, consider skimming only down to just inside the band rather than to parity |
| 7 | Dust surplus | Dust floor, same convention as arm 3 |
| 8 | Postcondition satisfiable while value leaks | Coverage is a ratio; the VALUE bound is the S 2.3 floor. Same lesson as arm-3 C-02 — do not mistake one for the other |

## 6. Test plan (both venues)

1. **One-call convergence**: coverage >103% -> `rebalance()` -> coverage at ~1.00 and
   `strategyDebtRebalanceNeeded()` false. Contrast with today's 60-call failure.
2. **Large surplus**: 135% coverage converges in ONE call.
3. **Strategy balance decreased, debt unchanged, collateral increased** — the defining signature.
4. **LTV falls, then arm 1 re-levers on the next call without reverting** (failure mode 5).
5. **Oracle floor**: mock an underperforming swapper, assert `SwapperUnderperformed`, assert no
   state mutation.
6. **Aave supply-cap case** (XAUT): drive a skim that would breach the cap; assert the chosen
   behaviour from failure mode 2, not an opaque revert.
7. **Round-trip cost**: measure NAV across skim + re-lever. Report the number even if unflattering.
8. **No oscillation** between arm 4 and arms 1/2 over several ticks.
9. Full regression: 661 unit (runs with NO RPC), three fork suites, `forge build --sizes`
   (margins must stay >= 1,536 / 1,468 / 1,489).

## 7. Size budget

Lands in `ZenjiCoreLib` (delegatecalled, ~12.9 KB spare). The call site needs `collateralAsset` and
`swapper`, which arm 3 already passes — check whether the arity actually changes before assuming a
vault cost.

## 8. Audit scope

`rebalanceCoverageDown` + call site. Focus: the S 2.3 floor (is it the right basis and does it bind
on the real swappers?); the postcondition (ratio vs value, per arm-3 C-02); supply-cap handling;
whether a manufactured surplus can now force a collateral swap — note the arm-4 probe found
**no upward manipulation vector** (`vpBased` tracks `get_virtual_price()`, which swaps do not move),
so re-confirm that still holds once the arm has a swap in it.

## 9. Open decisions

- Skim to parity (1.00) or to just inside the band? Parity maximises headroom; band-edge minimises
  the swapped amount. Spec says parity; revisit if S 6.7 shows the round trip is expensive.
- Aave supply-cap behaviour: cap the skim, or revert with a distinct error?
- Should the skimmed collateral be posted to the lender at all, or held in the vault as idle
  collateral? Posting reduces LTV and invites the arm-1 handoff; holding does not.
