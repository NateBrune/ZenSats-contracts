# State Variables

> Focus on accumulators, totals, snapshots, mirrors — key for security analysis.

## Zenji.sol (Main Vault)

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| PRECISION | uint256 | 1e18 | |
| DEADBAND_SPREAD | uint256 | 3e16 | 3% |
| MIN_TARGET_LTV | uint256 | 15e16 | 15% |
| MAX_FEE_RATE | uint256 | 2e17 | 20% |
| COOLDOWN_BLOCKS | uint256 | 1 | |
| MAX_REBALANCE_BOUNTY | uint256 | 5e17 | 50% |
| TIMELOCK_DELAY | uint256 | 1 weeks | swapper timelock |
| MAX_VAULT_SLIPPAGE | uint256 | 5e16 | 5% cap |
| ROLE_TRANSFER_DELAY | uint256 | 1 weeks | |
| GOV_GUARDIAN_TRANSFER_DELAY | uint256 | 4 weeks | |
| PARAM_TIMELOCK_DELAY | uint256 | 1 weeks | |
| EMERGENCY_SKIP_DELAY | uint256 | 3 days | |
| MAX_USER_SLIPPAGE | uint256 | 2e17 | 20% |

### Immutables
| Variable | Type | Note |
|----------|------|------|
| collateralAsset | IERC20 | |
| debtAsset | IERC20 | |
| loanManager | ILoanManager | |
| yieldStrategy | IYieldStrategy | |

### Mutable State
| Variable | Type | Visibility | Note (ACCUMULATOR / SNAPSHOT / MIRROR) |
|----------|------|------------|--------------------------------------|
| swapper | ISwapper | public | mutable via timelock |
| targetLtv | uint256 | public | |
| strategist | address | public | |
| gov | address | public | |
| guardian | address | public | |
| idle | bool | public | |
| emergencyMode | bool | public | |
| liquidationComplete | bool | public | |
| emergencyStepsCompleted | uint8 | public | |
| **accumulatedFees** | uint256 | public | **ACCUMULATOR** — running fee total |
| feeRate | uint256 | public | |
| **lastStrategyBalance** | uint256 | public | **SNAPSHOT** — cached strategy balance for fee accrual delta |
| _status | uint256 | private | reentrancy guard |
| pendingStrategist | address | public | |
| pendingGov | address | public | |
| pendingGuardian | address | public | |
| pendingStrategistTimestamp | uint256 | public | |
| pendingGovTimestamp | uint256 | public | |
| pendingGuardianTimestamp | uint256 | public | |
| rebalanceBountyRate | uint256 | public | |
| depositCap | uint256 | public | |
| maxSlippage | uint256 | public | |
| **feesAtLastRebalance** | uint256 | public | **SNAPSHOT** — fees at last rebalance for bounty delta |
| lastInBlock | mapping(address=>uint256) | public | per-user last deposit block |
| depositsPaused | bool | public | |
| rescueRecipient | address | public | |
| pendingSkipTimestamp | uint256[2] | public | emergency skip timelocks |

## AaveLoanManager.sol

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| MAX_DEBT_ORACLE_STALENESS | uint256 | 90000 | 25h — USDT/USD Chainlink heartbeat |
| AAVE_LTV_SCALE | uint256 | 1e4 | |
| VARIABLE_RATE_MODE | uint256 | 2 | |
| SWAP_AMOUNT_BUFFER | uint256 | 105 | 5% buffer |
| DUST_BUFFER | uint256 | 1 | |
| TIMELOCK_DELAY | uint256 | 1 weeks | |
| MIN_HEALTH | int256 | 1.1e18 | 110% health factor |
| MIN_SWAP_OUT_BPS | uint256 | 9500 | 95% of oracle quote |
| DUST_SWAP_THRESHOLD | uint256 | 1000 | |

### Immutables
| Variable | Type | Note |
|----------|------|------|
| collateralToken | IERC20 | |
| debtToken | IERC20 | |
| aToken | IERC20 | |
| variableDebtToken | IERC20 | |
| aavePool | IAavePool | |
| collateralOracle | IChainlinkOracle | |
| debtOracle | IChainlinkOracle | |
| DUST_THRESHOLD | uint256 | |
| MIN_ROUTABLE_DEBT | uint256 | |
| maxLtvBps | uint256 | |
| liquidationThresholdBps | uint256 | |
| maxCollateralOracleStaleness | uint256 | |

