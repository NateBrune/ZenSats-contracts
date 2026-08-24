# Security Re-Audit — Coverage Rebalance (arm 3), Post-Fix

**Date**: 2026-08-21
**Scope**: uncommitted working-tree delta to `src/libraries/ZenjiCoreLib.sol`, `src/Zenji.sol`,
`src/lenders/LlamaLoanManager.sol` (`git diff` against `128c88a`).
**Prior report**: `AUDIT_CoverageRebalance.md` (2 Critical, 1 High, 4 Medium, 2 Low).
**Plan**: `COVERAGE_REBALANCE_FIX_PLAN.md` (Plan B).
**Build**: `forge build` clean. `forge build --sizes`: `ZenjiWbtcLlamaUsdtStakeDao` 23,040 B
(margin 1,536), `ZenjiWstEthLlamaUsdtStakeDao` 23,108 B (1,468), `ZenjiXautAaveUsdtStakeDao`
23,087 B (1,489) — no vault lost margin.
**Method**: static read of every path reachable from the delta — both loan managers, `OracleLib`,
all 7 base swappers, the LP strategy bases, `ZenjiViewHelper`, `setIdle`, the withdrawal/unwind
path, and the three live deploy scripts. No tests executed (another agent owns testing).

---

## Verdict

| ID | Prior sev | Verdict |
|----|-----------|---------|
| C-01 | Critical | **FIXED** |
| C-02 | Critical | **FIXED** |
| M-01 | Medium | **FIXED** |
| M-02 | Medium | **PARTIAL** — new error is dead code; the actual deadlock mechanism is unchanged |
| M-03 | Medium | **FIXED** |
| H-01 | High | **NOT FIXED** (out of the stated fix scope) — now *bounded* by C-01's floor, downgrade to Medium |
| M-04 | Medium | **NOT FIXED** (out of scope) — latent, no live config affected |

The two Criticals are genuinely closed. The drain is gone: value can no longer leave arm 3 except
through a swap that is floored at 95 % of the oracle-implied value of the exact collateral spent,
and there is no second exit. The convergence math is right and does not oscillate.

**Ship recommendation: SHIP, with one caveat and one follow-up.**

* Caveat: **H-01 is still open.** With C-01 fixed it is no longer a drain — it degrades to a
  bounded bleed (≤ 5 % of a manufactured, attacker-sized collateral sale, plus round-trip swap
  cost). That is an acceptable residual *only if* it is a conscious decision. If it is not, do not
  ship until `exitBased` is clamped or the below-band condition is required to persist across
  blocks.
* Follow-up (not ship-blocking): M-02's liveness gap is unaddressed. Arm 3 still has no
  partial-progress mode, so a large genuine deficit reverts `rebalance()` on every keeper tick
  until a strategist runs `setIdle(true)/setIdle(false)`. I verified that escape still works and is
  independent of all new code — so this is liveness, not funds.

New issues found in the fixes: **0 High or above.** 2 Low, 4 Informational. Details below.

---

# PART 1 — verification of the prior findings

## C-01 — collateral→debt swap now carries an end-to-end oracle floor — **FIXED**

`ZenjiCoreLib.sol:335-338`:

```solidity
uint256 expectedDebt = (loanManager.getCollateralValue(c) * MIN_SWAP_OUT_BPS) / 10000; // 9500
collateralAsset.safeTransfer(address(swapper), c);
uint256 received = swapper.swapCollateralForDebt(c);
if (received < expectedDebt) revert SwapperUnderperformed(expectedDebt, received);
```

**Is `ILoanManager.getCollateralValue` the same oracle basis the loan managers use internally?**
Yes — bit-identical, not merely equivalent:

| Adapter | Public entry | Internal | Both resolve to |
|---|---|---|---|
| LlamaLend | `getCollateralValue` (`LlamaLoanManager.sol:657-659`) | `_getCollateralValue` (`:773-782`) | `OracleLib.getCollateralValue` (Llama overload, `OracleLib.sol:98-121`) with `collateralOracle`, `maxOracleStaleness`, `debtOracle`, `MAX_DEBT_ORACLE_STALENESS` |
| Aave | `getCollateralValue` (`AaveLoanManager.sol:587-588`) | `_getCollateralValue` (`:765-775`) | `OracleLib.getCollateralValue` (Aave overload, `OracleLib.sol:42-67`) |

`getCollateralValue` *is* `_getCollateralValue` — a one-line forwarder in both adapters. So the new
floor is measured against the exact same quantity as `LlamaLoanManager._swapCollateralForDebt:847`
and `AaveLoanManager:481`, at the same `MIN_SWAP_OUT_BPS = 9500`.

**Is the comparison unit-correct?** Yes.
* Llama overload returns debt-token units scaled by a hardcoded `1e18` (`OracleLib.sol:114`) —
  correct, crvUSD is 18 dp.
* Aave overload multiplies by `debtToken.decimals()` scale (`OracleLib.sol:54, 60`) — correct,
  USDT is 6 dp.
* `received` is the debt-token amount delivered by the swapper. Same token, same decimals. ✔

