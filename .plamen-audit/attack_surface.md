# Attack Surface & Token Flow Matrix — Zenji

## External Dependency Interaction Points

### 1. Aave V3 Pool (`aavePool`)

| Function | Contract | Notes |
|---|---|---|
| `supply(collateral, amount, lm, ref)` | AaveLoanManager.createLoan / addCollateral / borrowMore | Mints aToken to loan manager |
| `borrow(debt, amount, 2, ref, lm)` | AaveLoanManager.createLoan / borrowMore | Increases variableDebtToken |
| `repay(debt, amount, 2, lm)` | AaveLoanManager.repayDebt | Burns variableDebtToken |
| `withdraw(collateral, amount, vault)` | AaveLoanManager.removeCollateral / unwindPosition | Burns aToken, sends collateral |
| `flashLoanSimple(lm, debt, flashAmt, data, ref)` | AaveLoanManager.unwindPosition | Flash-borrow debt for unwind; callback: executeOperation |
| `setUserEMode(category)` | AaveLoanManager constructor | Sets eMode once at construction |

**aToken donation vector**: `aToken.balanceOf(address(loanManager))` is used in `getCurrentLTV()`, `getPositionValues()`, `getNetCollateralValue()`, `loanExists()`. An attacker who donates aTokens directly to the loan manager will inflate the apparent collateral balance, which would lower the reported LTV and could defer rebalance. `[ELEVATE: aToken donation inflates LTV read, could suppress rebalance trigger]`

**Collateral donation vector**: Direct collateral token donation to the vault is benign (inflates `getTotalCollateral()`, benefiting existing depositors).

---

### 2. LlamaLend Controller (`llamaController`)

| Function | Contract | Notes |
|---|---|---|
| `create_loan(collateral, debt, bands)` | LlamaLoanManager.createLoan | LLAMMA creates loan bands |
| `borrow_more(collateral, debt)` | LlamaLoanManager.borrowMore | Add collateral + borrow |
| `repay(debtAmount, i)` | LlamaLoanManager.repayDebt | Repay, get collateral back |
| `withdraw(collateral)` | LlamaLoanManager.removeCollateral | Withdraw excess collateral |
| `health(loanManager, full)` | LlamaLoanManager view | Health from LLAMMA |

**Hardcoded Flash Lender**: `DEBT_FLASH_LENDER = 0x26dE7861...` (crvUSD ERC3156). If deprecated, flash-unwind fails. Recoverable via `emergencySkipStep(1)`.

---

### 3. Chainlink Oracles

| Feed | Used In | Staleness Window |
|---|---|---|
| BTC/USD (8 dec, 1h heartbeat) | AaveLoanManager, CurveThreeCryptoSwapper, UniswapV3TwoHopSwapper | `maxCollateralOracleStaleness` (3600 for BTC/USD) |
| ETH/USD (8 dec, 1h heartbeat) | WstEthOracle, UniswapV3TwoHopSwapper | 7200 (2h) |
| USDT/USD (8 dec, 24h heartbeat) | AaveLoanManager.debtOracle | MAX_DEBT_ORACLE_STALENESS = 90000 (25h) |
| crvUSD/USD (8 dec, 24h heartbeat) | UsdtCrvUsdSwapMixin, BaseCurveStakeDaoStrategy | MAX_USDT_CRVUSD_STALENESS = 90000 |
| stETH/ETH (18 dec, 24h heartbeat) | WstEthOracle | STETH_ETH_MAX_STALENESS = 90000 |
| CRV/USD | BaseCurveStakeDaoStrategy.pendingRewards | MAX_ORACLE_STALENESS = 90000 |

**Oracle DoS (user-requested focus lens)**: `checkOracleFreshness()` is called before every state-changing vault operation. If either the collateral or debt oracle goes stale:
- `deposit`, `mint`, `withdraw`, `redeem`, `rebalance`, `setIdle`, `emergencyStep(1)` all revert.
- Emergency path: `emergencySkipStep` + `emergencyRescue` do NOT call `checkOracleFreshness` directly, so they remain functional. The Aave flash-unwind callback also skips the oracle check.
- `[ELEVATE: oracle DoS — collateral or debt feed goes stale blocks most operations]`

