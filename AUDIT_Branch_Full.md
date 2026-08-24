# Security Audit — Full Feature Branch (`main..HEAD`)

**Date**: 2026-08-24
**Scope**: all 12 commits on the branch, `src/` only as the audit target (`test/` read as evidence
of intent, not audited). 49 files changed; the `src/` delta is 5 files:

| File | Δ | Commit(s) |
|---|---|---|
| `src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol` | +164 (new) | `938f61e` |
| `src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol` | +47 (new) | `938f61e` |
| `src/libraries/ZenjiCoreLib.sol` | +296 | `e5065aa`, `699b78a`, `7bea682` |
| `src/lenders/LlamaLoanManager.sol` | +8 | `e5065aa` |
| `src/Zenji.sol` | +38 (37 NatSpec + 1 call-site) | `e5065aa` |

Plus `script/DeployXautAaveUsdtStakeDao.s.sol` (new) and the `7141087` retirement move.

**Build**: `forge build` clean (only pre-existing lint warnings, all in `test/`).
`retired/` confirmed **not** compiled — `foundry.toml` pins `src = "src"` / `test = "test"`, and no
retired artifact exists in `out/`.
**Method**: full read of every file in the `src/` delta plus everything reachable from it
(`BaseLPStrategy`, `BaseCurveStakeDaoStrategy`, `BaseYieldStrategy`, `UsdtCrvUsdSwapMixin`,
`CurveUsdtSwapLib`, `SafeTransferLib`, both loan managers, `ZenjiViewHelper`, `ZenjiGovLib`,
`ZenjiConstants`, `Zenji.rebalance/_withdrawFromYieldStrategy/_swapRemainingDebtToCollateral/
_accrueYieldFees`, share math). Live mainnet verification via `cast` for pool, staking vault,
gauge, coin ordering and Aave eMode. **No fork tests were run** (another agent owns that suite).

**Prior reports read and honoured**: `AUDIT_CoverageRebalance.md`,
`AUDIT_CoverageRebalance_v2.md` (incl. the accepted-risk H-01 section),
`AUDIT_PartialProgress.md`, `COVERAGE_REBALANCE_FIX_PLAN.md`,
`COVERAGE_PARTIAL_PROGRESS_PLAN.md`, `ARM4_VERIFICATION_PLAN.md`.

---

## Verdict

**SHIP.**

Zero Critical, zero High, zero Medium. Two Low and five Informational, none ship-blocking.

The branch is unusually low-risk for its size. The reason is structural, not luck: the two
"never audited" code additions are compositions of already-audited parts rather than new
mechanisms.

* `UsdtCrvUsdLpStakeDaoStrategy` is `CrvUsdLpStakeDaoStrategy._addLiquidity` (verbatim, byte-for-byte)
  bolted onto `UsdtNgCrvUsdLpStakeDaoStrategy`'s mixin wiring (verbatim). Both halves are already
  live: the legacy `_addLiquidity` runs against **this exact pool** (`0x390f…7BF4`) in
  `DeployWbtcLlamaUsdtStakeDao.s.sol:83-90`, and the USDT mixin wiring is the audited NG variant.
  I diffed both halves against their sources and found no drift.
* `ZenjiXautAaveUsdtStakeDao` is **constant-for-constant identical** to the retired
  `ZenjiXautAaveStakeDao` (`MAX_TARGET_LTV = 60e16`, `VIRTUAL_SHARE_OFFSET = 1e3`,
  `MIN_DEPOSIT = 2000`, same XAUT/USDT pair), and its deploy script passes the *same*
  loan-manager params (`6000` / `7500` / eMode 43 / `90000`) and the *same* swapper
  (`UniversalRouterV3SingleHopSwapper`, XAUT/USDT 0.05%). Only the yield leg changed.

Accepted risk H-01 is **unchanged in substance** — see the dedicated section below — but its
*written* analysis has gone stale in a way that matters operationally (L-02).

---

# NEW FINDINGS

## [L-01] Arm 4 (`rebalanceCoverageDown`) cannot reach the band, has no postcondition, and silently no-ops at the LTV ceiling

**Severity**: Low (benign direction — no fund loss; liveness/observability)
**Location**: `src/libraries/ZenjiCoreLib.sol:523-570`
**Status**: pre-existing code, never audited; in scope per the brief. Unchanged by this branch.

### Issue A — the sizing formula ignores its own deposit

```solidity
uint256 targetDebtAtMaxRatio = (strategyBalance * precision) / maxStrategyToDebtRatioForBorrow;
...
uint256 requiredBorrow = targetDebtAtMaxRatio - debt;
```

`maxStrategyToDebtRatioForBorrow` is `maxStrategyRatio = 1 + DEADBAND_SPREAD` (`Zenji.sol:636`,
`DEADBAND_SPREAD = 3e16`). So the borrow is sized to make `S / D_new = 1.03` — but the borrowed
amount is then **deposited into the strategy**, which raises `S` too. The postcondition the formula
solves for is therefore never the postcondition that obtains.

