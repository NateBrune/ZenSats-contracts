# Deploy: XAUT + USDT + crvUSD/USDT Stake DAO (Aave)

Runbook for deploying the XAUT-collateral Zenji vault that borrows USDT on Aave V3 (eMode 43 — "XAUt USDC USDT GHO") and farms yield via the crvUSD/USDT Stake DAO gauge. Uses a Uniswap V3 single-hop swapper (XAUT→USDT, 0.05% fee) and a CRV reward compounder.

Deploy script: `script/DeployXautAaveUsdtStakeDao.s.sol`
Vault contract: `src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol`
Strategy contract: `src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol`

> **Important — Oracle staleness**: XAU/USD Chainlink heartbeat is **24 hours** (vs 1h for BTC/ETH). The `AaveLoanManager` uses `maxCollateralOracleStaleness = 90000` (25h) to accommodate this. Keepers and monitoring must tolerate up to 24h between oracle updates without triggering unnecessary alerts — do not alert on stale oracle after 1h for this vault.

> **Important — eMode**: This vault uses Aave eMode category **43** (XAUt USDC USDT GHO). At eMode LTV = 70%, the vault's `MAX_TARGET_LTV()` is capped to **60%** by `ZenjiXautAaveUsdtStakeDao.MAX_TARGET_LTV()`, giving a health factor margin of `0.75 / 0.60 = 1.25` at target — well above `MIN_HEALTH = 1.1`.


## Advised Deposit Cap

**95 XAUT** (`setParam(2, 95000000)`) — binding constraint: collateral leg — XAUT/USDT Uniswap V3 0.05% depth (~$1.03M).

Derived from live exit liquidity; see **[DEPOSIT_CAPS.md](DEPOSIT_CAPS.md)** for the
methodology, the full fleet table, and the re-measurement procedure. The cap is a
point-in-time measurement of mainnet pool depth — re-check it at least monthly.

## Why crvUSD/USDT (not pmUSD/crvUSD)

The original XAUT vault (`ZenjiXautAaveStakeDao`) farms the pmUSD/crvUSD Stake DAO pool. That pool has gone thin: per `script/StrategyLiquidityReport.s.sol`, the minority (crvUSD) side is only **~2.84%** of the pool, so a single-sided crvUSD exit slips badly beyond small sizes.

This vault instead farms the **crvUSD/USDT** Curve pool (`0x390f3595bCa2Df7d23783dFd126427CCeb997BF4`), which is deep: **~31.4M USDT / ~16.1M crvUSD**, minority share ~33.9%. This is the same pool used by `ZenjiWbtcLlamaUsdtStakeDao` and `ZenjiWstEthLlamaUsdtStakeDao`.

**Same-pool swap + LP note**: because `UsdtCrvUsdLpStakeDaoStrategy` here is deployed with the *same* pool address for both `_usdtCrvUsdPool` (entry/exit USDT↔crvUSD swap leg) and `_lpPool` (single-sided crvUSD deposit), a deposit pays the pool's exchange fee (USDT→crvUSD) *plus* the implicit single-sided add-liquidity fee on that same pool — and the reverse (implicit remove-liquidity fee + crvUSD→USDT exchange fee) on exit. This is a few extra bps each way versus a strategy that swaps in one pool and LPs in a different one, and is accepted as the cost of using the deepest available crvUSD-anchored pool. See the contract-level comment in `UsdtCrvUsdLpStakeDaoStrategy.sol` for the base-math rationale (lpAsset stays crvUSD, 18-decimal virtual-price accounting).

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Optionally: `OWNER` and `GOV` (default to deployer address)
- Foundry installed and up to date

## Quick Deploy (script)
```bash
forge script script/DeployXautAaveUsdtStakeDao.s.sol --tc DeployXautAaveUsdtStakeDao \
  --rpc-url $MAINNET_RPC_URL --broadcast --verify -vv
```