**Does it actually bound a sandwich on `UniswapMixedCurveSwapper` with WBTC?** Yes, and this is the
load-bearing case: `script/DeployWbtcLlamaUsdtStakeDao.s.sol:68` and
`script/DeployWstEthLlamaUsdtStakeDao.s.sol:74` both deploy `UniswapMixedCurveSwapper`. For WBTC,
`stEthPerToken()` reverts so `v3MinOut = 0` (`UniswapMixedCurveSwapper.sol:134-143`) and the Curve
leg is floored by a same-tx `get_dy` (`:169-179`) — still no swapper-side protection. The bound is
now entirely external:

```
c            = collateralFor(deficit) / (1 - s)          [s = swapper.slippage]
expectedDebt = oracleValue(c) * 0.95
received     = oracleValue(c) * (1 - actualLoss)
=> the check reduces to  actualLoss <= 5%
```

Note the gross-up factor `1/(1-s)` cancels out of the check entirely — the floor is a clean
"the swap executed within 5 % of oracle", independent of sizing. On the prior report's own numbers
(`c ≈ 0.0208 WBTC ≈ $2,080`), maximum extraction falls from ~$2,079 to ~$104. The 2 %-of-NAV-per-call
drain is gone.

**Can the oracle basis be manipulated in the same tx?** No.
* WBTC/Llama: Chainlink BTC/USD (1 h window) + crvUSD/USD (25 h). Both push-oracle, not in-tx movable.
* wstETH/Llama: `WstEthOracle` composite (Chainlink stETH/ETH + ETH/USD) + crvUSD/USD.
* XAUT/Aave: Chainlink XAUT/USD + USDT/USD.
Deploy scripts confirm the loan manager and the swapper are constructed with the *same* oracle
addresses (`DeployWbtcLlamaUsdtStakeDao.s.sol:39-40, 96-99`), so there is no basis mismatch to
arbitrage. Staleness is enforced inside `OracleLib._validatedPrice` (`:24-26`), so a stale feed
**reverts** rather than yielding a trivially-satisfiable floor — the failure mode is liveness, not a
silent widening. `removeCollateral` additionally gates on `_checkOracleFreshness()` immediately
before.

Residual: `received` is the swapper's *return value*, not a balance delta. See **NEW-05**.

## C-02 — the value bound now exists, end to end — **FIXED**

The claim under test: "the gap between collateral spent and debt received is capped at 5 %."
Traced exhaustively.

**Value out of the vault, per arm-3 call.** Exactly one exit: `collateralAsset.safeTransfer(address(swapper), c)`
at `:336`. Nothing else leaves. `removeCollateral`/`transferCollateral` (`:325-326`) move collateral
*into* the vault. `debtAsset.safeTransfer(address(loanManager), toRepay)` (`:344`) is followed
immediately by `repayDebt(toRepay)`, which consumes it against the loan; no debt token is left
stranded at the loan manager. Verified against both adapters.

**Value in.** `received ≥ 0.95 · oracleValue(c)`, enforced at `:338` before any repay.

**The surplus.** `toRepay = min(received, deficit)` (`:342`). If `received > deficit`, the excess
stays at the vault as idle debt asset. That is **not** a leak: `ZenjiViewHelper.getTotalCollateralValue`
counts it exactly once at `:118-122`, separate from the strategy balance (`:104-117`) and from the
loan manager's raw balances (`:125-131`). Shareholders are credited. It is recovered on the
withdrawal paths and on `setIdle(true)` (`Zenji.sol:915-950`). With M-03 fixed the surplus is ≈ 0
on a fair swap anyway.

**Partial-repay path.** There is none. A single `repayDebt(toRepay)` with `toRepay ≤ deficit ≤ debt`;
Aave's `repay` and LlamaLend's `repay` both cap at the outstanding debt, so no overpayment can be
stranded. The old step-3 `unwindPosition` branch — which *was* a second, unfloored exit — is deleted.

So the 5 % floor is the *only* channel through which value can leave arm 3, and it is enforced.
The postcondition is correctly demoted in both the code (`:348-353`) and the NatSpec to a ratio
monotonicity check, with an explicit "do not mistake this check for one" — the comment is accurate.

Not implemented: the prior report's second suggestion, a `MIN_PROGRESS_BPS` floor on `toRepay`. It
is no longer load-bearing (the value bound stands on its own), so this is acceptable. Consequence to
be aware of: the keeper bounty is still payable on a call that clears the floor by 1 wei. The bounty
is capped at `rebalanceBountyRate × fees-since-last-rebalance` (`ZenjiCoreLib.sol:222-240`), so
bounty farming remains self-limiting.

## M-01 — `LlamaLoanManager.removeCollateral` MIN_HEALTH — **FIXED**

`LlamaLoanManager.sol:281-290`:

```solidity
llamaLend.remove_collateral(amount);
if (llamaLend.debt(address(this)) > 0) {
    int256 health = this.getHealth();
    if (health < MIN_HEALTH) revert HealthTooLow();
}
```

**Pattern match.** Identical to `createLoan` (`:237-238`), `borrowMore` (`:261-262`), and the
partial-unwind projection at `:463`, all against `MIN_HEALTH = 1e17`. Structurally identical to
`AaveLoanManager.removeCollateral` (`:240-249`), which uses `variableDebtToken.balanceOf(this) > 0`
where Llama uses `llamaLend.debt(this) > 0` — the venue-correct equivalent. ✔

