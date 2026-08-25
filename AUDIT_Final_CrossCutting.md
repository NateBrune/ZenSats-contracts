# Cross-Cutting Audit — Seams, Docs-vs-Code, Deploy Readiness

**Scope**: NOT a re-audit of the rebalance arms/strategy/loan-manager internals (covered elsewhere).
Focus: consistency between prose (specs/audits/README/NatSpec) and code, vault-wide NAV
double-count/stranding, keeper/CRE integration, and deploy readiness for the live 3-vault fleet.
**Method**: read-only, static.

---

## Findings

### [MEDIUM] CRE keeper workflow does not differentiate the new revert surfaces — contradicts the accepted monitoring runbook

**Location**: `keeper/zen-keep/my-workflow/workflow.ts:82-95`; guidance in
`AUDIT_CoverageRebalance_v2.md:635-644` ("Monitoring").

The accepted-risk writeup explicitly tells operators: alert on `CoverageDeficitTooLarge` (actionable
page), treat `SwapperUnderperformed` as retryable (not a page), and there's no "repeated partial
success" signature to watch for anymore. None of that is implemented. `processVault()` in the CRE
workflow treats every failure mode identically:

```ts
if (writeResult.txStatus !== TxStatus.SUCCESS) {
  throw new Error(`[${label}] Rebalance TX failed: ${writeResult.errorMessage || writeResult.txStatus}`)
}
```

A `SwapperUnderperformed` front-run (expected, transient, per `AUDIT_CoverageRebalance_v2.md` NEW-03)
and a `CoverageDeficitTooLarge` (needs an operator to run `setIdle`/`unIdle`) both surface as the same
generic thrown error from `onCronTrigger`, which `hadError`-gates the whole cron tick summary. There
is no revert-reason decoding anywhere in `workflow.ts` or `ZenjiRebalanceReceiver.sol` — the receiver
doesn't even try/catch `vault.rebalance()`, so any revert bubbles up as an opaque TX failure with
whatever `errorMessage` the RPC/CRE layer happens to surface.

**Why it matters**: the accepted-risk analysis for H-01 depends on operators reacting correctly and
promptly to `CoverageDeficitTooLarge` specifically. As deployed, an operator monitoring only workflow
alerts cannot distinguish "ignore, will retry next tick" from "page, vault needs `setIdle`/`unIdle`
now" — every keeper failure looks the same severity. `CoverageSkimPosted(available, posted)` (arm 4)
is similarly not surfaced anywhere in the workflow or `monitor/` app — grepped, no hits.

**Fix**: decode the revert selector in `_processReport`'s failure path (or have the receiver
try/catch `vault.rebalance()` and re-emit a typed failure event carrying the selector), and have
`workflow.ts` branch on it — swallow/retry on `SwapperUnderperformed`, escalate on
`CoverageDeficitTooLarge`, ignore on `RebalanceNotNeeded` (race between the read and the write).

---

### [MEDIUM] XAUT deploy script never authorizes the strategy on `CrvToCrvUsdSwapper` — CRV harvest is permanently deferred

**Location**: `script/DeployXautAaveUsdtStakeDao.s.sol` (missing call); compare
`script/DeployWbtcLlamaUsdtStakeDao.s.sol:116` and `script/DeployWstEthLlamaUsdtStakeDao.s.sol:122`.

Both LlamaLend deploy scripts call `crvSwapper.setAuthorizedCaller(address(strategy))` after
deploying the strategy. The XAUT/Aave script deploys the same `CrvToCrvUsdSwapper` and the same
`UsdtCrvUsdLpStakeDaoStrategy` family, but **never calls `setAuthorizedCaller`**. `authorizedCaller`
defaults to `address(0)` and nothing else sets it.