The script deploys and wires everything in one transaction batch: `ZenjiViewHelper`, `CrvToCrvUsdSwapper`, `UniversalRouterV3SingleHopSwapper`, `UsdtCrvUsdLpStakeDaoStrategy`, `AaveLoanManager`, and `ZenjiXautAaveUsdtStakeDao`, then calls `initializeVault`/`setVault` on each dependent contract. The strategy is bound to the vault in the vault's constructor — there is no separate strategy-setting step.

## Mainnet Addresses
```solidity
// Assets
address constant XAUT   = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CRV    = 0xD533a949740bb3306d119CC777fa900bA034cd52;

// Chainlink — NOTE: XAU/USD heartbeat is 24h (not 1h like BTC/ETH)
address constant XAU_USD_ORACLE    = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
address constant USDT_USD_ORACLE   = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
address constant CRV_USD_ORACLE    = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

// Aave V3 — eMode 43 ("XAUt USDC USDT GHO")
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_XAUT        = 0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2; // aEthXAUt
address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
uint8   constant AAVE_EMODE_XAUT    = 43;

// Uniswap V3 (XAUT→USDT single-hop, 0.05% fee tier)
address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
uint24  constant XAUT_USDT_V3_FEE = 500;

// Curve / Stake DAO — crvUSD/USDT pool used for BOTH the swap leg and the LP leg
address constant USDT_CRVUSD_POOL       = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
address constant STAKE_DAO_REWARD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
address constant USDT_CRVUSD_GAUGE      = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
address constant CRV_CRVUSD_TRICRYPTO   = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
int128  constant USDT_INDEX   = 0; // coins(0) = USDT
int128  constant CRVUSD_INDEX = 1; // coins(1) = crvUSD

// Aave LTV bounds (bps)
uint256 constant TARGET_LTV_BPS     = 6000;  // 60% — vault MAX_TARGET_LTV, conservative relative to eMode 70%
uint256 constant MAX_LTV_BPS        = 6000;  // AaveLoanManager maxLtvBps (eMode effective LTV bps)
uint256 constant LIQN_THRESHOLD_BPS = 7500;  // Aave eMode liquidation threshold
```

## Deployment Steps (manual `forge create`, if not using the script)

### 1) Deploy ZenjiViewHelper
```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --verify
```
Save as `VIEW_HELPER`.

---

### 2) Deploy CrvToCrvUsdSwapper (CRV reward compounder)
Swaps harvested CRV rewards into crvUSD for compounding back into the strategy.
```bash
forge create src/swappers/reward/CrvToCrvUsdSwapper.sol:CrvToCrvUsdSwapper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOV_ADDRESS> \
    0xD533a949740bb3306d119CC777fa900bA034cd52 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14 \
    0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f \
    0xEEf0C605546958c1f899b6fB336C20671f9cD49F \
  --verify
```
Save as `CRV_SWAPPER`.

---

### 3) Deploy UniversalRouterV3SingleHopSwapper (XAUT→USDT)
Used to swap collateral proceeds to USDT for debt repayment during unwinds. XAUT/USDT uses the 0.05% fee tier.
```bash
forge create src/swappers/base/UniversalRouterV3SingleHopSwapper.sol:UniversalRouterV3SingleHopSwapper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOV_ADDRESS> \
    0x68749665FF8D2d112Fa859AA293F07A622782F38 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af \
    500 \
    0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6 \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    90000 \
  --verify
```

Constructor args:
1. `<GOV_ADDRESS>` — governance address for slippage control
2. XAUT — collateral token
3. USDT — debt token
4. UNIVERSAL_ROUTER — Uniswap Universal Router
5. `500` — 0.05% fee tier (XAUT/USDT pool)
6. XAU/USD oracle
7. USDT/USD oracle
8. `90000` — max collateral oracle staleness (XAU/USD heartbeat is 24h)

Save as `SWAPPER`.

---

