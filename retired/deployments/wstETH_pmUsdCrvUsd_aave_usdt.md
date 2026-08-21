# Deploy: wstETH + USDT + pmUSD/crvUSD Stake DAO (Aave)

Runbook for deploying the wstETH-collateral Zenji vault that borrows USDT on Aave V3 and farms yield via the pmUSD/crvUSD Stake DAO gauge. Uses a Uniswap V3 two-hop swapper (wstETH→WETH→USDT), a dedicated wstETH oracle, and a CRV reward compounder.

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Optionally: `OWNER` and `GOV` (default to deployer address)
- Foundry installed and up to date

## Quick Deploy (full script)
```bash
bash scripts/deploy_pmusd_wsteth.sh
```

## Mainnet Addresses
```solidity
// Assets
address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CRV    = 0xD533a949740bb3306d119CC777fa900bA034cd52;
address constant PMUSD  = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

// Chainlink
address constant STETH_ETH_ORACLE  = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
address constant ETH_USD_ORACLE    = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
address constant USDT_USD_ORACLE   = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
address constant CRV_USD_ORACLE    = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

// Aave V3
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_WSTETH      = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

// Uniswap V3
address constant UNISWAP_ROUTER  = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
uint24  constant FEE_WSTETH_WETH = 100;   // 0.01%
uint24  constant FEE_WETH_USDT   = 3000;  // 0.30%

// Curve / Stake DAO
address constant USDT_CRVUSD_POOL      = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
address constant PMUSD_CRVUSD_POOL     = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
address constant PMUSD_CRVUSD_GAUGE    = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
address constant CRV_CRVUSD_TRICRYPTO  = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Aave LTV bounds (bps)
uint256 constant TARGET_LTV_BPS    = 6000;  // 60% — conservative for wstETH
uint256 constant MAX_LTV_BPS       = 7800;  // liquidation warning band
uint256 constant LIQN_THRESHOLD_BPS = 8100; // Aave liquidation threshold
```

## Deployment Steps

### 1) Deploy ZenjiViewHelper
```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --verify
```
Save as `VIEW_HELPER`.

### 2) Deploy WstEthOracle
Composes stETH/ETH and ETH/USD Chainlink feeds into a single USD price.
```bash
forge create src/WstEthOracle.sol:WstEthOracle \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    0x86392dC19c0b719886221c78AB11eb8Cf5c52812 \
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 \
  --verify
```
Save as `WSTETH_ORACLE`.

### 3) Deploy CrvToCrvUsdSwapper (CRV reward compounder)
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

### 4) Deploy UniswapV3TwoHopSwapper (wstETH→WETH→USDT)
Used to swap collateral proceeds back to USDT for debt repayment during unwinds.
```bash
forge create src/swappers/base/UniswapV3TwoHopSwapper.sol:UniswapV3TwoHopSwapper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOV_ADDRESS> \
    0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
    0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 \
    100 \
    3000 \
    <WSTETH_ORACLE> \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    3600 \
  --verify
```
Save as `SWAPPER`.

### 5) Deploy PmUsdCrvUsdStrategy
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

### 6) Deploy AaveLoanManager
```bash
forge create src/lenders/AaveLoanManager.sol:AaveLoanManager \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args \
    0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x0B925eD163218f6662a35e0f0371Ac234f9E9371 \
    0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8 \
    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    <WSTETH_ORACLE> \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    <SWAPPER> \
    7800 \
    8100 \
    0x0000000000000000000000000000000000000000 \
    0 \
    3600 \
  --verify
```
Save as `LOAN_MANAGER`.

### 7) Deploy Vault (ZenjiWstEthPmUsd)
```bash
forge create src/implementations/ZenjiWstEthPmUsd.sol:ZenjiWstEthPmUsd \
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

### 8) Deploy ZenjiRebalanceKeeper
```bash
forge create src/keepers/ZenjiRebalanceKeeper.sol:ZenjiRebalanceKeeper \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY \
  --constructor-args <VAULT> <OWNER> \
  --verify
```
Save as `KEEPER`.

### 9) Initialize references
```bash
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

### 10) Set initial strategy (owner)
```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

### 11) Optional parameters
```bash
# Target LTV: 60% (conservative for wstETH)
cast send <VAULT> "setParam(uint8,uint256)" 1 600000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Rebalance bounty: 10%
cast send <VAULT> "setParam(uint8,uint256)" 3 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Min strategy/debt ratio: 95% (alert if strategy falls below debt)
cast send <VAULT> "setParam(uint8,uint256)" 5 950000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY

# Max strategy/debt ratio: 110% (trigger borrow-more if strategy far above debt)
cast send <VAULT> "setParam(uint8,uint256)" 6 1100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

### 12) Verification checks
```bash
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "loanManager()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "strategyToDebtRatio()(uint256)" --rpc-url $MAINNET_RPC_URL
```

## Notes
- The wstETH oracle composes stETH/ETH × ETH/USD; verify both Chainlink feeds are live before first deposit.
- `lpCrvUsdIndex` must be checked on-chain: `cast call 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb "coins(uint256)(address)" 0 --rpc-url $MAINNET_RPC_URL` — if result is crvUSD use 0, else use 1.
- The pmUSD/crvUSD strategy path is: USDT → crvUSD (Curve USDT/crvUSD pool) → pmUSD LP (Curve pmUSD/crvUSD pool) → staked in Stake DAO gauge.
- CRV rewards are auto-compounded via CrvToCrvUsdSwapper through the CRV/crvUSD Tricrypto pool.
- After verification, transfer vault `gov` role to multisig if desired.
