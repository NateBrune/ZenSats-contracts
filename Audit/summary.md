# Zenji Audit Summary

**Date**: 2026-04-27
**Auditor**: AI-assisted manual review (4 parallel agents)
**Scope**: pmUSD/StakeDAO strategy + Aave Lend + LlamaLend
**Excluded**: IPOR strategies, Tokemak, legacy WBTC/wstETH vaults

---

## Severity Breakdown (pmUSD/StakeDAO + Aave/Llama only)

| Severity | Count | Key Areas |
|----------|-------|-----------|
| **HIGH** | 0 | (all downgraded after verification) |
| **MEDIUM** | 13 | Llama partial unwind, USDT stuck crvUSD, Aave swapper reentrancy, VP cache staleness, _claimAndCompound, balanceOf stale oracle, cost basis, SafeTransferLib USDT, multi-hop slippage |
| **LOW** | 25 | isFinalWithdraw + deposit return value, emergency skip + exchange rate drift, keeper LTV band + partial unwind repricing, DELEGATECALL, timelock expiry, dust-grief, implementation offsets |
| **INFO** | 5 | Harvest naming, oracle staleness checks, decimal handling |
| **INFO** | 5 | Harvest naming, oracle staleness checks, decimal handling |
| **TOTAL** | **44** | |

---

## Top Findings (All Severities)

### M1: LlamaLoanManager partial unwind — no health check before remove_collateral
**Contract**: LlamaLoanManager.sol → unwindPosition
Partial unwind path skips health check between oracle freshness check and remove_collateral. Reverts on oracle price drops.

### M2: UsdtPmUsdCrvUsdStrategy _withdraw — temporarily stuck crvUSD on swap failure
**Contract**: UsdtPmUsdCrvUsdStrategy.sol → _withdraw()
If _removeLiquidity succeeds but _swapCrvUsdToUsdt fails, crvUSD is temporarily stuck in the strategy. The whole withdraw reverts; user can retry.

### M14: AaveLoanManager executeOperation — swapper callback reentrancy
**Contract**: AaveLoanManager.sol → executeOperation
No reentrancy guard on flashloan callback. Malicious swapper could corrupt state mid-flashloan.

### M3: LlamaLoanManager DEBT_FLASH_LENDER hardcoded address staleness
**Contract**: LlamaLoanManager.sol
Flash lender address is hardcoded. If deprecated, full close unwinds fail until emergency step.

### M6: balanceOf reverts on stale oracle (USDT variant only)
**Contract**: UsdtPmUsdCrvUsdStrategy.sol → balanceOf()
USDT variant's balanceOf() reverts on stale oracle, breaking vault withdraw() and external consumers.

### M9: SafeTransferLib USDT zero-reset can fail
**Contract**: SafeTransferLib.sol → safeApprove
USDT zero-reset can fail on some token versions, causing unnecessary reverts.

---

## Medium Findings Summary

| # | Finding | Contract | Key Risk |
|---|---------|----------|----------|
| M1 | Llama partial unwind no health check | LlamaLoanManager | Partial unwind reverts on oracle drops |
| M2 | Aave executeOperation swapper reentrancy | AaveLoanManager | Malicious swapper could corrupt flashloan state |
| M3 | DEBT_FLASH_LENDER hardcoded staleness | LlamaLoanManager | Full close fails if crvUSD FlashLender deprecated |
| M4 | VP cache staleness window | BasePmUsdCrvUsdStrategy | Stale cache allows suboptimal LP prices |
| M5 | _claimAndCompound double-count risk | BasePmUsdCrvUsdStrategy | CRV rewards claimed multiple times |
| M6 | balanceOf reverts on stale oracle (USDT) | UsdtPmUsdCrvUsdStrategy | All consumers break during oracle staleness |
| M7 | Cost basis over-reduction in withdraw | BaseYieldStrategy | Cost basis reaches 0 while assets remain |
| M8 | Partial unwind re-pricing | Zenji.sol | Withdrawers absorb slippage (intended but worth noting) |
| M9 | SafeTransferLib USDT zero-reset gap | SafeTransferLib | USDT zero-reset can fail on some versions |
| M10 | _swapRemainingDebtToCollateral slippage floor | Zenji.sol | Multi-hop swappers have per-hop gaps |
| M11 | CbBtcWbtcUsdtSwapper multi-hop slippage | CbBtcWbtcUsdtSwapper | Effective slippage ~2× configured |
| M12 | CbBtc _safeGetDyThree return handling | CbBtcWbtcUsdtSwapper | Failing get_dy causes early return with 0 |
| M13 | UniswapMixedCurve minOut=0 on first hop | UniswapMixedCurveSwapper | No slippage protection on either hop |

---

## Top Actionable Items

