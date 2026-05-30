# Call Graph (grep-based)

> Method: grep-based analysis of src/ — not slither-generated graph.

## High-Level Architecture

```
User
  └── Zenji.sol (ERC4626 vault)
        ├── ILoanManager (immutable)
        │     ├── AaveLoanManager → Aave V3 Pool → Flash loan callback → ISwapper
        │     └── LlamaLoanManager → ILlamaLendController → ERC3156 flash lender → ISwapper
        ├── IYieldStrategy (immutable)
        │     ├── BaseVaultStrategy → IYieldVault (IPOR PlasmaVault)
        │     │     ├── UsdtIporStrategy (USDT → crvUSD → IPOR)
        │     │     └── CrvUsdIporStrategy (crvUSD → IPOR)
        │     └── BaseLPStrategy → Curve LP → Stake DAO RewardVault
        │           ├── CrvUsdLpStakeDaoStrategy
        │           ├── NgCrvUsdLpStakeDaoStrategy
        │           └── UsdtNgCrvUsdLpStakeDaoStrategy
        ├── ISwapper (mutable, timelock)
        │     ├── CurveThreeCryptoSwapper
        │     ├── CurveTwoCryptoSwapper
        │     ├── UniswapV3TwoHopSwapper
        │     ├── CbBtcUniswapV3TwoHopSwapper
        │     ├── UniswapMixedCurveSwapper
        │     └── UniswapMixedTwoHopSwapper
        └── ZenjiViewHelper (read-only external helper)
```

## Key Call Flows

### Deposit Flow
```
Zenji.deposit() / mint()
  → nonReentrant
  → _accrueYieldFees()  [reads lastStrategyBalance, writes accumulatedFees]
  → _deposit()
  → if (!idle): _deployCapital()
      → loanManager.borrow() [Aave: supply collateral, borrow debt]
      → _deployDebtToYield() → yieldStrategy.deposit()
      → lastStrategyBalance = yieldStrategy.balanceOf() [SNAPSHOT UPDATE]
```

### Withdraw Flow
```
Zenji.withdraw() / redeem()
  → nonReentrant
  → _accrueYieldFees()
  → _withdrawFromYieldStrategy() → yieldStrategy.withdraw()
      → lastStrategyBalance = yieldStrategy.balanceOf() [SNAPSHOT UPDATE]
  → loanManager.repay() / unwindPosition()
  → collateralAsset.safeTransfer(receiver)
```

### Rebalance Flow
```
Zenji.rebalance()  [no nonReentrant!]
  → yieldStrategy.updateCachedVirtualPrice()
  → ZenjiCoreLib.processRebalanceBounty() [may withdraw from strategy, update LSB]
  → ZenjiCoreLib.rebalance() → loanManager.adjustLtv()
  → _accrueYieldFees()
  → lastStrategyBalance update
```

### Emergency Flow
```
guardian.enterEmergencyMode()
guardian.emergencyStep(step)
  → ZenjiCoreLib.executeEmergencyStep()
    Step 0: yieldStrategy.redeemAll()
    Step 1: loanManager.emergencyRepay() via flash loan
    Step 2: collateral transfer
    Step 3: debt transfer
```

### Harvest Flow
```
Zenji.harvestYield()  [permissionless]
  → yieldStrategy.harvest()
      → BaseCurveStakeDaoStrategy: claimRewards + CRV→crvUSD swap
  → _accrueYieldFees() [updates accumulatedFees, lastStrategyBalance]
```

## External Call Sites (critical)

| Caller | Target | Function | Context |
|--------|--------|----------|---------|
| Zenji | yieldStrategy | deposit, withdraw, withdrawAll, harvest, balanceOf, updateCachedVirtualPrice | Core operations |
| Zenji | loanManager | borrow, repay, unwindPosition, getCollateralValue, getDebtBalance | Core operations |
| Zenji | swapper | swapCollateralForDebt, swapDebtForCollateral | Rebalance, emergency |
| AaveLoanManager | aavePool | supply, borrow, repay, withdraw, flashLoanSimple | All loan ops |
| AaveLoanManager | swapper | swapCollateralForDebt, swapDebtForCollateral | Inside flash callback |
| LlamaLoanManager | llamaLend | create_loan, add_collateral, remove_collateral, repay, borrow_more | All loan ops |
| LlamaLoanManager | ERC3156 flash lender | flashLoan | Emergency repay |
| LlamaLoanManager | swapper | swapCollateralForDebt, swapDebtForCollateral | Inside flash callback |
| BaseLPStrategy | lpPool | add_liquidity, remove_liquidity_one_coin, virtual_price | LP ops |
| BaseLPStrategy | stakingVault | deposit, withdraw, balanceOf | Staking ops |
| BaseCurveStakeDaoStrategy | gauge | claimRewards | Harvest |
| BaseCurveStakeDaoStrategy | crvSwapper | swap | CRV→crvUSD |
| BaseVaultStrategy | yieldVault | deposit, withdraw, balanceOf, convertToAssets | IPOR ops |
| UsdtCrvUsdSwapMixin | _usdtCrvUsdPool | exchange | USDT↔crvUSD swap |
