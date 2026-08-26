# retired/

Code that is no longer part of the live build/test set, kept for reference and possible
revival. **Nothing here is compiled or tested** — Foundry only compiles `src/`, `test/`, and
`script/` (plus their import closure), so these files are inert. Their internal import paths are
intentionally left as-was; if you revive a file, move it back under `src/`/`test/`/`script/` and
fix its relative imports.

## IPOR / LlamaRisk crvUSD Optimizer vaults (retired 2026-06-05)

The `*AaveIpor` vault configs deposited their borrowed debt into the **LlamaRisk crvUSD Optimizer**
IPOR Fusion vault (`0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117` on mainnet). LlamaRisk
[announced](https://app.ipor.io/fusion/ethereum/0xbfa9d6ec0e04b6691fcae5f8b48838c3918ec117) they are
**closing out those vaults**: supply caps set to ~0.1 crvUSD, allocations paused, all funds sitting
idle in crvUSD earning 0% APY (peak TVL was >$1M, now ~$13.6K). With `maxDeposit() == 0`, any new
deposit reverts `ERC4626ExceededMaxDeposit`, so the IPOR-backed vaults can no longer deploy capital
(existing positions remain withdrawable). The yield venue is gone, so this whole path is retired.

The live product is unaffected: WBTC / wstETH collateral + crvUSD (LlamaLend) + crvUSD/USDT Stake DAO
LP. Those vaults and tests remain under `src/` and `test/`.

### Moved here
- `src/` — `implementations/ipor/Zenji{CbBtc,Wbtc,WstEth}AaveIpor.sol`,
  `strategies/vault/{CrvUsdIporStrategy,UsdtIporStrategy,BaseVaultStrategy}.sol`,
  `interfaces/IPlasmaVault.sol`
- `script/` — `Deploy{CbBtc,Wbtc,WstEth}AaveIpor.s.sol`
- `test/` — `{CbBtc,Wbtc,WstEth}AaveExtensive.fork.t.sol`, `IporYieldStrategy.t.sol`,
  `UsdtIporAaveStrategy.t.sol`, `base/IporVaultStrategyTestBase.sol`, `H5_ATokenDonation.fork.t.sol`,
  `VerifyH40.fork.t.sol`, `VerifyH6.fork.t.sol`, `ProtocolSmokeTests.fork.t.sol` (it deployed the
  IPOR strategy as its yield venue), `IporCapProbe.fork.t.sol` (diagnostic)

`test/Zenji.t.sol` had only an unused `CrvUsdIporStrategy` import (removed) and a misnamed mock
helper; `ProtocolSmokeTests`'s only non-IPOR scenario is already covered by `WbtcPmUsdCrvUsdAave`.

### To revive
If a replacement IPOR Fusion vault (or another ERC4626 yield venue) is wired up, move the relevant
files back, repoint the vault address, and fix the relative imports.

## pmUSD test residue (retired 2026-08-25)

Commit `7141087` retired the five pmUSD vault configurations but deliberately left the pmUSD
Curve pool (`0xEcb0…2c2cb`) wired in as the *fixture* for ~20 audit regression suites, on the
grounds that rewriting them was too invasive. pmUSD is now ~97% of its own pool, so those
fixtures were both misleading (a suite named `ZenjiWbtcLlamaUsdtStakeDao` deploying a pmUSD
strategy) and increasingly flaky. This round finishes the job: every remaining test either
exercises the live crvUSD/USDT fixture or is generic across strategies.

### Moved here
- `test/` — `LargeLiquidityStressTest.fork.t.sol`, `SlippageSocialization.fork.t.sol`. Both
  bind to the *deployed* WBTC/pmUSD vault from `DeploymentV26.md`
  (`0x617A6877…FEB739`), a retired Aave/USDT-debt config that is no longer part of the fleet.
  Neither redeploys, so neither can be repointed — the address is the test.
- `test/base/` — `LlamaSecurityTestMixin.sol` (its only inheritors are the retired
  `Wbtc/WstEthCrvUsdPmUsdLlama` suites; all four of its tests are already provided to the live
  Llama suites by `ZenjiStrategyTestBase`), `AaveBackedStrategyTestBase.sol` (its only
  inheritor is the retired `IporVaultStrategyTestBase`). Moving both also repairs the dangling
  `./base/…` imports in the already-retired suites.

### Deleted outright
- `test/h4verify/H4_VirtualPriceLag.t.sol` — a byte-for-byte duplicate of
  `test/H4_VirtualPriceLag.t.sol` (differing only in import depth and ASCII arrows), running
  the same two tests twice.

### Repointed, not retired (still in `test/`)
- LlamaLend family — `M1_Llama_partial_unwind_health`, `M3_LlamaLoanManager_DEBT_FLASH_LENDER_staleness`,
  `POC_Batch2_HYP02_09_06_11`: `NgCrvUsdLpStakeDaoStrategy` + pmUSD pool →
  `CrvUsdLpStakeDaoStrategy` + USDT/crvUSD, matching `DeployWbtcLlamaUsdtStakeDao.s.sol`.
- USDT-debt family — `AC3_StaleOracle_WithdrawFreeze`, `M6_balanceOf_stale_oracle`,
  `M4_VP_cache_staleness`, `VaultInvariants`, `verification/M02_UsdtVaultOracleFreeze`,
  `verification/M03_WstEthOracleFreeze`: `UsdtNgCrvUsdLpStakeDaoStrategy` + pmUSD pool →
  `UsdtCrvUsdLpStakeDaoStrategy` with both legs on USDT/crvUSD, matching
  `DeployXautAaveUsdtStakeDao.s.sol`. These stay generic vault-mechanics tests (oracle
  staleness, VP-cache lag, invariants) — only the yield leg moved.
- Mock harnesses — `H4_VirtualPriceLag`, `VerifyH7_CrvOracleDoS`,
  `verification/H1_OracleEmergencyAbandonment`: moved off the Ng strategy class (which no live
  vault deploys) onto `UsdtCrvUsdLpStakeDaoStrategy`; their mock pools now expose the legacy
  2-coin `uint256[2]` add-liquidity ABI, and the LP pool's non-crvUSD side is a generic
  counter-asset instead of a mock etched at pmUSD's mainnet address.
- `AaveSecurityTestMixin._arbitrateUsdtPmUsdPool` → `_arbitrateLpPool`, now arbitraging the
  live USDT/crvUSD pool with correct 6/18-decimal normalisation (it previously swapped pmUSD
  into a pool the vault under test held no LP in, making the "realistic lifecycle" arb a no-op).
- `ZenjiForkTestBase._skipIfPmUsdPoolImbalanced` deleted — zero callers.

The NG strategy classes stay in `src/`: `ScrvUsdNgStrategy.fork.t.sol` and
`VerifyH1_EmergencyDoS.t.sol` still exercise them against live non-pmUSD pools.
