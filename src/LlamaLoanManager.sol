// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ILlamaLendController } from "./interfaces/ILlamaLendController.sol";
import { IChainlinkOracle } from "./interfaces/IChainlinkOracle.sol";
import { ICurveTwoCrypto } from "./interfaces/ICurveTwoCrypto.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { LlamaOracleLib } from "./libraries/LlamaOracleLib.sol";

/// @title LlamaLoanManager
/// @notice Manages LlamaLend loan positions for the Zenji
/// @dev Handles all interactions with LlamaLend: create, borrow, repay, remove collateral
/// @dev Also handles collateral <-> debt swaps via TwoCrypto pool
contract LlamaLoanManager is ILoanManager, IERC3156FlashBorrower {
    using SafeTransferLib for IERC20;
    using TimelockLib for TimelockLib.AddressTimelockData;

    // ============ Constants ============

    /// @notice Precision for percentage calculations (100% = 1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Timelock delay for swapper changes (2 days)
    uint256 public constant TIMELOCK_DELAY = 2 days;

    /// @notice Number of bands for LlamaLend loans
    uint256 public constant LLAMALEND_BANDS = 4;

    /// @notice Minimum collateral units for LlamaLend loans
    uint256 public constant MIN_COLLATERAL_UNITS = (((LLAMALEND_BANDS * 1000) * 105) / 100); // 4 bands * 1000 units + 5% buffer

    /// @notice Minimum health factor required (1.0 = 1e18)
    int256 public constant MIN_HEALTH = 1e17;

    /// @notice Maximum acceptable collateral/USD oracle staleness (1 hour)
    uint256 public constant MAX_ORACLE_STALENESS = 3600;

    /// @notice Maximum acceptable debt/USD oracle staleness (7 hours — heartbeat is 6 hours)
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 25200;

    /// @notice Dust threshold in debt asset (1 USD) - below this we leave position with safe collateral
    uint256 public constant DUST_THRESHOLD = 1e18;

    /// @notice Safety multiplier for dust collateral (4x debt = 25% LTV)
    uint256 public constant DUST_SAFETY_MULTIPLIER = 4;

    /// @notice Slippage tolerance for collateral swaps (5%)
    uint256 public constant COLLATERAL_SWAP_SLIPPAGE = 5e16;

    /// @notice Buffer for collateral withdrawal calculation (115% = keep extra collateral for safety)
    uint256 public constant WITHDRAW_COLLATERAL_BUFFER = 115;

    /// @notice Buffer for swap amount calculation (105% = swap slightly more to cover slippage)
    uint256 public constant SWAP_AMOUNT_BUFFER = 105;

    /// @notice Small dust buffer to handle rounding (100 units)
    uint256 public constant DUST_BUFFER = 100;

    /// @notice Collateral/debt TwoCrypto pool indices
    uint256 public constant TWOCRYPTO_COLLATERAL_INDEX = 1;
    uint256 public constant TWOCRYPTO_DEBT_INDEX = 0;

    /// @notice Debt flash lender for underwater position unwinding
    address public constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
    bytes32 private constant FLASH_LOAN_CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Temporary state for flashloan callback
    struct UnwindContext {
        uint256 collateralNeeded;
        bool fullyClose;
    }

    error InsufficientFlashloanRepayment();
    error HealthTooLow();

    event PositionUnwound(
        uint256 collateralRequested, uint256 debtRepaid, uint256 collateralRemoved
    );
    event CollateralSwapped(uint256 collateralIn, uint256 debtOut);
    event DebtSwapped(uint256 debtIn, uint256 collateralOut);
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);
    event SwapperChangeProposed(
        address indexed currentSwapper, address indexed newSwapper, uint256 effectiveTime
    );
    event SwapperChangeCancelled(address indexed cancelledSwapper);
    event VaultInitialized(address indexed vault);

    // ============ Immutables ============

    /// @notice Collateral token
    IERC20 public immutable collateralToken;

    /// @notice Debt token
    IERC20 public immutable debtToken;

    /// @notice LlamaLend controller for collateral/debt market
    ILlamaLendController public immutable llamaLend;

    /// @notice Collateral/debt TwoCrypto pool for collateral liquidation
    ICurveTwoCrypto public immutable collateralDebtPool;

    /// @notice Chainlink collateral/USD oracle
    IChainlinkOracle public immutable collateralOracle;

    /// @notice Chainlink debt/USD oracle
    IChainlinkOracle public immutable debtOracle;

    /// @notice The vault that owns this loan manager
    address public vault;

    /// @notice The address authorized to initialize the vault (deployer)
    address public initializer;

    /// @notice Swapper for collateral/debt conversions
    ISwapper public swapper;

    /// @notice Timelock state for swapper changes
    TimelockLib.AddressTimelockData internal _swapperTimelock;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _collateralAsset,
        address _debtAsset,
        address _llamaLend,
        address _collateralDebtPool,
        address _collateralOracle,
        address _debtOracle,
        address _swapper,
        address _vault
    ) {
        if (
            _collateralAsset == address(0) || _debtAsset == address(0) || _llamaLend == address(0)
                || _collateralDebtPool == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }

        collateralToken = IERC20(_collateralAsset);
        debtToken = IERC20(_debtAsset);
        llamaLend = ILlamaLendController(_llamaLend);
        collateralDebtPool = ICurveTwoCrypto(_collateralDebtPool);
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
        swapper = ISwapper(_swapper);
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
    }

    /// @notice Initialize the vault address (can only be called once by deployer)
    /// @param _vault The vault address to set
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
    function createLoan(uint256 collateral, uint256 debt, uint256 bands) external onlyVault {
        _checkOracleFreshness();
        _ensureApprove(address(collateralToken), address(llamaLend), collateral);
        llamaLend.create_loan(collateral, debt, bands);

        int256 health = this.getHealth();
        if (health < MIN_HEALTH) revert HealthTooLow();

        emit LoanCreated(collateral, debt, bands);
    }

    /// @inheritdoc ILoanManager
    function addCollateral(uint256 collateral) external onlyVault {
        if (collateral == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(collateralToken), address(llamaLend), collateral);
        llamaLend.add_collateral(collateral);
        emit CollateralAdded(collateral);
    }

    /// @inheritdoc ILoanManager
    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        if (collateral == 0 && debt == 0) revert ZeroAmount();
        _checkOracleFreshness();
        if (collateral > 0) {
            _ensureApprove(address(collateralToken), address(llamaLend), collateral);
        }
        llamaLend.borrow_more(collateral, debt);

        int256 health = this.getHealth();
        if (health < MIN_HEALTH) revert HealthTooLow();

        emit LoanBorrowedMore(collateral, debt);
    }

    /// @inheritdoc ILoanManager
    function repayDebt(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(debtToken), address(llamaLend), amount);
        llamaLend.repay(amount);
        emit LoanRepaid(amount);
    }

    /// @inheritdoc ILoanManager
    function removeCollateral(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        llamaLend.remove_collateral(amount);
        emit CollateralRemoved(amount);
    }

    /// @inheritdoc ILoanManager
    function unwindPosition(uint256 collateralNeeded) external onlyVault {
        bool fullyClose = (collateralNeeded == type(uint256).max);
        _checkOracleFreshness();

        // 1. If no loan, just transfer any collateral to vault and return
        if (!llamaLend.loan_exists(address(this))) {
            uint256 bal = collateralToken.balanceOf(address(this));
            if (bal > 0) {
                if (!collateralToken.transfer(vault, bal)) revert TransferFailed();
            }
            return;
        }

        // 2. Get position state and calculate pro-rata debt
        (uint256 collateral, uint256 debt) = _getPositionValues();
        uint256 debtToRepay =
            fullyClose ? debt : (collateral > 0 ? (debt * collateralNeeded) / collateral : 0);

        // 3. Repay with available debt asset (min of: balance, currentDebt, debtToRepay)
        uint256 debtBalance = debtToken.balanceOf(address(this));
        uint256 currentDebt = llamaLend.debt(address(this));
        uint256 repayNow = debtToRepay < currentDebt ? debtToRepay : currentDebt;
        repayNow = repayNow < debtBalance ? repayNow : debtBalance;

        if (repayNow > 0) {
            _ensureApprove(address(debtToken), address(llamaLend), repayNow);
            llamaLend.repay(repayNow);
        }

        // 4. Check remaining debt
        uint256 remainingDebt =
            llamaLend.loan_exists(address(this)) ? llamaLend.debt(address(this)) : 0;

        // For full close: flashloan if ANY debt remains (must cleanly close position).
        // For partial: flashloan only if debt exceeds dust threshold.
        bool needFlashloan = fullyClose ? (remainingDebt > 0) : !_isDustDebt(remainingDebt);

        if (needFlashloan) {
            // 5. Debt remains → flashloan the shortfall (+ 0.5% buffer)
            uint256 flashloanAmount = (remainingDebt * 10300) / 10000;
            bytes memory data = abi.encode(collateralNeeded, fullyClose);
            IERC3156FlashLender(DEBT_FLASH_LENDER).flashLoan(
                IERC3156FlashBorrower(address(this)), address(debtToken), flashloanAmount, data
            );
        } else {
            // 6. No meaningful debt remains → remove collateral directly
            if (llamaLend.loan_exists(address(this))) {
                (uint256 collAvail,) = _getPositionValues();
                if (collAvail > 0) {
                    // Repay any dust debt to free all collateral
                    if (remainingDebt > 0) {
                        uint256 dustDebt = debtToken.balanceOf(address(this));
                        if (dustDebt >= remainingDebt) {
                            _ensureApprove(address(debtToken), address(llamaLend), remainingDebt);
                            llamaLend.repay(remainingDebt);
                        }
                    }
                    // Re-check after dust repay
                    if (llamaLend.loan_exists(address(this))) {
                        (collAvail,) = _getPositionValues();
                        uint256 toRemove =
                            collateralNeeded < collAvail ? collateralNeeded : collAvail;
                        if (toRemove > 0) {
                            llamaLend.remove_collateral(toRemove);
                        }
                    }
                }
            }
        }

        // 7. Swap any remaining debt → collateral
        _swapRemainingDebt();

        // 8. Enforce terminal state for full close
        if (fullyClose && llamaLend.loan_exists(address(this))) {
            revert DebtNotFullyRepaid();
        }

        // 9. Transfer ALL collateral to vault
        uint256 totalCollateral = collateralToken.balanceOf(address(this));
        uint256 debtRepaid =
            debt - (llamaLend.loan_exists(address(this)) ? llamaLend.debt(address(this)) : 0);
        emit PositionUnwound(collateralNeeded, debtRepaid, totalCollateral);

        if (totalCollateral > 0) {
            if (!collateralToken.transfer(vault, totalCollateral)) revert TransferFailed();
        }
    }

    /// @notice ERC3156 flashloan callback for position unwinding
    /// @dev Called during unwindPosition when available debt can't cover the debt.
    ///      Repays remaining debt, removes collateral, swaps collateral→debt for repayment.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != DEBT_FLASH_LENDER) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        if (token != address(debtToken)) revert InvalidAddress();

        uint256 repaymentNeeded = amount + fee;
        UnwindContext memory ctx = abi.decode(data, (UnwindContext));

        // Step 1: Repay remaining LlamaLend debt
        _ensureApprove(address(debtToken), address(llamaLend), type(uint256).max);
        uint256 debt = llamaLend.debt(address(this));
        uint256 debtBal = debtToken.balanceOf(address(this));
        uint256 toRepay = debt < debtBal ? debt : debtBal;
        if (toRepay > 0) {
            llamaLend.repay(toRepay);
        }

        // Step 2: Handle residual debt from rounding/interest
        if (llamaLend.loan_exists(address(this))) {
            uint256 residual = llamaLend.debt(address(this));
            uint256 remaining = debtToken.balanceOf(address(this));
            if (residual > 0 && remaining >= residual) {
                llamaLend.repay(residual);
            }
        }

        // Step 3: Remove collateral — all if fullyClose, collateralNeeded if partial
        if (llamaLend.loan_exists(address(this))) {
            (uint256 collAvail,) = _getPositionValues();
            uint256 toRemove = ctx.fullyClose
                ? collAvail
                : (ctx.collateralNeeded < collAvail ? ctx.collateralNeeded : collAvail);
            if (toRemove > 0) {
                llamaLend.remove_collateral(toRemove);
            }
        }

        // Step 4: Swap enough collateral → debt to cover flashloan repayment
        uint256 debtAvailable = debtToken.balanceOf(address(this));
        if (debtAvailable < repaymentNeeded) {
            uint256 shortfall = repaymentNeeded - debtAvailable;
            uint256 collateralEstimate = _getDebtValue(shortfall);
            uint256 collateralToSwap = (collateralEstimate * SWAP_AMOUNT_BUFFER) / 100 + DUST_BUFFER;
            uint256 collateralBal = collateralToken.balanceOf(address(this));
            uint256 toSwap = collateralToSwap < collateralBal ? collateralToSwap : collateralBal;
            if (toSwap > 0) {
                _swapCollateralForDebt(toSwap);
            }

            // If still short, swap all remaining collateral
            debtAvailable = debtToken.balanceOf(address(this));
            if (debtAvailable < repaymentNeeded) {
                uint256 remainingCollateral = collateralToken.balanceOf(address(this));
                if (remainingCollateral > 0) {
                    _swapCollateralForDebt(remainingCollateral);
                }
            }
        }

        // Step 5: Verify and transfer repayment to flash lender
        if (debtToken.balanceOf(address(this)) < repaymentNeeded) {
            revert InsufficientFlashloanRepayment();
        }
        if (!debtToken.transfer(msg.sender, repaymentNeeded)) revert TransferFailed();

        return FLASH_LOAN_CALLBACK;
    }

    // ============ View Functions ============

    /// @inheritdoc ILoanManager
    function getCurrentLTV() external view returns (uint256 ltv) {
        if (!llamaLend.loan_exists(address(this))) return 0;

        uint256[4] memory state = llamaLend.user_state(address(this));
        uint256 collateralValue = _getCollateralValue(state[0]);
        uint256 debt = state[2];

        if (collateralValue == 0) return 0;
        ltv = (debt * PRECISION) / collateralValue;
    }

    /// @inheritdoc ILoanManager
    function getCurrentCollateral() external view returns (uint256 collateral) {
        if (!llamaLend.loan_exists(address(this))) return 0;
        uint256[4] memory state = llamaLend.user_state(address(this));
        collateral = state[0];
    }

    /// @inheritdoc ILoanManager
    function getCurrentDebt() external view returns (uint256 debt) {
        if (!llamaLend.loan_exists(address(this))) return 0;
        return llamaLend.debt(address(this));
    }

    /// @inheritdoc ILoanManager
    function getHealth() external view returns (int256 health) {
        if (!llamaLend.loan_exists(address(this))) return type(int256).max;
        // Use full=true to account for price differences above highest band
        return llamaLend.health(address(this), true);
    }

    /// @inheritdoc ILoanManager
    function loanExists() external view returns (bool exists) {
        return llamaLend.loan_exists(address(this));
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

    /// @notice Calculate health after hypothetical changes
    function healthCalculator(int256 dCollateral, int256 dDebt)
        external
        view
        returns (int256 health)
    {
        return llamaLend.health_calculator(address(this), dCollateral, dDebt, true);
    }

    /// @notice Get minimum collateral required for a debt amount
    function minCollateral(uint256 debt_, uint256 bands) external view returns (uint256) {
        return llamaLend.min_collateral(debt_, bands);
    }

    /// @inheritdoc ILoanManager
    function getPositionValues()
        external
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        return _getPositionValues();
    }

    /// @inheritdoc ILoanManager
    function checkOracleFreshness() external view {
        _checkOracleFreshness();
    }

    /// @inheritdoc ILoanManager
    function getCollateralBalance() external view returns (uint256 balance) {
        return collateralToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function getDebtBalance() external view returns (uint256 balance) {
        return debtToken.balanceOf(address(this));
    }

    /// @inheritdoc ILoanManager
    function getNetCollateralValue() external view returns (uint256 value) {
        if (!llamaLend.loan_exists(address(this))) {
            return 0;
        }

        (uint256 collateral, uint256 debt) = _getPositionValues();
        uint256 debtInCollateral = _getDebtValue(debt);

        return collateral > debtInCollateral ? collateral - debtInCollateral : 0;
    }

    // ============ Token Transfer Functions ============

    /// @inheritdoc ILoanManager
    function transferCollateral(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        if (!collateralToken.transfer(to, amount)) revert TransferFailed();
    }

    /// @inheritdoc ILoanManager
    function transferDebt(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        if (!debtToken.transfer(to, amount)) revert TransferFailed();
    }

    /// @inheritdoc ILoanManager
    function collateralAsset() external view returns (address) {
        return address(collateralToken);
    }

    /// @inheritdoc ILoanManager
    function debtAsset() external view returns (address) {
        return address(debtToken);
    }

    // ============ Internal Functions ============

    /// @notice Get position values (collateral and debt)
    /// @dev Uses llamaLend.debt() to get current debt WITH accrued interest
    function _getPositionValues()
        internal
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        uint256[4] memory state = llamaLend.user_state(address(this));
        collateralValue = state[0];
        debtValue = llamaLend.debt(address(this)); // Use debt() to include accrued interest
    }

    /// @notice Get collateral value in debt terms using Chainlink oracles
    /// @dev Accounts for debt/USD peg deviation: value = (COLLATERAL_USD) / (DEBT_USD)
    function _getCollateralValue(uint256 collateralAmount) internal view returns (uint256) {
        return LlamaOracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            MAX_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken
        );
    }

    /// @notice Get debt value in collateral terms using Chainlink oracles
    /// @dev Accounts for debt/USD peg deviation: value = (debt_amount * debt_USD) / collateral_USD
    function _getDebtValue(uint256 debtAmount) internal view returns (uint256) {
        return LlamaOracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            MAX_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken
        );
    }

    /// @notice Check oracle freshness (both collateral/USD and debt/USD)
    function _checkOracleFreshness() internal view {
        LlamaOracleLib.checkOracleFreshness(
            collateralOracle, MAX_ORACLE_STALENESS, debtOracle, MAX_DEBT_ORACLE_STALENESS
        );
    }

    /// @notice Canonical dust definition for partial unwinds
    function _isDustDebt(uint256 debt) internal pure returns (bool) {
        return debt <= DUST_THRESHOLD;
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

    /// @notice Swap collateral to debt
    function _swapCollateralForDebt(uint256 collateralAmount) internal returns (uint256) {
        if (address(swapper) == address(0)) revert InvalidAddress();
        collateralToken.safeTransfer(address(swapper), collateralAmount);
        uint256 received = swapper.swapCollateralForDebt(collateralAmount);
        emit CollateralSwapped(collateralAmount, received);
        return received;
    }

    /// @notice Swap debt to collateral
    function _swapDebtForCollateral(uint256 debtAmount) internal returns (uint256) {
        if (address(swapper) == address(0)) revert InvalidAddress();
        debtToken.safeTransfer(address(swapper), debtAmount);
        uint256 received = swapper.swapDebtForCollateral(debtAmount);
        emit DebtSwapped(debtAmount, received);
        return received;
    }

    /// @notice Swap any remaining debt to collateral
    function _swapRemainingDebt() internal {
        uint256 debtBal = debtToken.balanceOf(address(this));
        if (debtBal > 1000) {
            _swapDebtForCollateral(debtBal);
        }
    }

    /// @notice Ensure token approval for spender
    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
