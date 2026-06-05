# Security Audit Report — Zenji Protocol (Vault-Split Architecture)

**Date**: 2026-06-02
**Auditor**: Automated Security Analysis (Plamen Light Mode — Claude Sonnet 4.6)
**Scope**: Vault-split architecture (ZenjiStorage, ZenjiAdmin, ZenjiGovLib) + primary product stack (LlamaLoanManager, crvUSD/Stake DAO LP yield strategy, UniswapMixedCurveSwapper, CrvToCrvUsdSwapper, WstEthOracle)
**Language/Version**: Solidity ^0.8.33 (solc 0.8.34)
**Build Status**: Compiled successfully — all vault implementations under EIP-170 limit (~21.9KB max). Storage layout Zenji==ZenjiAdmin byte-identical (verified). 698/698 unit tests + ~997 fork tests green.
**Static Analysis**: Slither 0.11.5 available. Reentrancy-balance flags reviewed — confirmed false positives (see I-02).

---

## Executive Summary

Zenji is a conservative ERC4626 collateral yield vault. Users deposit collateral (WBTC, wstETH, cbBTC), the vault borrows a stable debt asset (crvUSD or USDT) against that collateral via an immutable Loan Manager, and deploys the borrowed debt to an immutable Yield Strategy for compounding yield. This audit focused on two primary areas: (1) the new **vault-split architecture** — a delegatecall-based facet system (`ZenjiAdmin`, `ZenjiGovLib`) that solved EIP-170 bytecode size constraints while preserving a single unified storage layout via the new `ZenjiStorage` abstract base; and (2) the **primary product stack** — LlamaLend (crvUSD) loan management, the Curve pmUSD/crvUSD + Stake DAO LP yield strategy, the UniswapMixedCurveSwapper, CrvToCrvUsdSwapper reward compounder, and WstEthOracle.

Two **High** severity findings were identified. The most critical is a double-lock condition in LlamaLend vaults: `LlamaLoanManager.MAX_DEBT_ORACLE_STALENESS` is set to 7 hours while the Chainlink crvUSD/USD feed has a 24-hour heartbeat. This creates a predictable 17-hour periodic window each cycle where all LlamaLend vault withdrawals freeze — and, critically, the designed emergency escape hatch (`emergencyStep(1)`) is blocked by the same oracle check, leaving users with only a 3-day `emergencySkipStep` as recourse. The second High finding is an error escalation path in `LlamaLoanManager`: a bare `catch {}` on any partial `llamaLend.repay()` failure forces a full-position flash unwind against a single hardcoded flash lender address. If that lender is ever paused or deprecated, all LlamaLend vault users face a minimum 3-day withdrawal freeze.

Seven **Medium** severity findings were identified, including an oracle staleness mismatch in the cbBTC swapper (25h window vs 1h BTC/USD heartbeat), a missing slippage cap in the CRV harvest swapper, a permanent governance/strategy-owner divergence after gov rotation, and fee accounting and slippage configuration issues. Ten **Low** findings and two **Informational** findings round out the audit. The vault-split architecture itself — the `ZenjiAdmin` delegatecall facet, `_adminDelegate` assembly, and storage layout alignment — was verified safe with no slot collisions.

Teams should prioritize the oracle staleness alignment in `LlamaLoanManager` and the narrow-catch fix in `unwindPosition` before any mainnet deployment of LlamaLend vaults. The cbBTC swapper constant fix is a one-line change and should be addressed simultaneously.

---

## Summary

| Severity | Count |
|----------|-------|
| High | 2 |
| Medium | 6 (+1 false positive) |
| Low | 9 (+1 false positive) |
| Informational | 2 |
| **Total** | **19** (+2 FP) |

> **Remediation status (2026-06-03):** All High and Medium findings are **resolved** (H-01, H-02, M-02–M-07 fixed with regression tests; **M-01 false positive**). All Lows are now addressed: **L-01, L-04, L-05, L-06, L-07, L-08, L-09 fixed** in code; **L-02 and L-03 acknowledged as accepted/by-design** with documentation (no behavior change); **L-10 is a false positive** (measured — see its STATUS note). The 2 Informational items remain open.

### Components Audited

| Component | Path | Lines | Description |
|-----------|------|-------|-------------|
| ZenjiStorage | `src/ZenjiStorage.sol` | 87 | Shared storage base — inherited by Zenji and ZenjiAdmin |
| Zenji | `src/Zenji.sol` | 1,325 | Core ERC4626 vault, forwarding stubs, delegatecall dispatch |
| ZenjiAdmin | `src/ZenjiAdmin.sol` | 511 | Cold-path admin facet (delegatecall target) |
| ZenjiGovLib | `src/libraries/ZenjiGovLib.sol` | 197 | Gov param admin library (delegatecall) |
| ZenjiCoreLib | `src/libraries/ZenjiCoreLib.sol` | 429 | Emergency/fee/rebalance library (delegatecall) |
| LlamaLoanManager | `src/lenders/LlamaLoanManager.sol` | 770 | LlamaLend loan adapter — primary product |
| AaveLoanManager | `src/lenders/AaveLoanManager.sol` | 710 | Aave V3 loan adapter — secondary |
| BaseYieldStrategy | `src/strategies/BaseYieldStrategy.sol` | 293 | Abstract base (cost basis, reentrancy, owner/slippage) |
| BaseLPStrategy | `src/strategies/lp/BaseLPStrategy.sol` | 327 | Abstract base for LP strategies (VP cache, staking helpers) |
| BaseCurveStakeDaoStrategy | `src/strategies/lp/BaseCurveStakeDaoStrategy.sol` | 240 | CRV harvest, Curve pool exits, VP calc |
| BaseNgCrvUsdLpStakeDaoStrategy | `src/strategies/lp/BaseNgCrvUsdLpStakeDaoStrategy.sol` | 119 | NG dynamic-array add_liquidity |
| NgCrvUsdLpStakeDaoStrategy | `src/strategies/lp/NgCrvUsdLpStakeDaoStrategy.sol` | 43 | Concrete crvUSD LP strategy — primary product |
| UniswapMixedCurveSwapper | `src/swappers/base/UniswapMixedCurveSwapper.sol` | 227 | wstETH/WBTC LlamaLend swapper — primary product |
| CrvToCrvUsdSwapper | `src/swappers/reward/CrvToCrvUsdSwapper.sol` | 135 | CRV→crvUSD reward compounder — primary product |
| CbBtcUniswapV3TwoHopSwapper | `src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol` | 153 | cbBTC-specific swapper |
| WstEthOracle | `src/WstEthOracle.sol` | 119 | Custom composite wstETH/USD oracle |
| OracleLib | `src/libraries/OracleLib.sol` | 175 | Oracle price helpers |

---

## High Findings

### [H-01] crvUSD Oracle Staleness Creates a 17-Hour Double-Lock: Withdrawals Blocked AND Emergency Escape Hatch Disabled [VERIFIED]

**Severity**: High
**Location**: `src/lenders/LlamaLoanManager.sol:49` (constant), `src/libraries/ZenjiCoreLib.sol:86,91` (emergency step 1), `src/libraries/OracleLib.sol:26` (freshness check)
**Confidence**: HIGH (5/5 PoC tests passed, [POC-PASS], two independent depth agents confirmed)

> **STATUS — FIXED (2026-06-02):** `MAX_DEBT_ORACLE_STALENESS` raised from `25200` (7h) to **`90000` (25h)** in `LlamaLoanManager.sol`, aligning the debt-oracle window with the strategy/swapper and clearing the crvUSD/USD 24h Chainlink heartbeat. The ~17h periodic DoS window is closed; genuine >25h staleness is still rejected (the shared freshness gate that drove both the withdraw and emergency paths). Regression: `test/POC_HYP01_HYP03_HYP07.t.sol` (`POC_HYP01_CrvUsdOracleDoubleLock`, 5/5). Fork-validated against the live LlamaLend controller (`WbtcCrvUsdUsdtLlama` 35/35, `WstEthCrvUsdUsdtLlama` 68/68, `M3` 68/68).

**Description**:
`LlamaLoanManager` defines `MAX_DEBT_ORACLE_STALENESS = 25200` (7 hours) as a hardcoded constant:

```solidity
// LlamaLoanManager.sol:49
uint256 public constant MAX_DEBT_ORACLE_STALENESS = 25200; // 6h (comment is wrong — value is 7h)
```

