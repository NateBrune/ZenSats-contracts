# Audit — LlamaLoanManager.removeCollateral MIN_HEALTH guard + pmUSD retirement

Scope: `src/lenders/LlamaLoanManager.sol` diff (main..HEAD) + pmUSD retirement (5 vault impls,
5 deploy scripts, test suites moved to `retired/`). Read-only review.

## Ship / Don't-ship

**Ship.** The `MIN_HEALTH` guard itself is correct and matches the established pattern. No
deployable path reaches pmUSD, and `forge build` is clean. One **Low** test-hygiene finding
(stale strategy wiring in two regression tests) should be fixed but does not block deployment.

---

## Findings

### [L-01] Two repointed regression tests still deploy the retired pmUSD strategy/pool, not the USDT/crvUSD one their vault class name implies

**Severity**: Low (test-only, no production code path affected)
**Location**:
- `test/M1_Llama_partial_unwind_health.fork.t.sol:12,39,138-149,163`
- `test/POC_Batch2_HYP02_09_06_11.fork.t.sol:12,41,140-149`

**Description**: Both files were repointed from the retired `ZenjiWbtcLlamaStakeDao` to the live
`ZenjiWbtcLlamaUsdtStakeDao` vault class (mechanical rename, correct), but the strategy fixture
inside `_deployVaultContracts()` was **not** migrated along with it. Both still construct
`NgCrvUsdLpStakeDaoStrategy` pointed at `PMUSD_CRVUSD_POOL` (`0xEcb0...2c2cb`) — the retired pmUSD
pool — rather than `CrvUsdLpStakeDaoStrategy` + `USDT_CRVUSD_POOL` (`0x390f...97BF4`), which is
what every other repointed suite now uses (compare `test/WhaleExitUnwindRepro.fork.t.sol:143-158`,
`test/WbtcCrvUsdUsdtLlama.fork.t.sol:309-...`, `test/WstEthCrvUsdUsdtLlama.fork.t.sol:237-...`,
all of which correctly use `CrvUsdLpStakeDaoStrategy` + `USDT_CRVUSD_POOL`).

So a reader (or CI) sees `ZenjiWbtcLlamaUsdtStakeDao` in the contract name and reasonably assumes
the fixture exercises the live USDT/crvUSD configuration, but the actual yield leg under test is
the abandoned pmUSD pool.

**Impact**: These two tests are `M1_Llama_partial_unwind_health` and `POC_Batch2_HYP02_09_06_11` —
both are LlamaLoanManager-focused PoCs (partial-unwind health / batch hypothesis regression),
and `LlamaLoanManager` itself takes no strategy argument and never touches the Curve pool, so the
loan-manager mechanics they're actually probing (including the new `MIN_HEALTH` guard in
`removeCollateral`) are unaffected by which pool the strategy wires to — this is a coverage/
labeling defect, not a false-positive risk for the change under audit. The practical risk is
future drift: `PMUSD_CRVUSD_POOL` is no longer part of the live fleet and isn't guaranteed to
keep the liquidity/state these forks assume, so these two suites could start failing (or passing
for the wrong reasons) independent of any real regression, and anyone reading test names during
a future audit will be misled about what configuration is covered.

**Recommendation**: Repoint the strategy fixture in both files to match the pattern already used
in `WhaleExitUnwindRepro.fork.t.sol` — swap `NgCrvUsdLpStakeDaoStrategy` → `CrvUsdLpStakeDaoStrategy`
and `PMUSD_CRVUSD_POOL`/`PMUSD_CRVUSD_GAUGE`/`STAKE_DAO_REWARD_VAULT` → the USDT/crvUSD pool +
gauge + Stake DAO vault constants, consistent with `script/DeployWbtcLlamaUsdtStakeDao.s.sol`.

---

## Verified Sound

### 1. `MIN_HEALTH` addition cannot block an existing caller, withdrawal, or emergency exit

Enumerated every call site of `LlamaLoanManager.removeCollateral` in `src/`:

- **Only one caller exists**: `ZenjiCoreLib.sol:494`, inside the "arm 3" coverage-rebalance
  routine (`rebalanceCoverageDown`-style deficit-repair path). This is a keeper/strategist-
  triggered rebalance step, not a user withdrawal or emergency path.
- That call site already runs a **feasibility probe** before calling `removeCollateral`
  (`ZenjiCoreLib.sol:482-488`, `loanManager.healthCalculator(-int256(cDesired), 0) < healthFloor`
  → `revert CoverageDeficitTooLarge`), sized off the same `MIN_HEALTH` constant with a documented
  margin (`HEALTH_FLOOR_MARGIN_PCT`). The new in-function check is explicitly documented at
  `ZenjiCoreLib.sol:476` as "the venue's own band check plus the MIN_HEALTH guard in
  removeCollateral" — i.e., a backstop the code already anticipated, not a new blocking surface.
- **User withdrawals and unwinds do not go through `removeCollateral` at all.** Both
  `unwindPosition`/`_unwindPosition` (normal withdraw) and `emergencyUnwindPosition` (guardian
  emergency exit) call `llamaLend.remove_collateral(...)` **directly** (`LlamaLoanManager.sol:475,
  582`), bypassing this function entirely — confirmed by grep, no other call sites in `src/`,
  `ZenjiAdmin.sol`, or `Zenji.sol`. The guardian's emergency step (`_unwindPosition` with
  `emergency=true`) is additionally exempted from the oracle-freshness gate, so this change adds
  zero new revert surface to the emergency path — consistent with the stated intent that this is
  a backstop for a *newly-live* primitive (arm 3), not a change to any pre-existing path. This
  addresses the specific regression class from commit 256de80 (which broke the *unwind* path,
  not `removeCollateral`).

