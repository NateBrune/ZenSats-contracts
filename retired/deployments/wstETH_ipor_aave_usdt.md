# Deploy: wstETH + USDT + IPOR (Aave)

Runbook for deploying the wstETH-collateral Zenji vault that borrows USDT on Aave V3 and farms IPOR (via crvUSD). Uses a Uniswap V3 two-hop swapper and a dedicated wstETH oracle.

## Prerequisites
- Export env vars: `PRIVATE_KEY`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`
- Foundry installed and up to date

## Mainnet Addresses
```solidity
// Assets
address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

// Chainlink
address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
address constant ETH_USD_ORACLE   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
address constant USDT_USD_ORACLE  = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

// Aave V3
address constant AAVE_POOL           = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_WSTETH       = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
address constant AAVE_VAR_DEBT_USDT  = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

// IPOR + Curve
address constant IPOR_PLASMA_VAULT      = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Uniswap V3
address constant UNISWAP_ROUTER   = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
uint24  constant FEE_WSTETH_WETH = 100;   // 0.01%
uint24  constant FEE_WETH_USDT   = 3000;  // 0.30%
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

2) **Deploy WstEthOracle**
```bash
forge create src/WstEthOracle.sol:WstEthOracle \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    0x86392dC19c0b719886221c78AB11eb8Cf5c52812 \
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 \
  --verify
```
Save as `WSTETH_ORACLE`.

3) **Deploy UniswapV3TwoHopSwapper** (wstETH→WETH→USDT)
```bash
forge create src/swappers/base/UniswapV3TwoHopSwapper.sol:UniswapV3TwoHopSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOVERNANCE_ADDRESS> \
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

4) **Deploy AaveLoanManager**
```bash
forge create src/lenders/AaveLoanManager.sol:AaveLoanManager \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
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

5) **Deploy UsdtIporYieldStrategy**
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

6) **Deploy Vault (ZenjiWstEth)**
```bash
forge create src/implementations/ZenjiWstEth.sol:ZenjiWstEth \
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

7) **Initialize references**
```bash
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

8) **Set initial strategy** (owner)
```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

9) **Optional parameters**
```bash
# target LTV (e.g., 60-65% for wstETH)
cast send <VAULT> "setParam(uint8,uint256)" 1 600000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
# rebalance bounty (e.g., 10%)
cast send <VAULT> "setParam(uint8,uint256)" 3 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

10) **Verification checks**
```bash
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
```

## Notes
- The wstETH oracle composes stETH/ETH and ETH/USD Chainlink feeds; ensure both are live before interacting.
- Keep Uniswap pool fee settings aligned with the liquidity you plan to route through (100 + 3000 as above).
