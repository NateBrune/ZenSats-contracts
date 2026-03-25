# Deploy: WBTC + USDT + IPOR (Aave)

Runbook for deploying the WBTC-collateral Zenji vault that borrows USDT on Aave V3 and farms IPOR (via crvUSD).

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Foundry installed and up to date

## Mainnet Addresses
```solidity
// Assets
address constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

// Chainlink
address constant BTC_USD_ORACLE  = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

// Aave V3
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_WBTC        = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

// IPOR + Curve
address constant IPOR_PLASMA_VAULT      = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Uniswap V3 (WBTC<->USDT single-hop via Universal Router)
address constant UNIVERSAL_ROUTER    = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
uint24  constant WBTC_USDT_V3_FEE    = 3000;  // 0.30%
```

## Deployment Steps

1) **Deploy ZenjiViewHelper**
```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify
```
Save as `VIEW_HELPER`.

2) **Deploy UniversalRouterV3SingleHopSwapper** (WBTC→USDT via Uniswap V3 0.3%)
```bash
forge create src/swappers/base/UniversalRouterV3SingleHopSwapper.sol:UniversalRouterV3SingleHopSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOVERNANCE_ADDRESS> \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af \
    3000 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
  --verify
```
Save as `SWAPPER`.

3) **Deploy AaveLoanManager**
```bash
forge create src/lenders/AaveLoanManager.sol:AaveLoanManager \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
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

4) **Deploy UsdtIporYieldStrategy**
```bash
forge create src/strategies/UsdtIporYieldStrategy.sol:UsdtIporYieldStrategy \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0x0000000000000000000000000000000000000000 \
    0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 \
    0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117 \
    0 \
    1 \
    0xEEf0C605546958c1f899b6fB336C20671f9cD49F \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
  --verify
```
Save as `STRATEGY`.

5) **Deploy Vault (ZenjiWbtc)**
```bash
forge create src/implementations/ZenjiWbtc.sol:ZenjiWbtc \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <LOAN_MANAGER> \
    <STRATEGY> \
    <SWAPPER> \
    <OWNER> \
    <VIEW_HELPER> \
  --verify
```
Save as `VAULT`.

6) **Initialize references**
```bash
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

7) **Set initial strategy** (owner)
```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

8) **Optional parameters**
```bash
# target LTV (e.g., 65%)
cast send <VAULT> "setParam(uint8,uint256)" 1 650000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
# rebalance bounty (e.g., 10%)
cast send <VAULT> "setParam(uint8,uint256)" 3 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

9) **Verification checks**
```bash
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
```

## Notes
- Governance/owner is set at deploy time; transfer to multisig after verification if desired.
- Swapper governance should be transferred alongside the vault when productionizing.