### Mutable State
| Variable | Type | Visibility | Note |
|----------|------|------------|------|
| vault | address | public | set once via initVault |
| initializer | address | public | |
| swapper | ISwapper | public | |
| _status | uint256 | private | reentrancy guard |

## LlamaLoanManager.sol

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| MAX_ORACLE_STALENESS | uint256 | 3600 | 1h |
| MAX_DEBT_ORACLE_STALENESS | uint256 | 25200 | 7h |
| DUST_THRESHOLD | uint256 | 1e18 | |
| DEFAULT_LOAN_BANDS | uint256 | 4 | |
| COLLATERAL_SWAP_SLIPPAGE | uint256 | 5e16 | 5% |
| WITHDRAW_COLLATERAL_BUFFER | uint256 | 115 | 15% buffer |
| SWAP_AMOUNT_BUFFER | uint256 | 105 | 5% buffer |
| MIN_HEALTH | int256 | 1e17 | 10% |
| MIN_SWAP_OUT_BPS | uint256 | 9500 | 95% |
| DEBT_FLASH_LENDER | address | 0x26dE... | crvUSD ERC3156 flash lender |

### Immutables / Key Addresses
| Variable | Type | Note |
|----------|------|------|
| collateralToken | IERC20 | |

## BaseYieldStrategy.sol

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| MIN_SLIPPAGE | uint256 | 1e15 | 0.1% |
| DEFAULT_SLIPPAGE | uint256 | 1e16 | 1% |
| MAX_SLIPPAGE | uint256 | 5e16 | 5% |
| EMERGENCY_SLIPPAGE | uint256 | 1e17 | 10% |

### Mutable State
| Variable | Type | Visibility | Note |
|----------|------|------------|------|
| debtAsset | IERC20 | public immutable | |
| vault | address | public | set once |
| initializer | address | public | |
| **_costBasis** | uint256 | internal | **ACCUMULATOR** — cumulative debt deposited into strategy |
| owner | address | public | |
| slippageTolerance | uint256 | public | |

## BaseLPStrategy.sol

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| LP_SLIPPAGE | uint256 | 5e15 | 0.5% |
| MAX_VP_DEVIATION | uint256 | 5e15 | 0.5% |
| MAX_VP_STALENESS | uint256 | 1 days | |

### Mutable State
| Variable | Type | Visibility | Note |
|----------|------|------------|------|
| lpToken | IERC20 | public immutable | |
| lpAsset | IERC20 | public immutable | |
| stakingVault | IYieldVault | public immutable | |
| **cachedVirtualPrice** | uint256 | public | **SNAPSHOT** — cached Curve pool VP for balanceOf() |
| **lastVpUpdate** | uint256 | public | **TIMESTAMP** — when cachedVirtualPrice was last set |

## BaseCurveStakeDaoStrategy.sol

### State
| Variable | Type | Visibility | Note |
|----------|------|------------|------|
| CRVUSD | IERC20 | public constant | 0xf939... |
| crv | IERC20 | public constant | 0xD533... |
| lpPool | ICurveLpShared | public immutable | |
| lpCrvUsdIndex | int128 | public immutable | |
| gauge | address | public immutable | |
| crvSwapper | ICrvSwapper | public immutable | |
| crvUsdOracle | IChainlinkOracle | public immutable | |
| crvOracle | IChainlinkOracle | public immutable | |

## UsdtCrvUsdSwapMixin.sol

### Constants
| Variable | Type | Value | Note |
|----------|------|-------|------|
| MAX_USDT_CRVUSD_STALENESS | uint256 | 90000 | 25h |

### Immutables
| Variable | Type | Note |
|----------|------|------|
| _usdt | IERC20 | |
| _crvUsd | IERC20 | |
| _usdtCrvUsdPool | ICurveStableSwap | |
| _usdtOracle | IChainlinkOracle | |
| _crvUsdOracle | IChainlinkOracle | |
| _usdtIndex | int128 | |
| _crvUsdIndex | int128 | |

## BaseSwapper.sol

### Mutable State
| Variable | Type | Visibility | Note |
|----------|------|------------|------|
| slippage | uint256 | public | |
| gov | address | public | |
| pendingGov | address | public | |
| vault | address | public | |
