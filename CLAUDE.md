# Zenji

## Architecture

**Read `ARCHITECTURE.md` first** for full codebase reference (all contracts, state, functions, flows, addresses).

ERC4626 conservative collateral yield vault. Deposits collateral → borrows via immutable LoanManager → deploys debt to immutable YieldStrategy. Swapper is mutable via 1-week timelock.

### Three-Role Governance
- **Strategist**: day-to-day operations (setIdle, withdrawFees)
- **Gov**: infrastructure changes (swapper timelock, params, all role transfers, strategy slippage)
- **Guardian**: emergency-only (enterEmergencyMode, emergencyStep, rescue)

### Vault Configurations
- **WBTC/Aave**: WBTC collateral, USDT debt, IPOR yield strategy, CurveThreeCryptoSwapper
- **cbBTC/Aave**: cbBTC collateral, USDT debt, IPOR yield strategy, CbBtcWbtcUsdtSwapper
- **wstETH/Aave**: wstETH collateral, USDT debt, IPOR yield strategy, UniswapV3TwoHopSwapper

## Code Structure

```
src/
  Zenji.sol                    Main ERC4626 vault
  ZenjiViewHelper.sol          External view helper (reduces bytecode)
  VaultTracker.sol             APR/performance tracking
  WstEthOracle.sol             Custom wstETH/USD oracle
  implementations/             Concrete vault deployments (ZenjiWbtc, ZenjiCbBtc, ZenjiWstEth)
  lenders/
    AaveLoanManager.sol        Aave V3 loan management
    LlamaLoanManager.sol       LlamaLend loan management
  strategies/
    BaseYieldStrategy.sol      Abstract base (cost basis, reentrancy, pause)
    BaseIporStrategy.sol       IPOR PlasmaVault helpers
    UsdtIporYieldStrategy.sol  USDT→crvUSD→IPOR yield
    IporYieldStrategy.sol      Direct crvUSD→IPOR yield
    BaseCurveRewardVaultStrategy.sol  Abstract base for Curve LP + Stake DAO
    PmUsdCrvUsdStrategy.sol    USDT→crvUSD→pmUSD/crvUSD LP→Stake DAO
  swappers/
    base/                      Debt/collateral ISwapper implementations
      CurveThreeCryptoSwapper.sol, CurveTwoCryptoSwapper.sol,
      CbBtcWbtcUsdtSwapper.sol, UniswapV3TwoHopSwapper.sol
    reward/
      CrvToCrvUsdSwapper.sol   Harvest: CRV→crvUSD
  libraries/
    SafeTransferLib.sol        USDT-safe transfers
    TimelockLib.sol            Timelock for swapper/param changes
    ZenjiCoreLib.sol           Emergency ops, fee processing
    AaveOracleLib.sol          Aave oracle helpers
    LlamaOracleLib.sol         Llama oracle helpers
  interfaces/                  All external interfaces
test/                          Unit tests (*.t.sol) and fork tests (*.fork.t.sol)
script/                        Deploy scripts per vault config
```

## Testing

```bash
# All tests (requires mainnet fork)
forge test --fork-url $MAINNET_RPC_URL -vv

# Unit tests only (no fork needed for mock-based tests)
forge test --match-path "test/Zenji.t.sol" -vv

# Fuzz tests with more runs
forge test --fork-url $MAINNET_RPC_URL --match-test "testFuzz" -vv

# Coverage
forge coverage --fork-url $MAINNET_RPC_URL

# Strategy exit-liquidity report (live on-chain depth/dislocation per strategy)
forge script script/StrategyLiquidityReport.s.sol --tc StrategyLiquidityReport --fork-url $MAINNET_RPC_URL -vv
# Add STRICT=1 to make it revert when any strategy's exit leg is BROKEN (CI gate)
```

## Test liquidity / graceful skips
- Fork suites run at the unpinned latest block, so external pool conditions vary run-to-run. Set
  `FORK_BLOCK=<n>` to pin a deterministic block.
- Size-dependent exit tests **skip** (not fail) when the underlying market can't be traded within the
  swapper's slippage budget (e.g. XAUT/USDT below the gold oracle, or a downstream arithmetic panic from
  a short swap). See `_isEnvironmentalRevert`/`_skipOnEnvironmentalRevert` in `test/base/ZenjiForkTestBase.sol`.
  This is environmental, not a vault bug — use the liquidity report above to see current pool health.

## Key Patterns
- `vm.prank()` only applies to ONE call; use `vm.startPrank()/vm.stopPrank()` for multi-call sequences
- **Do NOT run `forge fmt`** — it strips single-line blocks and corrupts this codebase. There is no fmt hook (intentionally); commits do not auto-format.
- Constructor uses `computeCreateAddress` for predictable contract addresses
- IPOR PlasmaVault has a short withdraw cooldown — tests must `_refreshOracles()` (warp + re-mock) before withdrawals