The Chainlink crvUSD/USD price feed has a **24-hour heartbeat** — Chainlink does not guarantee an update more frequently than every 24 hours on quiet market days. This mismatch creates a predictable 17-hour window per cycle (86400 − 25200 = 61200 seconds) during which `OracleLib._checkOracleFreshness()` reverts with `StaleOracle`. Every state-changing call through `LlamaLoanManager.unwindPosition()` invokes this freshness check.

The protocol's designed recovery path — `emergencyStep(1)` — calls `loanManager.unwindPosition(type(uint256).max)` with **no try/catch wrapper**, at both code paths through `ZenjiCoreLib.executeEmergencyStep`:

```solidity
// ZenjiCoreLib.sol:86,91 — step == 1 branch, no try/catch on either call
loanManager.unwindPosition(type(uint256).max);  // line 86
// ...
loanManager.unwindPosition(type(uint256).max);  // line 91
```

Compare with step 0, which correctly wraps the yield strategy call in try/catch (lines 59–64). Step 1 provides no such protection. The result: during the 17-hour stale window, both normal user withdrawals AND the guardian emergency path revert with `OracleLib.StaleOracle`, simultaneously. The only remaining escape is `emergencySkipStep(1)`, which carries a mandatory 3-day timelock (`EMERGENCY_SKIP_DELAY`). The maximum combined lockout duration is therefore approximately 4 days: 17-hour stale window + 3-day skip timelock.

Note: the wrong comment on the constant (`// 6h`) suggests the intended value may have been 21600 seconds (6 hours), making the mismatch with the 24h heartbeat even more severe than an oversight of the exact value.

During the lockout, LlamaLend positions continue accruing interest and may enter soft-liquidation range (LLAMMA AMM converts collateral to crvUSD). Users cannot exit while their position degrades.

For comparison, `AaveLoanManager` uses `maxOracleStaleness = 90000` (25h) for the same oracle type — confirming that a wider staleness window is the intended operational pattern.

**Impact**:
- All LlamaLend vault users' `withdraw()` and `redeem()` calls revert for up to 17 hours per cycle, with no attacker involvement required.
- The emergency escape hatch (`emergencyStep(1)`) is simultaneously disabled by the same condition, leaving the guardian unable to protect users.
- During the stale window, users' LlamaLend positions continue accruing interest and risk entering soft-liquidation.
- Maximum lockout if oracle stales at the worst time: ~4 days (17h stale + 3-day skip timelock).

**PoC Result**:
```
test_POC_HYP01_constant_verification — PASS
  LlamaLoanManager MAX_DEBT_ORACLE_STALENESS: 25200
  crvUSD/USD Chainlink heartbeat: 86400
  Periodic stale window: 61200 seconds (~17h)

test_POC_HYP01_unwindPosition_reverts_stale_crvusd_oracle — PASS
  CONFIRMED: unwindPosition reverts on stale crvUSD oracle (>7h)

test_POC_HYP01_emergencyStep1_reverts_stale_crvusd_oracle — PASS
  emergencyStep(0) completed successfully
  CONFIRMED: emergencyStep(1) reverts with StaleOracle on stale crvUSD oracle
  DOUBLE LOCK PROVEN: Normal withdrawal AND emergency step BOTH frozen
    during 17h window

test_POC_HYP01_aave_still_accepts_at_7h — PASS
  AaveLoanManager (25h window) is NOT frozen; LlamaLoanManager (7h) is FROZEN

5/5 tests passed [POC-PASS]
```

**Recommendation**:
1. **Align the constant**: Change `MAX_DEBT_ORACLE_STALENESS` to `90000` (25 hours) to match `AaveLoanManager` and to stay safely above the 24h Chainlink heartbeat while still catching genuine staleness. Also correct the misleading `// 6h` comment.
2. **Protect the emergency path**: Wrap `loanManager.unwindPosition()` in `ZenjiCoreLib.executeEmergencyStep` step 1 with a try/catch, similar to how step 0 handles the strategy withdrawal. On revert, fall through to `emergencySkipStep` or set a flag enabling the skip without the 3-day delay.

```solidity
// Recommended fix for ZenjiCoreLib.sol step 1:
try loanManager.unwindPosition(type(uint256).max) {
    // success
} catch {
    // Oracle stale or flash lender unavailable; 
    // allow emergencySkipStep without timelock, or log for manual intervention
    emit EmergencyUnwindFailed();
}
```

---

### [H-02] Broad `catch {}` on Partial Repay Escalates Any Error to Flash-Lender SPOF — ≥3-Day Withdrawal Freeze [VERIFIED]

**Severity**: High
**Location**: `src/lenders/LlamaLoanManager.sol:302` (bare catch), `src/lenders/LlamaLoanManager.sol:329,338-345` (flash lender unconditional call), `src/lenders/LlamaLoanManager.sol:86` (hardcoded lender address)
**Confidence**: HIGH (2/2 PoC tests passed, [POC-PASS], chain confirmed by two depth agents)

> **STATUS — FIXED (2026-06-02):** The partial-repay `catch {}` in `unwindPosition` is now narrowed — only LlamaLend's dust assertion (`"Amount too low"`) escalates to a full close; every other revert reverts with the new `PartialRepayFailed` error (fail-safe), so a transient controller fault no longer silently forces a destructive, flash-dependent full close that socializes exit costs. The `DEBT_FLASH_LENDER` is consequently reached only on genuine dust full-closes, retaining its documented `emergencySkipStep(1)` / `emergencyRescue(2)` recovery. The lender is **intentionally kept a hardcoded `constant`** (unchangeable after deployment, no setter) — a mutable flash-lender address was considered and rejected as a larger attack surface (a compromised gov could redirect the unwind flow to a malicious lender). The residual risk is limited to Curve itself deprecating that specific lender, an external low-likelihood event covered by the emergency recovery paths. Regression: `test/H02_NarrowCatch_Regression.t.sol` (non-dust revert → `PartialRepayFailed`) plus the reconciled `POC_Batch2` fork PoCs.

**Description**:
When `LlamaLoanManager.unwindPosition()` performs a partial repay, it wraps the call in a try/catch block intended to handle a specific LlamaLend dust-threshold assertion:

```solidity
// LlamaLoanManager.sol:299-316
try llamaLend.repay(repayNow) {
    // partial repay succeeded
}
catch {
    // Partial repay tripped LlamaLend's dust assertion. Escalate to full close.
    fullyClose = true;
    debtToRepay = currentDebt;
    // ...
}
```

The `catch {}` block uses **no error selector filtering** — it catches every possible revert from `llamaLend.repay()`, including oracle staleness, controller pause, arithmetic overflow, or any future LlamaLend upgrade that introduces new revert conditions. When it fires, it unconditionally sets `fullyClose = true`.

Downstream, `needFlashloan = fullyClose && (remainingDebt > 0)` evaluates to `true`, and the flash loan call is made with no fallback:

```solidity
// LlamaLoanManager.sol:338-345
IERC3156FlashLender(DEBT_FLASH_LENDER).flashLoan(
    IERC3156FlashBorrower(address(this)),
    address(debtToken),
    remainingDebt,
    data
);
```

`DEBT_FLASH_LENDER` is a hardcoded constant at `LlamaLoanManager.sol:86`:
```solidity
address public constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
```

This is a Curve-governance-controlled contract. If it is ever paused, deprecated, or rate-limited, the `flashLoan()` call reverts, propagating through `unwindPosition()`. Since `emergencyStep(1)` also calls `loanManager.unwindPosition(type(uint256).max)` without a try/catch (see H-01), the same revert propagates through the emergency path as well. The only recovery is `emergencySkipStep(1)` with its mandatory 3-day timelock.

The contract's own comments acknowledge this as a known risk (`LlamaLoanManager.sol:82-85`) but provide no mitigation.

A permissionless trigger path exists: any user withdrawal that results in a partial repay where `llamaLend.repay()` reverts for any transient reason — including the oracle staleness condition described in H-01 — will hit this escalation path. The escalation is not gated by a privileged role.

**Impact**:
- Any transient `llamaLend.repay()` revert (dust threshold, oracle stale, controller pause, etc.) triggers a full-position flash unwind against the hardcoded flash lender.
- If the flash lender is paused or deprecated, **all LlamaLend vault users' withdrawals freeze for a minimum of 3 days** with no alternative exit path.
- Costs are socialized across all depositors when the escalation forces a full-close swap on what should have been a minor partial unwind.
- Trigger is permissionless: any user withdrawal can reach the escalation path.

