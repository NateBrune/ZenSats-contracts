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
