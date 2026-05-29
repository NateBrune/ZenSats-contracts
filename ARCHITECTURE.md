# Zenji Architecture

> **Purpose**: Comprehensive codebase reference to avoid re-exploration each session.
> Last updated: 2026-03-04.

## Overview

ERC4626 conservative collateral yield vault. Three-layer architecture:

1. **Vault** (`Zenji.sol`) — ERC4626 entry point, manages deposits/shares/fees
2. **Loan Manager** (immutable) — Borrows debt against deposited collateral
3. **Yield Strategy** (immutable) — Deploys borrowed debt for yield

Flow: User deposits collateral → vault borrows debt via LoanManager → debt deployed to YieldStrategy.

Swapper is the only mutable dependency (1-week timelock via gov).

### Three-Role Governance (V14)
- **Strategist** — day-to-day: `setIdle`, `withdrawFees`
- **Gov** — infrastructure: swapper timelock, `setParam`, `setStrategySlippage`, all `transferRole` calls
- **Guardian** — emergency-only: `enterEmergencyMode`, `emergencyStep`, `emergencySkipStep`, `emergencyRescue`, `rescueAssets`

All three roles are initialized to the deployer. Gov controls all role transfers (2-step accept pattern).

## Directory Layout

```
src/
  Zenji.sol                    Main ERC4626 vault (1059 lines)
  ZenjiViewHelper.sol          External view helper (reduces bytecode)
  VaultTracker.sol             APR/performance tracking (separate contract)
  WstEthOracle.sol             Custom wstETH/USD Chainlink-compatible oracle
  implementations/
    ZenjiWbtc.sol              WBTC vault concrete deployment
    ZenjiCbBtc.sol             cbBTC vault concrete deployment
    ZenjiWstEth.sol            wstETH vault concrete deployment
  lenders/
    AaveLoanManager.sol        Aave V3 loan adapter (flashLoanSimple)
    LlamaLoanManager.sol       LlamaLend loan adapter (ERC3156 flash)
  strategies/
    BaseYieldStrategy.sol      Abstract base (cost basis, reentrancy, pause)
    BaseIporStrategy.sol       IPOR PlasmaVault helpers
    UsdtIporYieldStrategy.sol  USDT→crvUSD→IPOR yield
    IporYieldStrategy.sol      Direct crvUSD→IPOR yield
    BaseCurveRewardVaultStrategy.sol  Abstract base for Curve LP + Stake DAO
    PmUsdCrvUsdStrategy.sol    USDT→crvUSD→pmUSD/crvUSD LP→Stake DAO
    BaseTokemakStrategy.sol    (disabled placeholder)
    TokemakYieldStrategy.sol   (disabled placeholder)
    UsdcTokemakYieldStrategy.sol (disabled placeholder)
  swappers/
    base/                      Debt/collateral ISwapper implementations
      CurveThreeCryptoSwapper.sol   TriCrypto pool (e.g. WBTC↔USDT)
      CurveTwoCryptoSwapper.sol     TwoCrypto pool
      CbBtcWbtcUsdtSwapper.sol      Two-hop: cbBTC↔WBTC→USDT
      UniswapV3TwoHopSwapper.sol    Two-hop: collateral↔WETH↔debt via Uni V3
    reward/
      CrvToCrvUsdSwapper.sol        Harvest reward: CRV→crvUSD via TriCrypto
  libraries/
    SafeTransferLib.sol        USDT-safe transfers (reset-to-zero approve)
    TimelockLib.sol            Timelocked uint256 and address changes
    ZenjiCoreLib.sol           Emergency ops, fee processing, rebalance bounty
    AaveOracleLib.sol          Chainlink oracle validation + price conversions
    LlamaOracleLib.sol         Chainlink oracle for LlamaLend
  interfaces/
    ILoanManager.sol           Loan manager interface
    IYieldStrategy.sol         Yield strategy interface
    ISwapper.sol               Swapper interface (quote + swap both directions)
    IERC20.sol                 Minimal ERC20
    IERC4626.sol               ERC4626 interface
    IAavePool.sol              Aave V3 pool
    IFlashLoanSimpleReceiver.sol  Aave flashloan callback
    ILlamaLendController.sol   LlamaLend controller
    IChainlinkOracle.sol       Chainlink price feed
    ICurveThreeCrypto.sol      Curve TriCrypto pool
    ICurveTwoCrypto.sol        Curve TwoCrypto pool
    ICurveStableSwap.sol       Curve stable swap pool
    ICurveStableSwapNG.sol     Curve NG stable swap
    ICurveTriCrypto.sol        Curve TriCrypto (3-asset)
    ICurveLP.sol               Curve LP token
    ICurveRewardVault.sol      Stake DAO ERC4626 reward vault
    ICurveRegistry.sol         Curve registry
    IPlasmaVault.sol           IPOR PlasmaVault
    ISwapRouter.sol            Uniswap V3 SwapRouter
    IVaultTracker.sol          VaultTracker interface
    ILlamaLoanManager.sol      Extended LlamaLend LM interface
    IYieldVault.sol            Generic ERC4626 vault subset
    IAllocator.sol             IPOR allocator
    IAccountant.sol            Tokemak accountant
    IAutopilotRouter.sol       Tokemak router
    ITokemakAutopool.sol       Tokemak autopool
    IMainRewarder.sol          Tokemak rewarder
    IStakeDaoVault.sol         Stake DAO vault
    IStakeDaoClaimRewards.sol  Stake DAO claim
    IUniswapV2Router.sol       Uniswap V2 router
    IUniswapV2Pair.sol         Uniswap V2 pair
    IStrategy.sol              Generic strategy interface
script/
  DeployWbtc.s.sol             Deploy WBTC/Aave vault stack
  DeployCbBtc.s.sol            Deploy cbBTC/Aave vault stack
  DeployWstEth.s.sol           Deploy wstETH/Aave vault stack
test/
  Zenji.t.sol                  Unit tests (mock-based, 166 tests, no fork)
  AaveLoanManager.t.sol        Aave LM unit tests
  LlamaLoanManager.t.sol       LlamaLend LM unit tests
  UsdtIporAaveStrategy.t.sol   USDT→IPOR strategy unit tests
  IporYieldStrategy.t.sol      Direct IPOR strategy unit tests
  PmUsdCrvUsdStrategy.t.sol    PmUSD/crvUSD strategy unit tests
  TokemakYieldStrategy.t.sol   Tokemak strategy unit tests (disabled)
  WbtcAaveExtensive.fork.t.sol     WBTC/Aave full integration (fork)
  CbBtcAaveExtensive.fork.t.sol    cbBTC/Aave full integration (fork)
  WstEthAaveExtensive.fork.t.sol   wstETH/Aave full integration (fork)
  UsdtIporAaveStrategy.fork.t.sol  USDT/IPOR strategy fork tests
  CbBtcUsdtIporAaveStrategy.fork.t.sol  cbBTC strategy fork tests
  WstEthUsdtIporAave.fork.t.sol    wstETH strategy fork tests
  SwapperUnitTests.fork.t.sol      All swapper implementations (fork)
  ProtocolSmokeTests.fork.t.sol    Smoke tests across protocols (fork)
  APRDiagnostic.fork.t.sol         APR calculation diagnostics (fork)
  APRTracking.fork.t.sol           VaultTracker APR tracking (fork)
  TokemakYieldStrategy.fork.t.sol  Tokemak fork tests (disabled)
  TokemakProbe.t.sol               Tokemak probe (disabled)
  UsdcTokemakSmoke.fork.t.sol      USDC Tokemak smoke (disabled)
```