**PoC Result**:
```
test_POC_HYP02_broad_catch_forces_flash_lender_path — PASS
  EMERGENCY_SKIP_DELAY (recovery time if flash lender broken): 3 days
  LlamaLoanManager.sol:302 bare catch{} escalates ANY repay revert to full-close
  LlamaLoanManager.sol:338 DEBT_FLASH_LENDER.flashLoan() hardcoded, no fallback
  Recovery if flash lender breaks: emergencySkipStep(1) = 3-day timelock

test_POC_HYP02_no_fallback_on_flash_lender_revert — PASS
  Minimum withdrawal freeze if DEBT_FLASH_LENDER breaks: 72 hours

2/2 tests passed [POC-PASS]
```

**Recommendation**:
1. **Narrow the catch to the dust-specific error**: Replace the bare `catch {}` with a typed selector check. LlamaLend's dust assertion reverts with a specific custom error or panic code — catch only that.

```solidity
// Before:
catch {
    fullyClose = true;
    // ...
}

// After (pseudocode — verify LlamaLend's exact error selector):
catch (bytes memory err) {
    if (!_isDustError(err)) revert LlamaLendRepayFailed(err);
    fullyClose = true;
    // ...
}
```

2. **Make the flash lender configurable**: Replace the `address public constant DEBT_FLASH_LENDER` with a gov-updatable address (with a timelock) so the protocol can migrate if the lender is deprecated.
3. **Add a non-flash fallback path**: If the flash lender reverts and the position cannot close normally, allow the emergency path to signal this condition without reverting (emit an event, set a flag), enabling `emergencySkipStep` without requiring the full 3-day timelock.

---

## Medium Findings

### [M-01] cbBTC Swapper Accepts BTC/USD Prices That Are 25× Stale — Withdrawal DoS and MEV Exposure [FALSE POSITIVE]

**Severity**: ~~Medium~~ → **Not a finding**
**Location**: `src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol:26`
**Confidence**: HIGH (4/4 PoC tests passed, [POC-PASS])

> **STATUS — FALSE POSITIVE (2026-06-02):** The finding assumed the swapper's oracle is the BTC/USD feed (≈1h heartbeat). The actual feed is **Coinbase cbBTC/USD, which has a ~24h heartbeat**, so the 90000s (25h) staleness window is correct and intentional — matching the heartbeat plus margin. There is no over-loose acceptance window and no DoS/MEV exposure. No code change. (The PoC asserted the constant mismatch against an assumed 1h heartbeat; that premise does not hold for cbBTC/USD.)

**Description**:
`CbBtcUniswapV3TwoHopSwapper` defines its oracle staleness window as a hardcoded constant:

```solidity
// CbBtcUniswapV3TwoHopSwapper.sol:26
uint256 public constant MAX_COLLATERAL_ORACLE_STALENESS = 90000; // 25h
```

The BTC/USD Chainlink oracle has a **1-hour heartbeat** (3600 seconds). After the heartbeat expires (T+3601s), the swapper will continue accepting the stale price for another ~24 hours without reverting. This creates two exploitable conditions:

- **Withdrawal DoS**: If BTC/USD drops more than the vault's slippage tolerance after the 1h heartbeat but before the 25h window, the stale high price produces a `minOut` that exceeds the achievable market rate. The swap reverts with `SwapperUnderperformed`, DoS-ing all cbBTC vault withdrawals for up to 24h per cycle.
- **MEV exposure**: If BTC/USD rises, the stale low price produces a `minOut` below market, opening the swap to front-running.

The inconsistency is confirmed by comparison: `AaveLoanManager.sol:76` sets `maxOracleStaleness = 3600` (1h) for the same BTC/USD feed in the same vault stack — the swapper is 25× more lenient than the loan manager for an identical oracle.

**Impact**:
- cbBTC vault withdrawals silently compute `minOut` from a price that can be up to 24 hours stale.
- A 5% BTC/USD price drop during the staleness window (routine BTC daily volatility) causes all `redeem()` calls to revert.
- Users cannot exit the cbBTC vault during affected windows.

**PoC Result**:
```
test_POC_HYP03_constant_mismatch_verified — PASS
  CbBtcUniswapV3TwoHopSwapper.MAX_COLLATERAL_ORACLE_STALENESS: 90000
  BTC/USD heartbeat: 3600 s — mismatch: 25x stale relative to heartbeat

test_POC_HYP03_stale_price_drives_wrong_minOut — PASS
  Stale minOut (based on $95,000): 5% higher than correct
  When BTC/USD drops 5.3%: swap with stale price REVERTS (DoS)

4/4 tests passed [POC-PASS]
```

**Recommendation**: Change `MAX_COLLATERAL_ORACLE_STALENESS` to `3600` in `CbBtcUniswapV3TwoHopSwapper.sol` to match `AaveLoanManager`'s existing correct value for the BTC/USD oracle. This is a one-line fix.

---

### [M-02] Gov/Strategy-Owner Permanent Divergence After Role Rotation — Old Key Retains rescueERC20 and setSlippage Indefinitely [VERIFIED]

**Severity**: Medium
**Location**: `src/ZenjiAdmin.sol:258-283` (acceptRole), `src/strategies/BaseYieldStrategy.sol` (owner-locked functions)
**Confidence**: HIGH (1/1 PoC test passed, [POC-PASS], chain analysis confirmed)

> **STATUS — FIXED (2026-06-02):** `ZenjiAdmin.acceptRole(1)` now calls `yieldStrategy.transferOwnerFromVault()` **directly (no try/catch)**, so if the strategy can't accept the new owner the whole rotation reverts and `vault.gov` can never diverge from `strategy.owner`. (The swapper gov handoff stays best-effort — the swapper is mutable via its own 1-week timelock and not every swapper implements vault-initiated rotation.) Regression: `VerifyBatch3_Governance.t.sol::test_POC_HYP04...` and `test_POC_HYP10...` (rotation reverts atomically; no divergence; succeeds once the strategy is transferable). This also closes the M-10/CH-04 split-authority chain.

**Description**:
When governance rotates (`acceptRole(role=1)`), `ZenjiAdmin` updates `vault.gov` to the new key and then attempts to propagate ownership to the yield strategy and swapper via try/catch:

```solidity
// ZenjiAdmin.sol:268-283
gov = msg.sender;
// ...
try yieldStrategy.transferOwnerFromVault(msg.sender) {
    // success — strategy owner is now the new gov
}
catch {
    emit StrategyOwnerPropagationFailed(msg.sender);
}
```

If `transferOwnerFromVault()` reverts for any reason — strategy paused, bricked, or upgraded — the emission of `StrategyOwnerPropagationFailed` is the only observable indication. The divergence becomes **permanent**: `vault.gov` is the new key, but `strategy.owner` remains the old key. There is no on-chain re-sync path:
- `BaseYieldStrategy.transferOwner()` is locked once `vault.code.length > 0`.
- `BaseYieldStrategy.transferOwnerFromVault()` requires `msg.sender == vault` — the new gov cannot call it directly.
- The vault has no `forceSyncStrategyOwner()` function.

The old key indefinitely retains:
- `strategy.setSlippage()` (direct call, bypasses vault `setParam`; values in range 1e15–5e16)
- `strategy.rescueERC20()` for non-protected tokens (e.g., unclaimed CRV, any misc ERC20 in strategy)

Additionally, because the old key retains `setSlippage` access on the strategy directly, it can concurrently update strategy slippage independently of the new governance — creating split slippage authority with no coordination or veto mechanism.

**Impact**:
- After a gov rotation where strategy propagation silently fails, the old key retains privileged access to the yield strategy indefinitely.
- The old key can call `rescueERC20` on non-protected tokens held in the strategy.
- Split slippage authority: old key can set strategy slippage directly while new gov can only set it via the vault's `setParam` route (which is also subject to H-01-related operational constraints — see M-04).
- No on-chain remedy exists for new governance to reclaim strategy ownership without another full rotation attempt.

**PoC Result**:
```
test_POC_HYP04_GovStrategyOwnerDivergence — PASS
  CONFIRMED: vault.gov=0x24305F..., strategy.owner=0xDe5F5...
  Old gov can still call setSlippage directly on strategy
  newGov.strategy.transferOwnerFromVault(newGov) → reverts (Unauthorized)
[POC-PASS]
```

**Recommendation**:
1. **Fail-safe rotation**: Propagate strategy ownership **before** writing `vault.gov`. If propagation fails, revert the entire `acceptRole` call rather than silently continuing. This ensures vault governance and strategy governance stay in sync or the rotation is cleanly rejected.
2. **Alternatively**: Add a `syncStrategyOwner()` function callable by `gov` that re-triggers `yieldStrategy.transferOwnerFromVault(gov)`, allowing new governance to force resync if strategy becomes available after a temporary failure.
3. Remove the ability for `strategy.transferOwner()` to be called directly once the vault is deployed — or replace it with a vault-mediated path only.

