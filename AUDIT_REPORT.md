# Security Audit Report — Zenji

**Date**: 2026-05-29
**Auditor**: Automated Security Analysis (Plamen, Light mode — all Sonnet agents)
**Scope**: `src/` — primary focus on the USDT/crvUSD Stake DAO LP strategy on WBTC + wstETH via LlamaLend, the shared strategy base classes, the LlamaLend loan manager, and the `UniswapMixedCurveSwapper`. Tests excluded (context only).
**Language/Version**: Solidity ^0.8.33 (Foundry)
**Build Status**: Compiled successfully (warnings only)
**Static Analysis Status**: Slither 0.11.5 available (335 findings reviewed)
**Test Health**: 1,695/1,695 tests passing (698 unit + 997 fork)
**Remediation Status**: All findings triaged and addressed — see *Remediation Status* below (updated 2026-05-30)

> *This audit was performed in Light mode (all Sonnet agents). For maximum coverage, re-run in Core or Thorough mode on a Max plan.*

---

## Executive Summary

Zenji is an ERC-4626 conservative collateral yield vault: users deposit collateral (WBTC/cbBTC/wstETH/XAUT), the vault borrows a stablecoin (crvUSD via LlamaLend, or USDT via Aave V3) through an immutable loan manager, and deploys that debt into an immutable yield strategy (IPOR PlasmaVault, or a Curve LP staked in Stake DAO). The audit focused on the requested primary target — the **USDT/crvUSD Stake DAO LP strategy on WBTC + wstETH via LlamaLend** — plus the shared base classes (`BaseCurveStakeDaoStrategy` → `BaseLPStrategy` → `BaseYieldStrategy`), the `LlamaLoanManager`, the `UniswapMixedCurveSwapper`, and the surrounding platform risk (Chainlink/`WstEthOracle`, Curve, Stake DAO).

**No Critical, High, or Medium-severity issues were found.** The protocol's most important design decision — share price is **collateral-denominated** (`totalAssets = getTotalCollateral`), not strategy-NAV-denominated — structurally neutralizes the standard ERC-4626 vault inflation/donation/oracle-manipulation class: a flash-loan that manipulates the strategy's reported `balanceOf` cannot mint mispriced shares. Flash-loan callbacks are correctly authorized, the reward path fails closed, and the inheritance design keeps the audit surface small (auditing the base classes covers every LP strategy).

The findings are a cluster of **Low-severity hardening items** — chiefly an oracle composite-staleness gap on wstETH, a few swapper governance/slippage-propagation gaps, and reward-path observability/stranding issues — plus Informational notes. On the requested **private-key / secret-leak** lens: `src/` contains no hardcoded keys or secrets, deploy scripts read the key via `vm.envUint("PRIVATE_KEY")`, `.env` is git-ignored and absent from history.

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 6 |
| Informational | 5 |

### Components Audited

| Component | Path | Focus |
|----------|------|-------|
| LP strategy (primary) | `src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol` | crvUSD → USDT/crvUSD Curve LP → Stake DAO |
| Strategy base classes | `src/strategies/lp/BaseCurveStakeDaoStrategy.sol`, `BaseLPStrategy.sol`, `src/strategies/BaseYieldStrategy.sol` | cost basis, VP cache, reward compounding, balanceOf |
| Lender | `src/lenders/LlamaLoanManager.sol` | crvUSD debt, flash unwind, health, swaps |
| Swapper | `src/swappers/base/UniswapMixedCurveSwapper.sol`, `BaseSwapper.sol` | collateral↔crvUSD, slippage, gov |
| Oracle | `src/WstEthOracle.sol`, `src/libraries/CurveUsdtSwapLib.sol` | wstETH composite pricing, oracle floors |
| Reward path | `src/swappers/reward/CrvToCrvUsdSwapper.sol` | CRV → crvUSD |

---

## Remediation Status (post-audit, 2026-05-30)

All Low findings were triaged and addressed. The full test suite (1,695 tests) passes after the changes.

