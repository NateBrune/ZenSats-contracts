# Zenji

**A conservative, automated carry-trade vault for hard assets on Ethereum.**

Zenji lets holders of BTC, ETH, and gold put their assets to work without selling them. Deposit collateral, and the vault borrows a stablecoin against it, deploys that stablecoin into a battle-tested Curve + Stake DAO yield position, and pays you the spread between the yield earned and the cost to borrow. It's an [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) tokenized vault, so your position is a single fungible share token that appreciates as the strategy earns.

The design is deliberately conservative: collateral is supplied to blue-chip money markets (Aave V3, LlamaLend) at a bounded loan-to-value, yield comes from deep stablecoin Curve pools rather than exotic farms, and the protocol ships with timelocked governance, a vetoable emergency state machine, and oracle-staleness protection on every price-sensitive operation.

---

## How It Works

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Deposit                                                            │
│     User deposits collateral (WBTC / wstETH / XAUT) → receives shares  │
└───────────────────────────────────┬──────────────────────────────────┘
                                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  2. Borrow                                                             │
│     Collateral supplied to Aave V3 or LlamaLend                        │
│     Vault borrows a stablecoin (USDT or crvUSD) at a target LTV        │
└───────────────────────────────────┬──────────────────────────────────┘
                                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  3. Earn                                                               │
│     Borrowed stablecoin → single-sided deposit into a Curve LP         │
│     LP staked in a Stake DAO reward gauge                              │
│     CRV rewards harvested → swapped to crvUSD → compounded             │
│                                                                        │
│     yield earned  −  borrow cost  =  vault profit                      │
└───────────────────────────────────┬──────────────────────────────────┘
                                     ▼
┌──────────────────────────────────────────────────────────────────────┐
│  4. Withdraw (reverses the flow)                                       │
│     LP unstaked → swapped back to debt asset → loan repaid →           │
│     collateral freed → returned to user                               │
└──────────────────────────────────────────────────────────────────────┘
```

The vault continuously keeps the position inside a healthy band. A permissionless `rebalance()` adjusts leverage back toward target whenever the LTV or the strategy/debt ratio drifts outside a ±3% deadband, and anyone can call `harvestYield()` to claim and compound CRV rewards. Keepers are incentivized with a bounty paid from accrued fees.

---

## Strategies

Every live strategy borrows a stablecoin and deploys it single-sided into a deep Curve stablecoin pool, then stakes the LP in [Stake DAO](https://www.stakedao.org/) to capture CRV emissions and trading fees. Vaults are deployed per **(collateral, lending venue, Curve pool)** triple.

| Collateral | Lending Venue | Borrows | Yield Pool (Curve + Stake DAO) |
|------------|---------------|---------|--------------------------------|
| WBTC       | Aave V3       | USDT    | pmUSD/crvUSD |
| WBTC       | LlamaLend     | crvUSD  | pmUSD/crvUSD |
| WBTC       | LlamaLend     | crvUSD  | USDT/crvUSD |
| wstETH     | Aave V3       | USDT    | pmUSD/crvUSD |
| wstETH     | LlamaLend     | crvUSD  | pmUSD/crvUSD |
| wstETH     | LlamaLend     | crvUSD  | USDT/crvUSD |
| XAUT       | Aave V3       | USDT    | pmUSD/crvUSD |

**Two lending venues, one strategy engine.** Aave V3 vaults borrow USDT and use Aave `flashLoanSimple` for atomic unwinds; LlamaLend vaults borrow crvUSD natively and use ERC-3156 flash loans. In both cases the borrowed stablecoin lands in the same family of Curve + Stake DAO LP strategies, so the yield engine is shared across the whole fleet.

CRV rewards from every position are routed through a dedicated harvest swapper (`CrvToCrvUsdSwapper`) that prices the swap against a Chainlink oracle floor, then compounds the proceeds back into the LP.

---

## Architecture

```
                            ┌─────────────────────────────┐
                            │  Zenji.sol  (ERC-4626 core)  │
                            │  deposits · withdrawals ·    │
                            │  LTV mgmt · rebalancing ·    │
                            │  fee accrual · emergency mode│
                            └───┬───────────┬───────────┬──┘
                  delegatecall  │           │           │
                            ┌───▼────────┐  │           │
                            │ ZenjiAdmin │  │           │  (storage-compatible
                            │ governance │  │           │   admin facet —
                            │ + emergency│  │           │   keeps bytecode
                            │ + roles    │  │           │   under EIP-170)
                            └────────────┘  │           │
                       ┌────────────────────▼──┐   ┌────▼─────────────────────────┐
                       │  Loan Manager (immut.) │   │  Yield Strategy (immut.)     │
                       │  AaveLoanManager   or  │   │  Curve LP + Stake DAO         │
                       │  LlamaLoanManager      │   │  single-sided stablecoin dep. │
                       └────────────────────────┘   └────┬──────────────────────────┘
                                                          │
                                                    ┌─────▼──────────────┐
                                                    │ CrvToCrvUsdSwapper │
                                                    │ harvest CRV→crvUSD │
                                                    └────────────────────┘

  Mutable (1-week timelock):  Swapper  — the only upgradeable dependency
  Custom oracle:              WstEthOracle  — wstETH/USD composite (stETH/ETH × ETH/USD)
  Off-chain helper:           ZenjiRebalanceKeeper  — permissionless rebalance trigger
