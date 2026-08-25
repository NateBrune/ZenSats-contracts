# Security Audit — Arm 4 rewrite (`rebalanceCoverageDown` → skim-to-collateral)

**Date**: 2026-08-24
**Scope**: uncommitted working-tree delta to `src/libraries/ZenjiCoreLib.sol`
(`rebalanceCoverageDown`, L527-685) and its call site `src/Zenji.sol:703-712`. `git diff src/`.
**Spec**: `ARM4_SKIM_SPEC.md`. **Bug being fixed**: `AUDIT_Branch_Full.md` L-01.
**Prior rounds on the mirror arm (arm 3)**: `AUDIT_CoverageRebalance.md`,
`AUDIT_CoverageRebalance_v2.md` (incl. **ACCEPTED RISK H-01**), `AUDIT_PartialProgress.md`.
**Build**: `forge build` clean. `forge build --sizes`: 23,056 / 23,124 / 23,103 B
(margins 1,520 / 1,452 / 1,473 — see I-01).
**Method**: static read of every path reachable from the delta — both loan managers,
`OracleLib` (all four overloads), `BaseSwapper` + the two live swappers, `BaseYieldStrategy`,
`BaseLPStrategy`, `BaseCurveStakeDaoStrategy`, `ZenjiViewHelper`, `ZenjiGovLib`, `ZenjiAdmin`
(rescue), `_deployCapital`, `processWithdrawFees` / `processRebalanceBounty` / `_accrueYieldFees`,
and the three live deploy scripts. No tests executed (another agent owns the fork suite).

---

## Verdict

**SHIP — after fixing M-01.** M-01 is a two-line change and it is the one place where the value
bound is materially weaker than the code's own comment claims. M-02 is a liveness regression that
should be a conscious decision before deploy, not a surprise on the first thin-liquidity tick.
Everything else is Low/Informational.

The core design is correct and the two arm-3 Criticals do **not** recur:

* **C-01 by analogy — the oracle floor is present, correctly based, and unit-correct.** ✔
* **C-02 by analogy — the postcondition is correctly documented as a ratio check and is not being
  mistaken for a value bound.** The value bound exists and is identified below. ✔

| ID | Severity | Title | New? |
|----|----------|-------|------|
| M-01 | Medium | The 105 % withdrawal pad is not accounted for downstream: effective exit-slippage tolerance is 5.71 %, not 1 %; skim systematically overshoots below parity | **NEW** |
| M-02 | Medium | Arm 4 gains three unconditional revert paths and can brick permissionless `rebalance()` where the old arm never reverted | **NEW** |
| L-01 | Low | `collateralOut` is the swapper's return value, not a vault-side balance delta — diverges from both existing precedents | **NEW** (recurrence of prior NEW-05) |
| L-02 | Low | Pool-skew exit-price steering on a permissionless, non-user-initiated LP exit — extension of accepted **H-01** | **H-01 CHANGED** |
| L-03 | Low | No event on partial or zero collateral posting — the supply-cap fallback is silent | **NEW** |
| L-04 | Low | Gov can widen the oracle floor to 10 %, looser than the venue-internal 5 % `MIN_SWAP_OUT_BPS` standard | pre-existing pattern, newly on a permissionless path |
| I-01 | Info | 16-byte bytecode margin regression vs the gate in `ARM4_SKIM_SPEC.md` §6.9 | **NEW** |
| I-02 | Info | Arm 4 does not reserve `accumulatedFees`; arm 3 explicitly does | **NEW** |
| I-03 | Info | Six failed venue `supply()` attempts is ~1.5–2 M gas in the worst case | **NEW** |
| I-04 | Info | `ARM4_SKIM_SPEC.md` §8b's premise is stale (the code NatSpec is correct; the spec is not) | doc only |

**Nothing Critical or High.** No unbounded value exit, no stranding, no reentrancy, no
double-counting, no new manipulation lever that raises coverage.

---

# PART 1 — Findings

## [M-01] The 105 % withdrawal pad is not accounted for downstream

**Severity**: Medium (Impact: Medium — bounded value loss on a permissionless call; Likelihood: High
— fires on every arm-4 call with no prerequisites)
**Location**: `src/libraries/ZenjiCoreLib.sol:637-641`, and its consequence at `:654-655`

```solidity
uint256 withdrawRequest = (surplus * 105) / 100;
if (withdrawRequest > strategyBalance) withdrawRequest = strategyBalance;
uint256 received = yieldStrategy.withdraw(withdrawRequest);
uint256 minReceived = (surplus * (precision - maxSlippage)) / precision;   // <-- unpadded basis
if (received < minReceived) revert InsufficientWithdrawal();
```

The comment at `:635-636` states the intent explicitly: *"verify the received amount clears
maxSlippage against the REQUESTED amount (not the padded request)."* That is exactly the defect.
The pad was copied from `adjustLtv`'s decrease path (`:743-750`), where it is harmless because the
un-consumed remainder is left as idle debt asset and the repay is capped at `toRepay`. Here nothing
caps anything: the entire `received` is swapped and posted.

