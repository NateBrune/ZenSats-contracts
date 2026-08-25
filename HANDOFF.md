# Handoff — `feat/crvusd-usdt-fleet`

**As of 2026-08-25.** 19 commits ahead of `main`, 0 behind. `main` is untouched at `128c88a`, so this
is a clean fast-forward. **Nothing is pushed** — `origin` is configured
(`NateBrune/ZenSats-contracts`) but neither branch has an upstream. All work is local only.

---

## 1. What this branch does

**Fleet reduced to three vaults, all farming Curve crvUSD/USDT:**

| Collateral | Venue | Debt | Contract | Advised cap |
|---|---|---|---|---|
| WBTC | LlamaLend | crvUSD | `ZenjiWbtcLlamaUsdtStakeDao` | 18 WBTC |
| wstETH | LlamaLend | crvUSD | `ZenjiWstEthLlamaUsdtStakeDao` | 725 wstETH |
| XAUT | Aave V3 (eMode 43) | USDT | `ZenjiXautAaveUsdtStakeDao` **(new, undeployed)** | 95 XAUT |

Five pmUSD configs moved to `retired/` (pmUSD depegged to ~$0.60; pool is 97% pmUSD).

**Both rebalance arms fixed.** Neither converged before; both now do, in one call, on both venues.
- **Arm 3** (`coverage < 97%`): repays from COLLATERAL. `D − S` is conserved under any
  strategy-funded repay, which is why the original never converged.
- **Arm 4** (`coverage > 103%`): skims `S − debt` into collateral. The old borrow-and-deploy
  followed `c' = 2.03 − 1.03/c` and asymptoted at the band edge (measured: 60 calls,
  105.82% → 103.28%). **This bug is pre-existing and live on `main` and on the deployed fleet.**

---

## 2. Running tests

```bash
# Unit — needs NO fork. 661/661.
env -u MAINNET_RPC_URL forge test --no-match-path "test/**/*.fork.t.sol"

# Fork
set -a; . ./.env; set +a
forge test --match-path "test/{WbtcCrvUsdUsdtLlama,WstEthCrvUsdUsdtLlama,XautCrvUsdUsdtAave}.fork.t.sol"
```

**A broken RPC is worse than none.** Several `.t.sol` files fork conditionally and fall back to
mocks when no endpoint is set — but a *dead* endpoint makes them fail on `createSelectFork`. If the
unit suite shows ~5 suite failures, check the RPC before debugging code.

`.env` currently holds a working chainstack endpoint. Infura (402) and Alchemy (429) are commented
out and dead.

---

## 3. Open items, priority order

1. **Push the branch.** 19 commits exist only on this machine.
2. **Keeper error handling** (`keeper/zen-keep/my-workflow/workflow.ts`) — treats every
   `rebalance()` revert identically, no reason decoding. `CoverageDeficitTooLarge` should PAGE;
   `SwapperUnderperformed` should RETRY with backoff. Keeper repo, not contracts.
3. **Apply deposit caps on-chain.** All three vaults read `depositCap = 0` (unlimited). The XAUT
   runbook now has this as a REQUIRED step. Imposing/lowering a cap is immediate; **raising or
   removing one is timelocked** — plan increases ahead of demand.
4. **`monitor/` and `CLAUDE.md` have uncommitted pmUSD-retirement edits.** Both excluded because
   they're untracked — `monitor/` is 576 MB with `node_modules`; `CLAUDE.md` follows the root-doc
   convention where every sibling is untracked. The monitor still lists five dead vaults.
5. **Two regression tests** (`M1_Llama_partial_unwind_health`, `POC_Batch2_HYP02_09_06_11`) still use
   the pmUSD pool as their strategy fixture. Deliberate — migrating them changes what they regress
   against — but pmUSD is thin now, so expect flakiness.

---

## 4. Accepted risks (documented, do not re-derive)

- **H-01** — `deficit` is spot-manipulable (`balanceOf` is `min(vpBased, exitBased)`; the VP leg is
  clamped ±0.5% but `calc_withdraw_one_coin` is raw spot, and `rebalance()` has NO same-block
  cooldown). Accepted: gain is bounded and not farmable, skew cost runs to 5–6 figures, and the
  collateral swap uses a DIFFERENT venue than the skewed LP pool. **Four revisit conditions** in
  `AUDIT_CoverageRebalance_v2.md` — the sharpest being thin yield-pool depth, which is exactly what
  killed pmUSD; re-price whenever `DEPOSIT_CAPS.md` is re-measured.
- **No upward mirror exists.** Skewing 100% of the pool's crvUSD reserve moved coverage ~1 bp,
  because `vpBased` tracks `get_virtual_price()`, which swaps do not move.
- **M-02 liveness** (both arms) — a persistent arm revert blocks `rebalance()` while other bands are
  satisfied. Fails in the safe direction; `setIdle(true)/setIdle(false)` recovers (~1 bp at 1 WBTC).
- **L-03** relative health-floor margin; **L-04** `IMinHealth` bypasses `ILoanManager`.

---

## 5. Footguns learned the hard way

- **Never run `forge fmt`.** It brace-strips single-line blocks and corrupts the codebase.
- **Comments in this repo have been wrong, including safety claims.** A "SUPERSEDED" note outlived
  the thing that superseded it; a NatSpec claimed a postcondition made a bug class
  "unrepresentable" when it only bounds a *ratio*. Verify against code.
- **Green tests can be vacuous.** Three times this session a test passed while proving nothing —
  a hardcoded `MIN_DEPOSIT` boundary that tested a *valid* deposit; a supply-cap test that never
  breached the cap (Aave's `setSupplyCap` is whole-token granularity); a fee-reserve test where
  `accumulatedFees` was 0. Assert the precondition you think you've created.
- **Tests can deploy the wrong contract.** Both LlamaLend suites deployed the pmUSD-named impls, so
  two production vaults had zero coverage of the deployed artifact.
- **A single call can look correct while the loop diverges.** Both arm bugs moved the ratio the
  right way per call and only failed under iteration. Test convergence, not direction.
- **Swappers have no end-to-end oracle floor** — they document the loan manager's
  `SwapperUnderperformed` check as the hard floor. **Any direct `ISwapper` call from the vault must
  re-apply it** (this was a Critical). Measure output as a vault-side balance delta, not the
  swapper's return value; the swapper is governance-rotatable.
- **`CrvToCrvUsdSwapper.swap()` is locked until `setAuthorizedCaller`** — and the harvest wraps it
  in try/catch, so omitting it silently kills reward compounding with no revert.

---

## 6. Key documents

| File | What |
|---|---|
| `deployments/DEPOSIT_CAPS.md` | Cap methodology + why the repo's capacity tests overstate thin pools |
| `deployments/xaut_crvusd_usdt_aave.md` | Gold-vault deploy runbook |
| `COVERAGE_REBALANCE_FIX_PLAN.md` | Arm 3: the `D − S` conservation argument |
| `COVERAGE_PARTIAL_PROGRESS_PLAN.md` | Why partial progress was tried and **rejected** |
| `ARM4_SKIM_SPEC.md` | Arm 4 skim design; why it targets parity, not the band edge |
| `AUDIT_Final_{Arms,Strategy,Lenders,CrossCutting}.md` | Four-part final audit |
| `AUDIT_CoverageRebalance_v2.md` | **Accepted risk H-01 + revisit conditions** |
