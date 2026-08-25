# Audit — UsdtCrvUsdLpStakeDaoStrategy + ZenjiXautAaveUsdtStakeDao

**Scope**: `src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol`, `src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol`, `script/DeployXautAaveUsdtStakeDao.s.sol`, `deployments/DEPOSIT_CAPS.md`.
**Method**: static review + on-chain `cast call` verification against mainnet at review time. Read-only, no fork tests run.

---

## Findings

None at Medium+ severity.

### [I-01] No dedicated test file for the new strategy/vault (Informational)

**Location**: `test/` — no `*UsdtCrvUsdLp*` or `*XautAaveUsdt*` test file exists.

Every other strategy/vault pairing in this codebase has a corresponding unit/fork test. This is a new composition (legacy 2-coin add × USDT swap mixin × 6-dec pendingRewards denominator) and currently has zero direct test coverage — it only inherits coverage transitively through its parents' tests, which don't exercise this exact wiring (e.g. the same-pool-for-both-legs configuration, or the `_crvToPendingRewards`/`_pendingRewardsFallback` overrides on this concrete contract). Recommend adding at minimum: a deposit/withdraw round-trip fork test, a `pendingRewards()` sanity check, and a `_assertCoinOrdering()` regression test before shipping.

### [I-02] Double swap fee on the shared-pool deployment (Informational, already documented/accepted)

**Location**: `UsdtCrvUsdLpStakeDaoStrategy.sol:20-27`, `_deposit()` flow inherited from `BaseLPStrategy._deposit()`.

Because `_usdtCrvUsdPool == _lpPool` in this deployment, every deposit swaps USDT→crvUSD and then single-side-adds that same crvUSD back into the identical pool, paying two implicit-swap fees instead of one two-sided add. This is called out explicitly in the contract's NatSpec as an accepted trade-off (keeps `lpAsset` at 18 decimals for the inherited VP math, and reuses the audited legacy-pool `_addLiquidity` rather than a bespoke two-sided path). Confirmed the economics: it's a cost, not a correctness or security issue — reviewed for sandwich exposure (see "Same-pool swap + LP" below) and found adequately protected. No action required; flagging only so it's visible in this audit's paper trail.

---

## Verified SOUND (six focus areas)

1. **Decimals.** Re-derived every conversion:
   - `_crvToPendingRewards`: `pendingCrv(1e18) * crvPrice(1e8) / (usdtPrice(1e8) * 1e12)` → 1e6 (USDT). Correct, and byte-identical to `UsdtNgCrvUsdLpStakeDaoStrategy`'s override.
   - `_pendingRewardsFallback`: `crvSwapper.quote(pendingCrv) / 1e12` → correct 18→6 dec scaling.
   - `_convertYieldAssetValueToDebt` → `_crvUsdValueToUsdt` → `CurveUsdtSwapLib.convertCrvUsdToUsdt`: `crvUsdValue(1e18) * crvUsdPrice(1e8) / (usdtPrice(1e8) * 1e12)` → 1e6. Correct.
   - `_addLiquidity`'s `uint256[2]` array and `lpCrvUsdIndex` cast are unchanged from the legacy-pool base pattern — `lpAsset` stays crvUSD (18-dec) throughout, matching the inherited VP math (`lpTokens * VP / 1e18`) in `BaseCurveStakeDaoStrategy.balanceOf()`.
   - No decimal mismatch found anywhere in the composed contract.

2. **Inflation-attack economics.** `VIRTUAL_SHARE_OFFSET = 1e3` / `MIN_DEPOSIT = 2000` for XAUT (6-dec) were checked against the fleet's existing calibration, not in isolation:

   | Vault | Collateral decimals | Offset (raw) | Offset (collateral units) | USD value at snapshot price |
   |---|---|---|---|---|
   | WBTC/Aave, WBTC/LlamaLend | 8 | 1e4 | 0.0001 BTC | ~$6.95 (@ $69,466) |
   | wstETH/Aave, wstETH/LlamaLend | 18 | 3e15 | 0.003 wstETH | ~$8.39 (@ $2,796.45) |
   | **XAUT/Aave (new)** | 6 | **1e3** | **0.001 XAUT** | **~$4.49–4.64** (@ $4,490–4,638) |

   The new vault's dead-capital cost sits in the same $4.50–9 band as every other live vault — it is not an outlier, weaker, or stronger than the established pattern. `MIN_DEPOSIT = 2000 >= VIRTUAL_SHARE_OFFSET = 1e3`, satisfying the base contract's documented invariant (`MIN_DEPOSIT() >= VIRTUAL_SHARE_OFFSET()`). Sound, consistent with the rest of the fleet.

