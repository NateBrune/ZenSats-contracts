# Deploy: Aave + USDT + IPOR (Zenji)

📂 Per-strategy runbooks now live in `deployments/`:
- [deployments/wbtc_ipor_aave_usdt.md](deployments/wbtc_ipor_aave_usdt.md)
- [deployments/cbBTC_ipor_aave_usdt.md](deployments/cbBTC_ipor_aave_usdt.md)
- [deployments/wstETH_ipor_aave_usdt.md](deployments/wstETH_ipor_aave_usdt.md)
- [deployments/wbtc_pmUsdCrvUsd_aave_usdt.md](deployments/wbtc_pmUsdCrvUsd_aave_usdt.md)
- [deployments/wstETH_pmUsdCrvUsd_aave_usdt.md](deployments/wstETH_pmUsdCrvUsd_aave_usdt.md)
- [deployments/xaut_pmUsd_aave_usdt.md](deployments/xaut_pmUsd_aave_usdt.md)

The sections below retain the original WBTC notes and scratch material.

This guide walks through deploying the Zenji vault with:
- **Loan Manager**: Aave V3 (deposit WBTC, borrow USDT)
- **Yield Strategy**: IPOR Plasma Vault (deposit crvUSD via USDT→crvUSD swap)

---

## Prerequisites

1. Set your environment variables:
   ```bash
   export PRIVATE_KEY=0x...
   export MAINNET_RPC_URL=https://...
   export ETHERSCAN_API_KEY=...
   ```

2. Ensure Foundry is installed and up to date.

---

## Mainnet Addresses (Copy-Paste Ready)

```solidity
// Assets
address constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CBBTC  = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

// Chainlink Oracles
address constant BTC_USD_ORACLE  = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

// Aave V3
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant AAVE_A_WBTC        = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

// IPOR (crvUSD yield venue)
address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

// Curve: USDT ↔ crvUSD (for strategy)
address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
int128  constant USDT_INDEX   = 0;
int128  constant CRVUSD_INDEX = 1;

// Curve TriCrypto: WBTC ↔ USDT (for loan-manager swapper)
address constant TRICRYPTO_POOL       = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
uint256 constant TRICRYPTO_USDT_INDEX = 0;
uint256 constant TRICRYPTO_WBTC_INDEX = 1;

// Curve TwoCrypto: cbBTC ↔ WBTC (for cbBTC swapper)
address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
uint256 constant CBBTC_INDEX = 0;
uint256 constant WBTC_INDEX = 1;
```

---

## Deployment Steps

### Step 1: Deploy ZenjiViewHelper

```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify
```

Save the deployed address as `VIEW_HELPER`.

---

### Step 2: Deploy CurveThreeCryptoSwapper

This swapper handles WBTC ↔ USDT swaps for the loan manager (e.g., during unwind).

```bash
forge create src/swappers/base/CurveThreeCryptoSwapper.sol:CurveThreeCryptoSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOVERNANCE_ADDRESS> \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4 \
    1 \
    0 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    3600 \
  --verify
```

Constructor args:
1. `<GOVERNANCE_ADDRESS>` - governance address for slippage control
2. `WBTC` - collateral token
3. `USDT` - debt token
4. `TRICRYPTO_POOL` - Curve pool address
5. `1` - WBTC index in tricrypto
6. `0` - USDT index in tricrypto
7. `BTC_USD_ORACLE` - Chainlink BTC/USD price feed
8. `USDT_USD_ORACLE` - Chainlink USDT/USD price feed
9. `3600` - max collateral oracle staleness (seconds)

Save the deployed address as `SWAPPER`.

For cbBTC vaults, use the two-hop swapper (cbBTC <-> WBTC, then WBTC <-> USDT):

```bash
forge create src/swappers/base/CbBtcWbtcUsdtSwapper.sol:CbBtcWbtcUsdtSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <GOVERNANCE_ADDRESS> \
    0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0x839d6bDeDFF886404A6d7a788ef241e4e28F4802 \
    0 \
    1 \
    0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4 \
    1 \
    0 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0x3E7d1eAB13ad0104d2750B8863b489D65364e32D \
    3600 \
  --verify
```

