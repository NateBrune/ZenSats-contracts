# Deploy: XAUT + USDT + pmUSD/crvUSD Stake DAO (Aave)

Runbook for deploying the XAUT-collateral Zenji vault that borrows USDT on Aave V3 (eMode 43 — "XAUt USDC USDT GHO") and farms yield via the pmUSD/crvUSD Stake DAO gauge. Uses a Uniswap V3 single-hop swapper (XAUT→USDT, 0.05% fee) and a CRV reward compounder.

> **Important — Oracle staleness**: XAU/USD Chainlink heartbeat is **24 hours** (vs 1h for BTC/ETH). The `AaveLoanManager` uses `maxCollateralOracleStaleness = 90000` (25h) to accommodate this. Keepers and monitoring must tolerate up to 24h between oracle updates without triggering unnecessary alerts.

> **Important — eMode**: This vault uses Aave eMode category **43** (XAUt USDC USDT GHO). At eMode LTV = 70%, the vault's `MAX_TARGET_LTV` is capped to **60%** by `ZenjiXautPmUsd.MAX_TARGET_LTV()` for a health factor margin of ~1.25 at target.

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Optionally: `OWNER` and `GOV` (default to deployer address)
- Foundry installed and up to date

## Quick Deploy (full script)
```bash
bash scripts/deploy_pmusd_xaut.sh
```

## Mainnet Addresses
```solidity
// Assets
address constant XAUT   = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CRV    = 0xD533a949740bb3306d119CC777fa900bA034cd52;
address constant PMUSD  = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

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

// Curve / Stake DAO
address constant USDT_CRVUSD_POOL      = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
address constant PMUSD_CRVUSD_POOL     = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
address constant PMUSD_CRVUSD_GAUGE    = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
address constant CRV_CRVUSD_TRICRYPTO  = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Aave LTV bounds (bps)
uint256 constant TARGET_LTV_BPS     = 6000;  // 60% — vault MAX_TARGET_LTV, conservative relative to eMode 70%
uint256 constant MAX_LTV_BPS        = 6000;  // AaveLoanManager maxLtvBps (eMode effective LTV bps)
uint256 constant LIQN_THRESHOLD_BPS = 7500;  // Aave eMode liquidation threshold
```

## Deployment Steps

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

Save as `SWAPPER`.

---

### 4) Deploy PmUsdCrvUsdStrategy
`lpCrvUsdIndex` is 0 if crvUSD is `coins(0)` in the pmUSD/crvUSD pool, else 1. **Confirm on-chain before deploying**:
```bash
cast call 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb "coins(uint256)(address)" 0 --rpc-url $MAINNET_RPC_URL
# If returns 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E (crvUSD) → LP_CRVUSD_INDEX=0, else 1
```

```bash
forge create src/strategies/PmUsdCrvUsdStrategy.sol:PmUsdCrvUsdStrategy \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0xD533a949740bb3306d119CC777fa900bA034cd52 \
    0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF \
    0x0000000000000000000000000000000000000000 \
    <GOV_ADDRESS> \
    0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 \
    0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb \
    0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D \
    <CRV_SWAPPER> \
    0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087 \
    0 \
    1 \
    <LP_CRVUSD_INDEX> \
    0xEEf0C605546958c1f899b6fB336C20671f9cD49F \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f \
  --verify
```

Constructor args:
1. USDT — borrowed asset
2. crvUSD — yield asset
3. CRV — reward token
4. pmUSD — LP asset
5. `address(0)` — vault set later via `initializeVault`
6. `<GOV_ADDRESS>` — strategy owner (controls slippage etc.)
7. USDT/crvUSD pool — swap path for entering/exiting yield
8. pmUSD/crvUSD LP pool — gauge LP token pool
9. Stake DAO reward vault
10. `<CRV_SWAPPER>` — from Step 2
11. pmUSD/crvUSD gauge
12. `0` — USDT index in USDT/crvUSD pool
13. `1` — crvUSD index in USDT/crvUSD pool
14. `<LP_CRVUSD_INDEX>` — crvUSD index in pmUSD/crvUSD pool (query on-chain)
15. crvUSD/USD oracle
16. USDT/USD oracle
17. CRV/USD oracle

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

### 6) Deploy Vault (ZenjiXautPmUsd)
```bash
forge create src/implementations/ZenjiXautPmUsd.sol:ZenjiXautPmUsd \
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

> `ZenjiXautPmUsd` overrides `MAX_TARGET_LTV()` to return `60e16` (60%). The vault's `targetLtv` is initialized to `MAX_TARGET_LTV()` = 60% at construction — no separate `setParam` call needed for initial LTV.

---

### 7) Deploy ZenjiRebalanceKeeper (optional)
```bash
forge create src/keepers/ZenjiRebalanceKeeper.sol:ZenjiRebalanceKeeper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args <VAULT> <OWNER> \
  --verify
```
Save as `KEEPER`.

---

### 8) Initialize Vault References
```bash
# Initialize loan manager
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY

# Initialize strategy
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY

# Notify swapper of vault (if required by implementation)
cast send <SWAPPER> "setVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

---

### 9) Set Strategy on Vault
**Must be called by OWNER:**
```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

---

### 10) (Optional) Configure Additional Parameters
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

# eMode category — must be 43
cast call <LOAN_MANAGER> "maxLtvBps()(uint256)" --rpc-url $MAINNET_RPC_URL
# → 6000

# Vault not idle
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
# → false
```

---

## Architecture Notes

- **XAUT decimals**: XAUT has **6 decimals** (same as USDT), unlike WBTC (8). Account for this in deposit cap values.
- **Uniswap fee tier**: XAUT/USDT trades in the **0.05%** pool (fee = 500), not 0.3% like WBTC/USDT.
- **eMode 43**: Enables higher LTV (70%) than standard XAUT (otherwise lower). The vault caps `targetLtv` at 60% for safety.
- **Oracle frequency**: XAU/USD updates ~once per day. Monitoring dashboards should **not** alert on stale oracle after 1h for this vault.
- **Health factor at target**: `liquidationThreshold / targetLtv = 0.75 / 0.60 = 1.25`. Well above `MIN_HEALTH = 1.1`.