`CrvToCrvUsdSwapper.swap()` gates on `msg.sender == authorizedCaller` (explicitly documented at
`src/swappers/reward/CrvToCrvUsdSwapper.sol:99`, referencing a prior finding L-05: *"treat address(0)
as 'not yet configured' — fully locked until setAuthorizedCaller is called"*). Every call from the
strategy's harvest path (`BaseCurveStakeDaoStrategy._claimAndSwapRewards` →
`transferAndSwapCrv` → `crvSwapper.swap`) will therefore revert `Unauthorized`.

This does **not** revert `harvestYield()` outright — `_claimAndSwapRewards` wraps the swap in a
try/catch (M-06) and emits `CrvSwapDeferred(crvBalance)` on failure, leaving the CRV sitting at the
strategy for "the next harvest to retry." But nothing ever fixes `authorizedCaller`, so every harvest
defers forever: CRV rewards accumulate at the strategy contract, uncompounded, silently, until an
operator notices and manually calls `crvSwapper.setAuthorizedCaller(strategy)` post-deploy.

**Impact**: as scripted, the XAUT vault's CRV emissions never compound — a real, silent yield
underperformance for depositors, with no on-chain revert to surface it (only a `CrvSwapDeferred`
event nobody is watching per the finding above).

**Fix**: add `crvSwapper.setAuthorizedCaller(address(strategy));` to
`DeployXautAaveUsdtStakeDao.s.sol`, matching the other two scripts.

---

### [MEDIUM] `DEPOSIT_CAPS.md`'s advised caps are not applied by any deploy script — all three live vaults launch with `depositCap = 0` (unlimited)

**Location**: `deployments/DEPOSIT_CAPS.md`; `src/ZenjiStorage.sol:72` (`depositCap` default 0);
none of `script/DeployWbtcLlamaUsdtStakeDao.s.sol`, `DeployWstEthLlamaUsdtStakeDao.s.sol`,
`DeployXautAaveUsdtStakeDao.s.sol` call `setParam(2, ...)`.

`DEPOSIT_CAPS.md` derives caps (18 WBTC, 725 wstETH, 95 XAUT) from measured exit liquidity and is
explicit that the shared crvUSD/USDT yield pool's exit budget must be split three ways across the
fleet — exceeding it means a real exit cannot happen within the swapper's slippage budget. None of
the three live deploy scripts set `depositCap`; `Zenji.sol:383` treats `depositCap == 0` as
unlimited. So today, absent a manual post-deploy `setParam` call, deposits are unbounded and can
exceed the measured-safe exit liquidity for any of the three vaults, and in aggregate across the
fleet on the shared pool.

**Operational consequence**: lowering the cap from unlimited is immediate (no timelock, per
`DEPOSIT_CAPS.md`'s own note and `ZenjiGovLib`'s timelock-direction rule), so this is trivially
fixable — but it requires a deliberate operator action that isn't part of the deploy flow and isn't
gated by anything on-chain. If skipped, the vault is open to deposits beyond what its own
documentation says is safe to exit.

**Fix**: either add the `setParam(2, cap)` call to each deploy script (raw values are already
computed in `DEPOSIT_CAPS.md`), or add an explicit deploy-readiness checklist step / CI assertion
that caps are applied before a vault is announced as open.

---

### [LOW / Informational] `RebalancePerformed` cannot carry the signal the monitoring runbook asks for

**Location**: `keeper/zen-keep/contracts/evm/src/ZenjiRebalanceReceiver.sol:44,73`;
`AUDIT_CoverageRebalance_v2.md:635-636`.

The monitoring guidance says: *"Alert on arm-3 rebalances (`RebalancePerformed` with coverage as the
trigger) — especially any occurring while the LP pool is materially imbalanced."* Two problems:

1. `RebalancePerformed` is emitted by `ZenjiRebalanceReceiver` (the keeper contract), not the vault,
   and only after a successful `vault.rebalance()` call.
2. Its fields are `(currentLtv, lowerBand, upperBand)` — **no coverage value, and no indication of
   which of the four arms fired.** An operator cannot use this event to identify "an arm-3 rebalance"
   at all, let alone correlate it with LP pool imbalance, without separately decoding the vault's own
   `Rebalance(oldLtv, newLtv, increased)` event and independently reading `strategyToDebtRatio()`
   around the same block.