Constructor args:
1. `<GOVERNANCE_ADDRESS>` - governance address for slippage control
2. `cbBTC` - collateral token
3. `USDT` - debt token
4. `WBTC` - intermediate token
5. `CBBTC_WBTC_POOL` - Curve pool address
6. `0` - cbBTC index
7. `1` - WBTC index
8. `TRICRYPTO_POOL` - Curve TriCrypto pool
9. `1` - WBTC index in tricrypto
10. `0` - USDT index in tricrypto
11. `BTC_USD_ORACLE` - Chainlink BTC/USD price feed
12. `USDT_USD_ORACLE` - Chainlink USDT/USD price feed
13. `3600` - max collateral oracle staleness (seconds)

---

### Step 3: Deploy AaveLoanManager

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

Constructor args:
1. `WBTC` - collateral
2. `USDT` - debt asset
3. `aWBTC` - Aave aToken for WBTC
4. `varDebtUSDT` - Aave variable debt token for USDT
5. `AAVE_POOL` - Aave V3 pool
6. `BTC/USD oracle` - Chainlink
7. `USDT/USD oracle` - Chainlink
8. `SWAPPER` - from Step 2
9. `7300` - max LTV (73%)
10. `7800` - liquidation threshold (78%)
11. `address(0)` - vault set later
12. `0` - eMode category (disabled for WBTC; use 43 for XAUT)
13. `3600` - collateral oracle staleness limit in seconds (BTC/USD heartbeat = 1h; use 90000 for XAUT)

Save the deployed address as `LOAN_MANAGER`.

---

### Step 4: Deploy UsdtIporYieldStrategy

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

Constructor args:
1. `USDT` - borrowed asset
2. `crvUSD` - yield asset
3. `address(0)` - vault set later
4. `CURVE_USDT_CRVUSD_POOL` - Curve pool for swaps
5. `IPOR_PLASMA_VAULT` - yield venue
6. `0` - USDT index in Curve pool
7. `1` - crvUSD index in Curve pool
8. `CRVUSD_USD_ORACLE` - Chainlink crvUSD/USD oracle
9. `USDT_USD_ORACLE` - Chainlink USDT/USD oracle

Save the deployed address as `STRATEGY`.

---

### Step 5: Deploy Zenji Vault

```bash
forge create src/Zenji.sol:Zenji \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    <LOAN_MANAGER> \
    <STRATEGY> \
    <SWAPPER> \
    <OWNER> \
    <VIEW_HELPER> \
  --verify
```

Optional: deploy a per-asset implementation instead of the base vault:

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

For cbBTC, use `src/implementations/ZenjiCbBtc.sol:ZenjiCbBtc` with the same constructor args.

Constructor args:
1. `WBTC` - collateral asset
2. `USDT` - debt asset
3. `LOAN_MANAGER` - from Step 3
4. `address(0)` - strategy set later (or pass `STRATEGY` and skip Step 7)
5. `SWAPPER` - from Step 2
6. `OWNER` - vault owner address (handles day-to-day operations)
7. `VIEW_HELPER` - from Step 1

**Note**: Governance address is initially set to OWNER in constructor. You can transfer it to a multisig later.

Save the deployed address as `VAULT`.

---

### Step 6: Initialize Vault References

The loan manager and strategy need to know the vault address.

**6a. Initialize Loan Manager:**
```bash
cast send <LOAN_MANAGER> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

**6b. Initialize Strategy:**
```bash
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

### Step 7: Set Strategy on Vault

**Must be called by OWNER:**

```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

### Step 8: (Optional) Change Swapper Later

If you need to change the swapper after deployment, use the timelocked governance flow:

```bash
cast send <VAULT> "proposeSwapper(address)" <NEW_SWAPPER> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

cast send <VAULT> "executeSwapper()" \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

### Step 9: (Optional) Transfer Governance to Multisig

For production deployments, transfer governance control to a multisig:

```bash
# As current governance (owner initially), propose transfer
cast send <VAULT> "transferRole(uint8,address)" 1 <MULTISIG_ADDRESS> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

# As multisig, accept governance
cast send <VAULT> "acceptRole(uint8)" 1 \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $MULTISIG_PRIVATE_KEY

# Transfer swapper governance
cast send <SWAPPER> "transferGovernance(address)" <MULTISIG_ADDRESS> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

cast send <SWAPPER> "acceptGovernance()" \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $MULTISIG_PRIVATE_KEY
```

---

## Quick Reference: Deployment Order