**Is `this.getHealth()` correct and safe here?** Yes.
* `getHealth()` is `external view` (`:645-649`), so `this.getHealth()` compiles to a **STATICCALL**
  — no reentrancy surface, no state mutation.
* It guards `loan_exists` and returns `type(int256).max` when no loan exists, so it cannot revert on
  a fully-closed position. The `debt > 0` gate makes that unreachable anyway.
* The external self-call is required (not stylistic): `llamaLend.health(...)` is read through the
  same forwarder every other call site uses, keeping the `full=true` flag consistent.

**Does it break any existing caller?** No — the previous "zero callers" claim still holds, with one
now.

```
$ grep -rn "removeCollateral" src/ script/
src/interfaces/ILoanManager.sol:45      (declaration)
src/libraries/ZenjiCoreLib.sol:325      (the only call site)
```

Specifically checked:
* **Withdrawals / partial unwind** go `Zenji.withdraw` → `loanManager.unwindPosition` →
  `_unwindPosition` → `llamaLend.remove_collateral(toRemove)` **directly** at `:475`, never through
  the wrapper. Untouched.
* **Emergency**: `emergencyUnwindPosition` (`:307-309`) → same `_unwindPosition` internal path.
  `ZenjiCoreLib.executeEmergencyRescue(0)` uses `transferCollateral`, not `removeCollateral`.
  `executeEmergencyStep(1)` uses `emergencyUnwindPosition`. **The emergency path cannot reach the
  new check.** This matters: a health assertion on the guardian's escape route would be a serious
  regression, and it is not present.
* **Flash-unwind callback** `onFlashLoan:576-584` calls `llamaLend.remove_collateral` directly.

One behavioural note (see M-02): the check is evaluated at the *worst* point of arm 3 — after the
removal, before the repay restores health. That is deliberate and conservative, but it narrows
arm-3's operating envelope relative to Plan A's ordering.

## M-02 — over-large deficits — **PARTIAL**

`ZenjiCoreLib.sol:320-321` replaced the silent cap with:

```solidity
uint256 currentCollateral = loanManager.getCurrentCollateral();
if (c > currentCollateral) revert DeficitExceedsCollateral(c, currentCollateral);
```

Two problems.

**(a) The new revert is unreachable on all three live vaults — it is dead code.**
In collateral units, `c = deficit · C · ltv / (D · (1-s))` and `currentCollateral = C`, so
`c > C ⟺ deficit > D·(1-s)/ltv`. With the arm ordering forcing `ltv ≤ targetLtv + 3%`:

| Vault | max ltv at arm 3 | threshold (s = 1.5 %) | `deficit ≤ D`? |
|---|---|---|---|
| WBTC/Llama, wstETH/Llama | 0.68 | `deficit > 1.449·D` | impossible |
| XAUT/Aave | 0.63 | `deficit > 1.563·D` | impossible |

Even at the maximum `s = 5 %` the threshold is `1.40·D`. `deficit = D − S ≤ D` by construction. So
`DeficitExceedsCollateral` can never fire on an oracle-quoting swapper. It is reachable only through
an inflatable `quoteCollateralForDebt` (M-04, `CurveTwoCryptoSwapper` / `CurveThreeCryptoSwapper`),
neither of which is deployed. This also answers Part 2 Q2 directly: **an attacker cannot push a
vault into `DeficitExceedsCollateral` at all**, cheaply or otherwise, on the live configurations.

**(b) The mechanism the finding described is unchanged, and M-01 made it fire earlier.**
The prior report's deadlock was the *health* revert inside `removeCollateral`, not the collateral
cap. That is exactly where the code still lands. Intermediate LTV during removal is
`1/(1/ltv − δ/(1-s))` for `δ = deficit/D`:

| δ | intermediate LTV (ltv = 0.68, s = 1.5 %) |
|---|---|
| 0.03 (band edge) | 69.4 % — ~140 bps dip, matches the plan's measured 130 bps |
| 0.25 | 82.2 % |
| 0.40 | 93.9 % — LlamaLend health deeply negative |

Somewhere around `δ ≈ 0.25–0.35` on the WBTC market, the new `MIN_HEALTH` gate (M-01) rejects the
removal — *earlier* than LlamaLend's own liquidation edge would have. Arm 3 has **no partial-progress
mode**: it removes the full `c` or reverts. So `rebalance()` reverts on every keeper tick, which is
the operational state the fix was meant to eliminate. The NatSpec at `Zenji.sol:620-625` still
advertises single-call convergence and reserves idle/unidle for "a degenerate case (e.g. no swapper
configured)", which understates this.

**The operator escape does still work — verified independently.** `setIdle(true)`
(`Zenji.sol:730-758`) is strategist-gated, calls `yieldStrategy.withdrawAll()` then
`loanManager.unwindPosition(type(uint256).max)` (full close, flash-loan path) — it does not touch
`rebalanceCoverageUp`, `removeCollateral`, or any new code. `setIdle(false)` re-anchors
`lastStrategyBalance` and calls `_deployCapital()`. So this is **liveness only, no funds at risk**,
and recovery is one strategist transaction.