### 2. The guard is internally correct and matches precedent

- Pattern matches `createLoan`/`borrowMore` in the same file and `AaveLoanManager.removeCollateral`
  exactly: `debt > 0` (LlamaLend) / `variableDebtToken.balanceOf(...) > 0` (Aave) gate before
  calling `getHealth()`, then compare against `MIN_HEALTH` and revert `HealthTooLow()`.
- `this.getHealth()` is a `STATICCALL` to `LlamaLoanManager.getHealth()` (external view), which
  itself reads `llamaLend.health(address(this), true)` — no reentrancy risk (view/staticcall,
  no state mutation possible), and the same `this.`-prefixed external self-call idiom is already
  used elsewhere in the file (`_oracleIsFresh`, `IMinHealth` external calls in `ZenjiCoreLib`).
  If `debt == 0`, `getHealth()` would return `type(int256).max` anyway (line 646), so the `debt > 0`
  short-circuit is a gas optimization, not a correctness requirement — but it is correct either way.
- `llamaLend.debt(address(this))` is the correct interest-inclusive debt read (matches
  `ILlamaLendController.debt(address)` signature, same accessor used throughout the rest of the
  file for position sizing).

### 3. Prior-audit claim re-verified constant-by-constant: repointed vault pairs "differ only in name()/symbol()" — **confirmed true at the vault level**

Diffed the retired pmUSD vault contracts against their live USDT/crvUSD replacements directly:

- `retired/src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol` vs.
  `src/implementations/stakedao/ZenjiWbtcLlamaUsdtStakeDao.sol`: diff is exactly the contract
  name, `name()`, and `symbol()` strings. `VIRTUAL_SHARE_OFFSET` (1e4) and `MIN_DEPOSIT` (1e4)
  are identical; neither overrides `MAX_TARGET_LTV` (both inherit the `Zenji.sol` default).
- `retired/.../ZenjiWstEthLlamaStakeDao.sol` vs. `src/.../ZenjiWstEthLlamaUsdtStakeDao.sol`: same
  result — diff limited to contract/name/symbol.
- Confirmed the **`LlamaLoanManager` constructor arguments are unchanged** between the pmUSD and
  USDT deploy scripts for both WBTC and wstETH configs (collateral, debt, `LLAMALEND_*_CONTROLLER`,
  collateral/debt oracles, `maxOracleStaleness` all identical) — only the downstream
  `NgCrvUsdLpStakeDaoStrategy`→`CrvUsdLpStakeDaoStrategy` + pool/gauge/vault addresses changed,
  which is exactly the intended pmUSD→USDT strategy swap, not a discrepancy.
- `ZenjiXautAaveStakeDao` → `ZenjiXautAaveUsdtStakeDao`: same pattern; `MAX_TARGET_LTV` override
  (60%) and `MIN_DEPOSIT`/`VIRTUAL_SHARE_OFFSET` are unchanged between retired and live versions.

**Conclusion**: the prior audit's basis for repointing tests (vaults differ only in
name/symbol) holds for the **vault contract** itself and for the **LlamaLoanManager wiring**.
However, see **L-01** above — the claim does *not* extend transitively to "therefore any test
touching these vaults is safely repointed," because two specific test files' *strategy* fixtures
were left on the old pool despite the vault rename.

### 4. No deployable path reaches pmUSD

- `grep -rn "0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb" src/ script/` → **zero matches**. The
  pmUSD/crvUSD pool address does not appear anywhere in `src/` or `script/`.
- `grep -rln` for all 5 retired contract names (`ZenjiWbtcAaveStakeDao`, `ZenjiWbtcLlamaStakeDao`,
  `ZenjiWstEthAaveStakeDao`, `ZenjiWstEthLlamaStakeDao`, `ZenjiXautAaveStakeDao`) against `src/`
  and `script/` → **zero matches**. `src/implementations/stakedao/` now contains exactly 3 files:
  `ZenjiWbtcLlamaUsdtStakeDao.sol`, `ZenjiWstEthLlamaUsdtStakeDao.sol`,
  `ZenjiXautAaveUsdtStakeDao.sol`; `script/` contains exactly the 3 matching deploy scripts (plus
  `StrategyLiquidityReport.s.sol`).
- `foundry.toml` `[profile.default]` sets `src = "src"` with no `retired` or `keeper` entry in
  scope, and the default `test` path is `test/` (the `h4` profile's `test = "test/h4verify"` is a
  separate, non-default profile). `retired/` is outside every compiled path.
- Note (informational, not a finding): `CLAUDE.md`'s "Vault Configurations" section still lists
  WBTC/Aave and wstETH/Aave as separate live configs — those are now retired too (both Aave *and*
  Llama pmUSD-side WBTC/wstETH vaults were retired, leaving only 3 live vaults: WBTC/LlamaLend,
  wstETH/LlamaLend, XAUT/Aave, all USDT/crvUSD). Doc-only drift, outside this review's code scope.

### 5. Build is clean; NG strategy classes deliberately kept in `src/` are unaffected

- `forge build` exits 0. Only `forge-lint` style warnings (unchecked-typecast suggestions,
  unchecked ERC20 transfer-return-value warnings in test helpers) — no compile errors.
- `NgCrvUsdLpStakeDaoStrategy`, `NgScrvUsdLpStakeDaoStrategy`, `BaseNgCrvUsdLpStakeDaoStrategy`,
  and `BaseNgScrvUsdLpStakeDaoStrategy` remain in `src/strategies/lp/` (not retired) — correct,
  since no live vault currently uses them but they are general-purpose Ng-pool strategy bases,
  not pmUSD-specific; nothing in this diff modifies them.
