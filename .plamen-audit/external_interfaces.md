# External Interfaces

> Source: src/interfaces/ directory (34 interface files)

## DeFi Protocol Integrations

### Aave V3
| Interface | File | Key Functions |
|-----------|------|--------------|
| IAavePool | src/interfaces/IAavePool.sol | supply, borrow, repay, withdraw, flashLoanSimple, getUserAccountData |
| IFlashLoanSimpleReceiver | src/interfaces/IFlashLoanSimpleReceiver.sol | executeOperation callback |

### LlamaLend (Curve)
| Interface | File | Key Functions |
|-----------|------|--------------|
| ILlamaLendController | src/interfaces/ILlamaLendController.sol | create_loan, add_collateral, remove_collateral, repay, borrow_more, health |

### Curve Finance
| Interface | File | Key Functions |
|-----------|------|--------------|
| ICurveStableSwap | src/interfaces/ICurveStableSwap.sol | exchange, get_dy, add_liquidity, remove_liquidity_one_coin |
| ICurveStableSwapNG | src/interfaces/ICurveStableSwapNG.sol | exchange, get_dy, add_liquidity, remove_liquidity_one_coin |
| ICurveStableSwapTwoLP | src/interfaces/ICurveStableSwapTwoLP.sol | |
| ICurveStableSwapWithReceiver | src/interfaces/ICurveStableSwapWithReceiver.sol | |
| ICurveTwoCrypto | src/interfaces/ICurveTwoCrypto.sol | exchange, get_dy |
| ICurveTwoCryptoInt128 | src/interfaces/ICurveTwoCryptoInt128.sol | exchange with int128 indices |
| ICurveThreeCrypto | src/interfaces/ICurveThreeCrypto.sol | exchange |
| ICurveTriCrypto | src/interfaces/ICurveTriCrypto.sol | exchange |
| ICurveLpShared | src/interfaces/ICurveLpShared.sol | virtual_price, get_virtual_price |
| ICurveLP | src/interfaces/ICurveLP.sol | |
| ICurveRegistry | src/interfaces/ICurveRegistry.sol | |
| ICurveRewardVault | src/interfaces/ICurveRewardVault.sol | |

### Chainlink
| Interface | File | Key Functions |
|-----------|------|--------------|
| IChainlinkOracle | src/interfaces/IChainlinkOracle.sol | latestRoundData, decimals |

### IPOR Protocol
| Interface | File | Key Functions |
|-----------|------|--------------|
| IYieldVault | src/interfaces/IYieldVault.sol | deposit, withdraw, balanceOf, convertToAssets |
| IPlasmaVault | src/interfaces/IPlasmaVault.sol | |

### Stake DAO
| Interface | File | Key Functions |
|-----------|------|--------------|
| IStakeDaoRewardVault | src/interfaces/IStakeDaoRewardVault.sol | deposit, withdraw, claimRewards |
| IStakeDaoClaimRewards | src/interfaces/IStakeDaoClaimRewards.sol | claimRewards |
| IStakeDaoVault | src/interfaces/IStakeDaoVault.sol | |
| IAccountant | src/interfaces/IAccountant.sol | |

### Uniswap
| Interface | File | Key Functions |
|-----------|------|--------------|
| ISwapRouter | src/interfaces/ISwapRouter.sol | exactInputSingle, exactInput |
| IUniversalRouter | src/interfaces/IUniversalRouter.sol | execute |
| IUniswapV2Router | src/interfaces/IUniswapV2Router.sol | |
| IUniswapV2Pair | src/interfaces/IUniswapV2Pair.sol | |

## Internal Protocol Interfaces

| Interface | File | Implemented By |
|-----------|------|---------------|
| ILoanManager | src/interfaces/ILoanManager.sol | AaveLoanManager, LlamaLoanManager |
| ILlamaLoanManager | src/interfaces/ILlamaLoanManager.sol | LlamaLoanManager |
| IYieldStrategy | src/interfaces/IYieldStrategy.sol | All strategy contracts |
| ISwapper | src/interfaces/ISwapper.sol | All swapper contracts |
| IStrategy | src/interfaces/IStrategy.sol | |
| ICrvSwapper | src/interfaces/ICrvSwapper.sol | CrvToCrvUsdSwapper |
| IAllocator | src/interfaces/IAllocator.sol | |
| IERC20 | src/interfaces/IERC20.sol | |
| IERC4626 | src/interfaces/IERC4626.sol | |
| AutomationCompatibleInterface | src/interfaces/AutomationCompatibleInterface.sol | ZenjiRebalanceKeeper |

## Key External Contract Addresses (from constants in code)
| Contract | Address | Usage |
|----------|---------|-------|
| CrvUSD | 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E | Strategy base token |
| CRV | 0xD533a949740bb3306d119CC777fa900bA034cd52 | Reward token |
| DEBT_FLASH_LENDER (crvUSD) | 0x26dE7861e213A5351F6ED767d00e0839930e9eE1 | LlamaLoanManager ERC3156 |
