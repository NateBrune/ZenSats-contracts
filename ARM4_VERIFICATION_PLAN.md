# Verification Plan — Arm 4 (coverage > 1 + deadband) + full-branch audit

**Status**: plan. Arm 4 (`ZenjiCoreLib.rebalanceCoverageDown`) is **unchanged this session** — it is
pre-existing code that has never been fork-tested and was not in scope of the three prior audits.

---

## 1. What arm 4 does

Fires when `coverage = strategyBalance / debt > 1 + DEADBAND_SPREAD` (103%). It borrows more debt and
deploys it into the strategy, which pulls `S/D` back toward parity (adding equal amounts to
numerator and denominator moves a ratio > 1 downward).

Bounded by the lesser of two ceilings:
```
targetDebtAtMaxRatio = strategyBalance * P / maxStrategyRatio     // coverage ceiling (1 + spread)
maxDebtByLtv         = collateralValue * upperBand / P            // LTV ceiling (target + spread)
borrowAmount         = min(required, ltvRoom)
```
Call site passes `maxStrategyRatio` and `upperBand`, so it cannot lever past the LTV deadband.
Deposit is slippage-checked (`InsufficientDeposit`).

## 2. Why it needs verification

- **Zero fork coverage.** Only `test_rebalance_ratioHigh_withinDeadband_borrowsMore` in
  `Zenji.t.sol`, which is mock-based. Never exercised against real Aave/LlamaLend/Curve.
- **Not in prior audit scope.** `AUDIT_CoverageRebalance*.md` and `AUDIT_PartialProgress.md` all
  scoped arm 3 only.
- **It borrows on live capital.** An arm-3 failure sells collateral; an arm-4 failure LEVERS UP.
- **Asymmetry vs arm 3**: arm 3 now has a `CoverageDidNotImprove` postcondition. Arm 4 has none —
  only the deposit slippage check. Nothing asserts the ratio actually moved toward parity.
- **Prior form.** Every arm-3 belief in this session that rested on arithmetic rather than a fork run
  turned out wrong at least once. Arm 4 currently rests entirely on arithmetic.

## 3. Hypothesis to test (do NOT assume)

Manipulating coverage UPWARD may be much harder than downward.
`BaseCurveStakeDaoStrategy.balanceOf()` is `min(vpBased, exitBased)`; `vpBased` is clamped to
+/-`MAX_VP_DEVIATION` (0.5%) around the cache. Since the result is a `min`, the clamped leg CAPS the
upward direction — so a spot skew cannot push coverage far above the cache, and 0.5% is well inside
the 3% deadband. If true, arm 4 is largely unreachable by manipulation and H-01's mirror does not
exist. **This is the key thing to confirm or refute.** Note the clamp is bypassed after
`MAX_VP_STALENESS` (1 day), which is the obvious hole to probe.

## 4. Tests (both venues: WBTC/Llama and XAUT/Aave)

1. **Convergence**: drive coverage above 103% (inflate the strategy's staked share balance), call
   `rebalance()`, assert coverage returns to band and `strategyDebtRebalanceNeeded()` clears.
2. **No over-leverage**: assert final LTV <= `upperBand` and health >= `MIN_HEALTH` afterwards.
3. **LTV-bounded case**: construct a state where `ltvRoom < requiredBorrow`, assert it borrows the
   capped amount, does not revert, and leaves coverage still above band (partial by design) —
   confirm this does NOT deadlock the way arm-3 partial progress did (arm 4 RAISES LTV, so arm 1 is
   not triggered; verify).
4. **Ratio direction**: assert coverage strictly DECREASED. Arm 4 has no postcondition, so this is
   the check that would have caught an arm-3-class bug here.
5. **Upward-manipulation probe** (hypothesis in S 3): attempt to push coverage > 103% via pool skew
   alone and report whether the VP clamp prevents it.
6. **Interaction with arm 3**: after arm 4 runs, assert the vault is not left in a state where arm 3
   immediately fires (oscillation between arms).

## 5. Full-branch audit scope

Separately, audit the ENTIRE branch diff (`git diff main..HEAD`), not just arm 4. Prior audits
covered arm 3 at two points in time; the branch has moved since, and three items have never been
audited at all:
- `7bea682` NEW-02 (idle-debt spend + early exit + accumulatedFees reserve) — **never audited**
- `699b78a` all-or-nothing arm 3 + `CoverageDeficitTooLarge` — audited only in its partial-progress
  form, which was then removed
- `938f61e` `UsdtCrvUsdLpStakeDaoStrategy` + the XAUT gold vault — **never audited**
- `7141087` pmUSD retirement, including test repoints to production vault impls
- `e5065aa` LlamaLoanManager `MIN_HEALTH` on `removeCollateral` (M-01)

## 6. Deliverables

- `test/` arm-4 fork tests on both venues
- `AUDIT_Branch_Full.md` — findings by severity, explicitly separating NEW from
  already-accepted (H-01, M-02 liveness, L-03, L-04)
- Ship / don't-ship for the branch as a whole