Let `c = S/D` be the coverage at entry, `b = S/1.03 − D` the borrow. Post-call coverage is

```
c' = (S + b) / (D + b) = 2.03 − 1.03/c
```

Fixed points: `c' = c` ⇔ `c² − 2.03c + 1.03 = 0` ⇔ `c ∈ {1.00, 1.03}`. So `c'` decreases
monotonically toward 1.03 but **never reaches it in finite steps**. Concrete trace from `c = 1.10`:

| tick | S | D | coverage |
|---|---|---|---|
| 0 | 1.100 | 1.000 | 1.1000 |
| 1 | 1.168 | 1.068 | 1.0936 |
| 2 | 1.234 | 1.134 | 1.0882 |
| 3 | 1.298 | 1.198 | 1.0835 |

Each tick grows the balance sheet by ~6% and closes ~8% of the remaining excess. `ratioTooHigh`
stays true throughout, so the keeper is asked to call `rebalance()` forever.

### Issue B — silent no-op with a misleading success event

Every call is additionally bounded by the LTV ceiling:

```solidity
uint256 maxDebtByLtv = (collateralValue * maxLtvTarget) / precision;   // maxLtvTarget = upperBand
if (maxDebtByLtv <= debt) return strategyBalance;                       // ZenjiCoreLib.sol:544
```

Once LTV reaches `upperBand`, this returns the unchanged strategy balance. Control returns to
`rebalance()`, which does **not** revert — it reads `newLtv` and emits
`Rebalance(currentLtv, newLtv, true)` with `currentLtv == newLtv` (`Zenji.sol:693-702`). Three
consequences:

1. Coverage stays out of band permanently with no error surfaced anywhere.
2. `strategyDebtRebalanceNeeded()` stays `true`, so the Chainlink CRE keeper calls `rebalance()`
   on every cron tick, forever, burning gas on a guaranteed no-op.
3. A monitor cannot distinguish "rebalanced" from "did nothing" — the emitted event is identical.
   The keeper bounty is also payable on these no-ops (bounded, see below).

Contrast arm 3, which reverts `CoverageDidNotImprove()` (`:511`) precisely to make this class of
"looks corrective, isn't" outcome unrepresentable. Arm 4 has no equivalent.

### Why this is Low, not Medium

Coverage `> 1` is the **safe** direction: the strategy holds more than the debt. A permanent
over-coverage is an efficiency loss (idle equity in the strategy), not a solvency risk. The bounty
is not farmable — `processRebalanceBounty` sets `feesAtLastRebalance = accumulatedFees` on every
call (`ZenjiCoreLib.sol:263`), so a repeat tick with no fresh fee accrual pays 0. I confirmed there
is no path where arm 4 over-levers past the deadband: `maxDebtByLtv` is hard-capped at
`upperBand`, and `AaveLoanManager.borrowMore` independently enforces `MIN_HEALTH` (`:222-225`).

### Recommendation

Two-line fix, either of:

```solidity
// (a) size for the post-deposit state:  (S+b)/(D+b) = R  =>  b = (S - R·D)/(R - 1)
uint256 requiredBorrow = (strategyBalance - (debt * maxStrategyToDebtRatioForBorrow) / precision)
    * precision / (maxStrategyToDebtRatioForBorrow - precision);
```

```solidity
// (b) at minimum, make the no-op observable
if (maxDebtByLtv <= debt) revert CoverageCappedByLtv(debt, maxDebtByLtv);
```

(a) makes arm 4 converge in one call and matches arm 3's stated "reach parity in ONE call" premise
(`Zenji.sol` rebalance NatSpec). (b) alone is sufficient to close the operational half. I'd take
both.

---

## [L-02] The accepted-risk H-01 analysis and its monitoring runbook are stale after `699b78a`

**Severity**: Low (documentation / operational runbook)
**Location**: `AUDIT_CoverageRebalance_v2.md:574-651`, "Residual risk" and "Monitoring" subsections

`AUDIT_CoverageRebalance_v2.md` was written against the partial-progress implementation. It
explicitly strikes through the old "a large manufactured deficit reverts" paragraph and replaces it
with:

> ~~M-01 introduced a transient interaction: a large manufactured deficit now trips `MIN_HEALTH`
> inside `removeCollateral`, so `rebalance()` reverts instead of transacting.~~
> **SUPERSEDED by the M-02 partial-progress change** … A large manufactured deficit no longer
> reverts — it now takes a BOUNDED PARTIAL collateral sale, capped by a safe-removal search…

and instructs the operator to:

> **Alert on repeated SUCCEEDING partial arm-3 rebalances** — since the partial-progress change
> that, not a reverting call, is the signature of a large deficit being worked down over several
> ticks.

**Commit `699b78a` removed partial progress.** Arm 3 is now all-or-nothing
(`ZenjiCoreLib.sol:449-471`): the binary search is gone, replaced by a single feasibility probe that
reverts `CoverageDeficitTooLarge`. The struck-through paragraph is **live again** on Aave; the
replacement paragraph describes behaviour that no longer exists; and the monitoring alert looks for
a signature (`repeated succeeding partial arm-3 rebalances`) that the code can no longer produce.

