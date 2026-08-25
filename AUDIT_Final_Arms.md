# Rebalance Arms — Final Audit (Coverage Up/Down, Scope: ZenjiCoreLib arms 3/4 + Zenji.rebalance() dispatch + adjustLtv arms 1/2)

Scope: `ZenjiCoreLib.rebalanceCoverageUp` (arm 3), `ZenjiCoreLib.rebalanceCoverageDown` (arm 4),
`Zenji.rebalance()` dispatch, `ZenjiCoreLib.adjustLtv` (arms 1/2).

Already-accepted risks (H-01 manufactured deficit, M-02 arm-revert liveness, L-03 relative health
floor, L-04 IMinHealth bypass) are excluded per instructions.

---

## Findings

### [M-NEW-1] Arm 3's "one-call parity" guarantee does not hold — a bounded swap shortfall produces a genuine partial repay that can still hand a still-out-of-band position to arm 1's blocking guard

**Severity**: Medium
**Location**: `src/libraries/ZenjiCoreLib.sol:504-527` (`rebalanceCoverageUp`, steps 3-5)

**Description**

The function's own NatSpec (L453-466) states the all-or-nothing removal design exists specifically
because partial progress was "measured and rejected": a bounded partial correction previously dragged
LTV out of `lowerBand` while leaving coverage still below the exit threshold, handing the next
`rebalance()` call to arm 1, whose `enforceCoverageAfterIncrease` guard then refused because coverage
was still too low — a permanent revert loop broken only by manual `setIdle`/`unIdle`.

The fix that shipped (the `healthCalculator` feasibility probe at L482-488) only gates the **removal
size** (`cDesired`, sized for the *full* `deficit`) — it is genuinely all-or-nothing on that axis. But
the **swap outcome** is not similarly all-or-nothing:

```solidity
uint256 expectedDebt = (loanManager.getCollateralValue(c) * MIN_SWAP_OUT_BPS) / 10000;  // L504
...
uint256 received = swapper.swapCollateralForDebt(c);
if (received < expectedDebt) revert SwapperUnderperformed(expectedDebt, received);       // L507
...
uint256 toRepay = received < deficit ? received : deficit;                               // L511
```