**How much value actually leaves the strategy.** `BaseLPStrategy._withdraw:190`:

```solidity
uint256 sharesToRedeem = (shares * debtAmount) / currentValue;
```

`debtAmount` is `withdrawRequest`. So the strategy deterministically redeems a share fraction worth
**1.05 × surplus**, not `surplus`. `received` is what survives the LP exit + (for USDT vaults) the
crvUSD→USDT leg.

### Impact A — effective slippage tolerance is 5.71 %, not 1 %

The check passes at `received ≥ 0.99 × surplus` while `1.05 × surplus` of strategy value was
destroyed. Effective tolerance:

```
1 − (0.99 / 1.05) = 5.71 %
```

`maxSlippage` defaults to `1e16` (1 %, `Zenji.sol:287`). The vault's stated exit tolerance on this
leg is therefore **5.7× looser than configured**, on a permissionless entry point. This is the
weakest link in the value bound (see PART 2), and it is what makes L-02 worth more than dust.

### Impact B — systematic overshoot below parity

`newS ≈ S − 1.05·(S − D)  ⇒  newCoverage ≈ 1 − 0.05·(c − 1)`

| start coverage `c` | landing coverage |
|---|---|
| 1.03 (trigger edge) | 0.9985 |
| 1.35 | 0.9825 |
| **1.60** | **0.9700 — lower band edge** |
| 1.70 | 0.9650 — **arm 3 fires next tick** |

The spec's headline claim ("lands at exactly 1.00 coverage in ONE call", §2.2) is not what the code
does — it lands *below* 1.00, always. At `c > 1.6` it overshoots into arm-3 territory: the expensive
arm, the one carrying accepted risk H-01 and the `CoverageDeficitTooLarge` liveness gap. `c = 1.6`
is not a normal state for this vault, so this alone is Low; combined with Impact A it is Medium.

### Impact C — 5 % of every skim pays a pointless round trip

The pad is swapped debt→collateral and (usually) posted as collateral, then arm 1 borrows it back
and re-deposits it. Spec §4 flags round-trip cost as the thing that must be measured; the pad adds
5 % to the measured number for no benefit.

### Recommended fix

Two lines, no design change:

```solidity
uint256 received = yieldStrategy.withdraw(surplus);          // drop the pad entirely
uint256 minReceived = (surplus * (precision - maxSlippage)) / precision;
if (received < minReceived) revert InsufficientWithdrawal();
```

The pad exists in `adjustLtv` because that path needs *at least* `toRepay` debt asset in hand. Arm 4
has no such requirement — it only needs `S` to fall by roughly `surplus`. Dropping it fixes all
three impacts at once and lands coverage in `[1.0000, 1.0001]`.

If the pad is kept for some reason not visible in the code, then instead:

```solidity
uint256 minReceived = (withdrawRequest * (precision - maxSlippage)) / precision;
...
uint256 toSwap = received > surplus ? surplus : received;    // cap the swap input
// leave `received - toSwap` as idle debt asset (counted by getTotalCollateralValue:120-122)
```

but the first form is strictly better.

---

## [M-02] Arm 4 gains three unconditional revert paths and can brick `rebalance()`

**Severity**: Medium (Impact: Medium — protocol breakage/liveness, no fund loss; Likelihood: Medium)
**Location**: `src/libraries/ZenjiCoreLib.sol:641, 656, 682`

The replaced implementation **never reverted**: every failure mode was an early `return
strategyBalance`. The new one can revert on `InsufficientWithdrawal` (`:641`),
`SwapperUnderperformed` (`:656`), or `CoverageDidNotImprove` (`:682`).

The arms in `Zenji.rebalance():689-712` are mutually exclusive. When `coverage > 1.03` and LTV is
in band, arm 4 is the **only** arm selected. A persistent arm-4 revert therefore bricks
`rebalance()` entirely — the keeper tick fails every time — until a strategist runs
`setIdle(true)/setIdle(false)`. This is the same liveness class as arm-3 M-02, newly created here.

Three concretely reachable triggers:

1. **Thin-liquidity swap leg (XAUT/Aave).** `UniversalRouterV3SingleHopSwapper` is a single-hop
   USDT→XAUT V3 swap (`script/DeployXautAaveUsdtStakeDao.s.sol:77`). The vault floor is 2 % of the
   Chainlink XAUT/USD-implied value (`maxSlippage=1e16 ⇒ effectiveSlippage=2e16`). A skim of ~3 % of
   debt through a thin gold pool can exceed 2 % of oracle. `CLAUDE.md` already documents that
   XAUT exits routinely trade below the gold oracle — the fork suite *skips* those cases as
   environmental. Arm 4 will **revert**, not skip.

