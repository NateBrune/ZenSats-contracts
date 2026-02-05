# Deploy: Aave + USDT + IPOR (Zenji)

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
address constant TRICRYPTO_POOL       = 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
uint256 constant TRICRYPTO_USDT_INDEX = 0;
uint256 constant TRICRYPTO_WBTC_INDEX = 1;
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
forge create src/CurveThreeCryptoSwapper.sol:CurveThreeCryptoSwapper \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 \
    0xdAC17F958D2ee523a2206206994597C13D831ec7 \
    0xD51a44d3FaE010294C616388b506AcdA1bfAAE46 \
    1 \
    0 \
  --verify
```

Constructor args:
1. `WBTC` - collateral token
2. `USDT` - debt token
3. `TRICRYPTO_POOL` - Curve pool address
4. `1` - WBTC index in tricrypto
5. `0` - USDT index in tricrypto

Save the deployed address as `SWAPPER`.

---

### Step 3: Deploy AaveLoanManager

```bash
forge create src/AaveLoanManager.sol:AaveLoanManager \
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
    7500 \
    8000 \
    0x0000000000000000000000000000000000000000 \
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
9. `7500` - max LTV (75%)
10. `8000` - liquidation threshold (80%)
11. `address(0)` - vault set later

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
    0x0000000000000000000000000000000000000000 \
    <OWNER> \
    <VIEW_HELPER> \
  --verify
```

Constructor args:
1. `WBTC` - collateral asset
2. `USDT` - debt asset
3. `LOAN_MANAGER` - from Step 3
4. `address(0)` - strategy set later
5. `OWNER` - vault owner address
6. `VIEW_HELPER` - from Step 1

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

### Step 8: Enable Yield

**Must be called by OWNER:**

```bash
cast send <VAULT> "toggleYield(bool)" true \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

## Quick Reference: Deployment Order

| Step | Contract                | Init Required? | Who Calls |
|------|-------------------------|----------------|-----------|
| 1    | ZenjiViewHelper         | No             | Deployer  |
| 2    | CurveThreeCryptoSwapper | No             | Deployer  |
| 3    | AaveLoanManager         | Yes (Step 6a)  | Deployer  |
| 4    | UsdtIporYieldStrategy   | Yes (Step 6b)  | Deployer  |
| 5    | Zenji                   | No             | Deployer  |
| 6    | initializeVault (x2)    | -              | Deployer  |
| 7    | setInitialStrategy      | -              | Owner     |
| 8    | toggleYield(true)       | -              | Owner     |

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
cast call <VAULT> "strategy()(address)" --rpc-url $MAINNET_RPC_URL
# Should return <STRATEGY>

# Check yield enabled
cast call <VAULT> "yieldEnabled()(bool)" --rpc-url $MAINNET_RPC_URL
# Should return true
```

---

## Notes

- **USDT quirk**: USDT's `approve()` returns void instead of bool. The SafeTransferLib handles this with `safeApprove()`.
- **Loan manager swapper**: Required for flashloan unwind when there's a repayment shortfall. Uses the Curve TriCrypto pool.
- **Strategy swapper**: The strategy uses the Curve USDT/crvUSD pool directly for swaps before depositing into IPOR.
- **Owner vs Deployer**: Steps 7-8 must be called by the vault owner. If owner ≠ deployer, use the owner's key.

---

## Previously Deployed Contracts

| Contract        | Address                                      |
|-----------------|----------------------------------------------|
| ZenjiViewHelper | `0x3b737482fb04f3708c36689a283D421f92eb584c` |
| CurveThreeCryptoSwapper | `0x88BE2bc471c2851DDcd5Fb3DFe02aa6540849aD6` |
| AaveLoanManagerV2 | `0x1efe6822C515B49c8C76B9e3C5E62c17a59298B3` |
| UsdtIporYieldStrategy | `0x6AC9493C56fbAa8fD123F60372F8673bbb5e6A67` |
| Zenji | `0xc35019FB4cb2CFA02B599c54a0898c5d119d4c2D` |