**Fix**: either the guidance should point at `Zenji.Rebalance` plus an off-chain
`strategyToDebtRatio()` read at that block (what's actually needed), or `RebalancePerformed` should be
extended to carry the ratio that triggered it. Cheapest: correct the doc — no code change required to
ship.

---

### [Informational] `ARM4_SKIM_SPEC.md`'s pseudocode still shows the swapper's return value being measured; the shipped arm 4 code measures a balance delta

**Location**: `ARM4_SKIM_SPEC.md:66-72` vs `src/libraries/ZenjiCoreLib.sol:682-686`.

The spec's step 2 reads `collateralOut = swapper.swapDebtForCollateral(received);` — i.e., trusts the
swapper's return value. The shipped implementation (correctly, and consistent with the audit history
referenced in its own NatSpec — L-01/NEW-05) measures `collateralAsset.balanceOf(address(this))`
before and after instead, precisely because the swapper is governance-rotatable behind a timelock and
its return value is an untrusted self-report. This is exactly the class of drift called out for this
audit: `ARM4_SKIM_SPEC.md` is marked `Status: spec, not implemented` at the top, which is now stale —
it *was* implemented, and implemented more defensively than the spec's own pseudocode. Low risk since
the doc predates the code and is clearly labeled a design doc, not a behavior reference, but it should
either be updated to match the shipped balance-delta pattern or stamped `IMPLEMENTED — see
ZenjiCoreLib.rebalanceCoverageDown` so nobody mistakes the pseudocode for current behavior.

---

### [Informational] `Zenji.sol` rebalance() NatSpec's "unrepresentable" claim is narrower than it reads

**Location**: `src/Zenji.sol:621-623`.

> *"...guarded by a strict-improvement postcondition (`CoverageDidNotImprove`) that makes a repeat of
> the old non-convergent behavior unrepresentable."*

This is defensible read narrowly (the postcondition does make the specific old bug pattern — an
operation that looks corrective while moving the ratio backwards — revert instead of silently
degrading), and it matches the more careful phrasing in `ZenjiCoreLib.sol`'s own NatSpec one function
over: *"it bounds the RATIO, not value... it does NOT bound value loss."* But read in isolation (as a
future maintainer skimming `Zenji.sol` without also reading `ZenjiCoreLib.sol`'s longer comment
block) "unrepresentable" invites the conclusion that the postcondition is a value-loss bound too — it
is not; that's `MIN_SWAP_OUT_BPS`. Given this exact failure mode (a partially-true safety claim
outliving its qualifiers) is called out as a recurring problem on this branch, worth tightening the
`Zenji.sol` copy to explicitly say "ratio only" rather than relying on the reader to cross-reference
`ZenjiCoreLib.sol`.

---

### [Low, edge case] `getNetCollateralValue()` floors at zero rather than going negative

**Location**: `src/lenders/AaveLoanManager.sol:655-662`, `src/lenders/LlamaLoanManager.sol:722-731`,
consumed by `ZenjiViewHelper.getTotalCollateralValue:101`.

Both adapters clamp `collateral - debtInCollateral` at 0 when debt-in-collateral-terms exceeds
collateral. Since `getTotalCollateralValue` only ever *adds* component values, a position where debt
value exceeds collateral value (should not occur in normal operation given LTV bounds and each
venue's own liquidation mechanics, but is the direction arm 3's intermediate health dip moves toward)
would have its negative equity silently reported as `0` rather than subtracted, making NAV a slight
over-estimate in that specific scenario rather than under-estimate. Not exploitable via any path found
in this pass — flagging because it's the one place in the NAV enumeration that isn't a strict
value-preserving sum. No fix required unless the venue's liquidation threshold assumptions change.

---

## Areas Verified Sound