## Zenji.sol — Main Vault

### Key State
```
collateralAsset   (immutable)  e.g. WBTC, cbBTC, wstETH
debtAsset         (immutable)  always USDT
loanManager       (immutable)  AaveLoanManager or LlamaLoanManager
yieldStrategy     (immutable)  UsdtIporYieldStrategy, PmUsdCrvUsdStrategy, etc.
viewHelper        (immutable)  ZenjiViewHelper
swapper           (mutable)    via 1-week timelock (gov proposes)
targetLtv                      default 65%, range [15%, 65%]
strategist                     day-to-day ops (setIdle, withdrawFees)
gov                            infrastructure (swapper, params, role transfers)
guardian                       emergency ops only
idle                           when true: carry trade unwound, deposits held as collateral
emergencyMode                  one-way latch, no exit
liquidationComplete            set after emergency step 2, enables pro-rata withdrawals
accumulatedFees                in debt-asset terms (accrued on yield profit)
feeRate                        % of yield profit taken as fee (max 20%)
rebalanceBountyRate            % of fees paid to rebalance caller (max 50%)
depositCap                     max total collateral
lastStrategyBalance            fee accrual checkpoint
```

### Constants
```
PRECISION             = 1e18
DEADBAND_SPREAD       = 3e16   (3%)
MIN_TARGET_LTV        = 15e16  (15%)
MAX_TARGET_LTV        = 65e16  (65%)
DEFAULT_LOAN_BANDS    = 4
VIRTUAL_SHARE_OFFSET  = 1e5
TIMELOCK_DELAY        = 1 weeks
MIN_DEPOSIT           = 1e4
MAX_FEE_RATE          = 2e17   (20%)
MAX_REBALANCE_BOUNTY  = 1e18   (100%)
MIN_SWAP_OUT_BPS      = 9500   (95%)
```