This matters because H-01's *acceptance* is conditioned on that analysis. The substantive conclusion
survives — see the H-01 re-check below — but an operator following the current runbook would be
watching the wrong signal, and the "revisit if" checklist is now anchored to a code shape that is
two commits out of date.

### Recommendation

Amend the accepted-risk section before shipping:
1. Un-strike the `MIN_HEALTH`/revert paragraph and note it applies on **Aave** (on LlamaLend the
   `healthCalculator` projection is near-insensitive to `dCollateral` — the code's own measured
   note at `ZenjiCoreLib.sol:440-446` — so the probe effectively always passes there).
2. Replace the monitoring bullet with: *alert on `CoverageDeficitTooLarge` reverts* — that is now
   the signature of a large (genuine or manufactured) deficit, and it is the operator's cue to run
   `setIdle(true)/setIdle(false)`.
3. Note that the H-01 attacker must once again size the deficit precisely to avoid tripping the
   probe — the "removed the need to size precisely" claim is reversed.

---

# INFORMATIONAL

## [I-01] The `accumulatedFees` idle reserve is correct but unconditionally conservative

**Location**: `ZenjiCoreLib.sol:405-407`

```solidity
uint256 idle = debtAsset.balanceOf(address(this));
uint256 usable = idle > accumulatedFees ? idle - accumulatedFees : 0;
```

The reserve is **sound and load-bearing**, and my initial read that it was redundant was wrong.
`_accrueYieldFees` caps `accumulatedFees ≤ currentBalance` (`Zenji.sol:1213-1215`), so at accrual
time the strategy alone covers the claim — but `processWithdrawFees` withdraws
`min(fees, strategyBalance)` and takes whatever the strategy *actually delivers* after slippage
(`ZenjiCoreLib.sol:211-217`), then zeroes `accumulatedFees` before checking whether the transfer
covered them (`:207`, `:222-225`). The idle balance is the buffer that makes the fee claim whole on
a lossy strategy withdrawal. Arm 3 preserving it is correct.

The cost: arm 3 will sell collateral (paying the swap round-trip, ~2 bp measured, floored at 5%)
while holding idle debt asset it is forbidden to touch, in the common case where the strategy would
have covered the fees anyway. This is a deliberate trade of a small, bounded cost for the
strategist's claim. No action required — flagging so the trade is a conscious one.

## [I-02] Arm 3's all-or-nothing reverts discard the free idle-funded progress

**Location**: `ZenjiCoreLib.sol:405-412` vs `:427-431`, `:449-451`

The idle repay executes **before** both `DeficitExceedsCollateral` and `CoverageDeficitTooLarge`.
When either fires, the whole transaction rolls back, discarding a repay that was strictly
beneficial and cost zero slippage.

I checked whether this should be restructured and concluded **no**. An idle-funded partial repay
lowers `D` and therefore LTV by exactly the same mechanism as the collateral-funded partial repay
that `699b78a` deliberately removed — it would drag LTV past `lowerBand`, hand dispatch priority to
arm 1, and reintroduce the deadlock documented at `ZenjiCoreLib.sol:432-448`. Atomicity is the
correct choice. Noting it because the code comment sells the idle spend as unconditionally free,
and it is not free in the revert path.

## [I-03] The gold vault's effective LTV ceiling is 63%, not the 60% its `MAX_TARGET_LTV` comment implies

**Location**: `src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol:23-26`

```solidity
/// @notice XAUT loan manager maxLtvBps = 6000 (60%); cap targetLtv to match.
function MAX_TARGET_LTV() public pure override returns (uint256) { return 60e16; }
```

`Zenji`'s constructor sets `targetLtv = MAX_TARGET_LTV()` (`Zenji.sol:282`), so the vault launches
at its ceiling. Arm 4 then borrows up to `upperBand = targetLtv + DEADBAND_SPREAD = 63%`
(`Zenji.sol:634`, passed as `maxLtvTarget` at `Zenji.sol:697`). So the vault's real operating
ceiling exceeds `AaveLoanManager.maxLtvBps = 6000`.

**This is not a bug** — I traced every use of `maxLtvBps` and it is enforced nowhere on the borrow
path: only `getRequiredCollateral` (`AaveLoanManager.sol:641`) and the governance `targetLtv` cap
(`ZenjiGovLib.sol:85`, `:160`) read it. The position is safe at 63%:

* Verified on-chain: `getEModeCategoryCollateralConfig(43)` → **LTV 7000, LT 7500, bonus 10600**
  (`"XAUt__USDC_USDT_GHO"`). Exactly what the deploy script's comment claims.
* 63% < 70% Aave LTV → the borrow is accepted.
* Health at 63% = 0.75/0.63 = **1.190** vs `MIN_HEALTH = 1.1e18`, independently enforced by
  `AaveLoanManager.borrowMore:222-225`.
* Gold can fall 16% before liquidation.

