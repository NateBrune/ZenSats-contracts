# Deploy: WBTC + USDT + pmUSD/crvUSD Stake DAO (Aave)

Runbook for deploying the WBTC-collateral Zenji vault that borrows USDT on Aave V3 and farms yield via the pmUSD/crvUSD Stake DAO gauge. Uses a Uniswap Universal Router V3 single-hop swapper (WBTC→USDT) and a CRV reward compounder.

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Optionally: `OWNER` and `GOV` (default to deployer address)
- Foundry installed and up to date

## Quick Deploy (full script)
```bash
bash scripts/deploy_pmusd.sh
```

## Mainnet Addresses
```solidity
// Assets
address constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CRV    = 0xD533a949740bb3306d119CC777fa900bA034cd52;
address constant PMUSD  = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

// Chainlink
address constant BTC_USD_ORACLE    = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
address constant USDT_USD_ORACLE   = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
address constant CRV_USD_ORACLE    = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

// Aave V3
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_WBTC        = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

// Uniswap Universal Router (WBTC→USDT single-hop V3)
address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
uint24  constant WBTC_USDT_V3_FEE = 3000;  // 0.30%

// Curve / Stake DAO
address constant USDT_CRVUSD_POOL      = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
address constant PMUSD_CRVUSD_POOL     = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
address constant PMUSD_CRVUSD_GAUGE    = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
address constant CRV_CRVUSD_TRICRYPTO  = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Aave LTV bounds (bps)
uint256 constant TARGET_LTV_BPS     = 6500;  // 65%
uint256 constant MAX_LTV_BPS        = 7300;  // warning band
uint256 constant LIQN_THRESHOLD_BPS = 7800;  // Aave liquidation threshold
```

## Deployment Steps

### 1) Deploy ZenjiViewHelper
```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --verify
```
Save as `VIEW_HELPER`.

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

### 3) Deploy UniversalRouterV3SingleHopSwapper (WBTC→USDT)
Used to swap collateral proceeds back to USDT for debt repayment during unwinds.
```bash
forge create src/swappers/base/UniversalRouterV3SingleHopSwapper.sol:UniversalRouterV3SingleHopSwapper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOV_ADDRESS> \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af \
    3000 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    3600 \
  --verify
```
Save as `SWAPPER`.

### 4) Deploy PmUsdCrvUsdStrategy
`lpCrvUsdIndex` is 0 if crvUSD is coins(0) in the pmUSD/crvUSD pool, else 1. Confirm on-chain before deploying.
```bash
forge create src/strategies/PmUsdCrvUsdStrategy.sol:PmUsdCrvUsdStrategy \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0xD533a949740bb3306d119CC777fa900bA034cd52 \
    0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF \
    0x0000000000000000000000000000000000000000 \
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
Save as `STRATEGY`.

### 5) Deploy AaveLoanManager
```bash
forge create src/lenders/AaveLoanManager.sol:AaveLoanManager \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8 \
    0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8 \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    <SWAPPER> \
    7300 \
    7800 \
    0x0000000000000000000000000000000000000000 \
    0 \
    3600 \
  --verify
```
Save as `LOAN_MANAGER`.

### 6) Deploy Vault (ZenjiWbtcPmUsd)
```bash
forge create src/implementations/ZenjiWbtcPmUsd.sol:ZenjiWbtcPmUsd \
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

### 7) Deploy ZenjiRebalanceKeeper
```bash
forge create src/keepers/ZenjiRebalanceKeeper.sol:ZenjiRebalanceKeeper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args <VAULT> <OWNER> \
  --verify
```
Save as `KEEPER`.

### 8) Initialize references
```bash
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

### 9) Set initial strategy (owner)
```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

### 10) Optional parameters
```bash
# Target LTV: 65%
cast send <VAULT> "setParam(uint8,uint256)" 1 650000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Rebalance bounty: 10%
cast send <VAULT> "setParam(uint8,uint256)" 3 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Min strategy/debt ratio: 95%
cast send <VAULT> "setParam(uint8,uint256)" 5 950000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Max strategy/debt ratio: 110%
cast send <VAULT> "setParam(uint8,uint256)" 6 1100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

### 11) Verification checks
```bash
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "loanManager()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "strategyToDebtRatio()(uint256)" --rpc-url $MAINNET_RPC_URL
```

## Notes
- `lpCrvUsdIndex` must be checked on-chain before deploying the strategy: `cast call 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb "coins(uint256)(address)" 0 --rpc-url $MAINNET_RPC_URL` — if result is crvUSD use 0, else use 1.
- The pmUSD/crvUSD strategy path is: USDT → crvUSD (Curve USDT/crvUSD pool) → pmUSD LP (Curve pmUSD/crvUSD pool) → staked in Stake DAO gauge.
- CRV rewards are auto-compounded via CrvToCrvUsdSwapper through the CRV/crvUSD Tricrypto pool.
- WBTC has 8 decimals; the vault and loan manager handle this correctly via oracle-denominated LTV math.
- After verification, transfer vault `gov` role to multisig if desired.