`expectedDebt` is a 95%-of-oracle-value floor on the *collateral spent*, not a check that `received >=
deficit`. `cDesired` itself is sized purely from `swapper.quoteCollateralForDebt(deficit)`, which (per
every swapper implementation, e.g. `CurveTwoCryptoSwapper.quoteCollateralForDebt`) grosses up the
**oracle** value of `deficit` by the swapper's flat, self-reported `slippage()` tolerance — it is not a
simulation against the pool's actual depth/curve. In a market where real execution is worse than the
self-reported slippage tolerance (thin liquidity, size-dependent price impact — the exact condition the
adjacent NatSpec cites for XAUT/Aave: "a 35% loss took one successful step"), `received` can land
anywhere in `[expectedDebt, deficit)`, i.e. up to ~5% short of `deficit` (bounded by `MIN_SWAP_OUT_BPS`
against the collateral's oracle value, not against `deficit`). The call does **not** revert in this
case — it silently repays `toRepay = received < deficit`, coverage strictly improves (postcondition at
L527 only requires `newCoverage > startCoverage`), and the call returns success.

**Impact**

- The full `cDesired` collateral (sized for the *complete* deficit) has already been removed from the
  loan manager, but only a partial repay lands. As shown in the docstring's own measured example, LTV
  can fall faster than coverage rises during this arm. If the shortfall leaves coverage still below the
  0.97 exit band on a call where LTV also crosses `lowerBand`, the next `rebalance()` call routes to arm
  1 (LTV checked first in `Zenji.rebalance()`), whose `enforceCoverageAfterIncrease` guard can refuse
  while coverage is still low — reproducing the exact deadlock class the all-or-nothing removal fix was
  built to eliminate, just entered via the swap-shortfall path instead of the removal-sizing path.
- This also means the docstring's "arm 3 must reach parity in ONE call" premise (relied on by
  `rebalance()`'s dispatch-order NatSpec) is not actually enforced by the code — it's a best-effort
  outcome, not a guarantee.
- Not a fund-loss vector (the value bound is intact — `MIN_SWAP_OUT_BPS` still floors the swap), and the
  operational mitigation is the same as accepted M-02 (`setIdle`/`unIdle`), so this is scoped as a
  liveness/design-guarantee gap, not new risk to principal.

**Recommendation**

Either (a) treat a `received < deficit` outcome as informative and have arm 3 emit an event / distinct
return signal so the keeper knows a follow-up call is needed before LTV drifts further, or (b) size
`cDesired` more conservatively (probe expected pool output, not just oracle value) so the "one-call
parity" claim in the docstring is actually true, or (c) soften the docstring's claim to match the real
guarantee ("parity in one call absent swap underperformance beyond `MIN_SWAP_OUT_BPS`") so the dispatch-
order reasoning in `rebalance()` isn't built on a false premise.

---

### [L-NEW-1] Arm 3 trusts the swapper's return value instead of a balance delta, inconsistent with the L-01 fix applied everywhere else in the codebase

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:505-507` (`rebalanceCoverageUp`, step 3)

**Description**

```solidity
collateralAsset.safeTransfer(address(swapper), c);
uint256 received = swapper.swapCollateralForDebt(c);          // trusts the return value
if (received < expectedDebt) revert SwapperUnderperformed(expectedDebt, received);
```

Arm 4 (`rebalanceCoverageDown`, L675-679) and `Zenji._swapRemainingDebtToCollateral` both explicitly
measure the swap output as a vault-side balance delta rather than trusting the swapper's return value,
and arm 4's comment cites the reason directly: *"the return value is the swapper's own claim about a
swap it just performed, and the swapper is rotatable by governance behind a timelock"* (a prior audit
finding, L-01). Arm 3 does not apply the same fix — `received` and the subsequent `toRepay` (L511) and
`debtAsset.safeTransfer(loanManager, toRepay)` (L513) are computed entirely from the untrusted return
value.

**Impact**

Low under the current swapper set (Curve/Uniswap wrappers return the actual pool-reported output, which
matches balance for standard ERC20s). But it is a real defense-in-depth gap relative to the codebase's
own stated threat model for this exact call site: if a future or rotated swapper's return value diverges
from the amount actually credited to the vault (e.g. a multi-hop router with an intermediate fee, a
non-standard token, or simply a bug), `toRepay` could exceed the vault's real debt-asset balance,
causing `safeTransfer` to revert (DoS on that `rebalance()` call, recoverable on retry) — or understate
it, silently leaving a smaller-than-computed coverage improvement.

**Recommendation**

Mirror arm 4: measure `received` as `debtAsset.balanceOf(address(this))` before/after the swap, the same
way `L-01` was fixed there.

---

## Verified Sound

1. **Arm 4 convergence is exact, algebraically.** `rebalanceCoverageDown` withdraws *exactly* `surplus`
   (deliberately unpadded, L638-654) and never touches `D` in steps 1-3 (posting failures only affect
   how much of the proceeds land as collateral, not the coverage ratio). `newCoverage` is computed purely
   from `yieldStrategy.balanceOf()` (which fell by the withdrawal *request*, i.e. `surplus`) over the
   unchanged `debt`, so `newCoverage == 1.0000` in one call regardless of swap/posting outcome — this
   correctly avoids the previously-shipped non-convergent `c' = 2.03 - 1.03/c` recurrence, since that bug
   came from re-depositing into the strategy (raising both S and D together); arm 4 never does that.
2. **Both oracle floors use the correct basis/units.** Arm 3's `getCollateralValue(c) * 9500/10000`
   compared against debt-asset `received`, and arm 4's `getDebtValue(received) * effectiveSlippage`
   compared against `collateralOut`, both exactly mirror the pattern the loan managers themselves use
   internally (`AaveLoanManager`/`LlamaLoanManager` `_getCollateralValue`/`_getDebtValue` usage at
   comparable call sites) — units are consistent, not swapped.
3. **Arm 4's supply-cap retry loop cannot corrupt the coverage invariant.** The postcondition (L700-708)
   is computed from strategy balance and debt only; a fully-blocked `addCollateral` (posted = 0) still
   leaves the postcondition correctly satisfied because the strategy withdrawal in step 1 already
   happened unconditionally.
4. **Idle-debt-first repay in arm 3 (step 0, L406-426) is strictly correct**: it reduces `D` without
   touching `S`, so it can only improve coverage, and it correctly reserves `accumulatedFees` before
   spending idle balance.
5. **Dust floors are consistent** between arm 3 (`deficit <= 10**decimals`) and arm 4
   (`surplus <= 10**decimals`), and applied both pre- and post-idle-repay in arm 3.
6. **`Zenji.rebalance()` dispatch is correctly single-branch** (LTV checked first, then coverage-low,
   then coverage-high — `else if` chain, exactly one arm runs) and `nonReentrant` covers the whole call;
   no reentrancy path was found across the strategy/swapper/loan-manager external calls in this scope
   (delegatecall context is used correctly — `address(this)` resolves to the vault throughout
   `ZenjiCoreLib`, consistent with how state is read/written).
7. **LTV direction for arm 3, verified by algebra** (not just the docstring's empirical claim): with
   `c_val ≈ toRepay / 0.95 > toRepay`, `d(LTV)` after arm 3 has the sign of `(LTV_current - toRepay/c_val)
   ≈ (LTV_current - 0.95)`. For any realistic vault LTV (well under 95%), arm 3 lowers LTV — consistent
   with the "both coverage arms lower LTV, cooperating with arm 1 rather than deadlocking on the high
   side" claim in the arm 4 NatSpec, and with the measured 60%→56.78% example cited for arm 3.
8. **`adjustLtv` arms 1/2 (in scope for the handoff check only)**: the `enforceCoverageAfterIncrease`
   guard on the borrow path and the `105%` withdraw padding + `minReceived` slippage check on the repay
   path behave as documented; no additional convergence issue found beyond the already-accepted L-03/L-04
   and the arm-3-interaction issue above.

---

## Ship / Don't-Ship

**Ship**, with the two findings above logged for a follow-up patch. Neither is a fund-loss vector: M-NEW-1
is a liveness/design-guarantee gap bounded by the existing `MIN_SWAP_OUT_BPS` value floor and recoverable
via the same `setIdle`/`unIdle` path already accepted for M-02; L-NEW-1 is a defense-in-depth
inconsistency with no exploit under the current swapper set. Recommend fixing L-NEW-1 (small, mechanical,
mirrors an existing pattern) before the next release, and tracking M-NEW-1 alongside M-02 as a known
liveness edge case with the same mitigation.