The comment is what's wrong. Suggest: *"targetLtv ceiling 60%; arm 4 may lever to 63% (`+DEADBAND_SPREAD`), still inside Aave's eMode-43 70% LTV, health 1.19."*

## [I-04] `CurveUsdtSwapLib.exchange` masks legitimate `minOut` reverts as `ExchangeFailed`

**Location**: `src/libraries/CurveUsdtSwapLib.sol:95-110`

```solidity
try ICurveStableSwapWithReceiver(address(pool)).exchange(i, j, dx, minOut, address(this)) returns (...)
catch { try pool.exchange(i, j, dx, minOut) returns (...) catch { revert ExchangeFailed(); } }
```

When the oracle floor or spot floor is genuinely not met, the 5-arg call reverts with Curve's slippage
error, the catch swallows it, the 4-arg call reverts for the same reason, and the operator sees
`ExchangeFailed()` — which reads as "the pool doesn't support the ABI", not "the swap was too
expensive". Pre-existing, but the new deployment touches this pool **four times per deposit/withdraw
round trip** (the test file's own note), so the diagnostic is on a hotter path than before.

Cheap fix: probe ABI support once at construction and store a `bool useReceiverVariant` immutable,
then bubble the revert instead of catching it.

## [I-05] XAU/USD is the price basis for XAUt

**Location**: `script/DeployXautAaveUsdtStakeDao.s.sol:34` — `XAU_USD_ORACLE = 0x214eD9Da…`

Tether Gold is priced off the spot-gold feed, not an XAUt-specific feed. This is the standard
approach (Aave does the same for its XAUt reserve) and, critically, it is **consistent**: the same
address is passed to the loan manager (`:108`), the collateral swapper (`:78`), and nothing else
prices XAUT. There is no basis mismatch to arbitrage between the arm-3 `MIN_SWAP_OUT_BPS` floor and
the swapper's own floor. Unchanged from the retired XAUT vault. Flagged only so the XAUt/XAU basis
risk is a recorded assumption rather than an implicit one.

---

# FOCUS AREAS — WHAT I VERIFIED SOUND

## A. `UsdtCrvUsdLpStakeDaoStrategy` + gold vault (`938f61e`) — CLEAR

### On-chain configuration, verified live

| Check | Expected | Actual |
|---|---|---|
| `coins(0)` | USDT | `0xdAC17F…31ec7` ✔ |
| `coins(1)` | crvUSD | `0xf939E0…c1b4E` ✔ |
| pool identity | legacy plain pool | `"Curve.fi Factory Plain Pool: crvUSD/USDT"` ✔ |
| LP token | pool itself | reward vault `asset()` = `0x390f…7BF4` ✔ |
| reward vault | crvUSD/USDT | `"Stake DAO Curve.fi Factory Plain Pool: crvUSD/USDT Vault"` ✔ |
| `ACCOUNTANT()` | non-zero | `0x93b4B9…1Ce0` ✔ |
| Aave eMode 43 | 70/75/10600 | `(7000, 7500, 10600, "XAUt__USDC_USDT_GHO")` ✔ |
| pool depth | — | 43.8M USDT / 41.7M crvUSD, `A = 2000`, fee 1 bp |
| `get_virtual_price` | — | `1.027063457144611728e18` |

`DeployXautAaveUsdtStakeDao._assertCoinOrdering()` (`:145-152`) asserts coins 0/1 on-chain at
deploy time and covers all three index arguments in one check, because the swap leg and the LP leg
share the pool. `USDT_INDEX = 0`, `CRVUSD_INDEX = 1`, `lpCrvUsdIndex = CRVUSD_INDEX` — consistent,
and the assert makes an inverted deploy impossible. Good pattern.

### Decimals — every conversion checked

`lpAsset = crvUSD` (18 dec) is the right choice: `BaseLPStrategy.balanceOf` computes
`lpTokens * unitValue / 1e18`, and Curve's `get_virtual_price` is denominated in the pool's 18-dec
LP unit. Making `lpAsset = USDT` would have broken that. The NatSpec at
`UsdtCrvUsdLpStakeDaoStrategy.sol:22-27` states this reasoning correctly.

| Expression | Location | Units | Verdict |
|---|---|---|---|
| `oracleMinLp = crvUsdAmount * 1e18 * (1e18 − 5e15) / (safeVP * 1e18)` | `:104-106` | 18(crvUSD)+18−18−18 = 18 (LP) | ✔ |
| `_crvUsdValueToUsdt` → `crvUsdValue * cuPrice / (usdtPrice * 1e12)` | `CurveUsdtSwapLib.sol:139` | 18+8−8−12 = **6** (USDT) | ✔ |
| `_oracleFloor6to18` → `amountIn * inPrice * 1e12 / outPrice` | `:161` | 6+8+12−8 = **18** | ✔ |
| `_oracleFloor18to6` → `amountIn * inPrice / (outPrice * 1e12)` | `:174` | 18+8−8−12 = **6** | ✔ |
| `_crvToPendingRewards` → `pendingCrv * crvPrice / (usdtPrice * 1e12)` | `:150` | 18+8−8−12 = **6** | ✔ |
| `_pendingRewardsFallback` → `crvSwapper.quote(crv) / 1e12` | `:157` | 18−12 = **6** | ✔ |

`balanceOf()` therefore returns USDT 6-dec, matching `getCurrentDebt()` (USDT), so the coverage
ratio `S/D` in `rebalance()` is dimensionally sound. Both 6-dec hooks are **byte-identical** to the
audited `UsdtNgCrvUsdLpStakeDaoStrategy:88-107`.

XAUT's 6 decimals affect only the vault's share math, and those constants are unchanged from the
retired XAUT vault. Sanity-checked anyway: `VIRTUAL_SHARE_OFFSET = 1e3` = 0.001 XAUT ≈ $4.49 at
$4,490/oz; the OZ virtual-offset bound means an inflation attacker must donate ≈ 1000× what they
extract, and the donation accrues to the victims. `MIN_DEPOSIT = 2000` (≈$9) ≥ offset, preserving
the economics. Sound.

### Same-pool swap + LP composition — the sandwich legs are *opposed*

This was the sharpest question in the brief, and the answer is favourable. Deposit is
`USDT →(exchange, pool P)→ crvUSD →(single-sided add, pool P)→ LP`:

* To harm **leg 1** an attacker makes crvUSD expensive in P (buys crvUSD out) → but that leaves P
  crvUSD-*poor*, and adding the scarce coin single-sided earns an imbalance **bonus**, helping leg 2.
* To harm **leg 2** an attacker makes P crvUSD-*rich* → but then leg 1's `get_dy` for USDT→crvUSD
  improves, helping leg 1.

A sandwich cannot hurt both legs in the same direction. The withdraw path
(`remove_liquidity_one_coin(crvUSD)` then `exchange crvUSD→USDT`, both in P) has the same
opposition. The extra cost of the same-pool design is two fee legs (1 bp each) plus the implicit
add/remove fee — measured live below.

Independently, each leg carries a real floor:

* Leg 1 (`CurveUsdtSwapLib.swapUsdtToCrvUsd:41`): `minOut = max(spot get_dy·(1−slip),
  oracle·(1−slip))`. The **oracle** term is genuine protection — it is a Chainlink-anchored floor,
  not a same-tx quote.
* Leg 2 (`UsdtCrvUsdLpStakeDaoStrategy:107-109`): `minLp = max(calc_token_amount·0.995,
  crvUsdAmount·0.995/safeVP)`. The second term is anchored to the ±0.5%-clamped cached VP, so the
  vault always receives LP worth ≥ 99.5% of the crvUSD it contributed in VP terms. Also genuine.

### Measured round-trip cost at the advised cap

`deployments/DEPOSIT_CAPS.md:60` caps the gold vault at **95 XAUT** (~$427k TVL) at 60% LTV →
~$256k of USDT debt deployed. Live simulation of that size:

```
get_dy(USDT→crvUSD, 256,000 USDT)      = 255,967.38 crvUSD     (−0.013%)
calc_token_amount([0, 255,000], true)  = 248,270.83 LP
  → LP × VP (1.027063)                 = 254,997.4 crvUSD      (−0.001%)
oracle floor  = 255,000 × 0.995 / 1.027063 = 247,013 LP   (not binding, 0.5% of room)
calc floor    = 248,270 × 0.995            = 247,029 LP   (binding term)
```

Full deposit leg costs ~1.4 bp against a `maxSlippage` of 1% — two orders of magnitude of headroom.
The oracle floor sits *below* the spot floor under fair conditions, which is exactly right: it binds
only under manipulation.

Note `calc_token_amount` on legacy plain pools omits the imbalance fee, so `expectedLp` overstates
slightly and `minLp = expectedLp·0.995` must absorb that fee. At a 1 bp pool fee the single-sided
imbalance fee is ≲0.5 bp — 10× inside the 0.5% `LP_SLIPPAGE`. Safe. (Same property as the already-live
`CrvUsdLpStakeDaoStrategy` on this pool.)

### Other checks on the new strategy

* **`add_liquidity` return value**: legacy plain pools of this vintage return `uint256`. Not taken
  on faith — `CrvUsdLpStakeDaoStrategy` already runs `_addLiquidity` against **this same pool** in
  the live WBTC/wstETH LlamaLend deployments (`DeployWbtcLlamaUsdtStakeDao.s.sol:83-90`), so the
  ABI shape is proven in production.
* **Approval collision**: in the same-pool config, crvUSD is approved to pool `P` by two paths —
  `BaseYieldStrategy._ensureApprove` (`:294-296`) and `SafeTransferLib.ensureApproval` via the
  mixin (`:69`). Verified these are the **same function**: `_ensureApprove` is a one-line forwarder
  to `IERC20.ensureApproval`. No divergent allowance state. USDT's approve-from-nonzero quirk is
  handled by `safeApprove:40-47`. Sound.
* **`_isProtectedToken` coverage**: `BaseCurveStakeDaoStrategy:243-246` protects
  `{debtAsset=USDT, lpToken=P, lpAsset=crvUSD, stakingVault, CRV}`. In this configuration the
  "other coin" of the pool *is* the debt asset, already protected — so no gap versus the NG variant's
  extra `otherCoin` protection. `rescueAssets` cannot drain any live asset.
* **Constructor ordering**: `_initializeUnitValueCache()` runs inside `BaseCurveStakeDaoStrategy`'s
  constructor *after* `lpPool` is assigned (`:96-102`) and reads only `lpPool.get_virtual_price()` —
  no dependency on mixin state, so the C3 linearization (`BaseCurveStakeDaoStrategy` then
  `UsdtCrvUsdSwapMixin`) is safe.
* **`name`**: declared as `string public override name` rather than the sibling's
  `function name() external pure override`. The auto-generated getter satisfies
  `IYieldStrategy.name()`. Compiles and is ABI-compatible.

## B. NEW-02 idle-debt spend (`7bea682`) — CLEAR

**Can a donation of debt asset harm or be stolen?** No. I enumerated every exit for idle debt asset:

| Exit | Bound |
|---|---|
| arm 3 repay (`ZenjiCoreLib.sol:409-410`) | NAV-neutral (idle −x, debt −x); benefits all shareholders |
| `processWithdrawFees` (`:220-224`) | ≤ `accumulatedFees`, which arm 3 reserves |
| `_swapRemainingDebtToCollateral` (`Zenji.sol:915-950`) | converts to collateral, stays in vault; floored against `loanManager.getDebtValue` |
| `executeRescueAssets` (`:177-192`) | **explicitly reverts** for `token == debtAsset` |
| user withdraw | proportional to shares |

A donation raises `getTotalCollateralValue` via `ZenjiViewHelper:118-122`, which credits *existing*
shareholders. There is no path that routes it to the donor beyond their pro-rata share. No harm,
no theft.

**Is the early-exit coverage check equivalent to the main path's postcondition?** Yes, and I
checked it line by line.

```solidity
// early exit (:415-423)                         // main path (:505-511)
S' = yieldStrategy.balanceOf();                  S' = yieldStrategy.balanceOf();
D' = loanManager.getCurrentDebt();               D' = loanManager.getCurrentDebt();
cov = D'==0 ? max : S'*P/D';                     cov = D'==0 ? max : S'*P/D';
if (cov <= startCoverage) revert …;              if (cov <= startCoverage) revert …;
```

Structurally identical, same `startCoverage` baseline. Sound.

Reachability is also correct: the early exit can only fire when `fromIdle > 0`, because the
pre-idle dust gate at `:394` already returned for `deficit ≤ 1 unit`. If `usable == 0` the deficit
is unchanged and still above dust, so control necessarily falls through to the collateral path.
There is no "revert on a no-op" hole.

**Does skipping `MIN_SWAP_OUT_BPS` on the early-exit path matter?** No — and this is the right call,
not an oversight. `MIN_SWAP_OUT_BPS` exists solely to bound the *collateral→debt swap*
(`:485-492`); on the early-exit path no swap occurs, no collateral leaves the vault, and no value
crosses a price boundary. The floor would have nothing to floor. Confirmed by exhaustive exit
enumeration: the only `safeTransfer` on the early-exit path is `debtAsset → loanManager`,
immediately consumed by `repayDebt`, with `fromIdle ≤ deficit ≤ debt` so no overpayment can strand.

**Is the `accumulatedFees` reserve correct?** Yes — see I-01. Load-bearing, not redundant.

**Interactions with `lastStrategyBalance` / `_accrueYieldFees` / the bounty:**

* Arm 3 never touches `S`. Every return path (`:400`, `:412`, `:422`, `:426`, `:513`) yields a value
  equal to the live `yieldStrategy.balanceOf()`, so the stale-vs-fresh read at `:426`
  (`cDesired == 0 → return strategyBalance`) is provably identical. No `lastStrategyBalance` drift.
* `_accrueYieldFees()` runs before the bounty (`Zenji.sol:658`) and arm 3 receives the
  post-bounty-deduction `accumulatedFees` (`:671`, `:688`). Correct ordering.
* **New interaction introduced by this commit, and it is benign:** `processRebalanceBounty`
  withdraws `min(bounty, strategyBalance)` from the strategy and pays `bountyPaid = min(withdrawn,
  bounty)` (`ZenjiCoreLib.sol:252-259`). Any excess `withdrawn − bountyPaid` now lands as idle debt
  asset — which arm 3, running a few lines later, immediately repays into the loan instead of
  leaving it stranded. Net effect on `D − S`: `S` falls by `withdrawn`, `D` falls by
  `withdrawn − bountyPaid`, so `D − S` rises by exactly `bountyPaid` — i.e. the bounty cost and
  nothing more. Strictly an improvement over the prior behaviour.
* Same-transaction interest accrual is a non-issue: both venues' `repay` accrue to
  `block.timestamp`, and `debt` was read in the same block, so `getCurrentDebt()` before and after
  differ only by the repay. Verified for `AaveLoanManager.repayDebt:231-237` and
  `LlamaLoanManager.repayDebt:268-274`.
* Neither USDT nor crvUSD has transfer hooks, so the `safeTransfer` at `:409` cannot reenter and
  perturb `S` between the two reads.

## C. pmUSD retirement (`7141087`) — CLEAR

**No deployable path reaches the pmUSD pool.** `grep` over `src/`, `script/`, `test/` finds the
string only in (a) NatSpec examples in the generic NG base/strategy — which remain in `src/` because
`UsdtNgCrvUsdLpStakeDaoStrategy` still uses them and they are pool-agnostic by construction
(`BaseNgCrvUsdLpStakeDaoStrategy:20-24` derives the other coin from the pool, nothing hardcoded);
(b) a mock address in `test/VerifyH7_CrvOracleDoS.t.sol`; (c) comparative prose. The three live
deploy scripts are `DeployWbtcLlamaUsdtStakeDao`, `DeployWstEthLlamaUsdtStakeDao`,
`DeployXautAaveUsdtStakeDao` — all crvUSD/USDT.

**`retired/` is not compiled.** `foundry.toml` pins `src = "src"` and `test = "test"`; `out/`
contains no retired artifact. Nothing reachable was broken by the move.

**The "differ only in `name()`/`symbol()`" claim — VERIFIED, and it is exactly true.** Full
constant-by-constant diff:

| | retired `ZenjiWbtcLlamaStakeDao` | live `ZenjiWbtcLlamaUsdtStakeDao` |
|---|---|---|
| collateral | WBTC `0x2260FA…2C599` | **same** |
| debt | crvUSD `0xf939E0…c1b4E` | **same** |
| `VIRTUAL_SHARE_OFFSET` | `1e4` | **same** |
| `MIN_DEPOSIT` | `1e4` | **same** |
| `MAX_TARGET_LTV` | inherited (65%) | **same** |
| `name`/`symbol` | `"…(pmUSD/crvUSD LlamaLend)"` / `zenWBTC-LL-pmUSD` | `"…(USDT/crvUSD LlamaLend)"` / `zenWBTC-LL-USDT` |

Identical for the wstETH pair (`3e15` / `3e15` both sides). Since neither `name()` nor `symbol()` is
read by any accounting, oracle, or risk path, **repointing the tests masks no behavioural
difference.** The tests are now exercising the contracts that are actually deployed, which is a
strict improvement.

Same check for the gold vault: `ZenjiXautAaveUsdtStakeDao` vs retired `ZenjiXautAaveStakeDao` —
identical on `MAX_TARGET_LTV` (`60e16`), `VIRTUAL_SHARE_OFFSET` (`1e3`), `MIN_DEPOSIT` (`2000`), and
asset pair; only `name`/`symbol` differ. The loan-manager and swapper arguments in the two deploy
scripts are identical line-for-line.

## D. Arm 4 (`rebalanceCoverageDown`) — CLEAR except L-01

**Can it over-lever?** No. Hard-capped at `maxDebtByLtv = collateralValue × upperBand`
(`ZenjiCoreLib.sol:542-543`), with `AaveLoanManager.borrowMore:222-225` /
`LlamaLoanManager` enforcing `MIN_HEALTH` independently. For the gold vault: 63% vs eMode LTV 70%
(verified on-chain) and health 1.19 vs floor 1.1. See I-03.

**Can it be induced by manipulating coverage UPWARD?** No — and the `min()` genuinely caps it.
`balanceOf()` is `min(vpBased, exitBased)` (`BaseCurveStakeDaoStrategy:113-121`). To trigger arm 4
an attacker must raise **both** legs:

* `exitBased = calc_withdraw_one_coin` is raw spot and *is* movable upward (make P crvUSD-heavy) —
  but it is then no longer the minimum, so it stops mattering.
* `vpBased` is `lpTokens × _getSafeUnitValue() / 1e18`, clamped to ±0.5% around
  `cachedVirtualPrice`. Two escape routes examined and both closed:
  * **Ratchet abuse**: `updateCachedVirtualPrice()` is permissionless with no cooldown, and each
    call moves the cache 0.5% toward `current`. So N calls in one transaction move the cache up to
    N×0.5%. But `_getSafeUnitValue` clamps toward `current`, never past it — the ratchet is a
    *rate limiter toward truth*, and it converges to the real `get_virtual_price`. It cannot
    manufacture value.
  * **Moving `get_virtual_price` itself**: Curve's VP is invariant-per-LP-share. It only ratchets
    up from fees; a donation raises it but costs more than it yields. And crucially this pool holds
    **no raw ETH**, so there is no `remove_liquidity` reentrancy hook — the classic read-only
    reentrancy VP inflation does not apply here.

**Does the `MAX_VP_STALENESS` (1 day) bypass reopen it?** No. Two independent reasons:
1. `rebalance()` calls `yieldStrategy.updateCachedVirtualPrice()` as its *first* strategy
   interaction (`Zenji.sol:654`), which sets `lastVpUpdate = block.timestamp`. Every subsequent read
   inside that transaction is clamped, anchored to a value taken in the same transaction.
2. Even in the bypass, the returned value is the raw `get_virtual_price`, which the preceding
   paragraph establishes is not profitably movable in-transaction.

The bypass affects pure-view reads after a multi-day idle, which is the accepted L-03 trade-off and
is unchanged by this branch.

**Arm 3 ↔ arm 4 oscillation?** No. Arm 3 caps `toRepay` at `deficit` (`:496`), so it lands coverage
at ≈1.00 — inside the band, never above `1 + spread`. Arm 4's post-call coverage is
`2.03 − 1.03/c`, which for any triggering `c > 1.03` is strictly `> 1.03` and strictly `< c` — it
approaches the band from above and never crosses to `< 1 − spread`. Checked the worst case with the
`InsufficientDeposit` tolerance fully consumed (`maxSlippage = 1%`, cap 5%): from `c = 1.10` with a
3% deposit loss, `c' = 1.0918` — still comfortably above 1. The two arms cannot ping-pong.

**Sweeping the loan manager's whole balance.** `debtBalance = loanManager.getDebtBalance()`
(`:556`) is the loan manager's *entire* debt-token balance, not just `borrowAmount` — so stranded
tokens from a prior unwind get deployed too. The `InsufficientDeposit` check at `:564` uses the same
`debtBalance`, so the floor stays consistent. This mirrors `adjustLtv`'s pre-existing pattern and is
recovery-positive. Sound.

---

# ACCEPTED RISKS — DID THIS BRANCH CHANGE THEM?

| Risk | Status after this branch |
|---|---|
| **H-01** manufactured coverage deficit | **Substantively unchanged. Written analysis is stale → L-02.** |
| **M-02** liveness gap | Unchanged. `CoverageDeficitTooLarge` is the actionable signal; `setIdle(true)/setIdle(false)` escape verified still reachable and independent of all new code. |
| **L-03** relative health-floor margin | Unchanged. `HEALTH_FLOOR_MARGIN_PCT = 105` untouched. |
| **L-04** `IMinHealth` bypasses `ILoanManager` | Unchanged. `ZenjiCoreLib.sol:19-21` interface untouched. |

## H-01 re-checked against the branch's four revisit conditions

The accepted-risk section lists four triggers for re-analysis. I checked each against the new
deployment:

1. **"TVL grows such that a plausible bounty approaches the skew cost."** No. Gold vault cap is
   95 XAUT ≈ $427k (`DEPOSIT_CAPS.md:60`), and the bounty remains
   `(accumulatedFees − feesAtLastRebalance) × rebalanceBountyRate`, zeroed per tick. The skew cost
   in this pool is measured at $13.4M for 35 bps.
2. **"Yield-pool depth falls."** Improved, not degraded. `DEPOSIT_CAPS.md` snapshotted the crvUSD
   side at 15,874,221 (block 25793357); I measured **41.7M crvUSD / 43.8M USDT** live today. The
   caps are now more conservative than when derived. `A = 2000` unchanged.
3. **"A vault is deployed whose collateral swap venue coincides with its yield LP pool."**
   **Checked closely, and it does NOT trigger** — but it is a near miss worth recording. The gold
   vault's *collateral* swap venue is Uniswap V3 XAUT/USDT 0.05% (`0x6546…E5dA`), while the yield LP
   pool is Curve crvUSD/USDT (`0x390f…7BF4`). Distinct venues, so the "the collateral is not sold at
   a manipulated price" argument holds verbatim. What *is* new is that the **strategy's entry/exit
   swap** venue now coincides with the LP pool. That is a different coincidence and does not feed
   arm 3: arm 3 sells XAUT on Uniswap and repays; it never touches the Curve pool. The H-01 attack
   surface is unchanged. I'd suggest adding a fifth revisit condition covering the strategy-swap /
   LP-pool coincidence so the distinction is explicit for the next reviewer.
4. **"`rebalanceBountyRate` is raised."** No change on this branch.

**Conclusion: H-01's acceptance still holds for every vault in the fleet, including the new gold
vault.** The only required action is amending the stale prose (L-02).

---

# APPENDIX — SUMMARY

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 0 | — |
| Low | 2 | L-01, L-02 |
| Informational | 5 | I-01 … I-05 |

**Ship recommendation: SHIP.**

Neither Low blocks the branch. L-02 is a documentation amendment that should land before the gold
vault goes live, because an operator following the current runbook would be watching for the wrong
arm-3 signature. L-01 is pre-existing code that this branch did not touch; fix it on the next pass,
preferring the two-line sizing correction plus an explicit revert at the LTV ceiling.

I found no manufactured findings and no reason to withhold the branch. The `938f61e` strategy is a
faithful composition of two audited halves against a pool the fleet already trades in production;
`7141087` is a clean, fully verified retirement; and `7bea682`'s idle-debt spend is a genuine
improvement — it converts what used to be stranded bounty residue and swap surplus into zero-cost,
NAV-neutral deficit reduction, with the fee reserve correctly protecting the strategist's claim.
