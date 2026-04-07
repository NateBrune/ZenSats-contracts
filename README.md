# Zenji

A conservative ERC4626 collateral yield vault on Ethereum mainnet. Zenji accepts hard assets (WBTC, wstETH, XAUT) as collateral, borrows USDT against them on Aave V3, and deploys the borrowed USDT into yield strategies to earn the spread between borrow cost and yield generated.

## How It Works

```
User deposits collateral (WBTC / wstETH / XAUT)
  -> Collateral supplied to Aave V3 (AaveLoanManager borrows USDT at target LTV)
    -> Borrowed USDT deployed to pmUSD/crvUSD strategy
      -> USDT swapped to crvUSD, deployed into pmUSD/crvUSD Curve LP
        -> LP staked in Stake DAO reward vault; CRV rewards harvested
      -> Spread between yield earned and borrow cost = vault profit

User withdraws collateral
  <- LP unstaked, crvUSD swapped back to USDT, Aave debt repaid, collateral freed
    <- Collateral returned to user
```

## Architecture

```
+--------------------------------------------------------------+
|  Zenji.sol                                                    |
|  ERC4626 vault: deposits, withdrawals, LTV management,       |
|  rebalancing, fee accrual, emergency mode                     |
+---------------+------------------------------+---------------+
                |                              |
+---------------v-----------+  +---------------v-------------------------------+
| AaveLoanManager.sol       |  | PmUsdCrvUsdStrategy.sol                       |
| Aave V3 interactions:     |  | USDT → crvUSD → pmUSD/crvUSD LP → Stake DAO   |
| supply collateral,        |  | Harvest: CRV → crvUSD via CrvToCrvUsdSwapper  |
| flashLoanSimple to        |  +-----------------------------------------------+
| borrow/repay USDT,        |
| oracle validation         |  Also available:
+---------------------------+    UsdtIporYieldStrategy  (USDT → IPOR PlasmaVault)
                                 IporYieldStrategy       (crvUSD → IPOR PlasmaVault)

VaultTracker.sol - APR tracking via daily snapshots (separate contract for bytecode limits)
TimelockLib.sol  - Timelock library for swapper/parameter changes

Supported vault configurations:
  ZenjiWbtcPmUsd   — WBTC collateral, USDT debt, pmUSD/crvUSD strategy
  ZenjiWstEthPmUsd — wstETH collateral, USDT debt, pmUSD/crvUSD strategy
  ZenjiXautPmUsd   — XAUT (Tether Gold) collateral, USDT debt, pmUSD/crvUSD strategy
```

## Key Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Target LTV | 65% (default max) | Configurable 15–65% via timelock |
| Deadband | ±3% | Rebalance triggers outside this range |
| Fee Rate | 10% (default) | On yield profit only, max 20%, timelocked |
| Rebalance Bounty | 20% (default) | Of accumulated fees, paid to keeper, max 50% |
| Min Deposit | 10,000 sats / equivalent | Prevents dust deposits |
| Virtual Offset | 1e5 | Inflation attack prevention |
| Timelock Delay | 1 week | For swapper and slippage changes |

## Access Control

Three roles — all initialized to deployer; Gov controls all transfers (2-step accept pattern).

| Role | Responsibilities |
|------|-----------------|
| **Strategist** | Day-to-day ops: `setIdle()`, `withdrawFees()` |
| **Gov** | Infrastructure: `setParam()`, `setStrategySlippage()`, swapper timelock, all `transferRole()` calls |
| **Guardian** | Emergency-only: `enterEmergencyMode()`, `emergencyStep()`, `emergencySkipStep()`, `emergencyRescue()`, `rescueAssets()` |
| **Public** | `rebalance()`, `accrueYieldFees()`, `harvestYield()` |
| **User** | `deposit()`, `withdraw()`, `mint()`, `redeem()` (ERC4626), post-liquidation redemption |

## External Protocol Addresses (Mainnet)

| Contract | Address |
|----------|---------|
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Chainlink BTC/USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink XAU/USD | `0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| XAUT | `0x68749665FF8D2d112Fa859AA293F07A622782F38` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |
| pmUSD/crvUSD Curve LP | see `deployments/` |

## Building

Requires [Foundry](https://getfoundry.sh/).

```bash
forge build          # Compile
forge fmt            # Format
forge fmt --check    # Check formatting
```

## Testing

Tests require a mainnet fork:

```bash
# Set your RPC URL in .env
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# Run all tests
source .env && forge test --fork-url $MAINNET_RPC_URL

# Verbose / targeted
forge test --fork-url $MAINNET_RPC_URL -vvv
forge test --fork-url $MAINNET_RPC_URL --match-test testFunctionName
forge test --fork-url $MAINNET_RPC_URL --match-contract ContractName

# Coverage
forge coverage --fork-url $MAINNET_RPC_URL --via-ir
```

## Configuration

- **Solidity**: 0.8.33
- **EVM Version**: Cancun
- **Optimizer**: Enabled, 1 run, via-ir
- **Fuzz Testing**: 5,000 runs (CI profile)

## Security Considerations

- **Oracle validation**: Chainlink feeds checked for staleness, round completeness, and price positivity on every operation
- **Reentrancy protection**: All external entry points use reentrancy guards
- **Flash loan safety**: Aave `flashLoanSimple` callbacks validate sender and initiator
- **Inflation attack prevention**: Virtual share offset (1e5) makes share manipulation uneconomical
- **Timelock governance**: Swapper and slippage changes require 1-week proposal delay
- **Two-step role transfers**: All role transfers require explicit acceptance by the new address
- **Emergency mode**: One-way latch with flash-loan-based unwind and pro-rata collateral distribution

## License

MIT