3. **Deploy-script addresses — verified on-chain** (mainnet, live at review time):
   - Curve pool `0x390f...7BF4` `coins(0)` = `0xdAC17F9...` (USDT) ✓, `coins(1)` = `0xf939E0A0...` (crvUSD) ✓ — matches `USDT_INDEX=0` / `CRVUSD_INDEX=1`, and matches the deploy script's own `_assertCoinOrdering()` deploy-time revert guard.
   - Stake DAO reward vault `0xF980...4a066`.`asset()` = `0x390f...7BF4` (the pool address itself, i.e. the LP token) ✓.
   - Gauge `0x4e6b...7939`.`lp_token()` = `0x390f...7BF4` ✓ — consistent with the reward vault.
   - Aave `aXAUT` (`0x8A2b...4A2`).`UNDERLYING_ASSET_ADDRESS()` = XAUT ✓. Variable debt USDT (`0x6df1...5A8`).`UNDERLYING_ASSET_ADDRESS()` = USDT ✓.
   - XAUT `decimals()` = 6 ✓ (matches all hardcoded 6-dec assumptions).
   - All four Chainlink oracles (XAU, USDT, crvUSD, CRV): `decimals()` = 8 ✓ for all; `latestRoundData()` fresh (< 1 hour old at check time, well inside the 90,000s/25h staleness windows used everywhere) and no negative/zero prices, no `answeredInRound < roundId` staleness flags.
   - Aave eMode category 43 on-chain: `getEModeCategoryData(43)` = LTV 7000 (70%), liquidation threshold 7500 (75%), liquidation bonus 10600 (6%) — exact match to the deploy script's NatSpec comment and to the values passed into `AaveLoanManager` (`6000` target used, `7500` liq threshold).
   - No address mismatches found. Deploy script is safe to run as written.

4. **`_addLiquidity`.** Byte-for-byte diffed against `CrvUsdLpStakeDaoStrategy._addLiquidity` — identical. Slippage floor (`LP_SLIPPAGE = 0.5%` off `calc_token_amount`) and the independent cached-VP oracle floor (`oracleMinLp` from `_getSafeUnitValue()`) are both present and take the max of the two, exactly as in the audited sibling. No divergence introduced by the copy.

5. **Same-pool swap + LP.** Traced the deposit flow when `_usdtCrvUsdPool == _lpPool`: the USDT→crvUSD swap and the single-sided crvUSD add happen back-to-back within one atomic external transaction with no intervening external call, so there is no window for a third party to insert a transaction between them (only the whole tx can be front/back-run, and both legs already carry independent oracle-floored `minOut`/`minLp`). Net pool-balance effect is USDT added, crvUSD roughly round-tripped (paying two fee legs instead of one) — a cost, not an exploitable imbalance. No sandwich or donation vector beyond what the existing oracle floors already defend against.

6. **`MAX_TARGET_LTV = 60e16` vs Aave eMode 43.** Confirmed on-chain (see #3): eMode 43 = 70% max LTV / 75% liquidation threshold. Vault target 60% gives HF = 0.75/0.60 = 1.25 at target, and HF = 0.75/0.63 = 1.19 at the top of a +3% deadband — both comfortably above `MIN_HEALTH = 1.1` in `AaveLoanManager`. `maxLtvBps = 6000` passed to the loan manager matches `MAX_TARGET_LTV()`, so `setParam` bounds and the loan manager's own ceiling agree.

---

## Ship / Don't-Ship

**Ship**, for this scope. No Critical/High/Medium findings. Two Informational notes (missing dedicated test file; documented double-fee behavior on the shared-pool deployment) — neither blocks deployment, but adding a test file before going live is recommended.