2. **`CoverageDidNotImprove` from in-flight compounding.** `BaseLPStrategy._withdraw:193` calls
   `_compoundRewards()`, which claims CRV, swaps it to crvUSD and re-stakes — **after**
   `sharesToRedeem` was computed at `:190`. If pending rewards exceed `1.05 × surplus`, `balanceOf()`
   at `:678` can exceed `startCoverage`'s numerator and the postcondition reverts. Requires roughly
   `surplus`-sized unharvested rewards (~3 % of debt), i.e. months without a harvest — but
   `rebalance()` does not harvest, so nothing prevents it. Workaround exists and is permissionless:
   `harvestYield()` first (it raises `S`, so the next tick simply measures a larger surplus).

3. **`InsufficientWithdrawal` under LP-exit stress** — the intended behaviour per spec §5 #3,
   listed here for completeness.

**Recommendation.** Prefer degrading to a smaller skim over reverting, consistent with the SUPPLY-CAP
philosophy already adopted at `:663-672`. Minimal version: wrap steps 1-3 so that a swap-floor
failure halves the skim and retries once, or catch and `return strategyBalance` for
`SwapperUnderperformed` specifically (arm 4 not running is strictly better than `rebalance()` not
running). At minimum, decide this consciously and document the `setIdle` escape in the NatSpec the
way arm 3 does.

---

## [L-01] `collateralOut` is the swapper's return value, not a vault-side balance delta

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:655-656`

```solidity
uint256 collateralOut = swapper.swapDebtForCollateral(received);
if (collateralOut < floor) revert SwapperUnderperformed(floor, collateralOut);
```

Both existing precedents measure a **delta on the receiving contract**, deliberately:

* `Zenji._swapRemainingDebtToCollateral:932-936` — `collateralAfter - collateralBefore`
* `LlamaLoanManager._swapDebtForCollateral:860-869` — `collateralAfter - collateralBefore`, with an
  explicit `I-02: intentional check-after-transfer slippage measurement` comment

Arm 4 diverges from both. For the two live swappers this is currently safe — both compute their
return value as a self-balance delta and forward it to `msg.sender`
(`UniversalRouterV3SingleHopSwapper:145-151`, `UniswapMixedCurveSwapper:242-249`) — but `swapper` is
**mutable** (1-week gov timelock, `CLAUDE.md`). A future swapper that over-reports would cause the
loop at `:665` to transfer the vault's **pre-existing idle collateral** (the unposted remainder from
a prior arm-4 call, or an unposted deposit) into the loan manager, and the floor check would not
notice.

**Fix**: snapshot `collateralAsset.balanceOf(address(this))` before `:654` and use the delta.

---

## [L-02] Pool-skew exit-price steering — extension of ACCEPTED RISK H-01

**Severity**: Low (bounded by the same economics that made H-01 acceptable)
**Location**: `src/libraries/ZenjiCoreLib.sol:620, 637-641`; `BaseCurveStakeDaoStrategy.sol:113-133`

**Answering focus area 6 directly: the "no upward manipulation" conclusion still holds.**
`balanceOf() = min(vpBased, exitBased)` (`BaseCurveStakeDaoStrategy:113-119`). To raise the reported
balance an attacker must raise *both* legs; `vpBased` is clamped to ±0.5 % around the cache and
`_getSafeUnitValue` clamps *toward* current and never past it, so the ratchet is closed. Arm 4
cannot be *triggered* by manipulation. Verified unchanged.

What **is** new is that arm 4 now performs a discretionary LP exit on a permissionless, non-user
-initiated path. `exitBased = calc_withdraw_one_coin` is raw spot and *is* movable downward. Given a
genuine trigger at coverage `c > 1.03`, an attacker can depress `exitBased` to just above `1.03·D`
and the vault will exit at that depressed price:

| step | value |
|---|---|
| genuine coverage | `c = 1.10`, `D` = debt, true `S = 1.10 D` |
| attacker skews pool | reported `S' = 1.031 D` (still triggers) |
| `surplus` | `0.031 D` |
| shares redeemed (`_withdraw:190`) | `withdrawRequest / S' = 0.0326D / 1.031D ≈ 3.16 %` of shares |
| true value of those shares | `3.16 % × 1.10 D ≈ 0.0348 D` |
| `received` (at skewed price) | `≈ 0.0326 D` |
| outer check `received ≥ 0.99 × 0.031 D = 0.0307 D` | **passes** |
| leak to the skew unwinder | `≈ 0.0022 D` ≈ **0.22 % of debt** |

The inner floor at `BaseCurveStakeDaoStrategy._removeLiquidity:129-132` is computed from an in-tx
`calc_withdraw_one_coin` and therefore does **not** defend against a skew — the outer `minReceived`
is the only defence, and M-01 makes it 5.7× looser than configured. **Fixing M-01 shrinks this
finding by the same factor**, to ~0.04 % of debt.