| Step | Contract                | Init Required? | Who Calls  |
|------|-------------------------|----------------|------------|
| 1    | ZenjiViewHelper         | No             | Deployer   |
| 2    | CurveThreeCryptoSwapper | No             | Deployer   |
| 3    | AaveLoanManager         | Yes (Step 6a)  | Deployer   |
| 4    | UsdtIporYieldStrategy   | Yes (Step 6b)  | Deployer   |
| 5    | Zenji                   | No             | Deployer   |
| 6    | initializeVault (x2)    | -              | Deployer   |
| 7    | setInitialStrategy      | -              | Owner      |
| 8    | changeSwapper (optional) | -             | Gov        |
| 9    | Transfer Governance     | -              | Gov/Owner  |

---

## Verification Checklist

After deployment, verify everything is wired correctly:

```bash
# Check loan manager vault
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <VAULT>

# Check strategy vault
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <VAULT>

# Check vault strategy
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <STRATEGY>

# Check vault is not idle
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
# Should return false

# Check oracle staleness window
cast call <LOAN_MANAGER> "maxCollateralOracleStaleness()(uint256)" --rpc-url $MAINNET_RPC_URL
# Should return 3600 (BTC/ETH vaults) or 90000 (XAUT vault)

# Check target LTV (set to MAX_TARGET_LTV at construction)
cast call <VAULT> "targetLtv()(uint256)" --rpc-url $MAINNET_RPC_URL
# Should return 650000000000000000 (65e16) for BTC/ETH, or 600000000000000000 (60e16) for XAUT
```

---

## Notes

- **USDT quirk**: USDT's `approve()` returns void instead of bool. The SafeTransferLib handles this with `safeApprove()`.
- **Loan manager swapper**: Required for flashloan unwind when there's a repayment shortfall. Uses the Curve TriCrypto pool.
- **Strategy swapper**: The strategy uses the Curve USDT/crvUSD pool directly for swaps before depositing into IPOR.
- **Owner vs Deployer**: Steps 7-9 must be called by the vault owner/governance. If owner ≠ deployer, use the owner's key.

---

## Previously Deployed Contracts

| Contract        | Address                                      |
|-----------------|----------------------------------------------|
| ZenjiViewHelper | `0x3b737482fb04f3708c36689a283D421f92eb584c` |
| CurveThreeCryptoSwapper | `0x88BE2bc471c2851DDcd5Fb3DFe02aa6540849aD6` |
| AaveLoanManagerV2 | `0x1efe6822C515B49c8C76B9e3C5E62c17a59298B3` |
| UsdtIporYieldStrategy | `0x6AC9493C56fbAa8fD123F60372F8673bbb5e6A67` |
| Zenji | `0xc35019FB4cb2CFA02B599c54a0898c5d119d4c2D` |
| VaultTracker | `0x09d03014552519B44E0f74a45dB59Ffc9E3150c0` |

### Scratch notes
UsdtIpor Strat Balance day 0 - 4.6744 crvUSD in IPOR 10002

---

# Deploy: LlamaLend + crvUSD + IPOR (Zenji)

This guide walks through deploying the Zenji vault with:
- **Loan Manager**: LlamaLend (deposit WBTC, borrow crvUSD)
- **Yield Strategy**: IPOR Plasma Vault (deposit crvUSD directly - no swap needed!)

This is the **cleanest design** - no currency conversion needed since LlamaLend borrows crvUSD directly, which IPOR accepts natively.

---

## Prerequisites

1. Set your environment variables:
   ```bash
   export PRIVATE_KEY=0x...
   export MAINNET_RPC_URL=https://...
   export ETHERSCAN_API_KEY=...
   ```

2. Ensure Foundry is installed and up to date.

---

## Mainnet Addresses (Copy-Paste Ready)

```solidity
// Assets
address constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

// Chainlink Oracles
address constant BTC_USD_ORACLE    = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

// LlamaLend
address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;

// IPOR (crvUSD yield venue)
address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

// Curve TwoCrypto: WBTC ↔ crvUSD (for loan-manager swapper)
address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
uint256 constant TWOCRYPTO_CRVUSD_INDEX = 0;
uint256 constant TWOCRYPTO_WBTC_INDEX   = 1;
```

---

## Deployment Steps

### Step 1: Deploy ZenjiViewHelper

```bash
forge create src/ZenjiViewHelper.sol:ZenjiViewHelper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify
```

Save the deployed address as `VIEW_HELPER`.

---

### Step 2: Deploy CurveTwoCryptoSwapper

This swapper handles WBTC ↔ crvUSD swaps for the loan manager (e.g., during unwind).

```bash
forge create src/CurveTwoCryptoSwapper.sol:CurveTwoCryptoSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373 \
    1 \
    0 \
  --verify
```