**Recommendation** (unchanged from the prior report, still not implemented): clamp `c` to the
largest removal that preserves `MIN_HEALTH`, and take the min. Both adapters already have the
primitive:
* LlamaLend: `llamaLend.health_calculator(address(this), -int256(c), 0, true)` — already used at
  `LlamaLoanManager.sol:458-463`.
* Aave: the max-safe-removal arithmetic already exists in `_emergencyStaleExit`
  (`AaveLoanManager.sol:737-752`).
Successive keeper ticks then converge instead of hard-reverting, and the `CoverageDidNotImprove`
postcondition still turns a no-progress call into a revert rather than a bleed.

## M-03 — double slippage buffer removed — **FIXED**

Line `c = (c * precision) / (precision - maxSlippage);` is gone (`:315`). Verified the premise
across **all 7** `ISwapper` implementations in `src/swappers/base/` — every one ends
`quoteCollateralForDebt` with the identical gross-up:

```solidity
return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
```

| Swapper | Quote basis | Grosses up? |
|---|---|---|
| `UniversalRouterV3SingleHopSwapper` (XAUT/Aave, live) | oracle `getDebtValue` | ✔ |
| `UniswapMixedCurveSwapper` (WBTC + wstETH Llama, live) | oracle `getDebtValue` | ✔ |
| `UniswapV3TwoHopSwapper` | oracle | ✔ |
| `UniswapMixedTwoHopSwapper` | oracle | ✔ |
| `CbBtcUniswapV3TwoHopSwapper` | oracle | ✔ |
| `CurveTwoCryptoSwapper` | pool `get_dy` (M-04) | ✔ |
| `CurveThreeCryptoSwapper` | pool `get_dy` (M-04) | ✔ |

So the claim is uniformly true and no swapper under-removes after the buffer removal. Sizing is now
exact: `c` = the collateral whose fair value is `deficit`, grossed up by exactly the swapper's own
slippage, so a swap that executes at `s` returns ≈ `deficit`.

**No oscillation (Part 2 Q4).** Worst admissible case is the floor: `received = 0.95 · deficit/(1-s)`
≈ `0.9645 · deficit`. Then

```
newCoverage = S / (D − 0.9645·(D−S))
```

Entering at the trigger edge `S = 0.97·D` → `newCoverage = 0.97 / (0.0355 + 0.9359) = 0.9986`.
Entering at a deep `S = 0.90·D` → `0.90 / (0.0355 + 0.8681) = 0.996`. `DEADBAND_SPREAD = 3e16`
(`ZenjiConstants.sol:14`), so the band is `[0.97, 1.03]`. Both land comfortably inside, and the
`toRepay = min(received, deficit)` cap prevents overshoot past `1.03` in the surplus direction. Arm 3
does not re-trigger and does not hand off to arm 4. **Converges in one call, no oscillation.**

Resulting LTV also stays in band: for `D=100, C=153.8, deficit=4`, final LTV = `96/149.74 = 64.1 %`
vs a `[62 %, 68 %]` band. No arm-1 handoff, no `StrategyDebtCoverageTooLow` deadlock. The original
defect is closed.

---

# PART 2 — new issues introduced by the fixes

None at High or above. Two Low, four Informational, plus the two carried-over findings.

## NEW-01 (Medium) — H-01 is still open; damage is now bounded, not eliminated

**Location**: `src/strategies/lp/BaseCurveStakeDaoStrategy.sol:110-119`; consumed at
`ZenjiCoreLib.sol:304`. **Pre-existing, not introduced by this change, and explicitly outside the
stated fix set — but it is the enabler for the only remaining bleed vector, so it belongs in the
ship decision.**

```solidity
uint256 vpBased   = (lpTokens * _getSafeUnitValue()) / PRECISION;   // ratchet-clamped ±0.5%
uint256 exitBased = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex); // RAW SPOT
uint256 lpAssetValue = exitBased < vpBased ? exitBased : vpBased;
```

`_getSafeUnitValue` is clamped (`BaseLPStrategy.sol:147-159`, `MAX_VP_DEVIATION`), but `exitBased`
is unclamped and the `min()` means any downward spot skew flows straight into `balanceOf()`.

**Concrete scenario.** WBTC/Llama, `D = 50,000 crvUSD`, `S = 50,000`, coverage 100 %, collateral
1 WBTC. In one transaction: (1) flash-borrow USDT and buy crvUSD out of the USDT/crvUSD pool
(`0x390f...`) until `calc_withdraw_one_coin` reports `S = 47,000` (coverage 94 %, below the 97 %
band); (2) call `vault.rebalance()` — arm 3 fires with `deficit = 3,000`, `c ≈ 0.0305 WBTC`; (3) the
vault sells that WBTC, receives ≥ 2,850 crvUSD (the 95 % floor), repays; (4) unwind the pool skew,
repay the flash loan. Coverage is now `50,000 / 47,000 = 1.064` → out of band the other way, so arm 4
re-borrows on the next tick.

**Damage now vs before.** Before the fix, step 3 could return ~1 crvUSD (V3 hop `amountOutMin = 0`,
vacuous postcondition) — a full loss of `c`. Now it is capped at 5 % of `c`, i.e. ≈ 150 crvUSD in
this example, plus the arm-4 round-trip cost. The attacker must also pay to imbalance a stable pool
by 6 %, which on the USDT/crvUSD pool is expensive and largely non-recoverable. **This drops from a
drain to a bounded, likely-unprofitable griefing bleed.**

