# Advised Deposit Caps

Per-vault `depositCap` recommendations for the Zenji fleet, derived from live exit liquidity.

> **Snapshot**: block 25793357 (2026-08-19). Prices: XAU/USD $4,490.05, BTC/USD $69,466.13,
> wstETH ~$2,796.45. **These caps are a point-in-time measurement of mainnet pool depth and go
> stale as liquidity moves.** Re-run the measurement (below) at least monthly and after any
> material change in a yield pool's balance.

---

## Methodology

A vault's capacity is set by the **worst exit leg**, not by how much it can accept. Two legs bind:

1. **Yield leg** — the strategy holds the borrowed stablecoin as a single-sided crvUSD LP position.
   Exiting means `remove_liquidity_one_coin` in crvUSD, so the constraint is the pool's
   **pre-existing crvUSD-side balance**.
2. **Collateral leg** — delever, rebalance, and emergency paths swap collateral into the debt asset
   through the vault's swapper. The constraint is that venue's debt-side depth.

For each leg the position is capped at **25% of pre-existing depth**, so a full exit stays a
minority of the pool and the remaining LPs absorb it. The binding leg is then converted to a
collateral cap through the vault's target LTV:

```
debt_budget = 0.25 × pre_existing_depth
TVL_cap     = debt_budget / targetLtv
depositCap  = TVL_cap / collateral_price
```

### The yield-leg budget is SHARED

All three vaults farm crvUSD/USDT. They draw on the **same** pool depth, so the pool's budget is
divided **equally** across the vaults using it. Capping each vault at the full pool budget would
authorize several times the pool's depth in aggregate.

| Yield pool | Pre-existing crvUSD side | 25% budget | Vaults sharing | Per-vault debt budget |
|---|---|---|---|---|
| crvUSD/USDT (`0x390f…7BF4`) | 15,874,221 | 3,968,555 | 3 | **$1,322,852** |

### Why not the round-trip capacity tests

`test_capacityReport` / `test_singleDepositorSafeTvlCap_1pct` binary-search the largest deposit that
can round-trip within 1% slippage. Those numbers are **much larger** (e.g. 334 WBTC, 5,610 XAUT) and
must **not** be used as caps. A single depositor's round trip is self-consistent: the depositor adds
the crvUSD, so the depositor can remove it — unwinding exactly the imbalance they created, at ~2 bps,
even against a pool holding only 99k crvUSD. That measures round-trip symmetry, not market capacity.
Real exits are interleaved with other users, arbitrage, and price movement. Treat those tests as
regression checks on the swap path, not as capacity guidance.

---

## Advised Caps

| Vault | Binding leg | Debt budget | TVL cap | **Advised `depositCap`** | Raw value for `setParam` |
|---|---|---|---|---|---|
| WBTC / LlamaLend → crvUSD/USDT | collateral (WBTC/crvUSD Curve) | $837,544 | $1,288,529 | **18 WBTC** | `1800000000` |
| wstETH / LlamaLend → crvUSD/USDT | yield LP | $1,322,852 | $2,035,156 | **725 wstETH** | `725000000000000000000` |
| XAUT / Aave → crvUSD/USDT | collateral (XAUT/USDT V3 0.05%) | $256,626 | $427,709 | **95 XAUT** | `95000000` |

Caps are rounded **down** from the computed value. Target LTV is 65% except the XAUT vaults (60%).

### Collateral-leg depths used

| Swap venue | Debt-side depth | 25% ceiling | Vaults |
|---|---|---|---|
| XAUT/USDT Uniswap V3 0.05% (`0x6546…E5dA`) | $1,026,502 | $256,626 | XAUT / Aave |
| WBTC/crvUSD Curve | 3,350,176 crvUSD | $837,544 | WBTC / LlamaLend |
| wstETH → WETH → debt (multi-hop majors) | deep — not binding | — | wstETH / LlamaLend |

---

## Why pmUSD was retired

pmUSD depegged from ~$0.99 to ~$0.60 marginal (falling to ~$0.34 on a 200k sale), and the Curve
pmUSD/crvUSD pool became ~3.38M pmUSD against only ~103.7k crvUSD — crvUSD a ~3% minority side that
cannot absorb exits. Curve's `virtual_price` still reads ~1.0019 because it assumes both pool coins
are pegged, so VP-based accounting would have overstated the LP position by ~64%; the strategy's
`min(VP-based, calc_withdraw_one_coin)` guard in `BaseCurveStakeDaoStrategy.balanceOf()` is what
prevented that overstatement from reaching vault accounting. Live exposure at retirement was ~$0 —
the WBTC and wstETH pmUSD vaults held 0 TVL, and the XAUT pmUSD vault held ~$149. All five pmUSD
vault configurations (`ZenjiWbtcAaveStakeDao`, `ZenjiWbtcLlamaStakeDao`, `ZenjiWstEthAaveStakeDao`,
`ZenjiWstEthLlamaStakeDao`, `ZenjiXautAaveStakeDao`) are retired; their code lives in `retired/`.

The fleet now farms crvUSD/USDT exclusively, which is ~150× deeper on the exitable side than
pmUSD/crvUSD ever was.

---

## Applying a cap

`depositCap` is `setParam` index **2**, denominated in **collateral units**, and compared against
`getTotalCollateral()`. `0` means unlimited.

```bash
cast send <VAULT> "setParam(uint8,uint256)" 2 <RAW_VALUE> \
  --rpc-url $MAINNET_RPC_URL --private-key $GOV_PRIVATE_KEY
```

> **Timelock direction matters.** Lowering a cap (or setting one where none existed) is restrictive
> and applies immediately. **Raising or removing** a cap is treated as adverse and goes through the
> parameter timelock — see `ZenjiGovLib`. Plan cap increases ahead of demand.

Verify:
```bash
cast call <VAULT> "depositCap()(uint256)" --rpc-url $MAINNET_RPC_URL
```

---

## Re-measuring

```bash
# 1. Live pool depth + per-strategy exit health
forge script script/StrategyLiquidityReport.s.sol --tc StrategyLiquidityReport \
  --fork-url $MAINNET_RPC_URL -vv

# 2. Pre-existing crvUSD-side depth of the yield pool (the input to the budget)
cast call 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E "balanceOf(address)(uint256)" \
  0x390f3595bCa2Df7d23783dFd126427CCeb997BF4 --rpc-url $MAINNET_RPC_URL   # crvUSD/USDT
```

Then recompute with the formula above. A pool whose crvUSD side halves halves every cap drawing on it.

### Other ceilings (not binding today, but worth watching)

- **Aave XAUT supply cap**: 25,000 XAUT, ~14,320 supplied → ~10,680 headroom. Well above the XAUT
  vault cap, but a fleet-wide ceiling.
- **crvUSD/USDT slippage cliff**: with `A = 2000` the pool is nearly flat to ~$13M (35 bps) and then
  falls off sharply (~3,655 bps at $25M). The 25% rule keeps positions well inside the flat region.
