# Zenji

A conservative ERC4626-compliant WBTC yield vault built on Ethereum mainnet. Zenji deploys WBTC as collateral on [LlamaLend](https://llamalend.curve.fi/) to borrow crvUSD, then deposits the borrowed crvUSD into yield strategies to earn the spread between borrow cost and yield generated.

## How It Works

```
User deposits WBTC
  -> WBTC collateralizes a LlamaLend loan (borrow crvUSD at target LTV)
    -> Borrowed crvUSD deployed to yield strategy (IPOR PlasmaVault or Tokemak)
      -> Strategy auto-compounds / harvests rewards
      -> Spread between yield earned and borrow cost = vault profit

User withdraws WBTC
  <- Position unwound (withdraw crvUSD from strategy, repay debt, remove collateral)
    <- WBTC returned to user
```

## Architecture

```
+--------------------------------------------------------------+
|  Zenji.sol                                                    |
|  ERC4626 vault: deposits, withdrawals, LTV management,       |
|  rebalancing, fee accrual, emergency mode                     |
+---------------+------------------------------+---------------+
                |                              |
+---------------v-----------+  +---------------v---------------+
| LlamaLoanManager.sol      |  | YieldStrategy (pluggable)     |
| LlamaLend interactions:   |  |   - IporYieldStrategy.sol     |
| create/repay/unwind loans, |  |     (IPOR PlasmaVault)       |
| oracle validation, swaps   |  |   - TokemakYieldStrategy.sol |
+----------------------------+  |     (Tokemak autoUSD)        |
                                +-------------------------------+

VaultTracker.sol - APR tracking via daily snapshots (separate contract for size limits)
TimelockLib.sol  - Timelock library for parameter changes
```

## Key Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Target LTV | 70% (default) | Configurable 15-75% via timelock |
| Deadband | +/-3% | Rebalance triggers outside this range |
| Fee Rate | 10% (default) | On yield profit only, max 20%, timelocked |
| Rebalance Bounty | 20% (default) | Of accumulated fees, paid to keeper |
| Min Deposit | 10,000 sats | Prevents dust deposits |
| Virtual Offset | 1e5 | Inflation attack prevention |
| Timelock Delay | 2 days | For swapper, strategy, and loan manager changes |

## Access Control

| Role | Functions |
|------|-----------|
| **Public** | `rebalance()`, `accrueYieldFees()`, `harvestYield()` |
| **Owner** | `setParam()`, `setIdle()`, `enterEmergencyMode()`, `emergencyStep()`, `emergencyRescue()`, `proposeStrategy()`, `proposeLoanManager()`, and their execute/cancel counterparts, `withdrawFees()`, `setInitialStrategy()`, `transferRole()` |
| **Governance** | `proposeSwapper()`, `executeSwapper()`, `cancelSwapper()`, `transferRole()` |
| **User** | `deposit()`, `withdraw()`, `mint()`, `redeem()` (ERC4626), post-liquidation redemption |

## External Protocol Addresses (Mainnet)

| Contract | Address |
|----------|---------|
| LlamaLend Controller | `0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67` |
| Llamarisk crvUSD Vault (IPOR) | `0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117` |
| WBTC/crvUSD TwoCrypto | `0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373` |
| Chainlink BTC/USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| Chainlink crvUSD/USD | `0xEEf0C605546958c1f899b6fB336C20671f9cD49F` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |

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
# Set your RPC URL
export MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# Run tests
forge test --fork-url $MAINNET_RPC_URL
forge test --fork-url $MAINNET_RPC_URL -vvv                              # Verbose
forge test --fork-url $MAINNET_RPC_URL --match-test testFunctionName     # Single test
forge test --fork-url $MAINNET_RPC_URL --match-contract ContractName     # Single contract

# Coverage
forge coverage --fork-url $MAINNET_RPC_URL --via-ir
```

Alternatively, create a `.env` file (see `.env.example`):

```
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
```

## Configuration

- **Solidity**: 0.8.33
- **EVM Version**: Cancun
- **Optimizer**: Enabled, 1 run, via-ir
- **Fuzz Testing**: 5,000 runs (CI profile)

## Security Considerations

- **Oracle validation**: Both Chainlink feeds checked for staleness, round completeness, and price positivity on every operation
- **Reentrancy protection**: All external entry points use reentrancy guards
- **Flash loan safety**: ERC3156 callbacks validate sender and initiator
- **Inflation attack prevention**: Virtual share offset (1e5) makes share manipulation uneconomical
- **Timelock governance**: Fee rate, target LTV, and strategy changes require proposal + delay
- **Two-step ownership**: Ownership transfer requires explicit acceptance by new owner
- **Emergency mode**: One-way latch with flashloan-based liquidation and pro-rata WBTC distribution

## License

MIT
