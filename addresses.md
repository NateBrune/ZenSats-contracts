

# Deployment-Relevant Addresses

This file lists all addresses needed to deploy and configure the various Zenji vault strategies. Addresses are grouped as follows:
- **Shared (used by multiple strategies)**
- **Aave+USDT+IPOR**
- **LlamaLend+crvUSD+IPOR**
- **Tokemak**

---

## Shared (All/Most Strategies)
- **WBTC**: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
- **USDT**: 0xdAC17F958D2ee523a2206206994597C13D831ec7
- **USDC**: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
- **CRVUSD**: 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
- **BTC/USD Chainlink Oracle**: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
- **crvUSD/USD Chainlink Oracle**: 0xEEf0C605546958c1f899b6fB336C20671f9cD49F

---

## Aave+USDT+IPOR
- **Aave Pool**: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
- **Aave aWBTC**: 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8
- **Aave Variable Debt USDT**: 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8
- **USDT/USD Chainlink Oracle**: 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D
- **Curve USDT/crvUSD Pool**: 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4
- **Curve TriCrypto Pool**: 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46
- **IPOR Plasma Vault**: 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117
- **SushiSwap Router**: 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F

---

## LlamaLend+crvUSD+IPOR
- **Curve LlamaLend WBTC Market**: 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67
- **Curve WBTC/crvUSD Pool**: 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373
- **IPOR Plasma Vault**: 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117

---

## Tokemak
- **Tokemak Autopool**: 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35
- **Tokemak Router**: 0x39ff6d21204B919441d17bef61D19181870835A2
- **Tokemak Rewarder**: 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B
- **Curve crvUSD/USDC Pool**: 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E

---

## Test Accounts / Whales (for testing/forking only)
- **WBTC Whale**: 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8
- **crvUSD Whale**: 0x0a7b9483030994016567b3B1B4bbB865578901Cb
- **LlamaLend Flash Lender**: 0x26dE7861e213A5351F6ED767d00e0839930e9eE1

---

## Notes
- Addresses are mainnet unless otherwise noted.
- For more context, see the relevant test files (e.g., Zenji.t.sol, APRTracking.fork.t.sol, UsdtIporAaveStrategy.fork.t.sol, TokemakYieldStrategy.fork.t.sol, LlamaLoanManager.t.sol).
