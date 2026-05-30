# Contract Inventory — Zenji

## Line Count Summary (src/ only)

Total: 9,759 lines across ~70 .sol files in scope.

---

## Zenji Core

| Contract | Path | Lines | Notes |
|---|---|---|---|
| Zenji | src/Zenji.sol | 1699 | Main ERC4626 vault. ERC20 + IERC4626. |
| ZenjiViewHelper | src/ZenjiViewHelper.sol | 220 | External view helper (getTotalCollateralValue, etc.). Immutable. |
| WstEthOracle | src/WstEthOracle.sol | 117 | Chainlink-compatible derived oracle: stEthPerToken × stETH/ETH × ETH/USD. 8 decimals output. |

---

## Implementations

| Contract | Path | Lines | Notes |
|---|---|---|---|
| ZenjiWbtcAaveIpor | src/implementations/ipor/ZenjiWbtcAaveIpor.sol | 33 | WBTC vault, IPOR strategy. Overrides name/symbol/VIRTUAL_SHARE_OFFSET/MIN_DEPOSIT. |
| ZenjiCbBtcAaveIpor | src/implementations/ipor/ZenjiCbBtcAaveIpor.sol | 33 | cbBTC vault, IPOR strategy. |
| ZenjiWstEthAaveIpor | src/implementations/ipor/ZenjiWstEthAaveIpor.sol | 34 | wstETH vault, IPOR strategy. |
| ZenjiWbtcAaveStakeDao | src/implementations/stakedao/ZenjiWbtcAaveStakeDao.sol | 40 | WBTC vault, pmUSD/crvUSD StakeDao strategy (Aave). |
| ZenjiWbtcLlamaStakeDao | src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol | 40 | WBTC vault, StakeDao strategy (LlamaLend). |
| ZenjiWstEthAaveStakeDao | src/implementations/stakedao/ZenjiWstEthAaveStakeDao.sol | 41 | wstETH vault, StakeDao strategy. |
| ZenjiWstEthLlamaStakeDao | src/implementations/stakedao/ZenjiWstEthLlamaStakeDao.sol | 41 | wstETH vault, StakeDao strategy (LlamaLend). |
| ZenjiXautAaveStakeDao | src/implementations/stakedao/ZenjiXautAaveStakeDao.sol | 47 | XAUT vault, StakeDao strategy. Overrides MAX_TARGET_LTV (55%). |

---

## Loan Managers

| Contract | Path | Lines | Notes |
|---|---|---|---|
| AaveLoanManager | src/lenders/AaveLoanManager.sol | 708 | Aave V3 loan adapter. Implements ILoanManager + IFlashLoanSimpleReceiver. Has mutable swapper (vault-timelocked). |
| LlamaLoanManager | src/lenders/LlamaLoanManager.sol | 761 | LlamaLend loan adapter. Implements ILoanManager + IERC3156FlashBorrower. Hardcoded DEBT_FLASH_LENDER. Has mutable swapper (vault-timelocked). |

---

## Strategies

### Abstract Bases (inheritance chain)

```
BaseYieldStrategy (BaseYieldStrategy.sol, 290)
├── BaseVaultStrategy (vault/BaseVaultStrategy.sol, 175) — single-asset vault family
│   ├── UsdtIporStrategy (vault/UsdtIporStrategy.sol, 66) + UsdtCrvUsdSwapMixin
│   └── CrvUsdIporStrategy (vault/CrvUsdIporStrategy.sol, 20)
└── BaseLPStrategy (lp/BaseLPStrategy.sol, 315) — LP + staking family
    └── BaseCurveStakeDaoStrategy (lp/BaseCurveStakeDaoStrategy.sol, 227) — Curve+StakeDAO
        ├── CrvUsdLpStakeDaoStrategy (lp/CrvUsdLpStakeDaoStrategy.sol, 84) — legacy 2-coin add
        │   └── NgCrvUsdLpStakeDaoStrategy inherits from BaseNgCrvUsdLpStakeDaoStrategy
        └── BaseNgCrvUsdLpStakeDaoStrategy (lp/BaseNgCrvUsdLpStakeDaoStrategy.sol, 119) — NG pool
            ├── NgCrvUsdLpStakeDaoStrategy (lp/NgCrvUsdLpStakeDaoStrategy.sol, 43)
            └── UsdtNgCrvUsdLpStakeDaoStrategy (lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol, 109) + UsdtCrvUsdSwapMixin
```

### Mixins

| Contract | Path | Lines | Notes |
|---|---|---|---|
| UsdtCrvUsdSwapMixin | src/strategies/UsdtCrvUsdSwapMixin.sol | 108 | USDT↔crvUSD swap layer via Curve stable swap. Oracle-floored slippage. Shared by UsdtIporStrategy and UsdtNgCrvUsdLpStakeDaoStrategy. |

### Concrete Strategy Contracts

| Contract | Path | Lines | Notes |
|---|---|---|---|
| UsdtIporStrategy | src/strategies/vault/UsdtIporStrategy.sol | 66 | USDT→crvUSD→IPOR PlasmaVault. Paired with Aave vaults. |
| CrvUsdIporStrategy | src/strategies/vault/CrvUsdIporStrategy.sol | 20 | Direct crvUSD→IPOR. Paired with LlamaLend vaults. |
| CrvUsdLpStakeDaoStrategy | src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol | 84 | crvUSD→legacy Curve 2-coin LP→StakeDAO. |
| NgCrvUsdLpStakeDaoStrategy | src/strategies/lp/NgCrvUsdLpStakeDaoStrategy.sol | 43 | crvUSD→NG StableSwap LP→StakeDAO. Paired with LlamaLend. |
| UsdtNgCrvUsdLpStakeDaoStrategy | src/strategies/lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol | 109 | USDT→crvUSD→NG LP→StakeDAO. Paired with Aave. |