---

### [M-03] CrvToCrvUsdSwapper Removes the 5% Slippage Cap — Governance Can Enable Near-100% MEV Drain of CRV Harvest [VERIFIED]

**Severity**: Medium
**Location**: `src/swappers/reward/CrvToCrvUsdSwapper.sol:68-75`
**Confidence**: HIGH (1/1 PoC test passed, [POC-PASS])

> **STATUS — FIXED (2026-06-02):** `CrvToCrvUsdSwapper.setSlippage` now enforces `> MAX_SLIPPAGE` (5%) — the same cap as `BaseSwapper` — instead of `>= PRECISION`. Near-100% reward slippage is no longer settable. Regression: `VerifyBatch3_Governance.t.sol::test_POC_HYP05...` (9e17 reverts; 5e16 allowed; >5e16 reverts).

**Description**:
`BaseSwapper.setSlippage()` enforces a `MAX_SLIPPAGE = 5e16` (5%) cap on all swapper slippage:

```solidity
// BaseSwapper.sol:54
if (newSlippage == 0 || newSlippage > MAX_SLIPPAGE) revert InvalidSlippage();
```

`CrvToCrvUsdSwapper` overrides `setSlippage()` with a weaker guard that removes this cap entirely:

```solidity
// CrvToCrvUsdSwapper.sol:68-75
function setSlippage(uint256 newSlippage) external override {
    if (msg.sender != gov && msg.sender != vault && msg.sender != authorizedCaller) {
        revert Unauthorized();
    }
    if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
    slippage = newSlippage;
    emit SlippageUpdated(newSlippage);
}
```

The only upper bound is `newSlippage < PRECISION` (i.e., < 1e18), allowing values up to `1e18 - 1` (~100% slippage). When slippage is set high, the oracle floor `oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION` is also widened to near-zero, providing no protection. MEV bots can sandwich CRV→crvUSD swaps and extract nearly all harvest proceeds.

**Impact**:
- Swapper governance (which is vault governance after rotation) can set CRV harvest slippage to near-100%.
- On the next harvest call, MEV bots capture up to ~100% of CRV reward proceeds.
- Impact is bounded by the CRV reward accumulation rate, not vault principal — but represents systematic yield destruction while the misconfiguration persists.

**PoC Result**:
```
test_POC_HYP05_CrvToCrvUsdSwapperSlippageCapRemoved — PASS
  CONFIRMED: CrvToCrvUsdSwapper accepted 9e17 slippage (90%)
  BaseSwapper MAX_SLIPPAGE=5e16 cap is completely bypassed
  crvSwapper.setSlippage(1e18 - 1) → ACCEPTED (near-100%)
[POC-PASS]
```

**Recommendation**: Restore the `MAX_SLIPPAGE` cap in `CrvToCrvUsdSwapper.setSlippage()`. Either call `super.setSlippage(newSlippage)` to leverage the base class guard, or add an explicit check:

```solidity
if (newSlippage == 0 || newSlippage > MAX_SLIPPAGE) revert InvalidSlippage();
```

CRV→crvUSD is a direct Curve pool swap on a pegged pair; 5% is already generous. If a higher cap is intentionally needed for this specific swapper, document the reasoning and set it to no more than `10e16` (10%).

---

### [M-04] setParam(4) Slippage Update Blocked by Strategy MIN_SLIPPAGE Floor — Governance Cannot Tighten Below 0.1% [VERIFIED]

**Severity**: Medium
**Location**: `src/libraries/ZenjiGovLib.sol:115-119` (setParam), `src/libraries/ZenjiGovLib.sol:163-168` (executeParamChange), `src/strategies/BaseYieldStrategy.sol:26` (MIN_SLIPPAGE)
**Confidence**: HIGH (4/4 PoC tests passed, [POC-PASS])

> **STATUS — FIXED (2026-06-02):** Added `MIN_VAULT_SLIPPAGE = 1e15` to `ZenjiGovLib`, applied in both the `setParam(4)` and `executeParamChange(4)` paths, so the vault rejects sub-floor slippage up front instead of letting the strategy's `setSlippage` revert the whole change. The vault's accepted range `[1e15, 5e16]` now matches the strategy's `[MIN_SLIPPAGE, MAX_SLIPPAGE]`. Regression: `H11_MaxSlippage.t.sol` (the three slippage tests now use the `1e15` floor).

**Description**:
`ZenjiGovLib.setParam(p=4, v)` propagates a slippage update to the yield strategy with no error handling:

```solidity
// ZenjiGovLib.sol:115-119
s.maxSlippage = v;
IYieldStrategy(yieldStrategy).setSlippage(v);
if (swapper != address(0)) ISwapperSlippage(swapper).setSlippage(v);
```

`BaseYieldStrategy.setSlippage()` enforces `v >= MIN_SLIPPAGE = 1e15` (0.1%), reverting with `SlippageExceeded` for any `v < 1e15`. Since this revert is not caught, it propagates through the entire governance transaction, rolling back the `s.maxSlippage = v` assignment. The same issue exists in `executeParamChange(p=4)`.

The vault's own range check allows `v ∈ (0, MAX_VAULT_SLIPPAGE]` — the mismatch between vault's acceptable range and strategy's floor creates a permanently inaccessible range: governance can never set `maxSlippage` to any value in `(0, 1e15)`. The boundary is confirmed:

- `setParam(4, 1e15)` — succeeds (exactly at floor)
- `setParam(4, 1e15 - 1)` — reverts

Additionally, if the yield strategy is bricked or returns an unexpected revert, this pattern blocks all slippage updates via `setParam`, including any emergency tightening of slippage tolerances.

**Impact**:
- Governance cannot configure vault slippage below 0.1% even when protocol conditions warrant finer control.
- Any yield strategy revert in `setSlippage()` blocks the entire governance transaction for slippage updates.
- A bricked strategy prevents new governance from adjusting slippage at all via the vault's `setParam` route.

**PoC Result**:
```
test_POC_HYP07_setParam_below_min_slippage_reverts — PASS
  vault.maxSlippage after failed setParam(4, 5e14): UNCHANGED at 1e16
  CONFIRMED: setParam(4, v < 1e15) reverts; maxSlippage never updated

test_POC_HYP07_at_min_slippage_boundary_succeeds — PASS (1e15 succeeds)
test_POC_HYP07_one_below_min_slippage_reverts — PASS (1e15-1 reverts)

4/4 tests passed [POC-PASS]
```

**Recommendation**: Wrap the strategy and swapper `setSlippage()` calls in try/catch blocks in both `setParam` and `executeParamChange`. The vault's `maxSlippage` storage should always be updated successfully regardless of whether the downstream propagation succeeds. Emit a `StrategySlippagePropagationFailed` event on catch to allow monitoring.

```solidity
s.maxSlippage = v;
try IYieldStrategy(yieldStrategy).setSlippage(v) {} catch {
    emit StrategySlippagePropagationFailed(v);
}
if (swapper != address(0)) {
    try ISwapperSlippage(swapper).setSlippage(v) {} catch {
        emit SwapperSlippagePropagationFailed(v);
    }
}
```

---

### [M-05] withdrawFees Resets feesAtLastRebalance to Zero — Keeper Bounty Overcounting [VERIFIED]

**Severity**: Medium
**Location**: `src/Zenji.sol:724-726`, `src/libraries/ZenjiCoreLib.sol:164`
**Confidence**: HIGH (1/1 PoC test passed, [POC-PASS])

> **STATUS — FIXED (2026-06-02):** Removed the `feesAtLastRebalance = accumulatedFees` assignment from `withdrawFees`. The keeper-bounty baseline is now advanced **only** by `rebalance()`, so a strategist can no longer zero it via a fee withdrawal to inflate the next bounty. `processRebalanceBounty`'s `accumulatedFees > feesAtLastRebalance` guard keeps the subtraction underflow-safe, and the `_accrueYieldFees` clamp still resets the baseline only after genuine losses. Fee-accounting invariant suite remains green.

**Description**:
`Zenji.withdrawFees()` calls `ZenjiCoreLib.processWithdrawFees()` and then unconditionally sets `feesAtLastRebalance = accumulatedFees`:

```solidity
// Zenji.sol:724-726
(accumulatedFees, lastStrategyBalance) =
    ZenjiCoreLib.processWithdrawFees(recipient, yieldStrategy, debtAsset, accumulatedFees);
feesAtLastRebalance = accumulatedFees;
```

`processWithdrawFees` always returns `newAccumulatedFees = 0` (all fees are paid out). Therefore `feesAtLastRebalance` is unconditionally set to **0** on every `withdrawFees` call.

`feesAtLastRebalance` is intended as a **rebalance checkpoint** — it marks the accumulated fee level at the last rebalance, enabling keeper bounty calculation to pay only on fees earned in the *current* rebalance window:
```
feesSinceLastRebalance = accumulatedFees - feesAtLastRebalance
```

After a `withdrawFees` call, this baseline is zeroed. The next `rebalance()` computes keeper bounty on the **full post-withdrawal yield** rather than only the yield since the last rebalance. In the loss-recovery scenario, this is doubly incorrect: if a loss reduced `accumulatedFees` below the previous rebalance baseline, and then `withdrawFees` clears both values, the next rebalance pays bounty on yield that merely recovers from the loss — not on net new yield above the historical baseline.

The strategist can exploit this by calling `withdrawFees` immediately before a rebalance to inflate the keeper bounty paid on the next call.

**Impact**:
- Keeper bounties are systematically overstated following any `withdrawFees` call.
- In loss-recovery scenarios, bounties are paid on what is effectively yield recovery, not genuine surplus.
- A strategist can repeatedly call `withdrawFees` to maximize the effective keeper bounty on subsequent rebalances.

**PoC Result**:
```
test_POC_HYP08_WithdrawFeesResetsKeeperBountyBasis — PASS
  After withdrawFees: feesAtLastRebalance=0
  After new yield: feesSinceLastRebalance=100000000 (= full post-withdraw yield)
  keeper bounty at 20% rate=20000000 (= 20% of ALL post-withdraw yield, not marginal)
[POC-PASS]
```

**Recommendation**: Remove the `feesAtLastRebalance = accumulatedFees` assignment from the `withdrawFees` path. `feesAtLastRebalance` should only be updated by `rebalance()`. The fee withdrawal should not alter the rebalance baseline — it withdraws fees that were earned, but should not reset the bounty tracking window.

```solidity
// Remove line 726 from Zenji.sol:
// feesAtLastRebalance = accumulatedFees;  // DELETE THIS LINE
```

---

### [M-06] CRV Permanently Stranded at Swapper After Failed Harvest — Yield Lost Until Manual Rescue [VERIFIED]

**Severity**: Medium
**Location**: `src/strategies/lp/BaseCurveStakeDaoStrategy.sol:141-153`
**Confidence**: HIGH (2/2 PoC tests passed; 2/2 chain confirmation tests passed, [POC-PASS])

> **STATUS — FIXED (2026-06-02):** `_claimAndSwapRewards` now performs the CRV transfer + swap **atomically via an external self-call** (`transferAndSwapCrv`, callable only by the strategy). When the swap reverts, the external-call frame rolls back the CRV transfer, so the CRV stays at the strategy and is retried automatically on the next harvest — no stranding at the swapper, no manual `rescueToken` needed. Regression: `POC_Batch2_...fork.t.sol::test_POC_HYP09...` / `test_POC_HYP11...` (CRV retained at strategy; zero swapper accumulation across repeated failed harvests).

**Description**:
`BaseCurveStakeDaoStrategy._claimAndSwapRewards()` transfers CRV to the swapper contract **before** the swap attempt:

```solidity
// BaseCurveStakeDaoStrategy.sol:141-153
uint256 crvBalance = crv.balanceOf(address(this));
if (crvBalance < MIN_HARVEST_THRESHOLD) return 0;

crv.safeTransfer(address(crvSwapper), crvBalance);  // transfer BEFORE try block
try crvSwapper.swap(crvBalance) returns (uint256 received) {
    lpAssetReceived = received;
} catch {
    // Swap reverted (oracle floor / slippage). CRV stays at the swapper; recover via
    // its rescue path. CrvSwapDeferred is emitted below.
}
```