### Functions by Access

**Anyone (permissionless):**
- `deposit`, `mint`, `withdraw`, `redeem` — standard ERC4626
- `rebalance()` — adjust LTV if outside deadband, pays bounty
- `accrueYieldFees()` — checkpoint yield profits
- `harvestYield()` — call strategy.harvest() and compound

**Strategist only:**
- `setIdle(bool)` — enter/exit idle mode (unwind/redeploy carry trade)
- `withdrawFees(recipient)` — withdraw accumulated fees

**Gov only:**
- `proposeSwapper(address)` — start 1-week timelock
- `executeSwapper()` — execute after delay, within 7-day window
- `cancelSwapper()` — cancel pending proposal
- `setParam(uint8 p, uint256 v)` — change feeRate, targetLtv, depositCap, bountyRate, maxSlippage
- `setStrategySlippage(uint256)` — forward slippage config to strategy
- `transferRole(uint8, address)` — initiate transfer for any role (0=strategist, 1=gov, 2=guardian)

**Guardian only:**
- `enterEmergencyMode()` — one-way latch
- `emergencyStep(uint8)` — 0=withdrawYield, 1=unwindLoan, 2=completeLiquidation
- `emergencySkipStep(uint8)` — mark step resolved without executing (bricked component)
- `emergencyRescue(uint8)` — 0=transferCollateral, 1=transferDebt, 2=redeemYield
- `rescueAssets(token, recipient)` — rescue non-core stuck tokens

## Loan Managers

### AaveLoanManager.sol
Manages Aave V3 positions. Uses `flashLoanSimple` for unwinding.

**Key constants:** `MIN_HEALTH=1.1e18`, `MAX_ORACLE_STALENESS=3600`, `MAX_DEBT_ORACLE_STALENESS=90000`, `SWAP_AMOUNT_BUFFER=105%`, `DUST_THRESHOLD=1e6`

**Core functions (called by vault):**
- `createLoan(collateral, debt, bands)` — supply + borrow
- `borrowMore(collateral, debt)` — add collateral + borrow more
- `repayDebt(amount)` — repay debt
- `removeCollateral(amount)` — withdraw collateral
- `unwindPosition(collateralNeeded)` — partial/full close via flashloan
- `executeOperation(...)` — flashloan callback

**View:** `getCurrentLTV()`, `getHealth()`, `getPositionValues()`, `getNetCollateralValue()`

### LlamaLoanManager.sol
Manages LlamaLend positions. Uses ERC3156 flashloan for unwinding.

**Key constants:** `LLAMALEND_BANDS=4`, `MIN_HEALTH=1e17`, `DUST_THRESHOLD=1e18`, `DUST_SAFETY_MULTIPLIER=4`, `COLLATERAL_SWAP_SLIPPAGE=5%`

Same interface as Aave variant. Uses `DEBT_FLASH_LENDER=0x26dE7861...` for flash loans.

## Yield Strategies

### BaseYieldStrategy.sol (abstract)
Cost basis tracking, reentrancy guard, pause mechanism. All strategies inherit this.

State: `debtAsset`, `vault`, `_costBasis`, `paused`, `_status` (reentrancy)

### UsdtIporYieldStrategy.sol
USDT → crvUSD (Curve stable swap) → IPOR PlasmaVault.

Uses Chainlink oracles for peg detection. `balanceOf()` = IPOR shares in crvUSD terms → USDT value.

Slippage: default 1%, max 5%, emergency 10%.

### PmUsdCrvUsdStrategy.sol
USDT → crvUSD (Curve) → pmUSD/crvUSD LP (Curve NG) → Stake DAO RewardVault.

Harvests CRV rewards via `CrvToCrvUsdSwapper`, compounds back to LP.

### IporYieldStrategy.sol
Direct crvUSD → IPOR PlasmaVault (no USDT swap needed).

## Swappers (ISwapper interface)

All implement: `quoteCollateralForDebt(debtAmt)`, `swapCollateralForDebt(collAmt)`, `swapDebtForCollateral(debtAmt)`

Each has a timelocked `slippage` parameter (gov can propose changes).