This is the mirror of accepted **H-01** and is bounded by the same argument: the attacker pays Curve
imbalance fees on both the skew and the unwind, and the extraction is one-shot per genuine trigger
(after a successful call coverage lands ≈ 1.00, so arm 4 cannot be re-fired in the same block). The
same lever already exists on arm 2 (`adjustLtv` decrease) and on ordinary withdrawals, so this is a
pre-existing class — but arm 4 is the first path that exits LP with **no user or operator behind it**.

**H-01 status change**: H-01's accepted-risk note in `rebalanceCoverageUp`'s NatSpec
(`ZenjiCoreLib.sol:~330`) says the residual is a *manufactured collateral sale*. It now needs an
addendum: the same `exitBased` spot lever also steers the *price of a genuine strategy exit* on arm 4.
Same four revisit conditions apply. Recommend adding one sentence rather than reopening the decision.

---

## [L-03] The supply-cap fallback is silent

**Severity**: Low (observability)
**Location**: `src/libraries/ZenjiCoreLib.sol:663-672`

The halving loop emits nothing. There is no way to distinguish, from on-chain events, between
"skim fully posted as collateral" and "all six `addCollateral` attempts reverted and the entire swap
output is sitting idle at the vault." Both emit only `Rebalance(currentLtv, newLtv, false)` — and in
the fully-failed case `newLtv == currentLtv`, which is itself indistinguishable from a no-op.

This matters more than usual because the failure is *designed* to be silent (spec §8b) and because
`monitor/` and the CRE keeper have no other signal. Arm 3's analogous surplus is at least implied by
`CoverageDidNotImprove` not firing.

**Fix**: `emit CollateralSkimmed(received, collateralOut, posted, collateralOut - posted);`

---

## [L-04] Gov can widen the oracle floor to 10 %

**Severity**: Low
**Location**: `src/libraries/ZenjiCoreLib.sol:648-652`

```
effectiveSlippage = max(min(swapper.slippage(), 5e16), maxSlippage * 2)
```

`maxSlippage` is gov-settable up to `MAX_VAULT_SLIPPAGE = 5e16` (`ZenjiConstants.sol:20`), so
`maxSlippage * 2` reaches **1e17 = 10 %** — twice as loose as the `MIN_SWAP_OUT_BPS = 9500` (5 %)
standard that both loan managers and `ZenjiCoreLib.MIN_SWAP_OUT_BPS:38` enforce elsewhere. This is
inherited verbatim from `Zenji._swapRemainingDebtToCollateral:947-954` and is pre-existing, but that
path is operator-initiated (`setIdle`, unwind) whereas arm 4 is permissionless and periodic.

**Fix**: `if (effectiveSlippage > 5e16) effectiveSlippage = 5e16;` — one line, keeps arm 4 no looser
than the venue-internal standard.

---

## [I-01] Bytecode margin regressed 16 bytes on all three vaults

`ARM4_SKIM_SPEC.md` §6.9 sets the gate at margins ≥ 1,536 / 1,468 / 1,489. Measured:

| Vault | Size | Margin | Gate | Δ |
|---|---|---|---|---|
| `ZenjiWbtcLlamaUsdtStakeDao` | 23,056 | 1,520 | 1,536 | **−16** |
| `ZenjiWstEthLlamaUsdtStakeDao` | 23,124 | 1,452 | 1,468 | **−16** |
| `ZenjiXautAaveUsdtStakeDao` | 23,103 | 1,473 | 1,489 | **−16** |

Cause: the call site at `Zenji.sol:703-712` now passes `collateralAsset` + `swapper` instead of two
`uint256`s (spec §7 anticipated the arity might not change; it did not, but the argument *kinds* did).
1,452 B of headroom is ample. Flagging only because the spec states a hard gate that is now violated.

## [I-02] Arm 4 does not reserve `accumulatedFees`

Arm 3 explicitly reserves `accumulatedFees` before spending idle debt asset
(`ZenjiCoreLib.sol:~404-412`), citing that `processWithdrawFees:214,227-230` zeroes
`accumulatedFees` before it knows whether the transfer covered them, so a shortfall is silently
forfeited. Arm 4 shrinks the strategy balance by `1.05 × surplus` with no such reserve, and
`_accrueYieldFees`'s `accumulatedFees > currentBalance` cap (`Zenji.sol:1221-1223`) is deliberately
skipped inside the library.

**Verified not a live risk**: arm 4 never touches the vault's idle debt-asset balance — it swaps
exactly `received`, its own withdrawal proceeds — and reaching a shortfall would require
`accumulatedFees > D`, i.e. unwithdrawn fees exceeding the entire debt. Noted only because the
symmetry argument the NatSpec leans on ("exact mirror of arm 3") does not hold on this point.

## [I-03] Worst-case gas of the halving loop

Six failed `aavePool.supply` attempts ≈ 6 × ~250 k plus six ERC-20 transfers ≈ **1.5–2 M gas**,
consumed and then thrown away, on top of the rest of `rebalance()`. Well within a block, and the
keeper bounty is paid before arm 4 runs so the keeper is not out of pocket for a *successful* call —
but a call that ends up posting nothing still costs the keeper full price. Not worth changing;
recorded so it is not a surprise in gas reports.