When `crvSwapper.swap()` reverts for any reason (oracle staleness, slippage), the `catch {}` block is empty — CRV remains at the swapper address permanently. The next harvest reads only `crv.balanceOf(address(this))` (the strategy's own balance), never the swapper's accumulated balance. There is no auto-recovery path; stranded CRV requires manual governance intervention via `CrvToCrvUsdSwapper.rescueToken()`.

This bug compounds with the H-01 oracle staleness condition (see below): during the 17-hour crvUSD oracle stale window, harvest attempts transfer CRV to the swapper then revert in the swap. Every keeper retry during the window adds more CRV to the permanent stranded pool. Over a full oracle stale cycle, all CRV claimed during those 17 hours is lost to the strategy unless governance actively rescues it.

**Impact**:
- Every failed CRV harvest cycle permanently reduces compound yield by the full CRV balance claimed in that cycle.
- During oracle staleness events, repeated keeper retries can accumulate substantial stranded CRV.
- Requires manual `gov.rescueToken()` intervention for each occurrence — a monitoring and operational burden.

**PoC Result**:
```
test_POC_HYP09_crv_stranded_before_try_block — PASS
  CRV stranded at swapper: 1000000000000000000 CRV
  CRV at strategy before next harvest: 1000000000000000000 (unchanged)
  CRV transferred before try block; catch does not recover it

test_POC_HYP09_compounding_stranding_per_cycle — PASS
  Total CRV stranded after 3 failed harvests: 15 CRV
  (oracle stale chain) CRV stranded after 17 failed harvests: 170 CRV

4/4 tests passed [POC-PASS]
```

**Recommendation**:
1. **Move the transfer inside the try block**: Transfer CRV to the swapper only inside the `try` call, so that on revert the transfer never happens.

```solidity
try crvSwapper.swapFrom(address(this), crvBalance) returns (uint256 received) {
    lpAssetReceived = received;
} catch { }
```

This requires `crvSwapper.swap()` to pull from the strategy or accept a `from` address parameter, or the strategy can approve and the swapper can pull.

2. **Alternatively**: At the start of each harvest, check and recover any CRV balance sitting at the swapper (read `crv.balanceOf(address(crvSwapper))`) and include it in the current harvest. This is simpler to implement without changing the swapper interface.

---

### [M-07] Uniswap V3 Hop `amountOutMin=0` — Griefing DoS on wstETH Vault Withdrawals [VERIFIED]

**Severity**: Medium
**Location**: `src/swappers/base/UniswapMixedCurveSwapper.sol:128`
**Confidence**: HIGH (2/2 PoC tests passed, [POC-PASS])

> **STATUS — FIXED (2026-06-02):** The collateral→WETH V3 hop in `swapCollateralForDebt` now sets `amountOutMin` from the exact wstETH→stETH protocol rate (`stEthPerToken()`, stETH≈ETH≈WETH) × `(1 - slippage)`, so the hop can no longer be sandwiched beyond `slippage`. This uses the wstETH↔ETH relationship directly (not the crvUSD/composite path), avoiding the divergence that over-constrains the final leg; dust inputs below `DUST_SWAP_THRESHOLD` keep `minOut = 0`. The rate is fetched via a **soft staticcall**: `UniswapMixedCurveSwapper` also serves non-wstETH collateral (the WBTC/crvUSD Llama vault uses it via WBTC→WETH→crvUSD), which has no `stEthPerToken()`; for those the call fails and the hop keeps `minOut = 0`, relying on the Curve `get_dy` floor + the end-to-end 95% LoanManager floor (M-07 is specifically the *wstETH* vault). Regression: the wstETH **and** WBTC Llama fork suites pass with the new floor; `test_POC_HYP06...` updated.

**Description**:
`UniswapMixedCurveSwapper.swapCollateralForDebt()` sets `amountOutMin = uint256(0)` for the Uniswap V3 wstETH→WETH hop:

```solidity
// UniswapMixedCurveSwapper.sol:126-132
inputs[0] = abi.encode(
    address(this),      // recipient
    collateralAmount,
    uint256(0),         // amountOutMin: 0 — Curve step enforces floor
    v3Path,
    false
);
```

The comment explains the design intent: the end-to-end oracle floor (`MIN_SWAP_OUT_BPS = 9500`, i.e., 95% of oracle value) is enforced by the loan manager's `SwapperUnderperformed` check on the total crvUSD received. However, this floor does not prevent a grieving attack: a griefer can temporarily drain the V3 wstETH/WETH pool's depth, causing the V3 hop to produce far less WETH than oracle-implied. The Curve step then receives reduced WETH and produces insufficient crvUSD. The 95% oracle floor fires and the withdrawal reverts with `SwapperUnderperformed`.

The 95% floor does prevent the griefer from extracting profit (the floor blocks value extraction). The attack is therefore **grief-only**: the attacker costs money (pool manipulation gas) but gains nothing. However, repeated grief makes the wstETH vault unusable during periods of attacker activity — users cannot bypass the per-withdrawal DoS without governance adjusting the protocol-wide slippage tolerance.

**Impact**:
- Any withdrawal from the wstETH LlamaLend vault can be griefed by temporarily skewing the V3 wstETH/WETH pool.
- Withdrawal reverts with `SwapperUnderperformed` at the 95% floor.
- No profit extraction (floor prevents that), but repeatable grief DoS on withdrawals.
- Users are unable to adjust slippage tolerance on a per-transaction basis — only governance can change it protocol-wide.

**PoC Result**:
```
test_POC_HYP06_v3_hop_zero_amountOutMin_code_trace — PASS
  Oracle expected: 3800 crvUSD, 95% floor: 3610 crvUSD
  Sandwiched output: 1900 crvUSD
  SwapperUnderperformed fires: YES - DoS confirmed
  Grief only: no profit extraction confirmed

2/2 tests passed [POC-PASS]
```

**Recommendation**: Add a per-hop minimum for the V3 leg, computed from the oracle quote multiplied by a conservative floor (e.g., 90% of the expected WETH for that leg based on the wstETH/WETH price). This closes the griefing vector without requiring oracle-exact minimums on the intermediate hop.

```solidity
uint256 wethMinOut = _getExpectedWeth(collateralAmount) * 9000 / 10000; // 90% floor on V3 hop
inputs[0] = abi.encode(address(this), collateralAmount, wethMinOut, v3Path, false);
```

---

## Low Findings

### [L-01] maxDeposit Does Not Check depositsPaused — ERC4626 Non-Compliance [VERIFIED]

**Severity**: Low
**Location**: `src/Zenji.sol:358-363`
**Confidence**: HIGH ([POC-PASS])

**Description**:
`Zenji.maxDeposit()` checks `emergencyMode` but not `depositsPaused`:

```solidity
function maxDeposit(address) external view override returns (uint256) {
    if (emergencyMode) return 0;
    if (depositCap == 0) return type(uint256).max;
    // ...
}
```

When `pauseDeposits()` is active, `deposit()` reverts with `DepositsArePaused`, but `maxDeposit()` returns a non-zero value. EIP-4626 requires `maxDeposit()` to return 0 whenever `deposit()` would revert. Integrators relying on `maxDeposit()` for routing decisions would receive a misleading signal.

**Recommendation**: Add `if (depositsPaused) return 0;` in `maxDeposit()`.

---

### [L-02] cancelEmergencyMode Leaves depositsPaused Set — Deposits Remain Blocked After Cancel [ACKNOWLEDGED]

**Severity**: Low
**Location**: `src/ZenjiAdmin.sol:428-437`
**Confidence**: HIGH ([POC-PASS])

> **STATUS — ACKNOWLEDGED / BY DESIGN (2026-06-03):** `emergencyMode` and `depositsPaused` are intentionally independent controls — a guardian may pause deposits for reasons unrelated to an emergency, so cancelling emergency must not silently un-pause. Gov clears it explicitly via `resumeDeposits()`. The misleading-signal half is already resolved by L-01 (`maxDeposit()` returns 0 while paused, consistent with `deposit()` reverting). Documented in `cancelEmergencyMode`'s NatSpec; no behavior change.

**Description**:
`ZenjiAdmin.cancelEmergencyMode()` clears `emergencyMode` and `pendingSkipTimestamp` but does not clear `depositsPaused`. If guardian paused deposits before or during an emergency, and governance subsequently cancels emergency mode, deposits remain paused. Governance must additionally call `resumeDeposits()` — a non-obvious two-step pattern not evident from the `cancelEmergencyMode` interface. Combined with L-01, `maxDeposit()` returns non-zero while `deposit()` still reverts.

**Recommendation**: Either clear `depositsPaused` in `cancelEmergencyMode()`, or emit a specific event warning that deposits may still be paused after cancel, and document the required follow-up call prominently.

---

### [L-03] VP Cache Staleness Bypass After 1-Day Idle — Currently Mitigated by Pool Imbalance [ACKNOWLEDGED]

**Severity**: Low
**Location**: `src/strategies/lp/BaseLPStrategy.sol:137-148`
**Confidence**: MEDIUM (mitigated by current pool state; theoretical at 95% pmUSD imbalance)

> **STATUS — ACKNOWLEDGED / ACCEPTED RISK (2026-06-03):** The staleness bypass is a deliberate liveness choice and the residual risk is accepted: (1) the ±MAX_VP_DEVIATION clamp targets *same-tx* manipulation, but every state-changing withdraw calls `_syncValueCache()` first, so the funds-moving path re-anchors the clamp to a fresh value; (2) Curve `get_virtual_price()` is the invariant-per-share and cannot be profitably moved within one transaction (it only ratchets up from fees); and (3) the vault's sensitive paths are reentrancy-guarded, so an attacker cannot move the pool VP and the vault accounting atomically. The bypass only affects pure-view reads after a multi-day idle. Documented in `_getSafeUnitValue`'s NatSpec; no behavior change.

**Description**:
After `lastVpUpdate` age exceeds 1 day, `_getSafeUnitValue()` returns the raw current virtual price with no ±0.5% manipulation clamp. This bypass was intended for vaults idle for extended periods, but it removes the main protection against VP manipulation attacks. At the current 95% pmUSD pool imbalance, a VP attack is infeasible due to the high capital requirement. However, if the pool rebalances toward 50/50, the manipulation threshold decreases significantly and the bypass becomes exploitable.

**Recommendation**: Add a maximum VP staleness protection or document the operational dependency on pool imbalance. Consider removing the bypass entirely and requiring a cache refresh via `updateCachedVirtualPrice()` instead.

---

### [L-04] LlamaLoanManager Missing reentrancy Guard — Asymmetric with AaveLoanManager [VERIFIED]

**Severity**: Low
**Location**: `src/lenders/LlamaLoanManager.sol:256,448`
**Confidence**: MEDIUM (safe currently; future-change risk)

**Description**:
`AaveLoanManager` applies explicit `nonReentrant` guards on entry points. `LlamaLoanManager` relies solely on the outer vault's reentrancy guard, with no contract-level guard. crvUSD currently has no transfer callbacks, so this is safe. If crvUSD or the LlamaLend controller is upgraded to include callbacks, the asymmetry creates a gap. This is a defense-in-depth inconsistency.

**Recommendation**: Add `nonReentrant` to `LlamaLoanManager.unwindPosition()` and `repayDebt()` for consistency with `AaveLoanManager` and to provide defense-in-depth against future changes.

---

### [L-05] AaveLoanManager Flash Partial-Unwind Bypasses MIN_HEALTH=1.1 Check [VERIFIED]

**Severity**: Low
**Location**: `src/lenders/AaveLoanManager.sol:401-412`
**Confidence**: HIGH ([CODE])

**Description**:
`AaveLoanManager.executeOperation()` (the Aave flash loan callback) performs partial collateral withdrawals without the `MIN_HEALTH = 1.1` health factor check that is enforced in the direct `removeCollateral()` path. A partial flash unwind can leave the Aave position with a health factor between 1.0 and 1.1 — within Aave's liquidation buffer but below the protocol's intended safety floor. The `direct removeCollateral` path correctly enforces this check.

**Recommendation**: Apply the `MIN_HEALTH` check to the partial-collateral withdrawal within `executeOperation`, mirroring the protection in `removeCollateral`.

---

### [L-06] Cost Basis Over-Reduction on Slippage Losses — Minor Fee Over-Accrual [VERIFIED]

**Severity**: Low
**Location**: `src/strategies/BaseYieldStrategy.sol:189-192`
**Confidence**: HIGH ([CODE])

**Description**:
`BaseYieldStrategy` computes `basisReduction` using the **requested** withdrawal amount, not the **received** amount. When slippage causes the strategy to return less than requested, `_costBasis` is reduced as if the full requested amount was returned. This causes the fee accounting to treat the slippage loss as "profit" on the next yield accrual, resulting in minor fee over-accrual proportional to the cumulative slippage.

**Recommendation**: Use `min(amount, received)` as the basis reduction, not `amount`.

---

### [L-07] WstEthOracle Returns Round Metadata from ETH/USD Leg Only [VERIFIED]

**Severity**: Low
**Location**: `src/WstEthOracle.sol:80-81`
**Confidence**: HIGH ([CODE])

**Description**:
`WstEthOracle.latestRoundData()` returns `roundId` and `answeredInRound` from the ETH/USD feed only. The stETH/ETH feed's round completeness is not reflected in the composite oracle's metadata. Current Zenji consumers correctly use `updatedAt` for staleness checks (not `answeredInRound`), so this has no current impact. However, integrators who follow the standard Chainlink practice of checking `answeredInRound >= roundId` would receive misleading round health data from the stETH/ETH leg.

**Recommendation**: Return `min(stEthEth.roundId, ethUsd.roundId)` and the corresponding `answeredInRound` values from the stETH/ETH leg, or document clearly that round metadata reflects only the ETH/USD leg.

---

### [L-08] WstEthOracle stETH/ETH Decimal Assumption Hardcoded — Feed Upgrade Risk [VERIFIED]

**Severity**: Low
**Location**: `src/WstEthOracle.sol:72`
**Confidence**: MEDIUM (safe currently; feed upgrade creates risk)

**Description**:
`WstEthOracle` divides by `1e18 * 1e18` hardcoded, assuming the stETH/ETH Chainlink feed always returns 18-decimal values. `stEthEthFeed` is an immutable — governance cannot change it. If Chainlink migrates the stETH/ETH feed to a different decimal precision (as they did with some older feeds), the oracle would produce a near-zero or massively inflated price with no on-chain detection.

**Recommendation**: Add a constructor assertion: `require(stEthEthFeed.decimals() == 18, "decimal assumption")`. This cannot guard against future feed changes on the same address, but provides explicit documentation of the invariant and catches misconfiguration at deploy time.

---

### [L-09] previewWithdraw Returns 1:1 When totalCollateral=0, totalSupply>0 — Misleading ERC4626 View [VERIFIED]

**Severity**: Low
**Location**: `src/Zenji.sol` (`previewWithdraw` / `convertToShares` zero-collateral guard)
**Confidence**: HIGH ([CODE])

**Description**:
When `totalCollateral = 0` but `totalSupply > 0`, `previewWithdraw(assets)` returns `assets` (1:1), implying one share per asset unit. In reality, `withdraw(assets)` in this state would require approximately `assets * totalSupply / VIRTUAL_SHARE_OFFSET` shares — potentially ~1e13× more shares than the preview suggests. This misleads integrators and frontends computing expected share burns. No fund loss (the share math is correct in execution); the view is incorrect.

**Recommendation**: Return `type(uint256).max` from `previewWithdraw` when `totalCollateral = 0 && totalSupply > 0` to signal that the vault is in an undefined state, consistent with ERC4626's guidance on functions that are not meaningful in all states.

---

### [L-10] Pool Imbalance Generates Permanent strategyDebtRebalanceNeeded Signal [FALSE POSITIVE]

**Severity**: ~~Low~~ → **Not a finding**
**Location**: `src/strategies/lp/BaseCurveStakeDaoStrategy.sol` (`balanceOf` / `strategyDebtRatio` computation)
**Confidence**: HIGH ([CODE])

> **STATUS — FALSE POSITIVE (2026-06-03):** The finding compared `exitBased` (single-sided crvUSD
> exit) against the LP's **virtual-price value** and saw a 5–15% gap, concluding the rebalance
> signal trips permanently. But the rebalance metric is `strategyToDebtRatio = balanceOf / debt`,
> and `debt` ≈ the crvUSD that was **borrowed and deposited**, which ≈ `exitBased` — because a
> single-sided crvUSD deposit into the imbalanced pool earns the *balancing bonus* that inflates
> the VP value above the deposit. The deposit-bonus and withdraw-discount cancel (the round trip is
> a Curve inverse), so `balanceOf / debt ≈ 1.0`, not ~0.1. Measured on the **live pmUSD/crvUSD pool**
> (95.4% pmUSD / $224K crvUSD) via `test/PmUsdPoolProbe.t.sol`, `exitBased / deposit` is **0.999 at
> every size from $1K to $1M** — none within range of the 3% deadband (`1.0 − DEADBAND_SPREAD =
> 0.97`). The "permanent signal on every deposit" does not occur. The only way the ratio falls below
> 0.97 is if the pool drifts *substantially* more imbalanced **after** deposit (crvUSD side depleted
> toward ~99/1), at which point a rebalance signal is arguably correct. No code change; `balanceOf`'s
> conservative `min(VP, exit)` is correct. (The `test_capacityReport` / `test_oneMillion` slippage
> failures are a separate end-to-end collateral↔crvUSD swap-leg concern, not this signal.)

**Description**:
At 95% pmUSD imbalance in the Curve pool, `calc_withdraw_one_coin` (single-sided crvUSD exit) returns approximately 5–15% of the virtual-price-implied value. `balanceOf()` uses `min(VP-based value, single-sided exit value)`, so `strategyDebtRatio` is permanently far below the `1.0 − rebalanceThreshold` floor. Keepers receive unnecessary bounties for triggering rebalances that cannot meaningfully improve the ratio. This also amplifies M-05: if `withdrawFees` is called between rebalances during pool imbalance, the inflated bounty on the next rebalance is further exaggerated.

**Recommendation**: Document this as an operational constraint of the current pool composition. Consider adding a `balanceOf()` mode that returns the VP-based value (not the single-sided exit value) for the purpose of rebalance threshold evaluation, or suppress rebalance bounty signals when pool imbalance is detected via an on-chain check.

---

## Informational Findings

### [I-01] Constants Duplicated Across Zenji, ZenjiAdmin, and ZenjiGovLib — Maintenance Divergence Risk [VERIFIED]

**Severity**: Informational
**Location**: `src/Zenji.sol:58-84`, `src/ZenjiAdmin.sol:36-60`, `src/libraries/ZenjiGovLib.sol:22-26`
**Confidence**: HIGH ([CODE])

**Description**:
Five governance constants are duplicated across three files (Zenji, ZenjiAdmin, ZenjiGovLib): `PARAM_TIMELOCK_DELAY`, `GOV_GUARDIAN_TRANSFER_DELAY`, `STRATEGIST_TRANSFER_DELAY`, `MAX_VAULT_SLIPPAGE`, and related values. The duplication is currently consistent. Because all three contracts interact via delegatecall, a partial update of these constants (e.g., updating only one file during a future modification) could introduce silent behavioral divergence — the duplicated constants would differ, potentially changing governance timing or validation bounds in one code path but not another.

**Recommendation**: Centralize these constants into `ZenjiStorage` or a shared `ZenjiConstants` file, imported by all three contracts. This eliminates the maintenance surface without any runtime cost.

---

### [I-02] Slither Reentrancy-Balance Flags — Reviewed, Confirmed False Positives [VERIFIED]

**Severity**: Informational
**Location**: `src/lenders/LlamaLoanManager.sol:729-740`, `src/lenders/AaveLoanManager.sol:343-468`
**Confidence**: HIGH (manual review + Slither cross-check)

**Description**:
Slither 0.11.5 flagged three `reentrancy-balance` locations in `LlamaLoanManager._swapCollateralForDebt`, `LlamaLoanManager._swapDebtForCollateral`, and `AaveLoanManager.executeOperation`. These are intentional check-after-transfer patterns: the code reads `balanceOf` after a swap to measure the actual amount received (slippage accounting), not as a security check. All entry points carrying the reentrancy-relevant paths are protected by `nonReentrant` guards, and crvUSD and USDT have no transfer callbacks that could enable reentrancy.

**Recommendation**: Add NatSpec comments at the flagged locations explaining the intentional check-after-transfer design and suppressing future Slither noise. Example:

```solidity
// slither-disable-next-line reentrancy-benign
uint256 received = token.balanceOf(address(this)) - balanceBefore;
```

---

## Verified-Safe Architecture Notes

The following areas were analyzed in depth during this audit and found to be correctly implemented:

- **ZenjiAdmin storage layout**: `ZenjiAdmin` inherits `ZenjiStorage` and adds only functions, constants, and custom errors — no new state variables. No storage slot collision with `Zenji`. Verified via `forge inspect` comparison.
- **`_adminDelegate` assembly**: The inline assembly in `Zenji._adminDelegate()` uses sequential `calldatacopy → delegatecall → returndatacopy` without concurrent memory overlap. Memory is safe.
- **ZenjiAdmin direct call safety**: All role-check modifiers in `ZenjiAdmin` compare `msg.sender` to addresses stored in vault storage (e.g., `gov`, `guardian`). When called directly (not via delegatecall), those storage slots are zero — all modifiers revert. No unguarded execution paths exist on the facet.
- **First-depositor inflation attack**: `VIRTUAL_SHARE_OFFSET` (1e5 for BTC/ETH-denominated vaults) exceeds `MIN_DEPOSIT` by a sufficient margin. A first-depositor inflation attack requires ~$1.1M in donation capital for ~$0.0001 of gain. Refuted.
- **Flash buffer adequacy**: The 3% emergency flash buffer covers Aave's 0.05% fee with significant margin (60× headroom). crvUSD (LlamaLend) has a 0% flash fee. Sweep-all defense covers residuals. Refuted.
- **Donation/balanceOf manipulation**: All sites where donation could increase `balanceOf` benefit depositors pro-rata or have no attacker upside. No extraction vector identified.
- **CRV oracle-stale MEV**: `OracleLib._validatedPrice()` reverts with `StaleOracle` before any swap logic executes. A stale oracle does not enable a "swap at spot" code path. The CRV harvest is safely deferred on stale oracle.

---

## Priority Remediation Order

1. **H-01** (crvUSD oracle double-lock): Change `MAX_DEBT_ORACLE_STALENESS` to `90000` in `LlamaLoanManager.sol`; add try/catch to emergency step 1 in `ZenjiCoreLib.sol`. — **Immediate, before mainnet LlamaLend vault deployment**
2. **H-02** (broad catch → flash SPOF): Narrow `catch {}` on `llamaLend.repay()` to dust-specific error selector; make `DEBT_FLASH_LENDER` configurable. — **Immediate, before mainnet LlamaLend vault deployment**
3. **M-01** (cbBTC swapper 25h oracle): Change `MAX_COLLATERAL_ORACLE_STALENESS` to `3600` in `CbBtcUniswapV3TwoHopSwapper.sol`. — **One-line fix, ship with H-01/H-02**
4. **M-03** (CRV harvest slippage cap): Restore `MAX_SLIPPAGE` check in `CrvToCrvUsdSwapper.setSlippage()`. — **Before launch**
5. **M-06** (CRV stranding at swapper): Move CRV transfer inside try block or add swapper balance recovery at harvest start. — **Before launch**
6. **M-02** (gov/strategy divergence): Fail-safe rotation — propagate strategy ownership before updating `vault.gov`. — **Before launch**
7. **M-04** (setParam slippage floor): Add try/catch around strategy/swapper `setSlippage` calls in `ZenjiGovLib`. — **Before launch**
8. **M-05** (withdrawFees rebalance reset): Remove `feesAtLastRebalance = accumulatedFees` from `withdrawFees` path. — **Before launch**
9. **M-07** (V3 hop amountOutMin=0): Add per-hop oracle-based minimum for V3 wstETH→WETH leg. — **Before launch**
10. **L-01** (maxDeposit ERC4626): Add `depositsPaused` check to `maxDeposit()`. — **Before launch**
11. **L-02** (cancelEmergencyMode deposits): Clear `depositsPaused` in `cancelEmergencyMode()`. — **Before launch**
12. **L-05** (flash unwind MIN_HEALTH): Apply health factor check to `executeOperation` partial unwind. — **Before launch**
13. **L-06** (cost basis over-reduction): Use `min(amount, received)` for `basisReduction`. — **Before launch**
14. **L-08** (WstEthOracle decimal assertion): Add `require(stEthEthFeed.decimals() == 18)` to constructor. — **Before launch**
15. **L-07** (WstEthOracle roundId): Return composite round metadata from both feed legs. — **Before launch**
16. **L-09** (previewWithdraw 1:1): Return `type(uint256).max` for zero-collateral undefined state. — **Before launch**
17. **L-03** (VP cache bypass): Document or remove the 1-day bypass; add max-staleness guard. — **Pre-launch / operational**
18. **L-04** (LlamaLoanManager reentrancy): Add `nonReentrant` to entry points. — **Recommended hardening**
19. **L-10** (pool imbalance signal): Document rebalance threshold dependency on pool balance. — **Operational**
20. **I-01** (constants duplication): Centralize into `ZenjiStorage`. — **Maintenance improvement**
21. **I-02** (Slither false positives): Add suppression comments. — **Code quality**

---

## Appendix A: Internal Audit Traceability

> This appendix maps internal pipeline IDs to report IDs for audit team reference. It is not required for client-facing review.

| Report ID | Internal Hypothesis | Chain | Verification | Agent Sources |
|-----------|--------------------|----|------|------|
| H-01 | HYP-01, CH-01 | CH-01 | CONFIRMED, 5/5 PoC — verify_batch1.md | INV-03, INV-06, DEXT-1 |
| H-02 | HYP-02, CH-02 | CH-02 | CONFIRMED, 2/2 PoC — verify_batch2.md | INV-09, INV-08, DEXT-4 |
| M-01 | HYP-03 | — | CONFIRMED, 4/4 PoC — verify_batch1.md | INV-12, DEXT-2 |
| M-02 | HYP-04, HYP-10/CH-04 (sub-impact) | CH-04 | CONFIRMED — verify_batch3.md | INV-01, EN-01, EN-02 |
| M-03 | HYP-05 | — | CONFIRMED — verify_batch3.md | INV-15 |
| M-04 | HYP-07 | — | CONFIRMED, 4/4 PoC — verify_batch1.md | INV-05 |
| M-05 | HYP-08 | — | CONFIRMED — verify_batch3.md | INV-04 |
| M-06 | HYP-09, HYP-11/CH-03 (sub-impact) | CH-03 | CONFIRMED, 4/4 PoC — verify_batch2.md | INV-07, DTOK-1 |
| M-07 | HYP-06 | — | CONFIRMED, 2/2 PoC — verify_batch2.md | INV-16, DEXT-3 |
| L-01 | HYP-12 | — | CONFIRMED — verify_batch3.md | INV-02 |
| L-02 | HYP-17 | — | CONFIRMED — verify_batch3.md | DSTATE-1 |
| L-03 | HYP-13 | — | PARTIAL (mitigated by pool state) | INV-10, DEDGE-4 |
| L-04 | HYP-15 | — | PARTIAL (currently safe) | INV-11 |
| L-05 | HYP-16 | — | CONFIRMED [CODE] | INV-13, DEXT-5 |
| L-06 | HYP-18 | — | CONFIRMED [CODE] | INV-14, DTOK-2 |
| L-07 | HYP-21 | — | CONFIRMED [CODE] | INV-17 |
| L-08 | HYP-20 | — | PARTIAL (safe currently) | INV-18, DEDGE-5 |
| L-09 | HYP-19 | — | CONFIRMED [CODE] | DEDGE-2 |
| L-10 | HYP-14 | — | CONFIRMED [CODE] | DEDGE-1 |
| I-01 | HYP-22 | — | CONFIRMED [CODE] | INV-19 |
| I-02 | HYP-23 | — | REFUTED (false positives) | INV-20, DEXT-5 |

### Excluded / Refuted Findings

| Internal ID | Severity | Title | Exclusion Reason |
|-------------|----------|-------|-----------------|
| A-9 | Info | ZenjiAdmin storage layout alignment | FALSE_POSITIVE — confirmed safe by depth state trace; no slot collision |
| A-10 | Info | ZenjiAdmin direct calls fail safely | FALSE_POSITIVE — confirmed by breadth; all modifiers revert on direct call |
| A-11 | Info | `_adminDelegate` assembly memory safe | FALSE_POSITIVE — sequential memory ops; no concurrent overlap |
| A-12 / DEDGE-3 | Info | First-depositor inflation attack | FALSE_POSITIVE — VIRTUAL_SHARE_OFFSET > MIN_DEPOSIT; ~$1.1M attack cost for $0.0001 gain |
| C-7 | Info | CRV oracle stale → MEV exploitable | FALSE_POSITIVE — StaleOracle reverts before swap logic; no stale-price swap path |
| DTOK-3 | Info | LP share math snapshot before compounding | FALSE_POSITIVE — intentional design; VP is deterministic per-transaction |
| DTOK-4 | Info | Flash buffer inadequacy | FALSE_POSITIVE — crvUSD fee = 0; Aave fee 0.05%; 60× headroom |
| DTOK-5 | Info | Donation/balanceOf manipulation | FALSE_POSITIVE — all donation paths benefit depositors; no attacker upside |