1. **NAV double-count / stranding across the new flows.** Walked `ZenjiViewHelper.getTotalCollateralValue`
   against arm 3's idle-debt-first spend (`ZenjiCoreLib.sol:406-437`), arm 4's skim + halving retry
   (`:645-705`), and the halving retry's pullback semantics: each component (idle collateral, idle
   debt asset, loan-manager net collateral, loan-manager raw balances, strategy balance net of
   pending fees) is counted from a mutually-exclusive location, and arm 4's `catch` branch pulls any
   un-posted collateral back to the vault (counted via idle collateral) before the loop moves on —
   never left double-homed or stranged mid-retry. No path found where value sits in two buckets at
   once or in none.
2. **`monitor/lib/strategies.ts` matches the live 3-vault fleet.** Slugs, collateral/debt decimals
   (WBTC 8, wstETH/crvUSD 18, XAUT/USDT 6), venue, and shared crvUSD/USDT pool all agree with
   `DEPOSIT_CAPS.md` and `README.md`. No stale or missing vault entries, no retired pmUSD configs
   present.
3. **`rebalanceNeeded()` vs `rebalance()` agreement.** `ZenjiRebalanceReceiver._shouldRebalance()`
   mirrors `Zenji.rebalance()`'s own gating (idle/emergencyMode/loanExists/LTV-band/ratio-band) and
   fails safe (returns `needed=false`) on a stale-oracle `catch`, matching `rebalance()`'s own
   `checkOracleFreshness()` revert-first behavior — the keeper won't spuriously report "needed" into a
   transaction that would revert on staleness. The `_processReport` re-validation before the write
   also protects against a stale off-chain decision.
4. **`DeployXautAaveUsdtStakeDao.s.sol` wiring order** (aside from the missing `setAuthorizedCaller`
   above): `initializeVault` on both the loan manager and strategy, `setVault` on the swapper, coin-
   ordering assert before strategy construction — all present and in the same order as the other two
   live deploy scripts.
5. **The self-corrected doc drift the task flagged as a pattern risk.** `AUDIT_CoverageRebalance_v2.md`'s
   own "Accepted Risk" section already corrects an earlier "SUPERSEDED by partial progress" claim in
   place (explicitly marked WRONG, with the commit that reverted it) and its "Monitoring" bullets
   already reflect the current all-or-nothing arm-3 behavior — this document is internally consistent
   with current code except for the `RebalancePerformed` signal-availability issue above.
   `COVERAGE_PARTIAL_PROGRESS_PLAN.md`'s own OUTCOME section correctly documents the rejection of
   partial progress and matches the current `ZenjiCoreLib.sol` (all-or-nothing, single
   `healthCalculator` probe, `MIN_PROGRESS_BPS` removed).

---

## Deploy-Readiness Verdict

**Not ready to open the XAUT vault to depositors as currently scripted.** Two concrete, mechanical
gaps in `DeployXautAaveUsdtStakeDao.s.sol` and the deploy flow generally:

1. Missing `crvSwapper.setAuthorizedCaller(address(strategy))` — CRV harvest silently dead on arrival.
2. No `depositCap` applied on any of the three vaults (not XAUT-specific, but XAUT is most exposed —
   its collateral-leg exit depth is the shallowest of the three per `DEPOSIT_CAPS.md`, $256,626 debt
   budget vs $837,544 for WBTC).

Both are one-line fixes with no contract changes required. The WBTC and wstETH scripts are correctly
wired for CRV harvest authorization; only the deposit cap gap is fleet-wide.

Separately, the keeper/monitoring layer (workflow.ts + ZenjiRebalanceReceiver + monitor/ app) has not
been updated to reflect the new revert taxonomy the coverage-rebalance fixes introduced
(`CoverageDeficitTooLarge`, `SwapperUnderperformed`, `CoverageDidNotImprove`, `CoverageSkimPosted`) —
this is an operational readiness gap, not a funds-at-risk one (the accepted-risk framing for H-01 still
holds on-chain), but it means the runbook `AUDIT_CoverageRebalance_v2.md` describes cannot currently be
executed by the deployed keeper.
