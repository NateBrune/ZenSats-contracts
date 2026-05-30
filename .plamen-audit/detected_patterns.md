# Detected Patterns — Zenji

## Flags

### ORACLE
- Chainlink `latestRoundData()` used in OracleLib, WstEthOracle, CurveTwoCryptoSwapper, CurveThreeCryptoSwapper, UniswapV3TwoHopSwapper, CbBtcUniswapV3TwoHopSwapper, BaseCurveStakeDaoStrategy, UsdtCrvUsdSwapMixin
- Staleness validation present on all paths: `price > 0`, `answeredInRound >= roundId`, `block.timestamp - updatedAt <= maxStaleness`
- Custom derived oracle: WstEthOracle chains stEthPerToken × stETH/ETH × ETH/USD
- Two-tier staleness: collateral oracle (1–2h) vs debt oracle (25h)
- Fallback path in `BaseCurveStakeDaoStrategy.pendingRewards`: on stale CRV oracle, falls back to swapper quote

### ERC4626
- Zenji implements IERC4626 directly (not OpenZeppelin's ERC4626)
- Collateral-denominated: `totalAssets() = getTotalCollateral()`, not strategy balance
- Virtual share offset: `VIRTUAL_SHARE_OFFSET()` virtual, per-vault (1e4 to 1e8)
- Non-standard: `withdraw()` is overloaded (with/without minAssetsOut), `redeem()` likewise
- `previewRedeem`/`previewWithdraw` switch to emergency pro-rata mode when `liquidationComplete = true`
- No MEV sandwich protection on exits other than `maxSlippage` cap + user-supplied `minAssetsOut`

### BALANCE_DEPENDENT
- `strategy.balanceOf()` → `getTotalCollateral()` → share price (full chain)
- LP strategy: `_stakedLpBalance()` from `stakingVault.balanceOf(address(this))`
- `aToken.balanceOf(lm)` used for `getCurrentLTV`, `getPositionValues`, `loanExists`
- `variableDebtToken.balanceOf(lm)` used throughout AaveLoanManager
- `cachedVirtualPrice` ratchet around `get_virtual_price()` (±0.5% / 1 day)
- Fee accrual compares `strategy.balanceOf()` vs `lastStrategyBalance`

### FLASH_LOAN
- Aave: `flashLoanSimple` in AaveLoanManager.unwindPosition (LM self-borrows debt to repay position)
- LlamaLend: ERC3156 `flashLoan` in LlamaLoanManager.unwindPosition (via hardcoded crvUSD flash lender)
- Flash callback: `executeOperation` (Aave), `onFlashLoan` (IERC3156FlashBorrower)
- Flashloan amount: `(remainingDebt * 10300) / 10000` — 3% buffer

### FLASH_LOAN_EXTERNAL
- Curve `exchange` calls in all swappers (potential MEV sandwich during unwind)
- Uniswap V3 `exactInput` in UniswapV3TwoHopSwapper / CbBtcUniswapV3TwoHopSwapper
- These are one-sided swaps, not flash loans, but are accessible via public swap functions

### SEMI_TRUSTED_ROLE
- Strategist: `setIdle` (can enter/exit carry trade arbitrarily), `withdrawFees` (to any address)
- Guardian: `enterEmergencyMode`, `emergencyStep`, `emergencySkipStep` (timelocked), `emergencyRescue`, `rescueAssets`, `pauseDeposits`
- Strategy.owner: `rescueERC20`, `setSlippage`, `transferOwner`; may differ from vault.gov
- CrvToCrvUsdSwapper.gov: `setAuthorizedCaller`, `rescueToken`; may differ from vault.gov post-deploy
- BaseSwapper.gov: `setSlippage`, `setVault`, `transferGovernance`; initially separate from vault.gov
- ZenjiRebalanceKeeper.owner: `transferOwnership`, `rescueERC20(token, to, amount)` — **no token guard**

### TEMPORAL
- Swapper timelock: 1 week (`TIMELOCK_DELAY`)
- Role transfer delays: 1 week (strategist), 4 weeks (gov/guardian), guardian veto during window
- Param timelocks (adverse): `PARAM_TIMELOCK_DELAY = 1 week` for feeRate/targetLtv/bountyRate/maxSlippage increases
- depositCap decrease: timelocked (1 week); increase: immediate
- Emergency skip: `EMERGENCY_SKIP_DELAY = 3 days` + gov veto via `cancelEmergencySkip`
- VP cache age: `MAX_VP_STALENESS = 1 day` — clamp bypassed if cache > 1 day old
- Oracle staleness: per-feed (1h to 25h)

### MONETARY_PARAMETER
- `feeRate` (max 20%) — increase timelocked
- `targetLtv` (15%–65% or per-vault ceiling) — increase timelocked
- `rebalanceBountyRate` (max 50%) — increase timelocked
- `depositCap` — decrease timelocked
- `maxSlippage` (max 5%) — increase timelocked; propagated to strategy and swapper on execute
- `setSlippage` on strategy owner — immediate, no timelock at strategy level
- `setSlippage` on swapper gov/vault — immediate (via vault.setParam(4))

### SHARE_ALLOCATION
- Virtual share offset (`VIRTUAL_SHARE_OFFSET()`) mitigates first-depositor inflation attack
- Shares minted: `assets * (supply + offset) / (totalCollateral + offset)`
- `isFinalWithdraw` path burns all remaining shares to avoid stranded value on last exit
- `_cooling()`: 1-block cooldown after share receipt (update or mint) to block same-block flash-loan sandwich

### MIGRATION
- No explicit migration path in scope; `initializeVault()` is one-time bootstrap
- `verifyStrategyOwnership()` view for monitoring ownership sync

### HAS_SIGNATURES
- None detected: No `ecrecover`, `ECDSA.recover`, `permit`, EIP-712, `domainSeparator`, `nonces`, or `isValidSignature` in src/

### STORAGE_LAYOUT
- No `assembly`, `delegatecall`, `sstore`/`sload` in Zenji or strategies
- `ZenjiCoreLib` is called via `library` pattern (not `delegatecall`); it's a Solidity library so it runs in the vault's context but does not use explicit `delegatecall`
- No proxy/upgradeable/diamond patterns

### MISSING_EVENT
Checking setter functions for missing events:

| Setter | Contract | Emits? |
|---|---|---|
| `initializeVault` | BaseYieldStrategy | YES (`VaultInitialized`) |
| `initializeVault` | AaveLoanManager | YES (`VaultInitialized`) |
| `initializeVault` | LlamaLoanManager | YES (`VaultInitialized`) |
| `transferOwner` | BaseYieldStrategy | YES (`OwnerTransferred`) |
| `transferOwnerFromVault` | BaseYieldStrategy | YES (`OwnerTransferred`) |
| `setSlippage` | BaseYieldStrategy | YES (`SlippageUpdated`) |
| `rescueERC20` | BaseYieldStrategy | YES (`TokenRescued`) |
| `setVault` | BaseSwapper | YES (`VaultSet`) |
| `setSlippage` | BaseSwapper | YES (`SlippageUpdated`) |
| `transferGovernance` | BaseSwapper | YES (`GovernanceTransferStarted`) |
| `acceptGovernance` | BaseSwapper | YES (`GovernanceUpdated`) |
| `transferGovFromVault` | BaseSwapper | YES (`GovTransferredFromVault`) |
| `setAuthorizedCaller` | CrvToCrvUsdSwapper | YES (`AuthorizedCallerUpdated`) |
| `setSlippage` | CrvToCrvUsdSwapper | YES (`SlippageUpdated`) |
| `rescueToken` | CrvToCrvUsdSwapper | YES (`TokenRescued`) |
| `pauseDeposits` | Zenji | YES (`DepositsPaused`) |
| `resumeDeposits` | Zenji | YES (`DepositsResumed`) |
| `transferOwnership` | ZenjiRebalanceKeeper | YES (`OwnershipTransferred`) |

**Potential MISSING_EVENT**: `ZenjiRebalanceKeeper.drainERC20` — needs review. `BaseLPStrategy._compoundRewards` only emits if `lpAssetCompounded > 0` — silent when 0. `accrueYieldFees()` has `FeesAccrued` event but is called internally; callers (deposit, withdraw) emit their own events without re-emitting fee accrual. **FLAG: `HAS_MULTI_CONTRACT` flag applies (2+ in-scope contracts sharing parameters or formulas).**

### HAS_MULTI_CONTRACT
- Multiple vault implementations share `targetLtv`, `feeRate`, `maxSlippage` through Zenji.sol parameters
- Formula drift risk: `getTotalCollateralValue` in ZenjiViewHelper.sol mirrors fee calculation from Zenji.sol (both compute `(strategyBalance - lastBalance) * feeRate / PRECISION`)

### LENDING_PROTOCOL_SECURITY (injectable candidate)
- AaveLoanManager and LlamaLoanManager both qualify
- Health check (`MIN_HEALTH = 1.1e18` Aave, `MIN_HEALTH = 1e17` Llama) enforced post-borrow
- Liquidation threshold used in health calculation

### VAULT_ACCOUNTING (injectable candidate)
- ERC4626 with collateral-denominated shares
- Virtual share offset
- Fee checkpoint model

### DEX_INTEGRATION_SECURITY (injectable candidate)
- All swappers integrate Curve pools and Uniswap V3
- Oracle-based min-out floors on all swaps

## Not Detected
- No CROSS_CHAIN
- No MIGRATION flags
- No HAS_SIGNATURES
- No STORAGE_LAYOUT (no assembly/delegatecall)
- No EVENT_COMPLETENESS issues beyond minor `_compoundRewards` silent path
