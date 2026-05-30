# Design Context — Zenji

## Protocol Purpose

Zenji is an ERC4626 conservative collateral yield vault. Users deposit collateral (WBTC, cbBTC, wstETH, XAUT) and receive vault shares. The vault borrows a stablecoin debt asset (USDT or crvUSD) against that collateral via a LoanManager, then deploys the borrowed debt into a YieldStrategy. Yield accrues in the strategy and is passed back to depositors (minus fees). Shares are priced in collateral terms. The core invariant is:

> `totalAssets() == getTotalCollateral()` = collateral held in vault + net collateral value in loan manager (collateral − debt in collateral terms) + strategy balance converted to collateral + idle debt in vault converted to collateral.

---

## Key Invariants

1. **Share pricing is collateral-denominated**: `totalAssets()` returns `getTotalCollateral()`, which aggregates all collateral-equivalent value across vault, loan manager, and strategy.
2. **Strategy balance used only for fee accrual and rebalance caps, not share price directly**: `lastStrategyBalance` is the checkpoint for fee deltas; the full `strategy.balanceOf()` feeds into `getTotalCollateral()` only after subtracting accrued fees.
3. **Virtual share offset (1e4–1e5 by deployment) prevents first-depositor inflation attack**: `VIRTUAL_SHARE_OFFSET()` is added to both numerator and denominator in share math.
4. **LTV is maintained within a 3% deadband around `targetLtv`** (`[targetLtv - 3%, targetLtv + 3%]`). Rebalance adjusts debt to restore target LTV.
5. **Yield strategies are immutable; only the swapper is mutable** (1-week timelock, gov-initiated, guardian veto).
6. **Emergency mode is one-way**: `emergencyMode = true` has no off-chain revert; three sequential steps unwind the position.
7. **LP strategy balanceOf uses `min(VP-based, calc_withdraw_one_coin)`**: conservative single-sided exit price to account for pool imbalance.
8. **cachedVirtualPrice ratchet (±0.5% / day)**: LP unit value is clamped to a moving window to resist intra-day manipulation of the VP.

---

## External Dependencies

| Protocol | Role | Interface |
|---|---|---|
| Aave V3 | Lending/collateral for Aave vaults | Supply, borrow, repay, withdraw, `flashLoanSimple` |
| LlamaLend (LLAMMA controller) | Lending for LlamaLend vaults | Create loan, borrow, repay, withdraw collateral |
| Chainlink | Price feeds (BTC/USD, ETH/USD, USDT/USD, crvUSD/USD, stETH/ETH, CRV/USD) | `latestRoundData()` |
| IPOR PlasmaVault | ERC4626 yield vault for UsdtIporStrategy/CrvUsdIporStrategy | `deposit()`, `redeem()` |
| Curve StableSwap / StableSwapNG / TwoCrypto / TriCrypto | LP deposits, single-sided withdraws, USDT↔crvUSD swaps, collateral↔debt swaps | `add_liquidity`, `remove_liquidity_one_coin`, `exchange`, `get_virtual_price`, `calc_withdraw_one_coin` |
| Stake DAO RewardVault | ERC4626 reward vault wrapping Curve LP; accrues CRV | `deposit`, `redeem`, `ACCOUNTANT()` |
| Stake DAO Accountant | Claims CRV rewards on behalf of the strategy | `claim()`, `getPendingRewards()` |
| crvUSD Flash Lender (LlamaLend) | ERC3156 flash lender for LlamaLend unwind | `flashLoan()` |
| Uniswap V3 | Two-hop swaps (wstETH/cbBTC collateral → WETH → USDT) | `exactInput` |
| CrvToCrvUsdSwapper | CRV → crvUSD via TriCrypto (reward harvesting) | `swap()`, `quote()` |
| WstEthOracle | Custom derived oracle (stEthPerToken × stETH/ETH × ETH/USD) | `latestRoundData()` |

---

## Trust Assumption Table