| ID | Status | Resolution |
|----|--------|-----------|
| **L-01** | ✅ **Fixed** | `WstEthOracle.latestRoundData()` now returns `min(stETH/ETH, ETH/USD)` `updatedAt` so consumers see the true composite age. `LlamaLoanManager`'s collateral-staleness window is now a constructor parameter (`maxOracleStaleness`, mirroring `AaveLoanManager`) — WBTC deployments pass `3600` (1h), wstETH deployments pass `90000` (25h, matching the stETH/ETH 24h heartbeat). All wstETH consumers (both loan managers + the wstETH swappers) set to 90000s. |
| **L-02** | ✅ **Fixed** | `BaseSwapper.setSlippage` now reverts above `MAX_SLIPPAGE = 5e16` (5%, matching the vault's `MAX_VAULT_SLIPPAGE`). `Zenji.acceptRole(1)` now propagates gov to the registered swapper via `transferGovFromVault` (mirrors the strategy-owner handoff; wrapped in `try/catch` so it can't block gov rotation). *Note: the reward swapper (`CrvToCrvUsdSwapper`) keeps its own wider bound — its slippage governs a yield path, not the vault's debt↔collateral floor.* |
| **L-03** | ⚪ **False positive** | The vault and the loan manager reference the **same** swapper instance (deployment passes one `address(swapper)` to both), so `setParam(4)`'s `swapper.setSlippage(v)` already updates the slippage the loan manager reads. No desync exists. No code change. |
| **L-04** | 🟡 **Not changed — mitigated by existing backstop** | A swapper-level oracle floor was implemented and then reverted: flooring the final crvUSD against the oracle at the swapper's tight (1%) slippage over-constrains legitimate small swaps, because the oracle-vs-pool price level diverges by more than 1% (crvUSD peg drift + composite-wstETH vs V3 spot), causing Curve to revert legitimate dust/minimum redeems. The loan manager's `SwapperUnderperformed` check (95% of oracle-implied value) is already the hard end-to-end floor that catches a sandwich on the `amountOutMin = 0` V3 hop, so the residual is a Low liveness/revert-DoS that is already backstopped. A complete fix (flooring the intermediate WETH hop) would require adding a WETH/USD oracle to the swapper constructor — deferred as disproportionate to a backstopped Low. |
| **L-05** | ✅ **Fixed (comment)** | Corrected the misleading "retried next compound cycle" comment in `BaseCurveStakeDaoStrategy._claimAndSwapRewards`. Behavior is unchanged and accepted: on swap failure CRV remains at the reward swapper (recoverable via its rescue path) and `CrvSwapDeferred` is emitted for monitoring. |
| **L-06** | ✅ **Fixed** | `Zenji.withdrawFees` now advances the strategy's cached virtual price (`updateCachedVirtualPrice()`) before `_accrueYieldFees()` (mirrors `rebalance()`). `BaseYieldStrategy.withdraw` now calls a new `_syncValueCache()` hook before reading `balanceOf()` for `basisReduction` — a no-op for cacheless strategies (IPOR) and a VP-cache ratchet for LP strategies, so cost-basis and share math use one consistent snapshot. |

> **Informational (I-01…I-05):** not addressed in this pass (observability/precision notes and one intentional asymmetry). I-01 (Llama `onFlashLoan` reentrancy guard for symmetry) and I-03 (operation ordering in the oracle-floor helpers) remain reasonable low-risk hardening if desired.

---

## Low Findings

### [L-01] WstEthOracle reports ETH/USD timestamp as the composite freshness, hiding a stale stETH/ETH feed [VERIFIED] — ✅ FIXED

**Severity**: Low
**Location**: `src/WstEthOracle.sol:74-79`; consumer: `src/lenders/LlamaLoanManager.sol:44` (`MAX_ORACLE_STALENESS = 3600`)
**Confidence**: HIGH (2 agents, code-trace verified)

**Description**:
`WstEthOracle.latestRoundData()` computes `wstETH/USD = stEthPerToken × stETH/ETH × ETH/USD`, validating both Chainlink feeds *internally* (stETH/ETH against a ~25h window, ETH/USD against ~2h). But it returns only the **ETH/USD feed's** `updatedAt`/`roundId`/`answeredInRound` as the composite metadata:

```solidity
// WstEthOracle.sol:74-79
// Pass through ETH/USD updatedAt — stETH/ETH staleness is validated above
updatedAt = ethUsdUpdatedAt;   // ← ETH/USD timestamp only
```

`LlamaLoanManager` validates the collateral oracle with a 1-hour window (`MAX_ORACLE_STALENESS = 3600`), which only sees the ETH/USD age. If stETH/ETH goes stale (up to the internal 25h allowance) while ETH/USD is fresh, the consumer's 1h check passes against a price that embeds a stETH/ETH ratio up to ~25h old.

**Impact**:
During a stETH depeg event coinciding with a stETH/ETH feed gap, the wstETH/USD price can overstate collateral, allowing a marginally higher effective LTV / over-borrow and feeding stale oracle floors to the swapper and unwind paths. Likelihood is low (stETH/ETH is slow-moving and rarely gaps for long), which caps this at Low. External monitoring inspecting only the composite `updatedAt` cannot detect the stale component.