1. **Llama partial unwind health check** (M1) — Add pre-check before remove_collateral
2. **USDT variant balanceOf stale oracle** (M6) — Add fallback instead of revert
3. **SafeTransferLib USDT zero-reset** (M9) — Add try/catch around zero-reset
4. **isFinalWithdraw detection** (L01) — Replace `totalSupply() == shareAmount` with `shareAmount >= balanceOf(owner_)`
5. **Implementation MIN_DEPOSIT** (L09) — Add MIN_DEPOSIT overrides to ZenjiWbtc, ZenjiWstEth, ZenjiCbBtc
6. **Llama DEBT_FLASH_LENDER** (M3) — Make mutable or add fallback lender address

---

## Phase 2: Attack Chain Candidates

1. **VP Cache + LP Manipulation**: Manipulate pmUSD/crvUSD pool → VP spikes → cache clamped at ±0.5% → _removeLiquidity at inflated price → withdrawer gets more crvUSD → socializes loss on remaining shareholders
2. **Flash Loan + Emergency Skip**: Flash loan crvUSD → LlamaLend borrower → skip step 0 (yield) → skip step 1 (loan) → step 2 complete liquidation → users redeem only vault collateral, missing strategy assets
3. **Stale Oracle + USDT balanceOf**: USDT oracle stale → balanceOf reverts → keeper can't check rebalance → LTV drifts beyond deadband
4. **Multi-hop Slippage + Partial Unwind**: CbBtc multi-hop with 1% slippage → 2% effective → partial withdraw absorbs slippage → remaining shareholders protected by repricing
5. **Cost Basis + Withdraw**: VP drops → balanceOf underestimates → withdraw reduces cost basis too much → unrealized profit shows negative while assets remain

---

## Phase 3: PoC Test Candidates

- M1: test/M1_Llama_partial_unwind_health.fork.t.sol (3/3 failing - Accountant.claim issue)
- M2: test/M2_UsdtPmUsdCrvUsd_withdraw_stuck_crvUSD.fork.t.sol (3/3 failing - Accountant.claim issue)
- M3: test/M3_LlamaLoanManager_DEBT_FLASH_LENDER_staleness.fork.t.sol ✅ COMPLETE (5/5 passing)
- M4: test/M4_VP_cache_staleness.fork.t.sol ✅ COMPLETE (3/3 passing)
- M6: test/M6_balanceOf_stale_oracle.fork.t.sol ✅ COMPLETE (5/5 passing)
- M9: test/M9_SafeTransferLib_USDT_zero_reset.fork.t.sol ✅ COMPLETE (6/6 passing)
- M11: test/CbBtcWbtcUsdtSwapper_multi_hop_slippage.fork.t.sol (pending)

---

## Phase 4: Admin Centralization & Key Management

**Status**: ✅ Complete — 11 findings documented (2 MEDIUM, 9 LOW)

### Findings

| # | Severity | Finding | File |
|---|----------|---------|------|
| P4-1 | MEDIUM | Guardian can skip all emergency steps and capture strategy assets | medium/P4-1-... |
| P4-2 | MEDIUM | Sequential role transfers allow full takeover in ~5-8 weeks | medium/P4-2-... |
| P4-3 | LOW | All roles default to single owner at deployment | low/P4-3-... |
| P4-4 | LOW | Keeper ownership transfers immediately (no timelock) | low/P4-4-... |
| P4-5 | LOW | LlamaLoanManager gov is immutable | low/P4-5-... |
| P4-6 | LOW | Swapper timelock (1 week) audits infrastructure changes | low/P4-6-... |
| P4-7 | LOW | Strategy setSlippage has no timelock | low/P4-7-... |
| P4-8 | LOW | Emergency mode and liquidationComplete are one-way latches | low/P4-8-... |
| P4-9 | LOW | Parameter changes have asymmetric timelock (only adverse) | low/P4-9-... |
| P4-10 | LOW | Strategy owner propagation on gov accept (best-effort) | low/P4-10-... |
| P4-11 | LOW | CrvToCrvUsdSwapper authorizedCaller bypasses gov for setSlippage | low/P4-11-... |

### Governance Model Summary

| Role | Delay | Veto | Powers |
|------|-------|------|--------|
| Strategist | 1 week | Guardian | setIdle, withdrawFees |
| Gov | 4 weeks | Guardian | swapper, params, role transfers |
| Guardian | 4 weeks | Guardian | emergency mode, rescue |

### Timelock Matrix

| Action | Delay | Veto | Immediate? |
|--------|-------|------|------------|
| Strategist transfer | 1 week | Guardian | No |
| Gov transfer | 4 weeks | Guardian | No |
| Guardian transfer | 4 weeks | Guardian | No |
| Swapper change | 1 week | Guardian | No |
| Fee rate increase | 1 week | None | No |
| LTV increase | 1 week | None | No |
| Deposit cap / bounty / slippage | 0 | None | Yes |
| Emergency skip | 3 days | Gov | No |
| Emergency cancel | 0 (before steps) | Gov | Yes |
| Keeper ownership | 0 | None | Yes |