| # | Actor | Trust Level | Assumption | Source |
|---|---|---|---|---|
| 1 | Gov | FULLY_TRUSTED | Controls infrastructure: swapper timelock, all param changes, all role transfers, rescue recipient. Single EOA or multisig — if compromised, can drain via fee manipulation (timelock-protected) or swapper substitution (1-week delay + guardian veto). | `onlyGov` modifier throughout Zenji.sol |
| 2 | Strategist | SEMI_TRUSTED(day-to-day) | Can call `setIdle` (enters/exits carry trade) and `withdrawFees(recipient)` (pulls accrued fees to any address). Cannot change infrastructure. If compromised, can redirect fees or strand capital in idle mode. | `onlyStrategist` modifier |
| 3 | Guardian | SEMI_TRUSTED(emergency) | Can enter emergency mode (one-way), execute emergency steps, skip steps (timelocked), pause/rescue. Cannot change params or infrastructure. If compromised, can trigger unnecessary liquidation, causing slippage losses to depositors. Gov can veto emergency skip and cancel emergency mode before any step executes. | `onlyGuardian` modifier |
| 4 | Keeper / Rebalance caller | PRECONDITION(permissionless) | Anyone can call `rebalance()`, `accrueYieldFees()`, `harvestYield()`, `updateCachedVirtualPrice()`. Keeper earns bounty from accrued fees on successful rebalance. Cannot steal funds. | No access control |
| 5 | Deployer / Initializer | SEMI_TRUSTED(bootstrap) | Sets initial vault/strategy relationship via `initializeVault()` (callable once by `initializer`). After initialization, `initializer` is cleared. If deployer is different from gov, they can set an incorrect vault pointer before initialization. | `initializer` check in BaseYieldStrategy, AaveLoanManager, LlamaLoanManager |
| 6 | Swapper (mutable) | SEMI_TRUSTED(bounds) | Used for collateral↔debt swaps during unwind. Oracle-based slippage check (`MIN_SWAP_OUT_BPS = 95%`) enforced by AaveLoanManager and Zenji._swapRemainingDebtToCollateral. A malicious swapper can cause up to `effectiveSlippage` loss. Timelock (1 week) + guardian veto limits attack window. | `swapper` references in Zenji.sol, AaveLoanManager |
| 7 | Strategy Owner (BaseYieldStrategy.owner) | SEMI_TRUSTED(strategy admin) | Can call `rescueERC20` (rescue non-protected tokens), `setSlippage`, `transferOwner`. Linked to vault.gov via `transferOwnerFromVault` on role rotation. If desynchronized (strategy.owner ≠ vault.gov), a separate key controls the strategy surface. `verifyStrategyOwnership()` monitors this. | `onlyOwner` modifier in BaseYieldStrategy |
| 8 | Aave V3 Protocol | PRECONDITION(battle-tested) | Trusted to correctly execute supply/borrow/repay/withdraw/flashLoan. Aave liquidation if vault health drops below threshold. |  External protocol |
| 9 | LlamaLend Controller | PRECONDITION(external) | Trusted to correctly manage LLAMMA positions. Hardcoded `DEBT_FLASH_LENDER` at `0x26dE7861...`. | External protocol |
| 10 | Chainlink Oracles | PRECONDITION(validated) | Prices validated: `price > 0`, `answeredInRound >= roundId`, `updatedAt` within staleness window. Two oracle DoS risk: if collateral or debt feed goes stale, most state-changing operations revert. | OracleLib._validatedPrice() |
| 11 | IPOR PlasmaVault | PRECONDITION(external) | Trusted to honor ERC4626 deposit/redeem. Has IPOR-specific cooldown. | External protocol |
| 12 | Curve Pools | PRECONDITION(external) | Trusted for `add_liquidity`, `remove_liquidity_one_coin`, `get_virtual_price`, `calc_withdraw_one_coin`, `exchange`. Pool imbalance (depeg) reflected in `min(VP, calc_withdraw_one_coin)`. | External protocol |
| 13 | Stake DAO Accountant/RewardVault | PRECONDITION(external) | Claim calls wrapped in `try/catch`; failure is silently skipped. CRV stays at swapper if swap fails. | External protocol |
| 14 | CRV Flash Lender (hardcoded) | PRECONDITION(hardcoded) | `DEBT_FLASH_LENDER = 0x26dE7861...` — if deprecated/paused, LlamaLend flash-unwind fails. Recovery: emergencySkipStep(1) or emergencyRescue(2). | LlamaLoanManager constant |
| 15 | Uniswap V3 | PRECONDITION(external) | Used for two-hop swaps (wstETH/cbBTC ↔ USDT). Oracle-based min-out enforced by swappers. | External protocol |