**Recommendation**: Return `min(ethUsdUpdatedAt, stEthEthUpdatedAt)` as the composite `updatedAt` so any consumer's staleness window reflects the true age of the oldest component. Optionally raise `MAX_ORACLE_STALENESS` for this collateral to match the composite's real worst-case age, or tighten the internal stETH/ETH window.

---

### [L-02] BaseSwapper governance is not synced on vault gov rotation, and setSlippage has no upper cap [VERIFIED] — ✅ FIXED

**Severity**: Low (trust-model-bounded — requires the prior gov key to remain active after rotation)
**Location**: `src/swappers/base/BaseSwapper.sol:49-54`; `src/Zenji.sol` `acceptRole(1)` path; consumer `src/Zenji.sol:1266-1268`
**Confidence**: HIGH (code-trace verified)

**Description**:
`BaseSwapper.setSlippage` enforces only `0 < newSlippage < 1e18` — no equivalent of the vault's 5% (`maxSlippage`) cap. When vault gov rotates, the vault propagates ownership to the strategy (`transferOwnerFromVault`) but does **not** call `transferGovFromVault` on the registered swapper, so the swapper's `gov` keeps whatever key it had. The vault's `_swapRemainingDebtToCollateral` then widens its effective floor with the swapper's slippage (`effectiveSlippage = max(swapperSlippage, baseSlip*2)`), so a swapper `slippage` of ~99% removes the floor for that path.

**Impact**:
A stale (not-yet-rotated) or compromised swapper gov can set slippage to nearly 100%, making the vault's debt→collateral swap accept near-zero output (sandwichable). The loan-manager-side swaps are backstopped by `MIN_SWAP_OUT_BPS = 9500`, but the vault's own swap path is not. Within the stated FULLY_TRUSTED gov model this is a key-management risk; the missing cap is nonetheless an unnecessary surface.

**Recommendation**: (1) Add `if (newSlippage > MAX_VAULT_SLIPPAGE) revert InvalidSlippage();` to `BaseSwapper.setSlippage`. (2) In `acceptRole(1)`, after rotating `gov`, also call `transferGovFromVault(newGov)` on the registered swapper.

---

### [L-03] setParam(4) slippage change does not propagate to the LlamaLoanManager's swapper [VERIFIED] — ⚪ FALSE POSITIVE

**Severity**: Low
**Location**: `src/Zenji.sol:1122-1127`; `src/lenders/LlamaLoanManager.sol` (no propagation path)
**Confidence**: HIGH (code-trace verified)

**Description**:
`Zenji.setParam(4)`/`executeParamChange(4)` propagate a new `maxSlippage` to `yieldStrategy.setSlippage(v)` and to the **vault-level** swapper, but the `LlamaLoanManager` holds its own `ISwapper swapper` whose `slippage` is never updated. After a slippage decrease (e.g. 5% → 1%), the loan manager's swapper still computes its per-hop `minOut` floors at the stale 5%.

**Impact**:
Unwind/rebalance swaps routed through the loan manager use a more permissive slippage than the operator set, widening the per-hop sandwich window (backstopped only by the coarser 95% oracle floor). No direct fund loss; a configuration/parameter-coherence gap.

**Recommendation**: Have the vault also propagate slippage to `loanManager`'s swapper (expose a `setSwapperSlippage` on the loan manager callable only by the vault, or a `swapperAddress()` view the vault can target).

---

### [L-04] swapCollateralForDebt's Uniswap V3 hop uses amountOutMin = 0, enabling a per-hop sandwich revert-DoS [VERIFIED] — 🟡 NOT FIXED (mitigated by existing backstop)

**Severity**: Low (liveness — no fund loss; reverts atomically)
**Location**: `src/swappers/base/UniswapMixedCurveSwapper.sol:129`
**Confidence**: HIGH (code-trace verified)

**Description**:
In `swapCollateralForDebt` (wstETH → WETH → crvUSD), the V3 hop encodes `amountOutMin = 0`, relying on the subsequent Curve hop's `minCrvUsd = get_dy(wethReceived)·(1−slippage)` for protection. But if the V3 hop is sandwiched to deliver near-zero WETH, `get_dy(≈0)·(1−s) ≈ 0` and the Curve floor collapses; the real protection becomes the loan-manager's end-to-end `SwapperUnderperformed` (95% oracle) check, which reverts. The opposite direction (`swapDebtForCollateral`) correctly applies an end-to-end oracle floor on its final V3 hop, making the protection asymmetric.