```

- **`Zenji.sol`** — the ERC-4626 entry point holding all user-facing logic and storage.
- **`ZenjiAdmin.sol`** — a storage-layout-identical admin facet reached via `delegatecall`, carrying governance, role management, and the emergency state machine. The split exists purely to keep each deployed vault under the 24 KB EIP-170 bytecode limit.
- **Loan Manager & Yield Strategy** are immutable per vault — they cannot be swapped out, which removes an entire class of governance-rug risk.
- **Swapper** is the single mutable dependency and can only be rotated through a 1-week timelock.

---

## Governance & Safety

Zenji separates authority across three roles, all initialized to the deployer and transferable only through timelocked, two-step accept flows.

| Role | Scope | Powers |
|------|-------|--------|
| **Strategist** | Day-to-day ops | `setIdle()`, `withdrawFees()` |
| **Gov** | Infrastructure | `setParam()` (timelocked), strategy slippage, swapper rotation, all role transfers |
| **Guardian** | Emergency only | `enterEmergencyMode()`, stepwise unwind, `emergencyRescue()`, `rescueAssets()` |
| **Public** | Permissionless upkeep | `rebalance()`, `accrueYieldFees()`, `harvestYield()` |
| **User** | ERC-4626 | `deposit()`, `mint()`, `withdraw()`, `redeem()` |

**Security properties:**

- **Oracle integrity** — every price read validates Chainlink staleness, round completeness, and positivity. The emergency unwind path is deliberately oracle-free so a stale feed can never trap funds.
- **Bounded leverage** — target LTV is capped per vault (65% for BTC/ETH, 60% for gold) and rebalances keep the position inside a ±3% deadband.
- **Immutable core dependencies** — loan manager and yield strategy are fixed at deploy time; only the swapper is mutable, behind a 1-week timelock.
- **Vetoable emergency machine** — the Guardian can enter a one-way emergency mode and unwind in steps, but each skippable step carries a 3-day window during which Gov can veto. A 48-hour Gov break-glass path covers Guardian key loss.
- **Inflation-attack resistance** — a virtual share offset makes first-depositor share manipulation uneconomical.
- **Reentrancy guards** on all external entry points, and USDT-safe (reset-to-zero) token approvals throughout.

### Key Parameters

| Parameter | Default | Bound | Change Mechanism |
|-----------|---------|-------|------------------|
| Target LTV | per-vault max | 15% – 65% (60% gold) | `setParam`, 1-week timelock |
| Rebalance deadband | ±3% | fixed | — |
| Fee rate | 10% | ≤ 20%, on yield only | `setParam`, 1-week timelock |
| Rebalance bounty | 20% of fees | ≤ 50% | `setParam`, 1-week timelock |
| Vault slippage | 1% | 0.1% – 5% | `setParam`, 1-week timelock |
| Swapper rotation | — | — | 1-week timelock |
| Role transfer | — | — | 1-week (4-week for Guardian) |
| Emergency step skip | — | — | 3-day Gov veto window |

---

## Deployments

Each vault is a standalone deployment produced by a script under [`script/`](script/). For example, the WBTC/LlamaLend USDT/crvUSD vault:

```bash
export PRIVATE_KEY=0x...          # deployer (also default owner/gov)
export OWNER=0x...                # optional — vault owner
export GOV=0x...                  # optional — governance address
export MAINNET_RPC_URL=https://...
export ETHERSCAN_API_KEY=...

forge script script/DeployWbtcLlamaUsdtStakeDao.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvv
```

Each script deploys the full stack (view helper, swappers, loan manager, strategy, vault, keeper) and wires them together — including authorizing the strategy on the harvest swapper — in a single broadcast.

Before opening a vault to the public, check live pool depth and exit-leg health:

```bash
forge script script/StrategyLiquidityReport.s.sol \
  --tc StrategyLiquidityReport --fork-url $MAINNET_RPC_URL -vv
```

---

## Build & Test

Requires [Foundry](https://getfoundry.sh/).

```bash
forge build                                          # compile
forge test --fork-url $MAINNET_RPC_URL -vv           # full suite (mainnet fork)
forge test --match-path "test/Zenji.t.sol" -vv       # unit tests (no fork)
forge coverage --fork-url $MAINNET_RPC_URL --via-ir  # coverage
```

> **Do not run `forge fmt`** on this codebase — it strips single-line blocks and corrupts the source. There is no fmt hook, intentionally.

Fork suites run at the latest block by default, so external pool conditions vary run-to-run. Pin a deterministic block with `FORK_BLOCK=<n>`. Size-dependent exit tests gracefully **skip** (rather than fail) when an external market can't be traded within the swapper's slippage budget — that's environmental, not a vault bug.

### Toolchain

- **Solidity** 0.8.34 · **EVM** Cancun · **Optimizer** via-IR, 200 runs (tuned for runtime gas; vaults sit ~1.7 KB under the EIP-170 limit)
- **Fuzz** 5,000 runs (CI profile)

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a full contract-by-contract reference.

---

## License

MIT
