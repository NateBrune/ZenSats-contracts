# Constraint Variables — Zenji

## Vault (Zenji.sol)

| Variable | Current / Default | Min | Max | Setter | Enforcement | Notes |
|---|---|---|---|---|---|---|
| `feeRate` | 0 (default) | 0 | MAX_FEE_RATE = 2e17 (20%) | `setParam(0)` | Validated at propose and execute | Increase timelocked 1w |
| `targetLtv` | MAX_TARGET_LTV() (65% or per-vault) | MIN_TARGET_LTV = 15e16 | per-vault MAX_TARGET_LTV | `setParam(1)` | Validated + cross-checked vs loanManager.maxLtvBps | Increase timelocked 1w |
| `rebalanceBountyRate` | 2e17 (20%) | 0 | MAX_REBALANCE_BOUNTY = 5e17 (50%) | `setParam(3)` | Validated at propose and execute | Increase timelocked 1w |
| `depositCap` | 0 (unlimited) | 0 | none | `setParam(2)` | Revert `DepositCapExceeded` on deposit | Decrease timelocked 1w; 0 = unlimited |
| `maxSlippage` | 1e16 (1%) | must be > 0 | MAX_VAULT_SLIPPAGE = 5e16 (5%) | `setParam(4)` | Revert `InvalidSlippage` | Increase timelocked 1w; propagates to strategy + swapper |
| `DEADBAND_SPREAD` | 3e16 (3%) | — | — | Constant | Used in rebalance band | Immutable |
| `COOLDOWN_BLOCKS` | 1 | — | — | Constant | Share transfer/mint cooldown | Immutable |
| `TIMELOCK_DELAY` | 1 week | — | — | Constant | Swapper proposal | Immutable |
| `PARAM_TIMELOCK_DELAY` | 1 week | — | — | Constant | Adverse param changes | Immutable |
| `ROLE_TRANSFER_DELAY` | 1 week | — | — | Constant | Strategist transfer | Immutable |
| `GOV_GUARDIAN_TRANSFER_DELAY` | 4 weeks | — | — | Constant | Gov/guardian transfer | Immutable |
| `EMERGENCY_SKIP_DELAY` | 3 days | — | — | Constant | emergencySkipStep delay | Immutable |
| `MAX_USER_SLIPPAGE` | 2e17 (20%) | — | — | Constant | Cap on user-supplied minAssetsOut tolerance | Immutable |
| `MAX_VAULT_SLIPPAGE` | 5e16 (5%) | — | — | Constant | Cap on maxSlippage | Immutable |
| `VIRTUAL_SHARE_OFFSET()` | 1e5 base (virtual) | — | — | Virtual constant per impl | Inflation attack mitigation | Override per deployment |
| `MIN_DEPOSIT()` | 1e4 base (virtual) | — | — | Virtual constant per impl | Minimum deposit | Override per deployment |
| `MAX_TARGET_LTV()` | 65e16 base (virtual) | — | — | Virtual constant per impl | Per-vault LTV ceiling | ZenjiXautAaveStakeDao = 55% |

---

## AaveLoanManager

| Variable | Value | Notes |
|---|---|---|
| `maxCollateralOracleStaleness` | Immutable (set at construction) | Per-deployment; BTC/USD = 3600, XAU/USD = 90000 |
| `MAX_DEBT_ORACLE_STALENESS` | 90000 (25h) | USDT/USD heartbeat is 24h |
| `MIN_HEALTH` | 1.1e18 | Health factor threshold post-borrow/removeCollateral |
| `maxLtvBps` | Immutable | Aave's maxLtvBps for the collateral |
| `liquidationThresholdBps` | Immutable | Used in health factor calculation |
| `SWAP_AMOUNT_BUFFER` | 105 (5%) | Over-amount for flashloan swap coverage |
| `DUST_THRESHOLD` | 10**debtDecimals (1 USD) | Skip slippage below this |
| `MIN_ROUTABLE_DEBT` | 10**debtDecimals (1 USD) | Minimum swap size |
| `DUST_SWAP_THRESHOLD` | 1000 | Minimum collateral sat for slippage check |
| `MIN_SWAP_OUT_BPS` | 9500 (95%) | Minimum out vs oracle quote |

---

## LlamaLoanManager

| Variable | Value | Notes |
|---|---|---|
| `MAX_ORACLE_STALENESS` | 3600 (1h) | Collateral staleness |
| `MAX_DEBT_ORACLE_STALENESS` | 25200 (7h) | Debt staleness (crvUSD/USD heartbeat 6h) |
| `MIN_HEALTH` | 1e17 (0.1) | LLAMMA health threshold |
| `LLAMALEND_BANDS` | 4 | Number of bands for loan |
| `DUST_THRESHOLD` | 1e18 (1 crvUSD) | Minimum debt for clean close |
| `DUST_SAFETY_MULTIPLIER` | 4 | 4× safety on dust collateral (25% LTV) |
| `COLLATERAL_SWAP_SLIPPAGE` | 5e16 (5%) | Fixed collateral swap slippage |
| `SWAP_AMOUNT_BUFFER` | 105 (5%) | Swap amount buffer |
| `MIN_SWAP_OUT_BPS` | 9500 (95%) | Minimum swap out |
| `WITHDRAW_COLLATERAL_BUFFER` | 115 (15% extra) | Buffer on collateral withdrawal calc |

---

## BaseYieldStrategy (Strategies)

| Variable | Default | Min | Max | Setter | Notes |
|---|---|---|---|---|---|
| `slippageTolerance` | DEFAULT_SLIPPAGE = 1e16 (1%) | MIN_SLIPPAGE = 1e15 (0.1%) | MAX_SLIPPAGE = 5e16 (5%) | `setSlippage` | Enforced at set time |
| `EMERGENCY_SLIPPAGE` | 1e17 (10%) | — | — | Constant | Used only in emergency exits |

---

## BaseLPStrategy (VP Cache)

| Variable | Value | Notes |
|---|---|---|
| `LP_SLIPPAGE` | 5e15 (0.5%) | Applied to LP add operations |
| `MAX_VP_DEVIATION` | 5e15 (0.5%) | Maximum deviation per cache update |
| `MAX_VP_STALENESS` | 1 day | Age beyond which clamp is bypassed |
| `cachedVirtualPrice` | Updated on deposit/withdraw/harvest | Ratcheted ±0.5% per update |

---

## BaseSwapper

| Variable | Default | Setter | Notes |
|---|---|---|---|
| `slippage` | 1e16 (1%) | `setSlippage` (gov or vault) | No timelock; no min/max enforced beyond `> 0 && < 1e18` |

> ⚠️ **UNENFORCED**: Swapper `slippage` has no upper bound meaningful to safety (only `< 1e18`). The vault caps `maxSlippage` at 5%, but the swapper itself can be set to 99.9% by gov directly — bypassing the vault cap. Vault only propagates to the swapper via `setParam(4)` (which is capped at 5%), but gov can call `BaseSwapper.setSlippage()` directly without that cap. Flag: **SWAPPER_SLIPPAGE_UNCAPPED_BY_GOV**.

---

## ZenjiRebalanceKeeper

| Variable | Notes |
|---|---|
| `owner` | EOA; no multisig enforcement. `drainERC20` is unrestricted by token type. |