**Impact**:
Under sustained sandwich pressure, `swapCollateralForDebt` reverts repeatedly, delaying loan unwind / LTV normalization and potentially blocking withdrawals that require collateral→debt swaps. No funds are lost.

**Recommendation**: Compute an intermediate WETH floor from the wstETH/USD oracle and `wstETH.stEthPerToken()` and pass it as `amountOutMin` on the V3 hop, mirroring the protected direction.

---

### [L-05] Stake DAO claim and CRV-swap failures are silently swallowed; CRV can strand at the reward swapper [VERIFIED] — ✅ FIXED (comment)

**Severity**: Low (rewards/operational — not user funds; recoverable by gov)
**Location**: `src/strategies/lp/BaseCurveStakeDaoStrategy.sol:136-159`; `src/swappers/reward/CrvToCrvUsdSwapper.sol`
**Confidence**: HIGH (code-trace verified)

**Description**:
Two reward-path failures are swallowed without an on-chain signal:
1. `_accountantClaim()` wraps `IAccountant.claim()` in `try { } catch { }` with no event on failure — a Stake DAO accountant revert leaves CRV unclaimed with no alarm (observable only as a divergence between `pendingRewards()` and `harvest()` output).
2. `_claimAndSwapRewards()` transfers CRV to the reward swapper *before* the `try crvSwapper.swap(crvBalance)`. On swap failure the CRV sits at the swapper. **Verified**: `CrvToCrvUsdSwapper.swap(amount)` swaps the *passed* amount, not the swapper's balance — so the in-code comment "CRV stays at swapper; retried next compound cycle" is **incorrect**; the next cycle reads `crv.balanceOf(strategy) = 0` and never re-sweeps the stranded CRV. Recovery requires a manual `rescueToken` by gov, and recovered CRV does not re-enter the compound cycle.

**Impact**:
Unclaimed/stranded CRV reduces realized APR. Funds are not lost (gov-recoverable), but the accumulation is hard to detect on-chain and the misleading comment may cause operators to assume auto-retry.

**Recommendation**: (1) Emit `ClaimFailed(accountant)` in the claim catch block. (2) In `_claimAndSwapRewards`, sweep `crv.balanceOf(address(this)) + crv.balanceOf(address(crvSwapper))` (or have the swapper swap its own residual). (3) Correct the comment. (4) Add a `pendingCrvAtSwapper()` view for monitoring.

---

### [L-06] Fee / cost-basis accrual is sensitive to virtual-price timing inconsistencies [VERIFIED] — ✅ FIXED

**Severity**: Low (bounded by the ±0.5%/update VP clamp; no external exploit)
**Location**: `src/strategies/BaseYieldStrategy.sol` `withdraw` (pre- vs post-`_updateCachedUnitValue` `balanceOf`); `src/Zenji.sol:867` `withdrawFees` (no VP update before `_accrueYieldFees`)
**Confidence**: MEDIUM (code-trace; two related sites)

**Description**:
Fee/cost-basis accounting reads the strategy's VP-derived value at slightly inconsistent points:
- `BaseYieldStrategy.withdraw` computes `basisReduction` from a `balanceOf()` taken *before* `_withdraw` runs `_updateCachedUnitValue()`, then `_withdraw` computes `sharesToRedeem` from a *post-update* `balanceOf()`. The two can diverge by up to the ±0.5% clamp, skewing `_costBasis` decay (and thus subsequent `unrealizedProfit`/fee deltas).
- `Zenji.withdrawFees` calls `_accrueYieldFees()` **without** first calling `yieldStrategy.updateCachedVirtualPrice()`, whereas `rebalance()` deliberately advances the VP first (comment: "prevents VP drift from causing phantom fee accrual"). The same precaution is missing here.

**Impact**:
Marginal over/under-accrual of performance fees (bounded by the per-update VP clamp). Affects fee precision, not user principal, and is not externally exploitable.

**Recommendation**: Advance the cached VP (`updateCachedVirtualPrice()`) before fee accrual in `withdrawFees`, and use a single consistent `balanceOf()` snapshot across `withdraw`'s `basisReduction` and `sharesToRedeem`.

---

## Informational Findings

### [I-01] LlamaLoanManager.onFlashLoan has no reentrancy guard (no exploit path found)
`onFlashLoan` is tightly authorized (`msg.sender == DEBT_FLASH_LENDER`, `initiator == address(this)`, token check), and no callback path from the crvUSD flash lender or downstream Curve/Uniswap calls re-enters the manager. `AaveLoanManager.executeOperation` carries `nonReentrant`; the Llama side does not. Add a guard for symmetry / defense-in-depth. (`src/lenders/LlamaLoanManager.sol:433`)