**WstEthOracle composite risk**: The custom oracle chains three prices. If the stETH/ETH feed is stale, the oracle reverts, blocking all wstETH vault operations. The ETH/USD updatedAt is passed through as the composite updatedAt — meaning the consumer's staleness check applies only to ETH/USD freshness, not stETH/ETH freshness (stETH/ETH freshness is validated internally by the oracle). `[ELEVATE: stETH/ETH feed staleness blocks wstETH vault independently of consumer check]`

---

### 4. Curve Pools

| Pool Type | Operations | Side Effects |
|---|---|---|
| TriCrypto (WBTC/USDT) | `exchange` for collateral↔debt | Price impact; oracle-floored min-out |
| TwoCrypto (crvUSD/collateral) | `exchange` for LlamaLend collateral swaps | |
| StableSwap legacy (USDT/crvUSD) | `exchange` entry/exit for USDT strategies | |
| StableSwapNG (pmUSD/crvUSD) | `add_liquidity`, `remove_liquidity_one_coin` | Pool imbalance affects single-sided exit |
| TriCrypto (CRV→crvUSD) | CrvToCrvUsdSwapper `swap` | |

**VP manipulation**: `get_virtual_price()` used in `_lpUnitValue()`. The `cachedVirtualPrice` ratchet (±0.5% / 1 day) limits intra-day manipulation. `[ELEVATE: flash-loan VP manipulation constrained by cache but NOT eliminated for deposits that call _updateCachedUnitValue first]`

**Pool imbalance**: `calc_withdraw_one_coin` can return very low values if the pool is heavily skewed (pmUSD depeg). The `min(VP, calc_withdraw_one_coin)` in `BaseCurveStakeDaoStrategy.balanceOf()` reflects this conservatively. This can depress share prices and trigger rebalance. `[ELEVATE: pool imbalance/depeg → balanceOf drop → rebalance trigger → potential forced unwind at bad price]`

**Single-sided add**: Adding crvUSD to a pool skewed toward crvUSD increases pool imbalance. No protection beyond slippage on the LP receipt.

---

### 5. IPOR PlasmaVault

| Operation | Notes |
|---|---|
| `deposit(crvUSD, receiver)` | UsdtIporStrategy: after USDT→crvUSD swap |
| `redeem(shares, receiver, owner)` | On withdraw/withdrawAll |
| `balanceOf(strategy)` → `convertToAssets()` | Used in `_vaultBalance()` → `balanceOf()` |

**IPOR cooldown**: IPOR PlasmaVault has a short per-address deposit cooldown. Tests must `_refreshOracles()` (warp + re-mock). In mainnet, rapid deposit-then-redeem may revert at the IPOR level. No Zenji-side protection; the vault expects IPOR withdrawals to succeed.

---

### 6. Stake DAO RewardVault / Accountant

| Operation | Notes |
|---|---|
| `deposit(lp, receiver)` | LP staking |
| `redeem(shares, receiver, owner)` | LP unstaking |
| `ACCOUNTANT()` | Returns accountant address for each claim call |
| `accountant.claim(gauges, data, receiver)` | CRV reward claim; wrapped in `try/catch` |
| `accountant.getPendingRewards(vault, user)` | Pending CRV estimate; wrapped in `try/catch` |

**Claim failure**: All Stake DAO calls that can fail are wrapped in `try/catch` — CRV accrues at the strategy address but is not lost.
**Auto-compounding**: CRV→crvUSD swap happens within the same `_compoundRewards()` call that precedes deposits and withdrawals. Failure defers CRV to next cycle.

---

### 7. Mutable Swapper

**Vault-side**: `swapper` reference used in `_swapRemainingDebtToCollateral()` and `emergencyStep/rescue`. Only gov can propose (1-week timelock); guardian can veto.
**LM-side**: Aave and Llama LMs have their own `swapper` reference, updated via `proposeSwapper/executeSwapper` called from the vault. The vault-LM swapper rotation is atomic in `proposeSwapper` (both start the timelock) and in `executeSwapper` (both execute).

**Swapper governance on BaseSwapper**: Swapper has its own `gov` (separate from vault.gov initially). `transferGovFromVault` (callable by registered vault) syncs them. `verifyStrategyOwnership()` covers the strategy side but NOT the swapper gov. `[ELEVATE: swapper.gov desync — if vault.gov rotates, swapper.gov must be synced manually via vault calling transferGovFromVault]`