| Swapper | Path | Used By |
|---------|------|---------|
| CurveThreeCryptoSwapper | collateral↔debt via TriCrypto | WBTC vaults |
| CurveTwoCryptoSwapper | collateral↔debt via TwoCrypto | LlamaLend vaults |
| CbBtcWbtcUsdtSwapper | cbBTC↔WBTC (TwoCrypto) + WBTC↔USDT (TriCrypto) | cbBTC vaults |
| UniswapV3TwoHopSwapper | collateral↔WETH↔debt via Uni V3 | wstETH vaults |
| CrvToCrvUsdSwapper | CRV→crvUSD via TriCrypto (reward only) | PmUsdCrvUsdStrategy |

## Key Flows

### Deposit
1. Transfer collateral from user → vault
2. Mint shares: `assets * (supply + VIRTUAL_SHARE_OFFSET) / (collateral + VIRTUAL_SHARE_OFFSET)`
3. If not idle: `_deployCapital()` → transfer collateral to LM → borrow debt → deploy to strategy

### Withdraw
1. Calculate collateral owed: `shares * (collateral + VIRTUAL_SHARE_OFFSET) / (supply + VIRTUAL_SHARE_OFFSET)`
2. Burn shares
3. If insufficient idle collateral: `_unwindPosition()` → withdraw from strategy → repay debt (may flashloan) → recover collateral → swap residual debt→collateral
4. Transfer collateral to user. Reverts with `InsufficientCollateral` if short.

### Rebalance
1. Check LTV outside deadband `[targetLtv - 3%, targetLtv + 3%]`
2. Accrue fees, pay bounty (keeper + owner split)
3. If LTV too low: borrow more → deploy to strategy
4. If LTV too high: withdraw from strategy → repay debt

### Fee Accrual
- Compare current `strategy.balanceOf()` to `lastStrategyBalance`
- If profit: `fees = delta * feeRate / 1e18`, add to `accumulatedFees`
- Fees capped to not exceed strategy balance

### Emergency Mode (3 steps)
1. `emergencyStep(0)` — withdraw all from strategy
2. `emergencyStep(1)` — unwind loan position
3. `emergencyStep(2)` — set `liquidationComplete=true`, enable pro-rata withdrawals

## Deployment Addresses (Mainnet)

### Common
| Contract | Address |
|----------|---------|
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| IPOR PlasmaVault | `0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117` |

### Oracles
| Feed | Address |
|------|---------|
| BTC/USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| USDT/USD | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` |
| crvUSD/USD | `0xEEf0C605546958c1f899b6fB336C20671f9cD49F` |
| stETH/ETH | `0x86392dC19c0b719886221c78AB11eb8Cf5c52812` |

### Curve Pools
| Pool | Address | Indices |
|------|---------|---------|
| TriCrypto (WBTC/USDT) | `0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4` | WBTC=1, USDT=0 |
| USDT-crvUSD | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | USDT=0, crvUSD=1 |

## Design Patterns

1. **Immutable core**: LoanManager and YieldStrategy are immutable. Only swapper is mutable (timelock).
2. **Virtual share offset**: `VIRTUAL_SHARE_OFFSET=1e5` prevents inflation attacks.
3. **Deadband rebalancing**: 3% tolerance reduces rebalance frequency.
4. **Three-role governance**: Strategist (ops) + Gov (infrastructure/params/roles) + Guardian (emergency).
5. **Fee checkpoint model**: Fees only on profit delta since last checkpoint. Changing fee rate never retroactively charges.
6. **Emergency stepwise unwinding**: 3-step process avoids single mega-transaction.
7. **ZenjiCoreLib**: External library for emergency/fee ops to reduce vault bytecode.
8. **SafeTransferLib**: USDT-compatible (resets approval to 0 before setting new value).
9. **Dual flashloan**: Aave `flashLoanSimple` + ERC3156 for LlamaLend.
10. **Lazy strategy binding**: Strategies deployed with `vault=address(0)`, initialized later.

## Errors
```
Unauthorized, ZeroAmount, InsufficientShares, RebalanceNotNeeded,
InvalidAddress, AmountTooSmall, ReentrancyError, InvalidFeeRate,
InvalidTargetLtv, EmergencyModeActive, EmergencyModeNotActive,
InvalidBountyRate, DepositCapExceeded, InvalidStrategy,
LiquidationAlreadyComplete, InsufficientCollateral, InsufficientDeposit,
SwapperUnderperformed(expected, received)
```

## Key Events
```
Deposit, Withdraw, Rebalance, RebalanceBountyPaid, CapitalDeployed,
CapitalUnwound, FeesAccrued, FeesWithdrawn, YieldHarvested,
IdleModeEntered, IdleModeExited, SwapperChangeProposed, SwapperUpdated,
SwapperChangeCancelled, ParamUpdated, OwnerUpdated, GovernanceUpdated,
EmergencyModeEntered, LiquidationComplete, AssetsRescued
```