---

## Swappers

### Base

| Contract | Path | Lines | Notes |
|---|---|---|---|
| BaseSwapper | src/swappers/base/BaseSwapper.sol | 81 | Shared governance + slippage. gov and vault can set slippage. Two-step gov transfer. |
| CurveThreeCryptoSwapper | src/swappers/base/CurveThreeCryptoSwapper.sol | 162 | TriCrypto pool. collateral↔USDT. BTC/USD + USDT/USD oracles. |
| CurveTwoCryptoSwapper | src/swappers/base/CurveTwoCryptoSwapper.sol | 126 | TwoCrypto pool. collateral↔debt. |
| CbBtcUniswapV3TwoHopSwapper | src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol | 153 | cbBTC→WBTC→USDT two-hop. |
| UniswapV3TwoHopSwapper | src/swappers/base/UniswapV3TwoHopSwapper.sol | 168 | collateral→WETH→USDT via Uni V3. Immutable `maxCollateralOracleStaleness`. |
| UniswapMixedCurveSwapper | src/swappers/base/UniswapMixedCurveSwapper.sol | 223 | Hybrid Uni V3 + Curve path. |
| UniswapMixedTwoHopSwapper | src/swappers/base/UniswapMixedTwoHopSwapper.sol | 425 | Full two-hop with Uniswap Universal Router + optional Curve step. |
| UniversalRouterV3SingleHopSwapper | src/swappers/base/UniversalRouterV3SingleHopSwapper.sol | 147 | Single-hop via Uniswap Universal Router. |

### Reward Swapper

| Contract | Path | Lines | Notes |
|---|---|---|---|
| CrvToCrvUsdSwapper | src/swappers/reward/CrvToCrvUsdSwapper.sol | 135 | CRV→crvUSD via TriCrypto. Has `authorizedCaller` (strategy) and `gov`. setAuthorizedCaller is gov-only; setSlippage is gov or authorizedCaller. |

---

## Libraries

| Contract | Path | Lines | Notes |
|---|---|---|---|
| SafeTransferLib | src/libraries/SafeTransferLib.sol | 56 | USDT-safe: resets approval to 0 before setting. Also has `ensureApproval`. |
| TimelockLib | src/libraries/TimelockLib.sol | 94 | propose/execute/cancel for uint256 and address. 1-week default. |
| ZenjiCoreLib | src/libraries/ZenjiCoreLib.sol | 428 | External library (delegatecall from vault). Emergency steps, rescue, fee withdrawal, rebalance logic. |
| AaveOracleLib (now OracleLib) | src/libraries/OracleLib.sol | 175 | Chainlink oracle validation + price conversions (both Aave 6-dec and Llama 18-dec variants). |
| CurveUsdtSwapLib | src/libraries/CurveUsdtSwapLib.sol | 194 | USDT↔crvUSD swap math for the mixin (oracle-floored). |

---

## Keepers

| Contract | Path | Lines | Notes |
|---|---|---|---|
| ZenjiRebalanceKeeper | src/keepers/ZenjiRebalanceKeeper.sol | 112 | Chainlink Automation upkeep. Checks LTV bands, calls `rebalance()`. Has `rescueERC20` (owner-only). |

---

## Interfaces

26 interface files (not in scope for vulnerability analysis).

---

## Inheritance Summary

| Family | Chain |
|---|---|
| Vault implementations | `Zenji(ERC20, IERC4626)` ← all impl contracts |
| Vault strategy | `BaseYieldStrategy(IYieldStrategy, ReentrancyGuard)` ← `BaseVaultStrategy` ← `UsdtIporStrategy` / `CrvUsdIporStrategy` |
| LP strategy | `BaseYieldStrategy` ← `BaseLPStrategy` ← `BaseCurveStakeDaoStrategy` ← `CrvUsdLpStakeDaoStrategy` / `BaseNgCrvUsdLpStakeDaoStrategy` ← leaf |
| USDT mixin | `UsdtCrvUsdSwapMixin` mixed into `UsdtIporStrategy` and `UsdtNgCrvUsdLpStakeDaoStrategy` |

---

## PARENT_CONDITIONAL_OVERRIDE Flags

| Parent | Child | Override |
|---|---|---|
| Zenji.MAX_TARGET_LTV() | ZenjiXautAaveStakeDao | Returns 55% (vs 65% base) |
| Zenji.VIRTUAL_SHARE_OFFSET() | All impl contracts | Per-collateral values (1e4 for BTC, 1e8 for wstETH etc.) |
| Zenji.MIN_DEPOSIT() | All impl contracts | Per-collateral values |
| BaseCurveStakeDaoStrategy._crvToPendingRewards() | UsdtNgCrvUsdLpStakeDaoStrategy | Scales by 1/1e12 for 6-dec USDT |
| BaseCurveStakeDaoStrategy._pendingRewardsFallback() | UsdtNgCrvUsdLpStakeDaoStrategy | Same scaling |