---

## Token Flow Matrix

| Token | Type | Entry Functions | State Tracking | Accounting Queries Affected | Unsolicited Transfer? | Side-Effect? | Return-Value? |
|---|---|---|---|---|---|---|---|
| collateralAsset (WBTC/cbBTC/wstETH/XAUT) | ERC20 | `deposit`, `mint` | `collateralAsset.balanceOf(vault)`, `aToken.balanceOf(lm)` | `getTotalCollateral`, share pricing | Yes (ignored positively) | None | Returned on `withdraw/redeem` |
| debtAsset (USDT/crvUSD) | ERC20 (USDT non-standard) | Borrowed from Aave/Llama | `variableDebtToken.balanceOf(lm)` | `getNetCollateralValue`, strategy coverage | Yes (minor — counted as idleDebt in getTotalCollateral) | Aave variable rate | Repaid to LM on unwind |
| aToken (aWBTC, acbBTC, etc.) | ERC20 (Aave rebasing) | Auto-minted by Aave on supply | `aToken.balanceOf(lm)` | `loanExists`, `getCurrentLTV`, `getPositionValues` | **YES** — donation inflates apparent collateral | Aave interest accrual | Burned on `aavePool.withdraw` |
| variableDebtToken | ERC20 (Aave debt, non-transferable) | Auto-minted by Aave on borrow | `variableDebtToken.balanceOf(lm)` | LTV calc | No (non-transferable) | Interest accrual increases balance | None |
| IPOR shares (crvUSD → shares) | ERC4626 shares | `yieldVault.deposit` | `yieldVault.balanceOf(strategy)` | `strategy.balanceOf()` → `getTotalCollateral` | No | IPOR auto-compounds | Redeemed on withdraw |
| LP tokens (pmUSD/crvUSD LP) | ERC20 | `lpPool.add_liquidity` | `stakingVault.balanceOf(strategy)` | `strategy.balanceOf()` | No | None | Redeemed on exit |
| Stake DAO vault shares | ERC4626 | `stakingVault.deposit(lp)` | `stakingVault.balanceOf(strategy)` | `strategy.balanceOf()` | No | CRV accrual | Redeemed on unstake |
| CRV | ERC20 | `accountant.claim` | Transient (moves to swapper) | `pendingRewards()` | No | Auto-accumulated by Stake DAO | Converted to crvUSD via swapper |
| crvUSD | ERC20 | Borrowed (Llama) or swapped (USDT strategies) | Via IPOR shares or LP position | `strategy.balanceOf()` | No (protected token in strategies) | Deposited to IPOR or LP | Exits on redeem |

---

## ELEVATE Tags Summary

| Tag | Finding Area |
|---|---|
| `[ELEVATE: aToken donation → inflates LTV collateral read]` | Aave collateral accounting |
| `[ELEVATE: oracle DoS — stale feed blocks most vault operations]` | Oracle resilience |
| `[ELEVATE: stETH/ETH feed staleness blocks wstETH vault independently]` | WstEthOracle |
| `[ELEVATE: flash-loan VP manipulation — cache ratchet mitigates but not at deposit time]` | LP strategy VP cache |
| `[ELEVATE: pool imbalance/depeg → balanceOf drop → forced unwind at bad price]` | LP strategy depeg |
| `[ELEVATE: swapper.gov desync — not auto-synced on vault.gov rotation]` | Swapper governance |
| `[ELEVATE: mutable swapper within timelock can cause slippage loss up to effectiveSlippage]` | Swapper trust |
| `[ELEVATE: strategy.owner != vault.gov if not manually synced post-deploy]` | Strategy governance |
| `[ELEVATE: IPOR cooldown — rapid deposit-redeem can revert at IPOR level]` | IPOR side effect |
| `[ELEVATE: cachedVirtualPrice stale bypass when lastVpUpdate > 1 day → unclamped VP]` | VP cache staleness |
| `[ELEVATE: min(VP, calc_withdraw) balanceOf — calc_withdraw is live (unmanipulated by cache)]` | balanceOf accuracy |
| `[ELEVATE: DEBT_FLASH_LENDER hardcoded — if deprecated, LlamaLend unwind fails]` | LlamaLend flash |