**Aggregate bound (Part 2 Q5).** Per call: ≤ 5 % of `c`, and `c` is bounded above by the health gate
inside `removeCollateral` — the LlamaLend `MIN_HEALTH = 1e17` check added by M-01, and Aave's
`MIN_HEALTH = 1.1e18`. Repeats are not free-running: after a successful arm-3 call coverage is ≈ 1.0
under the *skewed* measurement, so a second call in the same transaction requires deepening the skew.
The attacker's cost scales super-linearly with skew depth; the vault's loss scales linearly. So there
is no self-financing loop.

**Fix** (unchanged, pick one): clamp `exitBased` with the same ratchet as `vpBased`; or record
`coverageBelowBandSince` and require the below-band condition to persist N blocks before arm 3 may
run (defeats same-tx manufacture cleanly and is the cheapest change); or role-gate arm 3 only.

## NEW-02 (Low) — arm 3 ignores the vault's idle debt-asset balance

**Location**: `ZenjiCoreLib.sol:304, 315-346`. **Introduced by this change** (arm 3 previously
funded from the strategy, so idle debt was consumed at `:277` of the old code).

`deficit = debt - strategyBalance` and the repay is funded *entirely* from a fresh collateral sale,
even when the vault already holds debt tokens. Coverage is defined as `strategyBalance / debt`
(`Zenji.sol:894-899`), which excludes idle vault debt asset, so the vault can be below band while
holding exactly the tokens that would fix it.

That state is reachable and arm 3 creates it itself: any `received > deficit` leaves the excess at
the vault (`:342`), and `_deployCapital` deploys idle **collateral** only (`Zenji.sol:884-886`), so
it is not swept by a deposit or a subsequent rebalance. Partial unwinds also deliberately leave debt
token at the vault (`LlamaLoanManager.sol:508-512`).

**Impact**: an unnecessary collateral→debt swap, i.e. up to 5 % of the avoidable amount burned
plus a later debt→collateral leg on withdrawal. No fund loss, no NAV mis-accounting.

**Fix** (≈4 lines, strictly reduces value burned and also makes arm 3 reachable in states where the
swap would breach the floor):

```solidity
uint256 idleDebt = debtAsset.balanceOf(address(this));
if (idleDebt >= deficit) {
    debtAsset.safeTransfer(address(loanManager), deficit);
    loanManager.repayDebt(deficit);
    // fall through to the postcondition
} else {
    deficit -= idleDebt;   // size c for the shortfall only, repay idleDebt alongside
    ...
}
```

## NEW-03 (Low) — `SwapperUnderperformed` is a new front-runnable revert on a permissionless keeper path

**Location**: `ZenjiCoreLib.sol:338`. **Introduced by this change.**

Arm 3 previously had no oracle floor and could not revert on swap quality. It now can. Because
`rebalance()` is permissionless and the CRE keeper's transaction is public in the mempool, an
attacker can front-run it with a TriCRV skew (WBTC/wstETH vaults) that pushes the WETH→crvUSD leg
below 95 % of oracle, reverting the keeper's transaction. No vault state changes; the attacker pays
the skew round trip; the keeper pays gas.

This is the correct trade — the alternative is C-01 — but it should be operationalised: the CRE
workflow in `keeper/zen-keep/` should treat `SwapperUnderperformed` (and `HealthTooLow`) as
**retryable**, not as an alert-worthy failure, or the monitor will page on a cheap grief.

## NEW-04 (Informational) — the 5 % floor is tighter than the vault's own tolerance on the reverse leg, and the constant is duplicated

**Location**: `ZenjiCoreLib.sol:23` vs `Zenji.sol:930-947`.

`Zenji._swapRemainingDebtToCollateral` floors the *debt→collateral* direction at
`max(swapper.slippage(), 2 × maxSlippage)` and documents why: *"loanManager.getDebtValue uses a
direct oracle feed while the swapper traverses a multi-hop path, so the two prices can differ by up
to ~2×slippage even on a fair swap."* Arm 3 floors the *collateral→debt* direction at a flat 5 %.