### 4) Deploy UsdtCrvUsdLpStakeDaoStrategy
`lpCrvUsdIndex` is 0 if crvUSD is `coins(0)` in the crvUSD/USDT pool, else 1. **Confirm on-chain before deploying** (this pool is verified `coins(0)=USDT, coins(1)=crvUSD`, i.e. index 1):
```bash
cast call 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 "coins(uint256)(address)" 1 --rpc-url $MAINNET_RPC_URL
# expect 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E (crvUSD) -> LP_CRVUSD_INDEX=1
```

```bash
forge create src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol:UsdtCrvUsdLpStakeDaoStrategy \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x0000000000000000000000000000000000000000 \
    <GOV_ADDRESS> \
    0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 \
    0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 \
    0xF980f195A93577DcCe48e91e98124D3B71C4a066 \
    <CRV_SWAPPER> \
    0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939 \
    0 \
    1 \
    1 \
    0xEEf0C605546958c1f899b6fB336C20671f9cD49F \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f \
    "USDT -> crvUSD/USDT LP Strategy" \
  --verify
```

Constructor args:
1. USDT — borrowed asset (debt token)
2. `address(0)` — vault set later via `initializeVault`
3. `<GOV_ADDRESS>` — strategy owner (controls slippage etc.)
4. crvUSD/USDT pool — used as `_usdtCrvUsdPool` (entry/exit swap leg)
5. crvUSD/USDT pool — used as `_lpPool` (same pool; see "Why crvUSD/USDT" note above)
6. Stake DAO reward vault (crvUSD/USDT)
7. `<CRV_SWAPPER>` — from Step 2
8. crvUSD/USDT gauge
9. `0` — USDT index in the pool (`_usdtIndex`)
10. `1` — crvUSD index in the pool (`_crvUsdIndex`)
11. `1` — crvUSD index in the pool for the LP leg (`_lpCrvUsdIndex`, query on-chain — see above)
12. crvUSD/USD oracle
13. USDT/USD oracle
14. CRV/USD oracle
15. `"USDT -> crvUSD/USDT LP Strategy"` — human-readable name

Save as `STRATEGY`.

---

### 5) Deploy AaveLoanManager
> **eMode 43** is set in the constructor and activates immediately — the loan manager enters the XAUt eMode on Aave before any funds are deposited.
> **Oracle staleness = 90000** (25h) to tolerate XAU/USD 24h Chainlink heartbeat.
```bash
forge create src/lenders/AaveLoanManager.sol:AaveLoanManager \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0x68749665FF8D2d112Fa859AA293F07A622782F38 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2 \
    0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8 \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6 \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    <SWAPPER> \
    6000 \
    7500 \
    0x0000000000000000000000000000000000000000 \
    43 \
    90000 \
  --verify
```

Constructor args:
1. XAUT — collateral token
2. USDT — debt token
3. `0x8A2b6f94...` — Aave aXAUT (aEthXAUt)
4. `0x6df1C1E3...` — Aave variable debt USDT
5. AAVE_POOL — Aave V3 pool
6. XAU/USD oracle — Chainlink (24h heartbeat)
7. USDT/USD oracle — Chainlink
8. `<SWAPPER>` — from Step 3
9. `6000` — maxLtvBps (60%; conservative vs eMode 70% ceiling)
10. `7500` — liquidationThresholdBps (eMode 43 value)
11. `address(0)` — vault set later via `initializeVault`
12. `43` — Aave eMode category (XAUt USDC USDT GHO)
13. `90000` — collateral oracle staleness limit, 25h (XAU/USD heartbeat = 24h)

Save as `LOAN_MANAGER`.

---

### 6) Deploy Vault (ZenjiXautAaveUsdtStakeDao)
```bash
forge create src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol:ZenjiXautAaveUsdtStakeDao \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    <LOAN_MANAGER> \
    <STRATEGY> \
    <SWAPPER> \
    <OWNER> \
    <VIEW_HELPER> \
  --verify
```
Save as `VAULT`.

> `ZenjiXautAaveUsdtStakeDao` overrides `MAX_TARGET_LTV()` to return `60e16` (60%). The vault's `targetLtv` is initialized to `MAX_TARGET_LTV()` = 60% at construction — no separate `setParam` call needed for initial LTV.