## [I-04] `ARM4_SKIM_SPEC.md` §8b's premise is stale

§8b argues partial skims are safe because *"a capped skim leaves coverage above the band and LTV
lower, which hands the next tick to arm 1."* Neither half is true of the implementation:

* Coverage does **not** stay above band — the strategy withdrawal at `:639` happens unconditionally,
  so coverage lands ≈ 1.00 (in fact just below, per M-01/B) regardless of how much posting succeeds.
* If posting fails **entirely**, LTV does **not** fall — the collateral sits at the vault and
  `loanManager.getCurrentLTV()` is unchanged — so arm 1 is *not* handed the next tick either.

The outcome is still benign (idle collateral is picked up by `_deployCapital:565-580` on the next
deposit or by a later cycle, and is correctly NAV-counted — see PART 2), and the **function NatSpec
in the code states this correctly** ("the strategy withdrawal in step 1 already happened regardless
of how much collateral posting succeeds"). Only the spec document is out of date. Fix the doc so the
next reader does not inherit the wrong mental model.

---

# PART 2 — What I verified SOUND

## Focus 1 — the oracle floor (arm-3 C-01 by analogy): **CLEARED**

**Is `getDebtValue(received)` the correct basis?** Yes — bit-identical to the venue's own basis, and
it is the exact inverse of arm 3's `getCollateralValue`.

| Adapter | Public entry | Internal | Resolves to |
|---|---|---|---|
| LlamaLend | `getDebtValue` (`LlamaLoanManager.sol:662-663`) | `_getDebtValue` (`:786-787`) | `OracleLib.getDebtValue` Llama overload (`OracleLib.sol:123-142`) |
| Aave | `getDebtValue` (`AaveLoanManager.sol:592-593`) | `_getDebtValue` (`:777-778`) | `OracleLib.getDebtValue` Aave overload (`OracleLib.sol:69-92`) |

`LlamaLoanManager._swapDebtForCollateral:863` floors against `_getDebtValue(debtAmount) * 9500/10000`
— the **same quantity**. ✔

**Unit-correct?** Yes. `getDebtValue` returns *collateral-token units* (`ILoanManager.sol:95-98`;
Aave overload divides by `debtTokenScale` and multiplies by `collateralTokenScale`, `OracleLib:86-91`;
Llama overload divides by hardcoded `1e18` for 18-dp crvUSD, `:138-141`). `collateralOut` is a
collateral-token amount from the same swapper. Same token, same decimals. ✔

**Does it bind on the real swappers?** Analysed honestly:

| Swapper | Vault (`ZenjiCoreLib`) floor | Swapper-internal floor on `swapDebtForCollateral` | Which binds |
|---|---|---|---|
| `UniswapMixedCurveSwapper` (WBTC, wstETH) | 2 % of oracle | **1 % of oracle, end-to-end** — `minWstEth` from `OracleLib.getDebtValue` enforced on the *final* collateral output of the V3 hop (`:204-215, 238`) | **swapper's** (tighter) |
| `UniversalRouterV3SingleHopSwapper` (XAUT) | 2 % of oracle | 1 % of oracle via router `minOut` (`:124-137`) — **but waived to 0 when `expectedOut < DUST_SWAP_THRESHOLD = 1000`** (`:135-137`) | swapper's normally; **vault's** in the dust window |

So for the live configs the vault floor is **defence-in-depth, not load-bearing** — because
`setParam(4)` propagates `maxSlippage` to the swapper (`ZenjiGovLib.sol:129-130, 178-179`), so
`swapper.slippage() == maxSlippage` always and `effectiveSlippage` collapses to `maxSlippage * 2`,
which is by construction looser than the swapper's own `maxSlippage`.

This is **not** the arm-3 C-01 situation and it is worth saying so precisely: arm-3's C-01 was real
because `UniswapMixedCurveSwapper.swapCollateralForDebt` leaves `v3MinOut = 0` for non-wstETH
collateral (`:134-143`). The `swapDebtForCollateral` direction has no such hole — both live swappers
carry an end-to-end oracle floor. The vault-side check correctly covers the one gap that does exist
(the `DUST_SWAP_THRESHOLD` waiver) and correctly protects a future mutable swapper. Keeping it is
right; L-04 is the only tightening I'd ask for.

**Can the oracle basis be moved in-tx?** No. Chainlink push feeds on both legs; deploy scripts
construct the loan manager and the swapper with the **same** oracle addresses
(`DeployWbtcLlamaUsdtStakeDao.s.sol`, `DeployXautAaveUsdtStakeDao.s.sol`), so there is no basis
mismatch to arbitrage. Staleness **reverts** inside `OracleLib._validatedPrice:24-26` rather than
silently widening the floor. ✔

**The `ISwapperSlippage` minimal-interface cast (prior L-04).** All seven vault swappers inherit
`BaseSwapper` (`grep "is BaseSwapper"` — 7/7), which declares `uint256 public slippage`
(`BaseSwapper.sol:14`), so the selector exists on every deployable swapper. Precedent already exists
verbatim at `Zenji.sol:948`. Unchanged risk profile. ✔

**Arithmetic safety**: `effectiveSlippage ≤ max(5e16, 1e17) = 1e17 < precision`, so
`precision - effectiveSlippage` at `:652` cannot underflow. ✔

## Focus 2 — the postcondition (arm-3 C-02 by analogy): **CLEARED**

**Can `newCoverage < startCoverage` hold while value leaks?** Yes — and the code says so, correctly,
at `:674-676` and in the NatSpec ("POSTCONDITION BOUNDS THE RATIO, NOT VALUE ... Do not mistake one
check for the other"). The comment is accurate and the ratio check is *not* being relied on as a
value bound. C-02's lesson has been learned.

Worth stating plainly how weak the check actually is: since debt is never touched,
`newCoverage < startCoverage` reduces to `newS < S`, i.e. **"the withdrawal removed something."**
It is close to vacuous — `InsufficientWithdrawal` at `:641` already guarantees a non-trivial
withdrawal. Its real value is structural: it makes the replaced borrow-and-deposit design
unrepresentable. That is a legitimate reason to keep it.

**What actually bounds value.** I traced every exit from arm 4:

| # | Exit | Bound | Verdict |
|---|---|---|---|
| 1 | `yieldStrategy.withdraw(withdrawRequest)` — LP exit slippage | `received ≥ surplus × (1 − maxSlippage)` (`:640-641`) | **WEAK — see M-01**: nominal 1 %, actual 5.71 % |
| 2 | `debtAsset.safeTransfer(swapper, received)` (`:654`) | `collateralOut ≥ getDebtValue(received) × (1 − effectiveSlippage)` (`:652, 656`) | **SOUND** — 2 % at current config |
| 3 | `collateralAsset.safeTransfer(loanManager, candidate)` (`:665`) | consumed by `addCollateral`, or pulled back by `transferCollateral` (`:669`) | **SOUND — no third exit** |

There is no fourth channel. Value in = value out minus (1) and (2). **The end-to-end bound per call
is therefore ~7.7 % of the surplus today, and would be ~3 % with M-01 fixed** — on a surplus that is
3 % of debt at the trigger, so ~0.23 % of debt per call, falling to ~0.09 %. Not repeatable in the
same block (coverage lands ≈ 1.00, so the trigger clears). ✔

## Focus 3 — the halving retry loop: **CLEARED**

`ZenjiCoreLib.sol:663-672`. Traced exhaustively.

**Can collateral be stranded at the loan manager?** **No.** In the `catch` branch the sub-call frame
is fully rolled back, so the loan manager still holds the `candidate` transferred at `:665` (plus any
pre-existing idle), hence `idle ≥ candidate` on both adapters:

* `LlamaLoanManager.transferCollateral:736-739` — plain `safeTransfer`, balance suffices, cannot revert.
* `AaveLoanManager.transferCollateral:672-686` — takes the `idle >= amount` fast path; the
  `aavePool.withdraw` fallback (which *would* pull collateral out of the live position — a genuine
  hazard) is **unreachable** here. ✔

On success the loop `break`s and the remainder `collateralOut − candidate` was never transferred —
it is still at the vault. No path leaves tokens at the loan manager. ✔

**Is the `try/catch` swallowing errors it should not?**

* **Stale oracle — cannot reach the catch.** Both `addCollateral` implementations call
  `_checkOracleFreshness()` (`AaveLoanManager:203`, `LlamaLoanManager:246`), but
  `loanManager.getDebtValue(received)` at `:647` reads the *same* two feeds through the same
  `_validatedPrice` with the same staleness bounds, and `Zenji.rebalance():655` calls
  `loanManager.checkOracleFreshness()` up front. A stale feed reverts the whole call long before the
  loop. This was the most important thing to rule out and it is ruled out. ✔
* **Genuine venue faults (pool paused, reserve frozen, LLAMMA band assertion) are swallowed** — by
  design (spec §5 #2/#4). Outcome: coverage still corrects, the swap output sits idle at the vault
  and is NAV-counted. Acceptable, but silent — see **L-03**.
* `ZeroAmount()` on `candidate == 0` is prevented by the `candidate > 0` loop guard. ✔
* Termination: `candidate /= 2` reaches 0 in ≤ 6 iterations from any `collateralOut`; the loop is
  bounded by `i < 6` regardless. No unbounded loop. ✔

**Reentrancy across the try boundary?** None. `rebalance()` is `nonReentrant` (`Zenji.sol:640`).
`addCollateral` reaches `aavePool.supply` / `llamaLend.add_collateral`, neither of which calls back
into the vault; WBTC / wstETH / XAUT have no transfer hooks. ✔

**Gas**: bounded, see I-03.

## Focus 4 — the unposted remainder: **CLEARED**

**Counted exactly once?** Yes. `ZenjiViewHelper.getTotalCollateralValue:98` counts
`v.collateralAsset().balanceOf(vault)` as its own term, distinct from `lm.getNetCollateralValue()`
(`:101`, the supplied position) and `lm.getCollateralBalance()` (`:125`, raw collateral at the loan
manager). The three sets are disjoint by construction. Shareholders are credited immediately. ✔

**Stranded?** No. `_deployCapital:565-580` sweeps `collateralAsset.balanceOf(address(this))` into the
position on the next deposit, and withdrawals price against `getTotalCollateral()`. ✔

**Stealable?** No. `ZenjiCoreLib.executeRescueAssets:192-194` **explicitly reverts** when
`token == collateralAsset || token == debtAsset`, so the guardian rescue path cannot touch it even
in emergency mode. ✔

## Focus 5 — withdrawal padding: **FINDING (M-01)**

Confirmed the over-withdraw is real and deterministic (`BaseLPStrategy._withdraw:190` redeems shares
proportional to the *padded* request), not merely a slippage buffer. Quantified above.

One sub-question answered separately: **can the strategy return much more than requested?**
No — `BaseYieldStrategy.withdraw:188` clamps `if (amount > currentValue) amount = currentValue;` and
`:190-199` transfers exactly `received` to the vault. The `withdrawRequest > strategyBalance` cap at
`:638` is redundant-but-harmless (it can only bind above ~2100 % coverage). ✔

## Focus 6 — manipulation: **CLEARED for the trigger; see L-02 for the exit price**

The `AUDIT_Branch_Full.md` §D conclusion holds unchanged: coverage cannot be manipulated **upward**,
because `balanceOf() = min(vpBased, exitBased)` and the `vpBased` leg is clamped to ±0.5 % with a
ratchet that clamps toward — never past — current. Adding a swap and a collateral deposit to arm 4
creates **no new lever that raises coverage**: nothing in the new code feeds back into `vpBased`,
`cachedVirtualPrice`, or `lpTokens` before the trigger is evaluated. ✔

The genuinely new exposure is the *exit price* of the LP withdrawal on a permissionless path — see
**L-02**, which is an extension of accepted H-01 rather than a new class.

## Focus 7 — arm interactions: **CLEARED (though not for the spec's stated reason)**

Spec §8b's argument is stale (see **I-04**), but the actual behaviour is safe on both branches:

* **Posting succeeds** (normal case): `S ↓`, `D` unchanged, collateral at the loan manager ↑ → LTV
  falls, coverage lands ≈ 0.9985. Next tick: if LTV < lowerBand, **arm 1** runs. Arm 1's
  `enforceCoverageAfterIncrease` requires post-borrow `ratio ≥ PRECISION − DEADBAND_SPREAD = 0.97`
  (`ZenjiCoreLib.sol:~727-733`); starting from 0.9985, `(S+b)/(D+b)` moves *up* toward 1, so the
  guard passes with margin. **No deadlock.** This is the failure mode that killed arm-3 partial
  progress and it does not occur here. ✔
* **Posting fails entirely**: coverage still lands ≈ 0.9985 (in band), LTV unchanged, collateral idle
  at the vault. `rebalance()` reverts `RebalanceNotNeeded` on the next tick, which is correct — there
  is nothing left to correct. The idle collateral is deployed by the next `_deployCapital`. ✔
* **Arm 2 (`ltv > upperBand`)**: cannot be induced by arm 4, which only *lowers* LTV. The
  arm-2/arm-4 sawtooth described in the spec for the *old* design is structurally gone. ✔

Residual: the M-01/B overshoot is the one path back into arm-3 territory, and only above `c > 1.6`.

## Focus 8 — keeper bounty / fee accounting: **CLEARED**

* **Ordering.** `Zenji.rebalance():661-684` runs `updateCachedVirtualPrice()` → `_accrueYieldFees()`
  → `processRebalanceBounty(...)` (which sets `lastStrategyBalance` to the **post-bounty** balance,
  `ZenjiCoreLib.sol:274`) → arm 4. Arm 4 then reads `yieldStrategy.balanceOf()` **fresh** at `:620`,
  so the bounty withdrawal is already reflected. No stale baseline. ✔
* **`lastStrategyBalance`.** Arm 4 returns the post-skim balance (`:678, 684`) and the call site
  assigns it (`Zenji.sol:707`). The next `_accrueYieldFees` therefore sees no phantom loss and no
  phantom profit. Skipping `_accrueYieldFees` inside the library is correct — `rebalance()` already
  ran it. ✔
* **`accumulatedFees`.** Arm 4 swaps exactly `received` (`:654`), its own withdrawal proceeds — it
  never touches the vault's pre-existing idle debt-asset balance, which is where a pending fee claim
  would sit. The arm-3 reserve is therefore not needed for correctness here. See **I-02** for the
  one theoretical edge. ✔
* **Bounty farmability unchanged.** The bounty is capped at
  `rebalanceBountyRate × (accumulatedFees − feesAtLastRebalance)` (`:254-256`) and
  `feesAtLastRebalance` advances on every rebalance. Arm 4 adds no new fee-accrual path. ✔
* **Trigger/skim consistency.** `ratioTooHigh` is computed at `Zenji.sol:648-653` from the
  *pre-bounty* balance while the skim sizes off the *post-bounty* balance. The bounty is a fraction
  of fees-since-last-rebalance, orders of magnitude below a 3 %-of-debt surplus; and if it were ever
  large enough to push `S ≤ D`, arm 4 early-returns cleanly at `:621` rather than misbehaving. ✔

## Also verified

* **Call-site correctness** (`Zenji.sol:703-712`): `increased = false` now matches reality (arm 4
  lowers LTV); the removed `maxStrategyRatio` / `upperBand` arguments are still used for the
  dispatch conditions at `:649-653`, so nothing became dead. Dispatch-table NatSpec updated to match.
  Argument order matches the new signature (`loanManager, yieldStrategy, debtAsset, collateralAsset,
  swapper, maxSlippage, PRECISION`) — checked positionally against `:607-615`. ✔
* **All declared errors exist**: `InsufficientWithdrawal:48`, `SwapperUnderperformed:53`,
  `CoverageDidNotImprove:52`. ✔
* **Dust floor** (`:629`) matches the arm-3 and `_swapRemainingDebtToCollateral` convention
  (`10 ** debtAsset.decimals()`, ≈ $1 for USDT and crvUSD). ✔
* **`debt == 0` / `S <= debt` / no-swapper early returns** (`:617-623`) are non-mutating and mirror
  arm 3 exactly. ✔
* **`forge build` clean**; only pre-existing lint warnings in `test/`.

---

# PART 3 — Accepted risks: status

| ID | Prior status | Status after this change |
|----|--------------|--------------------------|
| **H-01** (spot-manipulable `exitBased`, no same-block cooldown) | Accepted | **CHANGED — needs a one-sentence addendum.** Arm 4 does not create a new *trigger* vector (upward manipulation remains impossible), but it does create a new *exit-price steering* surface on a permissionless, non-user-initiated path. See **L-02**. Bounded by the same economics; the four revisit conditions are unaffected. Fixing M-01 shrinks the residual 5.7×. |
| **M-02** (arm 3 liveness: large deficit reverts until `setIdle` cycling) | Open, non-blocking | **Unchanged for arm 3 — but the same class is now introduced on arm 4.** See **M-02** in Part 1. |
| **L-03** (idle-exit fee baseline anchoring) | Accepted | Unchanged — arm 4 does not touch `setIdle`. |
| **L-04** (minimal-interface cast for `slippage()`) | Accepted | Unchanged in kind. Arm 4 adds a second instance (`ISwapperSlippage`, `ZenjiCoreLib.sol:27-29`) with the same rationale and the same 7/7 `BaseSwapper` coverage. Noted, not re-raised. |

---

# PART 4 — Ship checklist

**Before merge (blocking):**
1. **M-01** — drop the `105/100` pad at `ZenjiCoreLib.sol:637-638`. Two lines. This is the only
   change I would gate the merge on.

**Before deploy (decide consciously):**
2. **M-02** — decide whether arm 4 should degrade or revert on a swap-floor miss, and document the
   `setIdle(true)/setIdle(false)` escape in the NatSpec the way arm 3 does. Fork-test the XAUT/Aave
   skim at ~3 % of debt against the live USDT→XAUT pool specifically.

**Cheap, do them now:**
3. **L-01** — measure `collateralOut` as a vault-side balance delta (2 lines).
4. **L-03** — emit a skim event carrying `(received, collateralOut, posted, remainder)`.
5. **L-04** — clamp `effectiveSlippage` at `5e16` (1 line).
6. **H-01** — add the addendum sentence to `rebalanceCoverageUp`'s ACCEPTED RISK block.
7. **I-04** — correct `ARM4_SKIM_SPEC.md` §8b; the code NatSpec is already right.

**Fork tests I'd add beyond spec §6** (all in scope of the other agent's work):
* Assert **`received ≥ withdrawRequest × (1 − maxSlippage)`**, not against `surplus` — this is the
  test that would have caught M-01, and it should stay in the suite after the fix as a regression guard.
* Assert landing coverage ∈ `[1.0000, 1.0001]` (post-fix), not merely "in band" — "in band" passes
  today *with* the overshoot.
* Drive `c ≈ 1.65` and assert arm 3 does **not** fire on the next tick.
* Skew the Curve pool downward to just above `1.03·D`, run arm 4, and measure realised NAV loss
  (L-02's number) — before and after the M-01 fix, to confirm the 5.7× reduction.
* All six `addCollateral` attempts failing (mock a reverting loan manager): assert zero tokens at the
  loan manager, full `collateralOut` idle at the vault, `getTotalCollateralValue` unchanged
  modulo swap cost, and no revert.