If gov ever raises `maxSlippage` or the swapper's `slippage` above 2.5 %, the reverse leg tolerates
divergence that arm 3 rejects — an inconsistency that surfaces as arm-3 liveness failures on
otherwise-fair swaps. (Today `slippage` defaults to 1 % — `BaseSwapper.sol:38` — so there is
headroom, and matching the loan managers' 95 % is defensible precedent.)

Separately, `MIN_SWAP_OUT_BPS = 9500` is redeclared in `ZenjiCoreLib` rather than read from the
adapter (it is not on `ILoanManager`). The NatSpec at `:18-22` says it "MUST match" but nothing
enforces it; a future adapter with a different value diverges silently. Consider exposing
`minSwapOutBps()` on `ILoanManager`, or at minimum add a deployment-time assertion.

## NEW-05 (Informational) — `received` is the swapper's return value, not a balance delta

**Location**: `ZenjiCoreLib.sol:337`.

Both loan managers deliberately measure a delta —
`LlamaLoanManager.sol:846-855` (`debtAfter - debtBefore`) and `AaveLoanManager.sol:483-491` — and the
prior report recommended the same here. The fix trusts `swapper.swapCollateralForDebt`'s return.

I verified this is **sound today**: all 7 implementations return exactly the amount transferred to
`msg.sender` (`UniswapMixedCurveSwapper.sol:183-193`, `UniswapV3TwoHopSwapper.sol:113-117`,
`UniversalRouterV3SingleHopSwapper.sol:128-133`, `UniswapMixedTwoHopSwapper.sol:224-228`,
`CbBtcUniswapV3TwoHopSwapper.sol:103-107`, `CurveThreeCryptoSwapper.sol:93-98`, and
`CurveTwoCryptoSwapper.sol` which passes `msg.sender` as the pool receiver and returns the pool's
own output). None of the tokens involved is fee-on-transfer.

But this is a weaker invariant at a **governance-rotatable** boundary (the vault swapper is mutable
via a 1-week timelock). A swapper that over-reports would both evade the floor and cause the
subsequent `debtAsset.safeTransfer(loanManager, toRepay)` to spend pre-existing vault-held debt
asset. Two lines closes it:

```solidity
uint256 before = debtAsset.balanceOf(address(this));
collateralAsset.safeTransfer(address(swapper), c);
swapper.swapCollateralForDebt(c);
uint256 received = debtAsset.balanceOf(address(this)) - before;
```

## NEW-06 (Informational) — NatSpec now contradicts the code it documents

`ZenjiCoreLib.sol:260-274`, the step-summary block, was not updated to match the rewrite:

* `:260-261` — *"size collateral for the deficit (buffered for slippage, capped at available collateral)"*.
  Both clauses are now wrong: the extra buffer was removed (M-03) and the code **reverts** instead of
  capping (`:321`).
* `:263-264` — *"swap collateral -> debt asset via the configured swapper (oracle-floored by the
  swapper itself)"*. This is the exact claim C-01 refuted; the floor is re-applied locally at `:338`.
  The step-3 inline comment (`:329-334`) is correct — the summary above it is stale.
* `:272-274` — *"the surplus is swept up on the next `_swapRemainingDebtToCollateral`-style flow or a
  subsequent deposit/rebalance cycle"*. Deposit and rebalance do **not** sweep idle debt asset
  (`_deployCapital` handles idle collateral only, `Zenji.sol:884-886`). Only withdrawal/redeem and
  `setIdle(true)` do.

These are the exact sentences a future maintainer will trust when deciding whether the local floor is
redundant. Worth correcting before merge.

## NEW-07 (Informational) — `DeficitExceedsCollateral`'s comment overstates what it guards

`ZenjiCoreLib.sol:317-321` describes the revert as the insolvency signal. Per M-02(a) it is
unreachable on every live configuration. The real ceiling on `deficit` is the health check inside
`removeCollateral`, which reverts `HealthTooLow` with no indication that the cause was an oversized
coverage deficit. Either implement the health-aware clamp (M-02 recommendation) or reword.

---

## Focus areas cleared

Traced end to end this pass, found sound. Listed explicitly because clean results are results.

1. **Oracle basis identity (C-01).** `getCollateralValue == _getCollateralValue` in both adapters,
   forwarding to the same `OracleLib` overload with the same oracles and staleness windows. Deploy
   scripts confirm the loan manager and swapper share oracle addresses. No basis mismatch.

2. **Decimal correctness.** Llama overload hardcodes `1e18` for crvUSD; Aave overload uses
   `debtToken.decimals()` for USDT (6 dp). `received` is in the same units. `MIN_SWAP_OUT_BPS`
   arithmetic (`* 9500 / 10000`) has no truncation risk at these magnitudes.

3. **Value-exit enumeration (C-02).** Exactly one token exit in the new function
   (`ZenjiCoreLib.sol:336`), guarded. `repayDebt` cannot strand tokens at the loan manager on either
   venue. The old unfloored `unwindPosition` branch is deleted.

4. **NAV accounting.** `ZenjiViewHelper.getTotalCollateralValue` counts idle vault debt asset exactly
   once (`:118-122`), independently of the strategy balance and the loan manager balances. The
   surplus is credited to shareholders, not lost. Fee accrual is unaffected: `_accrueYieldFees`
   (`Zenji.sol:1194-1212`) keys only on `yieldStrategy.balanceOf()`, and arm 3 provably never touches
   the strategy, so the returned `newStrategyBalance` equals the value `processRebalanceBounty`
   already established.

5. **Convergence and band arithmetic.** One-call convergence confirmed analytically at the trigger
   edge and at deep deficits; final coverage and final LTV both land inside their bands; no arm-1
   handoff, so the `StrategyDebtCoverageTooLow` deadlock cannot re-form. `DEADBAND_SPREAD = 3e16`.

6. **Emergency-path isolation (M-01).** `emergencyUnwindPosition`, `executeEmergencyStep(0/1/2)`,
   `executeEmergencyRescue(0/1/2)`, and `onFlashLoan` all reach LlamaLend's `remove_collateral`
   *directly* or via `transferCollateral` — none goes through the new `removeCollateral` health
   check. The guardian's escape is unaffected.