Constructor args:
1. `WBTC` - collateral token
2. `crvUSD` - debt token
3. `WBTC_CRVUSD_POOL` - Curve TwoCrypto pool address
4. `1` - WBTC index in TwoCrypto
5. `0` - crvUSD index in TwoCrypto

Save the deployed address as `SWAPPER`.

---

### Step 3: Deploy LlamaLoanManager

```bash
forge create src/LlamaLoanManager.sol:LlamaLoanManager \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67 \
    0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373 \
    0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c \
    0xEEf0C605546958c1f899b6fB336C20671f9cD49F \
    <SWAPPER> \
    <VAULT_PLACEHOLDER> \
  --verify
```

Constructor args:
1. `WBTC` - collateral token
2. `crvUSD` - debt token
3. `LLAMALEND_WBTC_CONTROLLER` - LlamaLend controller for WBTC/crvUSD market
4. `WBTC_CRVUSD_POOL` - Curve TwoCrypto pool for swaps
5. `BTC/USD oracle` - Chainlink
6. `crvUSD/USD oracle` - Chainlink
7. `<SWAPPER>` - from Step 2
8. `<VAULT_PLACEHOLDER>` - vault address (from Step 5 - see note below)

**Note**: LlamaLoanManager requires the vault address at construction (unlike AaveLoanManager which uses `initializeVault`). You have two options:
- **Option A (Recommended)**: Deploy vault first (Step 5), then come back to deploy LlamaLoanManager with the real vault address
- **Option B**: Use a temporary address like your own EOA, deploy everything, then redeploy LlamaLoanManager with the correct vault address

Save the deployed address as `LOAN_MANAGER`.

---

### Step 4: Deploy IporYieldStrategy

```bash
forge create src/strategies/IporYieldStrategy.sol:IporYieldStrategy \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    0x0000000000000000000000000000000000000000 \
    0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117 \
  --verify
```

Constructor args:
1. `crvUSD` - debt/yield asset (same token!)
2. `address(0)` - vault set later via `initializeVault`
3. `IPOR_PLASMA_VAULT` - yield venue

Save the deployed address as `STRATEGY`.

---

### Step 5: Deploy Zenji Vault

```bash
forge create src/Zenji.sol:Zenji \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E \
    <LOAN_MANAGER> \
    0x0000000000000000000000000000000000000000 \
    <SWAPPER> \
    <OWNER> \
    <VIEW_HELPER> \
  --verify
```

Constructor args:
1. `WBTC` - collateral asset
2. `crvUSD` - debt asset
3. `LOAN_MANAGER` - from Step 3
4. `address(0)` - strategy set later
5. `SWAPPER` - from Step 2
6. `OWNER` - vault owner address
7. `VIEW_HELPER` - from Step 1

Save the deployed address as `VAULT`.

**If you used Option A above**: Go back to Step 3 now and deploy LlamaLoanManager with this vault address.

---

### Step 6: Initialize Strategy

The strategy needs to know the vault address.

```bash
cast send <STRATEGY> "initializeVault(address)" <VAULT> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

### Step 7: Set Strategy on Vault

**Must be called by OWNER:**

```bash
cast send <VAULT> "setInitialStrategy(address)" <STRATEGY> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

### Step 8: Configure Vault Parameters

**Must be called by OWNER:**

Set target LTV (param 1, recommended: 50% for LlamaLend):
```bash
cast send <VAULT> "setParam(uint8,uint256)" 1 500000000000000000 \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

Set fee rate (param 0, e.g., 10%):
```bash
cast send <VAULT> "setParam(uint8,uint256)" 0 100000000000000000 \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

Set deposit cap (param 2, e.g., 10 WBTC = 1e9 satoshis):
```bash
cast send <VAULT> "setParam(uint8,uint256)" 2 1000000000 \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

**`setParam` reference:** 0=feeRate, 1=targetLtv, 2=depositCap, 3=rebalanceBountyRate

---

### Step 9: (Optional) Change Swapper Later

If you need to change the swapper after deployment, use the timelocked governance flow:

```bash
cast send <VAULT> "proposeSwapper(address)" <NEW_SWAPPER> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

cast send <VAULT> "executeSwapper()" \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

### Step 10: (Optional) Transfer Governance to Multisig

For production deployments, transfer governance control to a multisig:

```bash
# As current governance (owner initially), propose transfer
cast send <VAULT> "transferRole(uint8,address)" 1 <MULTISIG_ADDRESS> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

# As multisig, accept governance
cast send <VAULT> "acceptRole(uint8)" 1 \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $MULTISIG_PRIVATE_KEY

# Transfer swapper governance (swapper uses its own interface)
cast send <SWAPPER> "transferGovernance(address)" <MULTISIG_ADDRESS> \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

cast send <SWAPPER> "acceptGovernance()" \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $MULTISIG_PRIVATE_KEY
```

---

## Quick Reference: Deployment Order

| Step | Contract             | Init Required? | Who Calls |
|------|----------------------|----------------|-----------|
| 1    | ZenjiViewHelper      | No             | Deployer  |
| 2    | CurveTwoCryptoSwapper| No             | Deployer  |
| 3    | LlamaLoanManager     | No*            | Deployer  |
| 4    | IporYieldStrategy    | Yes (Step 6)   | Deployer  |
| 5    | Zenji                | No             | Deployer  |
| 6    | initializeVault      | -              | Deployer  |
| 7    | setInitialStrategy   | -              | Owner     |
| 8    | Configure parameters | -              | Owner     |
| 9    | changeSwapper (optional) | -           | Gov       |
| 10   | Transfer Governance  | -              | Gov/Owner |

\* LlamaLoanManager needs vault address at construction (see Step 3 note)

---

## Verification Checklist

After deployment, verify everything is wired correctly:

```bash
# Check loan manager vault
cast call <LOAN_MANAGER> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <VAULT>

# Check strategy vault
cast call <STRATEGY> "vault()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <VAULT>

# Check vault loan manager
cast call <VAULT> "loanManager()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <LOAN_MANAGER>

# Check vault strategy
cast call <VAULT> "yieldStrategy()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <STRATEGY>

# Check vault is not idle
cast call <VAULT> "idle()(bool)" --rpc-url $MAINNET_RPC_URL
# Should return false

# Check target LTV
cast call <VAULT> "targetLtv()(uint256)" --rpc-url $MAINNET_RPC_URL
# Should return 500000000000000000 (50%)

# Verify strategy asset matches vault debt asset
cast call <STRATEGY> "asset()(address)" --rpc-url $MAINNET_RPC_URL
# Should return crvUSD address

cast call <VAULT> "debtAsset()(address)" --rpc-url $MAINNET_RPC_URL
# Should return crvUSD address
```

---

## Architecture Highlights

### Why This Is The Cleanest Design

1. **No Currency Conversions**: LlamaLend borrows crvUSD → IPOR accepts crvUSD directly
   - UsdtIporYieldStrategy needs USDT→crvUSD swap (Curve pool + slippage)
   - IporYieldStrategy needs NO swap (direct deposit)

2. **Single Debt Asset**: crvUSD throughout the entire flow
   - Collateral (WBTC) → Borrow (crvUSD) → Yield (crvUSD) → Repay (crvUSD)

3. **Lower Gas Costs**: Fewer external calls, no swap operations

4. **Less Complexity**: No Curve pool interactions for debt asset swaps

5. **Reduced Slippage Risk**: No slippage on debt asset → yield strategy flow

---

## Notes

- **LlamaLend Bands**: All loans use 4 bands (constant in LlamaLoanManager)
- **Target LTV**: Recommended 50% for conservative leverage (LlamaLend default max ~67%)
- **Flashloan Support**: LlamaLoanManager uses Balancer flashloans for underwater position unwinding
- **No Swapper for Strategy**: IporYieldStrategy doesn't need swaps - crvUSD in, crvUSD out
- **Loan Manager Swapper**: Curve TwoCrypto pool handles WBTC↔crvUSD for emergency unwinding
- **Owner vs Deployer**: Steps 7-9 must be called by the vault owner/governance. If owner ≠ deployer, use the owner's key.

---

## Comparison: LlamaLend vs Aave

| Feature | LlamaLend + IPOR | Aave + USDT + IPOR |
|---------|------------------|---------------------|
| Collateral | WBTC | WBTC |
| Debt Asset | crvUSD | USDT |
| Yield Asset | crvUSD (direct) | crvUSD (via swap) |
| Strategy Swaps | None ✓ | USDT→crvUSD on every flow |
| Loan Manager | LlamaLoanManager | AaveLoanManager |
| Liquidation Model | Soft liquidation (LLAMMA) | Hard liquidation threshold |
| Flashloan Provider | Balancer | Aave V3 |
| Gas Efficiency | Higher ✓ | Lower (extra swaps) |
| Code Complexity | Lower ✓ | Higher (swap logic) |