### [I-02] Virtual-price staleness opens a one-time same-block anchor window (mitigated)
After `lastVpUpdate > MAX_VP_STALENESS` (1 day), the first `updateCachedVirtualPrice()` sets the cache to the *unclamped* live VP, so a same-block flash manipulation of `get_virtual_price()` could set an elevated anchor. The impact is contained because `balanceOf() = min(VP-based, calc_withdraw_one_coin)` keeps the reported value honest via the live single-coin exit quote, and Curve StableSwap VP is monotonic (no downward manipulation). Residual effect ≤ 0.5%/day drift on the VP-based branch. (`src/strategies/lp/BaseLPStrategy.sol:134`)

### [I-03] divide-before-multiply in the Curve oracle floor helpers (precision)
`CurveUsdtSwapLib._oracleFloor6to18` / `_oracleFloor18to6` divide before multiplying by `(1−slippage)`, losing precision in the oracle-derived minimum-out. The error is small and conservative in normal ranges, but tightening the operation order avoids an unnecessarily low floor at small amounts. (Slither: divide-before-multiply) (`src/libraries/CurveUsdtSwapLib.sol`)

### [I-04] `_harvest()` return value understates compounded yield (event only)
`_harvest()` returns only the CRV→crvUSD swap output, not the residual `lpAsset` re-staked by `_addLiquidityAndStake()`, so the `Harvested` event under-reports. On-chain fee accrual (driven by the `_accrueYieldFees` balance delta) is unaffected. (`src/strategies/lp/BaseCurveStakeDaoStrategy.sol`)

### [I-05] `_removeLiquidity` applies only a spot floor, asymmetric with `_addLiquidity`'s oracle floor (intentional)
`_addLiquidity` enforces both a spot (`calc_token_amount`) and an oracle (`_getSafeUnitValue`) minimum-LP floor; `_removeLiquidity` enforces only the spot `calc_withdraw_one_coin` floor. The asymmetry is deliberate — always allow exits, even during a depeg — and is the correct design for a user-withdrawal path, but is noted for completeness. (`src/strategies/lp/BaseCurveStakeDaoStrategy.sol`)

---

## Private-Key / Secret-Leak Assessment

- **No hardcoded private keys or secrets in `src/`.** Deploy scripts read the deployer key via `vm.envUint("PRIVATE_KEY")` and broadcast with it; no key is embedded in source.
- **`.env` is git-ignored** (`.gitignore` line 80) and **absent from git history** (30 commits scanned); the live `PRIVATE_KEY`, RPC API keys, and Etherscan key exist only in the local, untracked `.env`.
- The only key-shaped value in history is Anvil's well-known public test key inside vendored `lib/forge-std` (by design, not a secret).
- **Operational reminder (not a code issue):** the local `.env` holds a real-looking deployer key and live API keys — keep that file off any shared medium, and ensure the deployer key isn't reused for anything holding material funds.

---

## Priority Remediation Order

1. **L-01** — fix `WstEthOracle` composite `updatedAt` (`min` of both feeds) — the one finding with a (low-likelihood) collateral-mispricing path.
2. **L-02** — cap `BaseSwapper.setSlippage` + auto-sync swapper gov on rotation.
3. **L-05** — correct the reward-stranding comment + sweep the swapper's CRV residual + emit claim-failure events.
4. **L-03 / L-04 / L-06** — slippage-propagation coherence, V3 per-hop floor, VP-timing consistency in fee accrual.
5. **I-01 / I-03** — add the Llama flash-loan guard; tighten the oracle-floor operation order.

---

## Notes on Methodology and Limits

This was a Light-mode run (all Sonnet agents): 2 recon agents, 2 breadth agents (LP accounting + platform/external), and a focused verification pass on the three findings whose severity hinged on a specific mechanism. It did **not** include the heavier Core/Thorough stages (multi-iteration depth, invariant/Medusa fuzz campaigns, RAG historical-precedent validation, or executed PoC tests on a mainnet fork). The verdicts here are code-trace (`[CODE-TRACE]`) — strong for the resolved items but not machine-proven. Given the absence of any Critical/High/Medium finding and the collateral-denominated share model that removes the main vault-manipulation class, a Core/Thorough re-run is optional rather than necessary, but would add executed-PoC confidence and fuzz coverage on the fee/VP-accrual edge cases (L-06, I-02).