7. **Withdrawal / partial-unwind isolation (Part 2 Q6).** Confirmed still clean, and strictly
   *cleaner* than before. `rebalanceCoverageUp` has exactly one caller (`Zenji.sol:687`).
   `removeCollateral` has exactly one caller in `src/` (`ZenjiCoreLib.sol:325`). The withdrawal path
   (`withdraw`/`redeem` → `unwindPosition` → `_unwindPosition` → `llamaLend.remove_collateral` at
   `:475`) never touches the wrapper, so the M-01 health check cannot regress it. Deleting the old
   step 3 removed arm 3's *only* use of `unwindPosition`/`transferDebt` — the surface that regressed
   in **256de80** is now less entangled with arm 3 than it was before this change.
   `_swapRemainingDebtToCollateral`, `_deployDebtToYield`, `_deployCapital`, and both adapters'
   unwind code are untouched by the diff.

8. **Reentrancy.** `rebalance()` is `nonReentrant` (`Zenji.sol:625`) via the vault-storage guard,
   which covers the whole delegatecall into `ZenjiCoreLib`. `repayDebt` carries its own guard
   (`LlamaLoanManager.sol:268`) — different contract, no conflict. External calls are to the
   timelocked swapper and transitively Uniswap/Curve; none of WBTC, wstETH, XAUT, crvUSD, USDT, WETH
   has transfer hooks. The `this.getHealth()` self-call is a STATICCALL. No callback into the vault.

9. **Postcondition spuriousness (prior L-02).** `newStrategyBalance` re-reads
   `min(vp, calc_withdraw_one_coin)`. Checked whether arm 3's own swap can move it: for the LlamaLend
   vaults the swap routes WBTC/wstETH→WETH→crvUSD through **TriCRV** (`0x4eBd...`) while the strategy
   prices the **USDT/crvUSD** pool (`0x390f...`) — different pools, no interaction. For XAUT/Aave the
   swap is a single-hop XAUT→USDT V3 pool, also disjoint from the strategy's Curve pool. So the
   theoretical spurious `CoverageDidNotImprove` does not arise on any live configuration.

10. **Dust floor.** `deficit <= 10 ** debtAsset.decimals()` (`:308`) sits before every mutation, so
    the early return is a true no-op. The band is 3 % of debt vs a 1-unit floor; they overlap only
    below ~33 debt units, far under both adapters' `DUST_THRESHOLD`. No "sit just under the floor"
    state.

11. **`c == 0` and `swapper == address(0)` early returns** (`:302, 316`) precede all mutations.
    `getCurrentCollateral` is a live read on both venues (`AaveLoanManager.sol:548-550` aToken
    balance; `LlamaLoanManager.sol:632-636` `user_state[0]`).

12. **`transferCollateral` ordering.** `removeCollateral(c)` then `transferCollateral(vault, c)` is
    correct on both venues: Aave's (`:672-686`) consumes the idle balance the withdraw just created
    before falling through to a second `aavePool.withdraw`, so it cannot double-withdraw; LlamaLend's
    (`:736-739`) is a plain transfer of the just-freed collateral.

13. **Build and sizes.** `forge build` clean (lint warnings only, all in pre-existing test files). No
    vault lost EIP-170 margin; all three remain ≈ 1.5 KB clear.

---

## Test-coverage gaps

The new fork tests (`test/WbtcCrvUsdUsdtLlama.fork.t.sol` +233, `test/XautCrvUsdUsdtAave.fork.t.sol`
+55) cover one-call convergence, a loss-size sweep, the postcondition guard on a dust-adjacent
deficit, and strategy-balance-untouched. Good coverage of the convergence property. Two of the prior
report's suggested regression tests are **not** present and directly target the fixes shipped here:

1. **A mock swapper that returns 1 wei of debt asset for the full `c`** — must revert
   `SwapperUnderperformed`, not succeed. This is the direct C-01 regression test; without it the
   floor is untested.
2. **A pool-skew NAV test**: skew the LP pool, call `rebalance()`, unwind the skew, all in one
   transaction, and assert NAV loss is within the 5 % bound. This is the H-01/C-01 interaction test
   and the one that would quantify NEW-01.

A third worth adding: **assert `HealthTooLow` on an oversized deficit and that `setIdle(true)/
setIdle(false)` recovers from that state** — the M-02 escape, which is currently asserted only by the
older `test_idleUnidle_recoversFromCoverageDeadlock`.

---

## Recommended before ship

1. **Decide H-01 explicitly** (NEW-01). Either accept the bounded bleed in writing, or add the
   persist-across-blocks gate on arm 3 — that is the cheapest of the three fixes and defeats
   same-transaction manufacture outright.
2. **Fix the stale NatSpec** (NEW-06). Three sentences; one of them actively invites a future
   maintainer to delete the C-01 floor as redundant.
3. **Use the idle debt-asset balance** (NEW-02, ≈4 lines) — strictly reduces value burned.
4. Add the mock-swapper regression test.

Not ship-blocking, worth scheduling: the health-aware clamp on `c` (M-02), the balance-delta measure
(NEW-05), and keeper-side handling of retryable reverts (NEW-03).

---

# Accepted Risk — H-01 / NEW-01: manufactured coverage deficit

**Status**: ACCEPTED by protocol owner, 2026-08-22. Not fixed; no gate added to arm 3.

