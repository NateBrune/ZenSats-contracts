// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IAavePool } from "../interfaces/IAavePool.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { IFlashLoanSimpleReceiver } from "../interfaces/IFlashLoanSimpleReceiver.sol";
import { ILoanManager } from "../interfaces/ILoanManager.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { TimelockLib } from "../libraries/TimelockLib.sol";
import { OracleLib } from "../libraries/OracleLib.sol";

/// @title AaveLoanManager
/// @notice Manages Aave V3 collateralized borrowing positions for Zenji
/// @dev Uses Chainlink oracles for collateral/debt valuation
contract AaveLoanManager is ILoanManager, IFlashLoanSimpleReceiver {
    using SafeTransferLib for IERC20;
    using TimelockLib for TimelockLib.AddressTimelockData;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000; // 25 hours for USDT/USD (Chainlink heartbeat is 24h)
    uint256 public constant AAVE_LTV_SCALE = 1e4;
    uint256 public constant VARIABLE_RATE_MODE = 2;
    uint16 public constant AAVE_REFERRAL_CODE = 0;
    uint256 public constant SWAP_AMOUNT_BUFFER = 105;
    uint256 public constant DUST_BUFFER = 1;
    uint256 public constant DUST_THRESHOLD = 1e6;
    uint256 public constant TIMELOCK_DELAY = 1 weeks;
    int256 public constant MIN_HEALTH = 1.1e18;
    uint256 public constant MIN_SWAP_OUT_BPS = 9500; // 95% of oracle quote
    /// @notice Collateral amounts below this threshold skip slippage enforcement.
    /// At 1000 sat input the Uniswap V3 0.3% pool rounds its 3-sat fee to 1 sat (0.1%
    /// effective, within tolerance). Below 334 sat the 1-sat minimum fee exceeds 0.3%
    /// of input, so oracle-based minOut checks are unreliable and must be waived.
    uint256 public constant DUST_SWAP_THRESHOLD = 1000;

    // ============ Immutables ============

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    IERC20 public immutable aToken;
    IERC20 public immutable variableDebtToken;
    IAavePool public immutable aavePool;
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;
    address public vault;
    address public initializer;
    ISwapper public swapper;

    // Timelock state
    TimelockLib.AddressTimelockData internal _swapperTimelock;

    // Aave risk params (basis points)
    uint256 public immutable maxLtvBps;
    uint256 public immutable liquidationThresholdBps;
    /// @notice Staleness window for the collateral oracle (seconds). Set to the
    ///         Chainlink heartbeat of the collateral feed plus a small buffer.
    ///         e.g. BTC/USD = 3600 (1 h), XAU/USD = 90000 (25 h).
    uint256 public immutable maxCollateralOracleStaleness;

    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);
    event SwapperChangeProposed(
        address indexed currentSwapper, address indexed newSwapper, uint256 effectiveTime
    );
    event SwapperChangeCancelled(address indexed cancelledSwapper);
    event VaultInitialized(address indexed vault);

    error InsufficientFlashloanRepayment();
    error HealthTooLow();
    error SwapperUnderperformed(uint256 expected, uint256 received);

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _collateralAsset,
        address _debtAsset,
        address _aToken,
        address _variableDebtToken,
        address _aavePool,
        address _collateralOracle,
        address _debtOracle,
        address _swapper,
        uint256 _maxLtvBps,
        uint256 _liquidationThresholdBps,
        address _vault,
        uint8 _emodeCategory,
        uint256 _maxCollateralStaleness
    ) {
        if (
            _collateralAsset == address(0) || _debtAsset == address(0) || _aToken == address(0)
                || _variableDebtToken == address(0) || _aavePool == address(0)
                || _collateralOracle == address(0) || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_maxLtvBps == 0 || _liquidationThresholdBps == 0) revert InvalidAddress();
        if (_maxCollateralStaleness == 0) revert InvalidAddress();

        collateralToken = IERC20(_collateralAsset);
        debtToken = IERC20(_debtAsset);
        aToken = IERC20(_aToken);
        variableDebtToken = IERC20(_variableDebtToken);
        aavePool = IAavePool(_aavePool);
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
        maxLtvBps = _maxLtvBps;
        liquidationThresholdBps = _liquidationThresholdBps;
        maxCollateralOracleStaleness = _maxCollateralStaleness;
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
        swapper = ISwapper(_swapper);
        if (_emodeCategory > 0) {
            aavePool.setUserEMode(_emodeCategory);
        }
    }

    /// @notice Initializes the vault address exactly once.
    /// @param _vault Vault contract authorized to call state-changing methods.
    function initializeVault(address _vault) external {
        if (vault != address(0)) revert InvalidAddress();
        if (_vault == address(0)) revert InvalidAddress();
        if (msg.sender != initializer) revert Unauthorized();

        vault = _vault;
        initializer = address(0);
        emit VaultInitialized(_vault);
    }

    // ============ Loan Management Functions ============

    /// @inheritdoc ILoanManager
    function createLoan(uint256 collateral, uint256 debt) external onlyVault {
        if (collateral == 0) revert ZeroAmount();
        _checkOracleFreshness();

        _ensureApprove(address(collateralToken), address(aavePool), collateral);
        aavePool.supply(address(collateralToken), collateral, address(this), AAVE_REFERRAL_CODE);

        if (debt > 0) {
            aavePool.borrow(
                address(debtToken), debt, VARIABLE_RATE_MODE, AAVE_REFERRAL_CODE, address(this)
            );
        }

        if (debt > 0) {
            int256 health = this.getHealth();
            if (health < MIN_HEALTH) revert HealthTooLow();
        }

        emit LoanCreated(collateral, debt, 0);
    }

    /// @inheritdoc ILoanManager
    function addCollateral(uint256 collateral) external onlyVault {
        if (collateral == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(collateralToken), address(aavePool), collateral);
        aavePool.supply(address(collateralToken), collateral, address(this), AAVE_REFERRAL_CODE);
        emit CollateralAdded(collateral);
    }

    /// @inheritdoc ILoanManager
    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        if (collateral == 0 && debt == 0) revert ZeroAmount();
        _checkOracleFreshness();
        if (collateral > 0) {
            _ensureApprove(address(collateralToken), address(aavePool), collateral);
            aavePool.supply(address(collateralToken), collateral, address(this), AAVE_REFERRAL_CODE);
        }
        if (debt > 0) {
            aavePool.borrow(
                address(debtToken), debt, VARIABLE_RATE_MODE, AAVE_REFERRAL_CODE, address(this)
            );
        }
        if (debt > 0) {
            int256 health = this.getHealth();
            if (health < MIN_HEALTH) revert HealthTooLow();
        }

        emit LoanBorrowedMore(collateral, debt);
    }

    /// @inheritdoc ILoanManager
    function repayDebt(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(debtToken), address(aavePool), amount);
        aavePool.repay(address(debtToken), amount, VARIABLE_RATE_MODE, address(this));
        emit LoanRepaid(amount);
    }

    /// @inheritdoc ILoanManager
    function removeCollateral(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        aavePool.withdraw(address(collateralToken), amount, address(this));
        if (variableDebtToken.balanceOf(address(this)) > 0) {
            int256 health = this.getHealth();
            if (health < MIN_HEALTH) revert HealthTooLow();
        }
        emit CollateralRemoved(amount);
    }

    /// @inheritdoc ILoanManager
    function unwindPosition(uint256 collateralNeeded) external onlyVault {
        bool fullyClose = (collateralNeeded == type(uint256).max);
        _checkOracleFreshness();

        uint256 collateral = aToken.balanceOf(address(this));
        uint256 debt = variableDebtToken.balanceOf(address(this));
        if (collateral == 0 && debt == 0) return;

        uint256 debtToRepay =
            fullyClose ? debt : (collateral > 0 ? (debt * collateralNeeded) / collateral : 0);

        uint256 debtBalance = debtToken.balanceOf(address(this));
        uint256 repayNow = debtToRepay < debtBalance ? debtToRepay : debtBalance;
        if (repayNow > 0) {
            _ensureApprove(address(debtToken), address(aavePool), repayNow);
            aavePool.repay(address(debtToken), repayNow, VARIABLE_RATE_MODE, address(this));
        }

        uint256 remainingDebt = variableDebtToken.balanceOf(address(this));
        // For partial unwinds: only flashloan if the proportional debt wasn't fully repaid.
        // The remaining Aave debt stays backed by remaining collateral.
        uint256 unrepaidDebt = debtToRepay > repayNow ? debtToRepay - repayNow : 0;
        bool needFlashloan;
        if (fullyClose) {
            needFlashloan = remainingDebt > 0;
        } else if (!_isDustDebt(unrepaidDebt)) {
            needFlashloan = true;
        } else if (remainingDebt > 0) {
            // Dust unrepaid debt but Aave still has remaining debt.
            // Check if remaining collateral can safely back that debt.
            uint256 remainingCollateral =
                collateral > collateralNeeded ? collateral - collateralNeeded : 0;
            uint256 remainingCollateralUsd = _getCollateralUsdValue(remainingCollateral);
            uint256 remainingDebtUsd = _getDebtUsdValue(remainingDebt);
            // Health factor: (collateralUsd * liquidationThreshold) / debtUsd must be >= 1e18
            if (remainingCollateralUsd * liquidationThresholdBps * 1e14 < remainingDebtUsd * 1e18) {
                // Withdrawing would violate health factor — escalate to full close
                needFlashloan = true;
                fullyClose = true;
            }
        }
        if (needFlashloan) {
            uint256 flashDebt = fullyClose ? remainingDebt : unrepaidDebt;
            uint256 flashloanAmount = (flashDebt * 10300) / 10000;
            bytes memory data = abi.encode(collateralNeeded, fullyClose);
            aavePool.flashLoanSimple(
                address(this), address(debtToken), flashloanAmount, data, AAVE_REFERRAL_CODE
            );

            if (fullyClose && variableDebtToken.balanceOf(address(this)) > 0) {
                revert DebtNotFullyRepaid();
            }
            uint256 idleCollateral = collateralToken.balanceOf(address(this));
            if (idleCollateral > 0) {
                collateralToken.safeTransfer(vault, idleCollateral);
            }
            return;
        }

        if (fullyClose) {
            if (variableDebtToken.balanceOf(address(this)) > 0) revert DebtNotFullyRepaid();
            aavePool.withdraw(address(collateralToken), type(uint256).max, vault);
        } else if (collateralNeeded > 0) {
            aavePool.withdraw(address(collateralToken), collateralNeeded, vault);
        }

        uint256 idleAfter = collateralToken.balanceOf(address(this));
        if (idleAfter > 0) {
            collateralToken.safeTransfer(vault, idleAfter);
        }
    }

    /// @inheritdoc IFlashLoanSimpleReceiver
    function executeOperation(
        address asset_,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata data
    ) external override returns (bool) {
        // ── Access control ──
        if (msg.sender != address(aavePool)) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        if (asset_ != address(debtToken)) revert InvalidAddress();

        (uint256 collateralNeeded, bool fullyClose) = abi.decode(data, (uint256, bool));
        uint256 repaymentNeeded = amount + premium;

        // ── Step 1: Repay Aave debt ──
        // Use all available debt tokens (flash loan proceeds) to repay.
        // For fullyClose we pass type(uint256).max so Aave handles the
        // exact-to-the-wei calculation internally, avoiding the 1-wei
        // rounding edge case from interest accrual between balanceOf reads.
        uint256 debt = variableDebtToken.balanceOf(address(this));
        if (debt > 0) {
            uint256 debtBal = debtToken.balanceOf(address(this));
            uint256 toRepay;
            if (fullyClose) {
                // type(uint256).max tells Aave "repay everything I owe",
                // but we can only spend what we hold.
                toRepay = debt < debtBal ? debt : debtBal;
                if (toRepay == debt) {
                    // We have enough to clear it all — let Aave handle rounding
                    _ensureApprove(address(debtToken), address(aavePool), type(uint256).max);
                    aavePool.repay(address(debtToken), type(uint256).max, VARIABLE_RATE_MODE, address(this));
                } else {
                    // Not enough to cover full debt — repay what we can
                    _ensureApprove(address(debtToken), address(aavePool), toRepay);
                    aavePool.repay(address(debtToken), toRepay, VARIABLE_RATE_MODE, address(this));
                }
            } else {
                toRepay = debt < debtBal ? debt : debtBal;
                if (toRepay > 0) {
                    _ensureApprove(address(debtToken), address(aavePool), toRepay);
                    aavePool.repay(address(debtToken), toRepay, VARIABLE_RATE_MODE, address(this));
                }
            }

            // Defensive: handle 1-wei residual from interest accrual between reads
            uint256 residual = variableDebtToken.balanceOf(address(this));
            if (residual > 0 && residual <= 2) {
                uint256 remaining = debtToken.balanceOf(address(this));
                if (remaining >= residual) {
                    _ensureApprove(address(debtToken), address(aavePool), residual);
                    aavePool.repay(address(debtToken), residual, VARIABLE_RATE_MODE, address(this));
                }
            }
        }

        // ── Step 2: Withdraw collateral from Aave ──
        if (fullyClose) {
            aavePool.withdraw(address(collateralToken), type(uint256).max, address(this));
        } else if (collateralNeeded > 0) {
            aavePool.withdraw(address(collateralToken), collateralNeeded, address(this));
        }

        // ── Step 3: Ensure we can repay the flash loan ──
        uint256 debtAvailable = debtToken.balanceOf(address(this));
        if (debtAvailable < repaymentNeeded) {
            if (address(swapper) == address(0)) revert InvalidAddress();

            uint256 shortfall = repaymentNeeded - debtAvailable;
            uint256 collateralQuote = _getDebtValue(shortfall);
            uint256 collateralNeededForSwap =
                (collateralQuote * SWAP_AMOUNT_BUFFER) / 100 + DUST_BUFFER;
            uint256 collateralBal = collateralToken.balanceOf(address(this));
            uint256 toSwap =
                collateralNeededForSwap < collateralBal ? collateralNeededForSwap : collateralBal;

            if (toSwap > 0) {
                uint256 debtBefore = debtToken.balanceOf(address(this));
                // Skip oracle-based slippage floor for dust swaps: integer fee rounding
                // in the V3 pool makes the effective fee exceed any oracle estimate.
                uint256 expectedDebt = toSwap >= DUST_SWAP_THRESHOLD
                    ? (_getCollateralValue(toSwap) * MIN_SWAP_OUT_BPS) / 10000
                    : 0;
                collateralToken.safeTransfer(address(swapper), toSwap);
                swapper.swapCollateralForDebt(toSwap);
                uint256 debtDelta = debtToken.balanceOf(address(this)) - debtBefore;
                if (expectedDebt > 0 && debtDelta < expectedDebt) {
                    revert SwapperUnderperformed(expectedDebt, debtDelta);
                }
            }

            // Defensive: if oracle underestimated and we're still short,
            // sweep ALL remaining collateral as a last resort.
            if (debtToken.balanceOf(address(this)) < repaymentNeeded) {
                uint256 remainingCollateral = collateralToken.balanceOf(address(this));
                if (remainingCollateral > 0) {
                    collateralToken.safeTransfer(address(swapper), remainingCollateral);
                    swapper.swapCollateralForDebt(remainingCollateral);
                }
            }
        }

        // ── Step 4: Final assertion ──
        if (debtToken.balanceOf(address(this)) < repaymentNeeded) {
            revert InsufficientFlashloanRepayment();
        }

        _ensureApprove(address(debtToken), address(aavePool), repaymentNeeded);
        return true;
    }

    /// @notice Propose a new swapper (requires timelock)
    function proposeSwapper(address newSwapper) external onlyVault {
        if (newSwapper == address(0)) revert InvalidAddress();
        _swapperTimelock.proposeAddress(newSwapper, TIMELOCK_DELAY);
        emit SwapperChangeProposed(address(swapper), newSwapper, _swapperTimelock.timestamp);
    }

    /// @notice Execute pending swapper change after timelock
    function executeSwapper() external onlyVault {
        address oldSwapper = address(swapper);
        swapper = ISwapper(_swapperTimelock.executeAddress());
        emit SwapperUpdated(oldSwapper, address(swapper));
    }

    /// @notice Cancel pending swapper change
    function cancelSwapper() external onlyVault {
        address cancelled = _swapperTimelock.cancelAddress();
        emit SwapperChangeCancelled(cancelled);
    }

    // ============ View Functions ============

    /// @inheritdoc ILoanManager
    function getCurrentLTV() external view returns (uint256 ltv) {
        uint256 collateral = aToken.balanceOf(address(this));
        uint256 debt = variableDebtToken.balanceOf(address(this));
        if (collateral == 0 || debt == 0) return 0;

        uint256 collateralValue = _getCollateralValue(collateral);
        if (collateralValue == 0) return 0;
        ltv = (debt * PRECISION) / collateralValue;
    }

    /// @inheritdoc ILoanManager
    function getCurrentCollateral() external view returns (uint256 collateral) {
        return aToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function getCurrentDebt() external view returns (uint256 debt) {
        return variableDebtToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function collateralAsset() external view returns (address) {
        return address(collateralToken);
    }

    /// @inheritdoc ILoanManager
    function debtAsset() external view returns (address) {
        return address(debtToken);
    }

    /// @inheritdoc ILoanManager
    function getHealth() external view returns (int256 health) {
        uint256 collateral = aToken.balanceOf(address(this));
        uint256 debt = variableDebtToken.balanceOf(address(this));
        if (collateral == 0 && debt == 0) return type(int256).max;

        uint256 collateralUsd = _getCollateralUsdValue(collateral);
        uint256 debtUsd = _getDebtUsdValue(debt);
        if (debtUsd == 0) return type(int256).max;

        uint256 hf = (collateralUsd * liquidationThresholdBps * 1e14) / debtUsd;
        return int256(hf);
    }

    /// @inheritdoc ILoanManager
    function loanExists() external view returns (bool exists) {
        return aToken.balanceOf(address(this)) > 0 || variableDebtToken.balanceOf(address(this)) > 0;
    }

    /// @inheritdoc ILoanManager
    function getCollateralValue(uint256 collateralAmount) external view returns (uint256 value) {
        return _getCollateralValue(collateralAmount);
    }

    /// @inheritdoc ILoanManager
    function getDebtValue(uint256 debtAmount) external view returns (uint256 value) {
        return _getDebtValue(debtAmount);
    }

    /// @inheritdoc ILoanManager
    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        view
        returns (uint256 borrowAmount)
    {
        uint256 collateralValue = _getCollateralValue(collateral);
        return (collateralValue * targetLtv) / PRECISION;
    }

    /// @inheritdoc ILoanManager
    function healthCalculator(int256 dCollateral, int256 dDebt)
        external
        view
        returns (int256 health)
    {
        uint256 collateral = aToken.balanceOf(address(this));
        uint256 debt = variableDebtToken.balanceOf(address(this));

        if (dCollateral < 0) {
            collateral -= uint256(-dCollateral);
        } else {
            collateral += uint256(dCollateral);
        }

        if (dDebt < 0) {
            debt -= uint256(-dDebt);
        } else {
            debt += uint256(dDebt);
        }

        if (debt == 0) return type(int256).max;

        uint256 collateralUsd = _getCollateralUsdValue(collateral);
        uint256 debtUsd = _getDebtUsdValue(debt);
        if (debtUsd == 0) return type(int256).max;

        uint256 hf = (collateralUsd * liquidationThresholdBps * 1e14) / debtUsd;
        return int256(hf);
    }

    /// @inheritdoc ILoanManager
    function minCollateral(uint256 debt_, uint256) external view returns (uint256) {
        if (debt_ == 0) return 0;
        uint256 debtInCollateral = _getDebtValue(debt_);
        return (debtInCollateral * AAVE_LTV_SCALE + maxLtvBps - 1) / maxLtvBps;
    }

    /// @inheritdoc ILoanManager
    function getPositionValues()
        external
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        collateralValue = aToken.balanceOf(address(this));
        debtValue = variableDebtToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function getNetCollateralValue() external view returns (uint256 value) {
        uint256 collateral = aToken.balanceOf(address(this));
        uint256 debt = variableDebtToken.balanceOf(address(this));
        if (collateral == 0) return 0;

        uint256 debtInCollateral = _getDebtValue(debt);
        return collateral > debtInCollateral ? collateral - debtInCollateral : 0;
    }

    /// @inheritdoc ILoanManager
    function checkOracleFreshness() external view {
        _checkOracleFreshness();
    }

    // ============ Token Management ============

    /// @inheritdoc ILoanManager
    function transferCollateral(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        uint256 idle = collateralToken.balanceOf(address(this));
        if (idle >= amount) {
            collateralToken.safeTransfer(to, amount);
            return;
        }
        if (idle > 0) {
            collateralToken.safeTransfer(to, idle);
            amount -= idle;
        }
        if (amount > 0) {
            aavePool.withdraw(address(collateralToken), amount, to);
        }
    }

    /// @inheritdoc ILoanManager
    function transferDebt(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        debtToken.safeTransfer(to, amount);
    }

    /// @inheritdoc ILoanManager
    function getCollateralBalance() external view returns (uint256 balance) {
        return collateralToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function getDebtBalance() external view returns (uint256 balance) {
        return debtToken.balanceOf(address(this));
    }

    // ============ Internal Helpers ============

    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }

    function _isDustDebt(uint256 debt) internal pure returns (bool) {
        return debt <= DUST_THRESHOLD;
    }

    function _checkOracleFreshness() internal view {
        OracleLib.checkOracleFreshness(
            collateralOracle, maxCollateralOracleStaleness, debtOracle, MAX_DEBT_ORACLE_STALENESS
        );
    }

    function _getCollateralValue(uint256 collateralAmount) internal view returns (uint256) {
        return OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
    }

    function _getDebtValue(uint256 debtAmount) internal view returns (uint256) {
        return OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
    }

    function _getCollateralUsdValue(uint256 collateralAmount) internal view returns (uint256) {
        return OracleLib.getCollateralUsdValue(
            collateralAmount, collateralOracle, maxCollateralOracleStaleness, collateralToken
        );
    }

    function _getDebtUsdValue(uint256 debtAmount) internal view returns (uint256) {
        return
            OracleLib.getDebtUsdValue(debtAmount, debtOracle, MAX_DEBT_ORACLE_STALENESS, debtToken);
    }
}
