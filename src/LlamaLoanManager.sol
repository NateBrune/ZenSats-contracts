// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ILlamaLendController } from "./interfaces/ILlamaLendController.sol";
import { IChainlinkOracle } from "./interfaces/IChainlinkOracle.sol";
import { ICurveTwoCrypto } from "./interfaces/ICurveTwoCrypto.sol";
import { ILlamaLoanManager } from "./interfaces/ILlamaLoanManager.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";

/// @title LlamaLoanManager
/// @notice Manages LlamaLend loan positions for the Zenji
/// @dev Handles all interactions with LlamaLend: create, borrow, repay, remove collateral
/// @dev Also handles WBTC <-> crvUSD swaps via TwoCrypto pool
contract LlamaLoanManager is ILlamaLoanManager, IERC3156FlashBorrower {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    /// @notice Precision for percentage calculations (100% = 1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Number of bands for LlamaLend loans
    uint256 public constant LLAMALEND_BANDS = 4;

    /// @notice Minimum number of satoshis for LlamaLend loans
    uint256 public constant MIN_SATS = (((LLAMALEND_BANDS * 1000) * 105) / 100); // 4 bands * 1000 sats + 5% buffer

    /// @notice Minimum health factor required (1.0 = 1e18)
    int256 public constant MIN_HEALTH = 1e17; // 10% - very conservative

    /// @notice Maximum acceptable BTC/USD oracle staleness (1 hour)
    uint256 public constant MAX_ORACLE_STALENESS = 3600;

    /// @notice Maximum acceptable crvUSD/USD oracle staleness (7 hours — heartbeat is 6 hours)
    uint256 public constant MAX_CRVUSD_ORACLE_STALENESS = 25200;

    /// @notice Dust threshold in crvUSD (1 USD) - below this we leave position with safe collateral
    uint256 public constant DUST_THRESHOLD = 1e18;

    /// @notice Safety multiplier for dust collateral (4x debt = 25% LTV)
    uint256 public constant DUST_SAFETY_MULTIPLIER = 4;

    /// @notice Slippage tolerance for collateral swaps (5%)
    uint256 public constant COLLATERAL_SWAP_SLIPPAGE = 5e16;

    /// @notice Buffer for collateral withdrawal calculation (115% = keep extra collateral for safety)
    uint256 public constant WITHDRAW_COLLATERAL_BUFFER = 115;

    /// @notice Buffer for swap amount calculation (105% = swap slightly more to cover slippage)
    uint256 public constant SWAP_AMOUNT_BUFFER = 105;

    /// @notice Small dust buffer to handle rounding (100 satoshis)
    uint256 public constant DUST_BUFFER = 100;

    /// @notice WBTC/crvUSD TwoCrypto pool indices
    uint256 public constant TWOCRYPTO_WBTC_INDEX = 1;
    uint256 public constant TWOCRYPTO_CRVUSD_INDEX = 0;

    /// @notice crvUSD flash lender for underwater position unwinding
    address public constant CRVUSD_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
    bytes32 private constant FLASH_LOAN_CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Temporary state for flashloan callback
    struct UnwindContext {
        uint256 wbtcNeeded;
        bool fullyClose;
    }

    error InsufficientFlashloanRepayment();

    event PositionUnwound(uint256 wbtcRequested, uint256 debtRepaid, uint256 collateralRemoved);

    // ============ Immutables ============

    /// @notice WBTC token (collateral)
    IERC20 public immutable wbtc;

    /// @notice crvUSD token (borrowed asset)
    IERC20 public immutable crvUSD;

    /// @notice LlamaLend controller for WBTC/crvUSD market
    ILlamaLendController public immutable llamaLend;

    /// @notice WBTC/crvUSD TwoCrypto pool for collateral liquidation
    ICurveTwoCrypto public immutable wbtcCrvUsdPool;

    /// @notice Chainlink BTC/USD oracle
    IChainlinkOracle public immutable btcOracle;

    /// @notice Chainlink crvUSD/USD oracle
    IChainlinkOracle public immutable crvUsdOracle;

    /// @notice The vault that owns this loan manager
    address public immutable vault;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _wbtc,
        address _crvUSD,
        address _llamaLend,
        address _wbtcCrvUsdPool,
        address _btcOracle,
        address _crvUsdOracle,
        address _vault
    ) {
        if (
            _wbtc == address(0) || _crvUSD == address(0) || _llamaLend == address(0)
                || _wbtcCrvUsdPool == address(0) || _btcOracle == address(0)
                || _crvUsdOracle == address(0) || _vault == address(0)
        ) {
            revert InvalidAddress();
        }

        wbtc = IERC20(_wbtc);
        crvUSD = IERC20(_crvUSD);
        llamaLend = ILlamaLendController(_llamaLend);
        wbtcCrvUsdPool = ICurveTwoCrypto(_wbtcCrvUsdPool);
        btcOracle = IChainlinkOracle(_btcOracle);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        vault = _vault;
    }

    // ============ Loan Management Functions ============

    /// @inheritdoc ILlamaLoanManager
    function createLoan(uint256 collateral, uint256 debt, uint256 bands) external onlyVault {
        _checkOracleFreshness();
        _ensureApprove(address(wbtc), address(llamaLend), collateral);
        llamaLend.create_loan(collateral, debt, bands);
        emit LoanCreated(collateral, debt, bands);
    }

    /// @inheritdoc ILlamaLoanManager
    function addCollateral(uint256 collateral) external onlyVault {
        if (collateral == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(wbtc), address(llamaLend), collateral);
        llamaLend.add_collateral(collateral);
        emit CollateralAdded(collateral);
    }

    /// @inheritdoc ILlamaLoanManager
    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        if (collateral == 0 && debt == 0) revert ZeroAmount();
        _checkOracleFreshness();
        if (collateral > 0) {
            _ensureApprove(address(wbtc), address(llamaLend), collateral);
        }
        llamaLend.borrow_more(collateral, debt);
        emit LoanBorrowedMore(collateral, debt);
    }

    /// @inheritdoc ILlamaLoanManager
    function repayDebt(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(crvUSD), address(llamaLend), amount);
        llamaLend.repay(amount);
        emit LoanRepaid(amount);
    }

    /// @inheritdoc ILlamaLoanManager
    function removeCollateral(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        llamaLend.remove_collateral(amount);
        emit CollateralRemoved(amount);
    }

    /// @inheritdoc ILlamaLoanManager
    function unwindPosition(uint256 wbtcNeeded) external onlyVault {
        bool fullyClose = (wbtcNeeded == type(uint256).max);
        _checkOracleFreshness();

        // 1. If no loan, just transfer any WBTC to vault and return
        if (!llamaLend.loan_exists(address(this))) {
            uint256 bal = wbtc.balanceOf(address(this));
            if (bal > 0) {
                if (!wbtc.transfer(vault, bal)) revert TransferFailed();
            }
            return;
        }

        // 2. Get position state and calculate pro-rata debt
        (uint256 collateral, uint256 debt) = _getPositionValues();
        uint256 debtToRepay =
            fullyClose ? debt : (collateral > 0 ? (debt * wbtcNeeded) / collateral : 0);

        // 3. Repay with available crvUSD (min of: balance, currentDebt, debtToRepay)
        uint256 crvUsdBalance = crvUSD.balanceOf(address(this));
        uint256 currentDebt = llamaLend.debt(address(this));
        uint256 repayNow = debtToRepay < currentDebt ? debtToRepay : currentDebt;
        repayNow = repayNow < crvUsdBalance ? repayNow : crvUsdBalance;

        if (repayNow > 0) {
            _ensureApprove(address(crvUSD), address(llamaLend), repayNow);
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
            uint256 flashloanAmount = (remainingDebt * 10050) / 10000;
            bytes memory data = abi.encode(wbtcNeeded, fullyClose);
            IERC3156FlashLender(CRVUSD_FLASH_LENDER).flashLoan(
                IERC3156FlashBorrower(address(this)), address(crvUSD), flashloanAmount, data
            );
        } else {
            // 6. No meaningful debt remains → remove collateral directly
            if (llamaLend.loan_exists(address(this))) {
                (uint256 collAvail,) = _getPositionValues();
                if (collAvail > 0) {
                    // Repay any dust debt to free all collateral
                    if (remainingDebt > 0) {
                        uint256 dustCrvUsd = crvUSD.balanceOf(address(this));
                        if (dustCrvUsd >= remainingDebt) {
                            _ensureApprove(address(crvUSD), address(llamaLend), remainingDebt);
                            llamaLend.repay(remainingDebt);
                        }
                    }
                    // Re-check after dust repay
                    if (llamaLend.loan_exists(address(this))) {
                        (collAvail,) = _getPositionValues();
                        uint256 toRemove = wbtcNeeded < collAvail ? wbtcNeeded : collAvail;
                        if (toRemove > 0) {
                            llamaLend.remove_collateral(toRemove);
                        }
                    }
                }
            }
        }

        // 7. Swap any remaining crvUSD → WBTC
        _swapRemainingCrvUsd();

        // 8. Enforce terminal state for full close
        if (fullyClose && llamaLend.loan_exists(address(this))) {
            revert ILlamaLoanManager.DebtNotFullyRepaid();
        }

        // 9. Transfer ALL WBTC to vault
        uint256 totalWbtc = wbtc.balanceOf(address(this));
        uint256 debtRepaid =
            debt - (llamaLend.loan_exists(address(this)) ? llamaLend.debt(address(this)) : 0);
        emit PositionUnwound(wbtcNeeded, debtRepaid, totalWbtc);

        if (totalWbtc > 0) {
            if (!wbtc.transfer(vault, totalWbtc)) revert TransferFailed();
        }
    }

    /// @notice Swap remaining crvUSD to WBTC
    function _swapRemainingCrvUsd() internal {
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        if (crvUsdBal > 1000) {
            _swapDebtForCollateral(crvUsdBal);
        }
    }

    /// @notice ERC3156 flashloan callback for position unwinding
    /// @dev Called during unwindPosition when available crvUSD can't cover the debt.
    ///      Repays remaining debt, removes collateral, swaps WBTC→crvUSD for repayment.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != CRVUSD_FLASH_LENDER) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        if (token != address(crvUSD)) revert InvalidAddress();

        uint256 repaymentNeeded = amount + fee;
        UnwindContext memory ctx = abi.decode(data, (UnwindContext));

        // Step 1: Repay remaining LlamaLend debt
        _ensureApprove(address(crvUSD), address(llamaLend), type(uint256).max);
        uint256 debt = llamaLend.debt(address(this));
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        uint256 toRepay = debt < crvUsdBal ? debt : crvUsdBal;
        if (toRepay > 0) {
            llamaLend.repay(toRepay);
        }

        // Step 2: Handle residual debt from rounding/interest
        if (llamaLend.loan_exists(address(this))) {
            uint256 residual = llamaLend.debt(address(this));
            uint256 remaining = crvUSD.balanceOf(address(this));
            if (residual > 0 && remaining >= residual) {
                llamaLend.repay(residual);
            }
        }

        // Step 3: Remove collateral — all if fullyClose, wbtcNeeded if partial
        if (llamaLend.loan_exists(address(this))) {
            (uint256 collAvail,) = _getPositionValues();
            uint256 toRemove = ctx.fullyClose
                ? collAvail
                : (ctx.wbtcNeeded < collAvail ? ctx.wbtcNeeded : collAvail);
            if (toRemove > 0) {
                llamaLend.remove_collateral(toRemove);
            }
        }

        // Step 4: Swap enough WBTC → crvUSD to cover flashloan repayment
        uint256 crvUsdAvailable = crvUSD.balanceOf(address(this));
        if (crvUsdAvailable < repaymentNeeded) {
            uint256 shortfall = repaymentNeeded - crvUsdAvailable;
            uint256 wbtcEstimate = _getDebtValue(shortfall);
            uint256 wbtcToSwap = (wbtcEstimate * SWAP_AMOUNT_BUFFER) / 100 + DUST_BUFFER;
            uint256 wbtcBal = wbtc.balanceOf(address(this));
            uint256 toSwap = wbtcToSwap < wbtcBal ? wbtcToSwap : wbtcBal;
            if (toSwap > 0) {
                _swapCollateralForDebt(toSwap);
            }

            // If still short, swap all remaining WBTC
            crvUsdAvailable = crvUSD.balanceOf(address(this));
            if (crvUsdAvailable < repaymentNeeded) {
                uint256 remainingWbtc = wbtc.balanceOf(address(this));
                if (remainingWbtc > 0) {
                    _swapCollateralForDebt(remainingWbtc);
                }
            }
        }

        // Step 5: Verify and transfer repayment to flash lender
        if (crvUSD.balanceOf(address(this)) < repaymentNeeded) {
            revert InsufficientFlashloanRepayment();
        }
        if (!crvUSD.transfer(msg.sender, repaymentNeeded)) revert TransferFailed();

        return FLASH_LOAN_CALLBACK;
    }

    /// @inheritdoc ILlamaLoanManager
    function swapCollateralForDebt(uint256 wbtcAmount) external onlyVault returns (uint256) {
        return _swapCollateralForDebt(wbtcAmount);
    }

    /// @inheritdoc ILlamaLoanManager
    function swapDebtForCollateral(uint256 crvUsdAmount) external onlyVault returns (uint256) {
        return _swapDebtForCollateral(crvUsdAmount);
    }

    // ============ View Functions ============

    /// @inheritdoc ILlamaLoanManager
    function getCurrentLTV() external view returns (uint256 ltv) {
        if (!llamaLend.loan_exists(address(this))) return 0;

        uint256[4] memory state = llamaLend.user_state(address(this));
        uint256 collateralValue = _getCollateralValue(state[0]);
        uint256 debt = state[2];

        if (collateralValue == 0) return 0;
        ltv = (debt * PRECISION) / collateralValue;
    }

    /// @inheritdoc ILlamaLoanManager
    function getCurrentCollateral() external view returns (uint256 collateral) {
        if (!llamaLend.loan_exists(address(this))) return 0;
        uint256[4] memory state = llamaLend.user_state(address(this));
        collateral = state[0];
    }

    /// @inheritdoc ILlamaLoanManager
    function getCurrentDebt() external view returns (uint256 debt) {
        if (!llamaLend.loan_exists(address(this))) return 0;
        return llamaLend.debt(address(this));
    }

    /// @inheritdoc ILlamaLoanManager
    function getHealth() external view returns (int256 health) {
        if (!llamaLend.loan_exists(address(this))) return type(int256).max;
        // Use full=true to account for price differences above highest band
        return llamaLend.health(address(this), true);
    }

    /// @inheritdoc ILlamaLoanManager
    function loanExists() external view returns (bool exists) {
        return llamaLend.loan_exists(address(this));
    }

    /// @inheritdoc ILlamaLoanManager
    function getCollateralValue(uint256 wbtcAmount) external view returns (uint256 value) {
        return _getCollateralValue(wbtcAmount);
    }

    /// @inheritdoc ILlamaLoanManager
    function getDebtValue(uint256 crvUsdAmount) external view returns (uint256 value) {
        return _getDebtValue(crvUsdAmount);
    }

    /// @inheritdoc ILlamaLoanManager
    function quoteWbtcForCrvUsd(uint256 crvUsdAmount) external view returns (uint256 wbtcNeeded) {
        if (crvUsdAmount == 0) return 0;
        uint256 wbtcUnit = 1e8;
        uint256 crvUsdPerWbtc =
            wbtcCrvUsdPool.get_dy(TWOCRYPTO_WBTC_INDEX, TWOCRYPTO_CRVUSD_INDEX, wbtcUnit);
        if (crvUsdPerWbtc == 0) return 0;
        wbtcNeeded = (crvUsdAmount * wbtcUnit + crvUsdPerWbtc - 1) / crvUsdPerWbtc;
    }

    /// @inheritdoc ILlamaLoanManager
    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        view
        returns (uint256 borrowAmount)
    {
        uint256 collateralValue = _getCollateralValue(collateral);
        return (collateralValue * targetLtv) / PRECISION;
    }

    /// @inheritdoc ILlamaLoanManager
    function healthCalculator(int256 dCollateral, int256 dDebt)
        external
        view
        returns (int256 health)
    {
        return llamaLend.health_calculator(address(this), dCollateral, dDebt, true);
    }

    /// @inheritdoc ILlamaLoanManager
    function minCollateral(uint256 debt_, uint256 bands) external view returns (uint256) {
        return llamaLend.min_collateral(debt_, bands);
    }

    /// @inheritdoc ILlamaLoanManager
    function getPositionValues()
        external
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        return _getPositionValues();
    }

    /// @inheritdoc ILlamaLoanManager
    function checkOracleFreshness() external view {
        _checkOracleFreshness();
    }

    /// @inheritdoc ILlamaLoanManager
    function getWbtcBalance() external view returns (uint256 balance) {
        return wbtc.balanceOf(address(this));
    }

    /// @inheritdoc ILlamaLoanManager
    function getCrvUsdBalance() external view returns (uint256 balance) {
        return crvUSD.balanceOf(address(this));
    }

    /// @inheritdoc ILlamaLoanManager
    function getNetCollateralValue() external view returns (uint256 value) {
        if (!llamaLend.loan_exists(address(this))) {
            return 0;
        }

        (uint256 collateral, uint256 debt) = _getPositionValues();
        uint256 debtInWbtc = _getDebtValue(debt);

        return collateral > debtInWbtc ? collateral - debtInWbtc : 0;
    }

    // ============ Token Transfer Functions ============

    /// @inheritdoc ILlamaLoanManager
    function transferWbtc(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        if (!wbtc.transfer(to, amount)) revert TransferFailed();
    }

    /// @inheritdoc ILlamaLoanManager
    function transferCrvUsd(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        if (!crvUSD.transfer(to, amount)) revert TransferFailed();
    }

    // ============ Internal Functions ============

    /// @notice Get position values (collateral and debt)
    /// @dev Uses llamaLend.debt() to get current debt WITH accrued interest
    function _getPositionValues()
        internal
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        if (!llamaLend.loan_exists(address(this))) return (0, 0);
        uint256[4] memory state = llamaLend.user_state(address(this));
        collateralValue = state[0];
        debtValue = llamaLend.debt(address(this)); // Use debt() to include accrued interest
    }

    /// @notice Get validated BTC price from Chainlink oracle
    function _getValidatedPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            btcOracle.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StaleOracle();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StaleOracle();
        return uint256(price);
    }

    /// @notice Get validated crvUSD/USD price from Chainlink oracle
    function _getValidatedCrvUsdPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            crvUsdOracle.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StaleOracle();
        if (block.timestamp - updatedAt > MAX_CRVUSD_ORACLE_STALENESS) revert StaleOracle();
        return uint256(price);
    }

    /// @notice Get collateral value in crvUSD terms using Chainlink oracles
    /// @dev Accounts for crvUSD/USD peg deviation: value = (WBTC_USD) / (crvUSD_USD)
    function _getCollateralValue(uint256 wbtcAmount) internal view returns (uint256) {
        if (wbtcAmount == 0) return 0;
        uint256 btcPrice = _getValidatedPrice();
        uint256 crvUsdPrice = _getValidatedCrvUsdPrice();
        uint8 btcOracleDecimals = btcOracle.decimals();
        uint8 crvUsdOracleDecimals = crvUsdOracle.decimals();
        uint8 wbtcDecimals = wbtc.decimals();
        return (wbtcAmount * btcPrice * 1e18 * (10 ** crvUsdOracleDecimals))
            / ((10 ** btcOracleDecimals) * (10 ** wbtcDecimals) * crvUsdPrice);
    }

    /// @notice Get crvUSD value in collateral terms using Chainlink oracles
    /// @dev Accounts for crvUSD/USD peg deviation: value = (crvUSD_amount * crvUSD_USD) / BTC_USD
    function _getDebtValue(uint256 crvUsdAmount) internal view returns (uint256) {
        if (crvUsdAmount == 0) return 0;
        uint256 btcPrice = _getValidatedPrice();
        uint256 crvUsdPrice = _getValidatedCrvUsdPrice();
        uint8 btcOracleDecimals = btcOracle.decimals();
        uint8 crvUsdOracleDecimals = crvUsdOracle.decimals();
        uint8 wbtcDecimals = wbtc.decimals();
        return (crvUsdAmount * crvUsdPrice * (10 ** btcOracleDecimals) * (10 ** wbtcDecimals))
            / ((10 ** crvUsdOracleDecimals) * btcPrice * 1e18);
    }

    /// @notice Check oracle freshness (both BTC/USD and crvUSD/USD)
    function _checkOracleFreshness() internal view {
        _getValidatedPrice();
        _getValidatedCrvUsdPrice();
    }

    /// @notice Canonical dust definition for partial unwinds
    function _isDustDebt(uint256 debt) internal pure returns (bool) {
        return debt <= DUST_THRESHOLD;
    }

    /// @notice Swap WBTC to crvUSD
    function _swapCollateralForDebt(uint256 wbtcAmount) internal returns (uint256) {
        _checkOracleFreshness();
        uint256 expectedOut =
            wbtcCrvUsdPool.get_dy(TWOCRYPTO_WBTC_INDEX, TWOCRYPTO_CRVUSD_INDEX, wbtcAmount);
        uint256 minOut = (expectedOut * (PRECISION - COLLATERAL_SWAP_SLIPPAGE)) / PRECISION;

        uint256 crvUsdBefore = crvUSD.balanceOf(address(this));

        _ensureApprove(address(wbtc), address(wbtcCrvUsdPool), wbtcAmount);
        wbtcCrvUsdPool.exchange(TWOCRYPTO_WBTC_INDEX, TWOCRYPTO_CRVUSD_INDEX, wbtcAmount, minOut);

        uint256 crvUsdAfter = crvUSD.balanceOf(address(this));
        uint256 received = crvUsdAfter - crvUsdBefore;
        emit CollateralSwapped(wbtcAmount, received);
        return received;
    }

    /// @notice Swap crvUSD to WBTC
    function _swapDebtForCollateral(uint256 debtAmount) internal returns (uint256) {
        _checkOracleFreshness();
        uint256 expectedOut =
            wbtcCrvUsdPool.get_dy(TWOCRYPTO_CRVUSD_INDEX, TWOCRYPTO_WBTC_INDEX, debtAmount);
        uint256 minOut = (expectedOut * (PRECISION - COLLATERAL_SWAP_SLIPPAGE)) / PRECISION;

        uint256 wbtcBefore = wbtc.balanceOf(address(this));

        _ensureApprove(address(crvUSD), address(wbtcCrvUsdPool), debtAmount);
        wbtcCrvUsdPool.exchange(TWOCRYPTO_CRVUSD_INDEX, TWOCRYPTO_WBTC_INDEX, debtAmount, minOut);

        uint256 wbtcAfter = wbtc.balanceOf(address(this));
        uint256 received = wbtcAfter - wbtcBefore;
        emit DebtSwapped(debtAmount, received);
        return received;
    }

    /// @notice Ensure token approval for spender
    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