## The issue
`deficit = D - S` is spot-manipulable. `BaseCurveStakeDaoStrategy.balanceOf()` returns
`min(vpBased, exitBased)`. The `vpBased` leg is clamped to +/-`MAX_VP_DEVIATION` (0.5%) around a
cached value by `BaseLPStrategy._getSafeUnitValue`, but `exitBased` is
`lpPool.calc_withdraw_one_coin(...)` — **raw spot, unclamped**. The clamp guards one leg and the
`min()` deliberately selects the other. Any caller can therefore manufacture a coverage breach and
force arm 3 to sell collateral on demand.

## Why the existing guards do not cover it
- `COOLDOWN_BLOCKS = 1` / `lastInBlock` gates share **mint/transfer -> redeem** in the same block.
  `rebalance()` has **no cooldown check** and is permissionless. Verified, not assumed.
- The VP clamp protects `vpBased` only, and `min()` selects `exitBased` precisely when it is lower —
  which is the state an attacker creates.

## Attack
1. Flash-borrow USDT.
2. Swap USDT -> crvUSD in the crvUSD/USDT pool, draining the crvUSD side so
   `calc_withdraw_one_coin` falls -> `S` falls -> coverage < 97%.
3. Call `rebalance()`; arm 3 sells collateral and repays debt.
4. Unskew, repay the flash loan.

## Why it is accepted
**Gain is bounded and not farmable.** The only profit is the keeper bounty,
`(accumulatedFees - feesAtLastRebalance) * rebalanceBountyRate`. `processRebalanceBounty` sets
`feesAtLastRebalance = accumulatedFees` on every rebalance, so the first call drains the pool and a
repeat in the same period pays ~0.

**Cost is large.** crvUSD/USDT runs `A = 2000` — flat until a cliff. Measured: $13.4M moves it
35 bps; $25M moves it 3,655 bps. Depressing the exit leg by >3% means pushing past the cliff, order
$20M+, paying the round-trip fee and realised slippage on that size, plus flash fee and gas.

**Vault damage is small and bounded.** The collateral is NOT sold at a manipulated price:
1. the collateral swap uses a DIFFERENT venue than the skewed LP pool (WBTC->WETH->crvUSD for the
   LlamaLend vaults; XAUT/USDT V3 for the gold vault), so the skew does not move it at all; and
2. C-01's `MIN_SWAP_OUT_BPS = 9500` floor caps that swap at 5% below the Chainlink-implied value.

Realised cost is ordinary swap fees (~2 bps measured) plus the fee round-trip when arm 1 re-levers
on the following tick. Per call it is bounded by `deficit <= D - S` and by the `removeCollateral`
health checks. The vault is also an LP in the skewed pool (~2.7% at the 18 WBTC cap) and so earns a
slice of the attacker's skew fees.

Arm 3 firing on a genuine coverage drop is correct behaviour; the cost asymmetry makes a
manufactured one unattractive.

## Residual risk (explicitly retained)
- **Griefing has no cost floor for a motivated adversary.** The economics deter profit-seekers, not
  a competitor or someone already positioned in the pool who partially recoups the skew.
- **A deficit past the venue's health threshold reverts.** On XAUT/Aave that is roughly >20% of debt
  at target LTV and >12% at the top of the LTV band; LlamaLend tolerates more. Arm 3 is
  ALL-OR-NOTHING: it takes the full required collateral removal or reverts
  `CoverageDeficitTooLarge(deficit, collateralRequired)`, and the operator runs setIdle/unIdle.
  (History, so this is not re-derived: a partial-progress version was implemented and REJECTED —
  it reintroduced the deadlock by dragging LTV past lowerBand into arm 1's territory, and cost more
  than the escape it replaced. See `COVERAGE_PARTIAL_PROGRESS_PLAN.md`. An earlier revision of this
  section marked the revert "SUPERSEDED by partial progress" — that is WRONG; partial progress was
  removed in 699b78a and the revert is live.)

## Monitoring
- Alert on arm-3 rebalances (`RebalancePerformed` with coverage as the trigger) — especially any
  occurring while the LP pool is materially imbalanced.
- **Alert on `CoverageDeficitTooLarge`** — arm 3 cannot self-heal from here and the vault needs an
  operator `setIdle`/`unIdle`. This is the actionable page.
- **Treat `SwapperUnderperformed` as retryable**, not as a page — it is transient (market conditions
  or a front-run) and the keeper should back off and retry.
- Arm 3 produces no partial rebalances, so there is no "repeated partial success" signature to watch
  for. Repeated arm-3 SUCCESS simply means coverage keeps drifting — investigate the strategy, not
  the rebalancer.

## Revisit if ANY of these change
1. **TVL grows** such that a plausible bounty approaches the skew cost.
2. **Yield-pool depth falls** — a thinner pool makes the skew cheap. This is a live concern: it is
   exactly what happened to pmUSD/crvUSD. Re-price this risk whenever `DEPOSIT_CAPS.md` is
   re-measured.
3. **A vault is deployed whose collateral swap venue coincides with its yield LP pool.** The
   "different venue" argument above would no longer hold and this must be re-analysed before launch.
4. **`rebalanceBountyRate` is raised** (cap is `MAX_REBALANCE_BOUNTY = 50%`).