---

### 7) Rebalancing (Chainlink CRE workflow)
Rebalancing is triggered off-chain, not by an on-chain keeper contract. The Chainlink CRE workflow in `keeper/zen-keep/` runs on a cron trigger, reads `ZenjiRebalanceReceiver.rebalanceNeeded()`, and submits a DON-signed report that calls `vault.rebalance()`. Register this vault with the CRE workflow's config per `keeper/zen-keep/README.md` — no separate keeper contract deployment is needed for this vault.
>
> The old Chainlink Automation `ZenjiRebalanceKeeper` referenced by earlier runbooks is retired (`retired/src/keepers/`) and is **not** used for new vaults.

---

### 8) Initialize Vault References
```bash
# Initialize loan manager
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY

# Initialize strategy
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY

# Notify swapper of vault
cast send <SWAPPER> "setVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

---

### 9) (Optional) Configure Additional Parameters
The vault starts with `targetLtv = 60e16` and default slippage. Adjust if needed:

```bash
# Set deposit cap (param 2, e.g., 100 XAUT = 100e6 since XAUT has 6 decimals)
cast send <VAULT> "setParam(uint8,uint256)" 2 100000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Set fee rate (param 0, e.g., 10% = 0.1e18)
cast send <VAULT> "setParam(uint8,uint256)" 0 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

**`setParam` reference**: 0=feeRate, 1=targetLtv, 2=depositCap, 3=rebalanceBountyRate, 4=maxSlippage

---

## Verification Checklist

```bash
# Vault wiring
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# → <VAULT>

cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# → <VAULT>

cast call <VAULT> "loanManager()(address)" --rpc-url $MAINNET_RPC_URL
# → <LOAN_MANAGER>

cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
# → <STRATEGY>

# Target LTV — should start at 60% (MAX_TARGET_LTV for XAUT)
cast call <VAULT> "targetLtv()(uint256)" --rpc-url $MAINNET_RPC_URL
# → 600000000000000000  (60e16)

# Oracle staleness window — must be 90000 (25h) for XAU/USD 24h heartbeat
cast call <LOAN_MANAGER> "maxCollateralOracleStaleness()(uint256)" --rpc-url $MAINNET_RPC_URL
# → 90000

# eMode / maxLtvBps — must be 6000 (60%)
cast call <LOAN_MANAGER> "maxLtvBps()(uint256)" --rpc-url $MAINNET_RPC_URL
# → 6000

# Vault not idle
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
# → false

# Strategy pool wiring — confirm both legs point at the crvUSD/USDT pool
cast call <STRATEGY> "lpPool()(address)" --rpc-url $MAINNET_RPC_URL
# → 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4
```

Also spot-check current pool health before going live:
```bash
forge script script/StrategyLiquidityReport.s.sol --tc StrategyLiquidityReport --fork-url $MAINNET_RPC_URL -vv
# Look for "XAUT / Aave / crvUSD-USDT" — collateral leg + yield LP should both read OK.
```

---

## Architecture Notes

- **XAUT decimals**: XAUT has **6 decimals** (same as USDT), unlike WBTC (8). Account for this in deposit cap values.
- **Uniswap fee tier**: XAUT/USDT trades in the **0.05%** pool (fee = 500), not 0.3% like WBTC/USDT.
- **eMode 43**: Enables higher LTV (70%) than standard XAUT (otherwise lower). The vault caps `targetLtv` at 60% for safety.
- **Oracle frequency**: XAU/USD updates ~once per day. Monitoring dashboards should **not** alert on stale oracle after 1h for this vault.
- **Health factor at target**: `liquidationThreshold / targetLtv = 0.75 / 0.60 = 1.25`. Well above `MIN_HEALTH = 1.1`.
- **Same-pool swap+LP fee stacking**: see "Why crvUSD/USDT" above — deposits/withdrawals pay an extra exchange-fee leg versus a two-pool design, in exchange for deep, non-thin liquidity.
