// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ILlamaLendController } from "../interfaces/ILlamaLendController.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { ICurveTwoCrypto } from "../interfaces/ICurveTwoCrypto.sol";
import { ILoanManager } from "../interfaces/ILoanManager.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import {
    IERC3156FlashBorrower
} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { TimelockLib } from "../libraries/TimelockLib.sol";
import { OracleLib } from "../libraries/OracleLib.sol";

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

    /// @notice Timelock delay for swapper changes (1 week)
    uint256 public constant TIMELOCK_DELAY = 1 weeks;

    /// @notice Number of bands for LlamaLend loans
    uint256 public constant LLAMALEND_BANDS = 4;

    /// @notice Minimum collateral units for LlamaLend loans
    uint256 public constant MIN_COLLATERAL_UNITS = (((LLAMALEND_BANDS * 1000) * 105) / 100); // 4 bands * 1000 units + 5% buffer

    /// @notice Minimum LLAMMA health required (0.1 = 1e17; liquidation threshold is 0)
    int256 public constant MIN_HEALTH = 1e17;

    /// @notice Maximum acceptable collateral/USD oracle staleness (seconds), set per-deployment.
    /// @dev 1h for single Chainlink feeds (e.g. BTC/USD); 25h for composite feeds whose slowest
    ///      leg has a long heartbeat (e.g. WstEthOracle's stETH/ETH leg — 24h Chainlink heartbeat).
    uint256 public immutable maxOracleStaleness;

    /// @notice Maximum acceptable debt/USD oracle staleness (25 hours).
    /// @dev The crvUSD/USD Chainlink feed has a 24h heartbeat (updates are deviation-triggered
    ///      in between), so the window MUST exceed 24h or valid-but-quiet prices get rejected.
    ///      A previous 7h value caused a predictable periodic DoS: during any quiet >7h gap,
    ///      _checkOracleFreshness reverted and blocked BOTH normal withdrawals AND the emergency
    ///      unwind step, while the strategy/swapper (25h window) still accepted the same price.
    ///      Now aligned to the 90000s window used by the strategy and swapper for this feed.
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000;

    /// @notice Dust threshold in debt asset (1 USD) - below this we leave position with safe collateral
    uint256 public constant DUST_THRESHOLD = 1e18;

    /// @notice Number of LLAMMA price bands for new loans
    uint256 public constant DEFAULT_LOAN_BANDS = 4;

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

    /// @notice Minimum acceptable swap output vs oracle quote (bps)
    uint256 public constant MIN_SWAP_OUT_BPS = 9500; // 95%

    /// @notice Collateral/debt TwoCrypto pool indices
    uint256 public constant TWOCRYPTO_COLLATERAL_INDEX = 1;
    uint256 public constant TWOCRYPTO_DEBT_INDEX = 0;

    /// @notice Debt flash lender for underwater position unwinding
    /// @dev Hardcoded to the crvUSD FlashLender at deployment time.
    ///      If this contract is deprecated or paused, emergency unwinding via
    ///      flashloan will revert. Recovery paths:
    ///        1. emergencySkipStep(1) — skip the flash-unwind step entirely
    ///        2. emergencyRescue(2)   — gov sends collateral directly from the loan manager
    ///      A swapper migration does NOT affect this address.
    address public constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
    bytes32 private constant FLASH_LOAN_CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice keccak of LlamaLend's band-redistribution dust revert reason ("Amount too low").
    /// @dev The ONLY partial-repay revert that may be escalated to a destructive full close.
    bytes32 private constant _DUST_REVERT_HASH = keccak256(bytes("Amount too low"));

    /// @notice Temporary state for flashloan callback
    struct UnwindContext {
        uint256 collateralNeeded;
        bool fullyClose;
    }

    error InsufficientFlashloanRepayment();
    error HealthTooLow();
    error SwapperUnderperformed(uint256 expected, uint256 received);
    /// @notice A partial repay reverted for a reason other than LlamaLend's dust assertion.
    error PartialRepayFailed();
    /// @notice A health_calculator or remove_collateral call reverted for a non-dust reason.
    error PartialUnwindFailed();

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

    /// @notice Reentrancy guard state (L-04 — parity with AaveLoanManager, defense-in-depth).
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    /// @dev Not applied to onFlashLoan: that callback runs inside a guarded unwindPosition, so
    ///      guarding it too would deadlock the flash-unwind path.
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Unauthorized();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
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
        address _vault,
        uint256 _maxOracleStaleness
    ) {
        if (
            _collateralAsset == address(0) || _debtAsset == address(0) || _llamaLend == address(0)
                || _collateralDebtPool == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_maxOracleStaleness == 0) revert InvalidAddress();
        maxOracleStaleness = _maxOracleStaleness;
        _status = _NOT_ENTERED;

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
    function createLoan(uint256 collateral, uint256 debt) external onlyVault {
        _checkOracleFreshness();
        _ensureApprove(address(collateralToken), address(llamaLend), collateral);
        llamaLend.create_loan(collateral, debt, DEFAULT_LOAN_BANDS);

        int256 health = this.getHealth();
        if (health < MIN_HEALTH) revert HealthTooLow();

        emit LoanCreated(collateral, debt, DEFAULT_LOAN_BANDS);
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
    function repayDebt(uint256 amount) external onlyVault nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        _ensureApprove(address(debtToken), address(llamaLend), amount);
        llamaLend.repay(amount);
        emit LoanRepaid(amount);
    }

    /// @inheritdoc ILoanManager
    /// @dev M-01: enforce the vault's own MIN_HEALTH after removal, matching createLoan/borrowMore
    ///      and AaveLoanManager.removeCollateral. LlamaLend only enforces its own liquidation
    ///      bounds, which are looser than this policy. Previously unreachable (no callers); it is
    ///      now the primitive behind coverage rebalancing, so the gap is live.
    function removeCollateral(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        _checkOracleFreshness();
        llamaLend.remove_collateral(amount);
        if (llamaLend.debt(address(this)) > 0) {
            int256 health = this.getHealth();
            if (health < MIN_HEALTH) revert HealthTooLow();
        }
        emit CollateralRemoved(amount);
    }

    /// @inheritdoc ILoanManager
    function unwindPosition(uint256 collateralNeeded) external onlyVault nonReentrant {
        _checkOracleFreshness();
        _unwindPosition(collateralNeeded, false);
    }

    /// @inheritdoc ILoanManager
    /// @dev M-03: skips the oracle freshness gate so a stale Chainlink feed cannot block the
    ///      guardian's emergency exit. When this contract's debt-token balance covers the debt,
    ///      the close is oracle-free (repay closes the loan and LlamaLend returns all
    ///      collateral). The trailing leftover-debt→collateral swap becomes best-effort: it is
    ///      skipped while the oracle is stale (the swapper's price floor would revert), leaving
    ///      the debt token here for the vault to recover and convert once the feed heals. A debt
    ///      shortfall still routes through the oracle-priced flashloan path, which reverts while
    ///      stale.
    function emergencyUnwindPosition() external onlyVault nonReentrant {
        _unwindPosition(type(uint256).max, true);
    }

    function _unwindPosition(uint256 collateralNeeded, bool emergency) internal {
        bool fullyClose = (collateralNeeded == type(uint256).max);

        // 1. If no loan, just transfer any collateral to vault and return
        if (!llamaLend.loan_exists(address(this))) {
            uint256 bal = collateralToken.balanceOf(address(this));
            if (bal > 0) {
                collateralToken.safeTransfer(vault, bal);
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

        // Dust-residual escalation: LlamaLend Controller's _calculate_debt_n1 asserts
        // `y_effective > 0` when redistributing a partially-repaid position into bands.
        // For tiny remaining (collateral, debt) pairs the calculation rounds to zero
        // and the partial repay reverts with "Amount too low", which would otherwise
        // lock remaining users' funds after a large depositor exits.
        //
        // We can't predict the rounding offline (it depends on AMM internals), so we
        // attempt the partial repay and on revert escalate to a full close: repay all
        // remaining debt (via flashloan if our balance is short), return all collateral
        // to the vault, and let the vault re-price remaining shares against the now-idle
        // collateral. The next deposit re-opens the LlamaLend position cleanly.
        if (repayNow > 0) {
            _ensureApprove(address(debtToken), address(llamaLend), repayNow);
            if (fullyClose || repayNow == currentDebt) {
                // Either caller asked for a full close, or we happen to be repaying
                // exactly the full debt. No band redistribution needed inside repay()
                // — the position closes — so the rounding assertion can't fire.
                llamaLend.repay(repayNow);
            } else {
                try llamaLend.repay(repayNow) {
                // partial repay succeeded
                }
                catch Error(string memory reason) {
                    // ONLY LlamaLend's band-redistribution dust assertion ("Amount too
                    // low") may be escalated to a destructive, flash-loan-dependent full
                    // close. Any other revert (controller pause, transient fault, oracle
                    // issue inside the controller) must surface — silently escalating it
                    // would socialize exit costs across all remaining depositors and force
                    // the flash lender unnecessarily. Escalation fails safe: an unmatched
                    // reason reverts here, leaving the position intact and recoverable via
                    // the vault's emergency flow rather than auto-closing.
                    if (keccak256(bytes(reason)) != _DUST_REVERT_HASH) {
                        revert PartialRepayFailed();
                    }
                    // Dust residual confirmed → escalate to full close. If we hold enough
                    // debt token, repay all now; otherwise leave repayNow=0 and let the
                    // flashloan path cover the whole debt below.
                    fullyClose = true;
                    debtToRepay = currentDebt;
                    if (debtBalance >= currentDebt) {
                        repayNow = currentDebt;
                        _ensureApprove(address(debtToken), address(llamaLend), repayNow);
                        llamaLend.repay(repayNow);
                    } else {
                        repayNow = 0;
                    }
                }
                catch {
                    // Non-string revert (Vyper Panic / empty returndata) — not the dust
                    // assertion. Fail safe rather than escalate to a full close.
                    revert PartialRepayFailed();
                }
            }
        }

        // 4. Check remaining debt
        uint256 remainingDebt =
            llamaLend.loan_exists(address(this)) ? llamaLend.debt(address(this)) : 0;

        // For full close: flashloan if ANY debt remains (must cleanly close position).
        // For partial: never flashloan — a proportional debt repay maintains the LTV ratio,
        // so remove_collateral(collateralNeeded) can succeed directly. Flashing the entire
        // remaining debt (other depositors' share) causes unnecessarily large collateral swaps
        // that routinely breach the oracle floor check.
        bool needFlashloan = fullyClose && (remainingDebt > 0);

        // Dust-residual escalation may have set fullyClose mid-flight. The caller
        // passed a partial collateralNeeded; for a clean full close we must remove
        // all remaining collateral, which requires the full-close paths below.
        if (fullyClose && collateralNeeded != type(uint256).max) {
            collateralNeeded = type(uint256).max;
        }

        if (needFlashloan) {
            // 5. Debt remains → flashloan the shortfall (+ 0.5% buffer)
            uint256 flashloanAmount = (remainingDebt * 10300) / 10000;
            bytes memory data = abi.encode(collateralNeeded, fullyClose);
            IERC3156FlashLender(DEBT_FLASH_LENDER)
                .flashLoan(
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
                        // Pro-rata shortfall guard: when the repay was balance-capped
                        // (strategy exit cost ate into the proportional debt share),
                        // scale the collateral removal down to the debt actually repaid
                        // so the residual position's LTV cannot worsen. Without this, a
                        // near-total exit parks the shortfall as debt on a dust residual
                        // position and LlamaLend rejects the removal with "Debt too
                        // high", bricking the withdrawal. The withdrawer absorbs the
                        // shortfall via the vault's post-unwind share re-pricing.
                        // Zero-repay unwinds (no debt token sent) are NOT scaled: they
                        // are deliberate collateral removals gated solely by the health
                        // check below (see M1_Llama_partial_unwind_health).
                        if (repayNow > 0 && repayNow < debtToRepay) {
                            collateralNeeded = (collateralNeeded * repayNow) / debtToRepay;
                        }
                        uint256 toRemove =
                            collateralNeeded < collAvail ? collateralNeeded : collAvail;
                        if (toRemove > 0) {
                            // Both health_calculator and remove_collateral internally
                            // call _calculate_debt_n1, which asserts y_effective > 0.
                            // For dust (collateral, debt) pairs after a large depositor
                            // exited, that rounds to zero and either call reverts with
                            // "Amount too low". On any such revert, escalate to a full
                            // close: take a flashloan for the residual debt, repay it,
                            // and let LlamaLend auto-return all collateral. The vault
                            // re-prices remaining shares against the now-idle collateral;
                            // next _deployCapital re-opens the position.
                            bool escalate;
                            try llamaLend.health_calculator(
                                address(this), -int256(toRemove), 0, true
                            ) returns (
                                int256 projectedHealth
                            ) {
                                if (projectedHealth < MIN_HEALTH) revert HealthTooLow();
                            } catch Error(string memory reason) {
                                // Only the dust assertion ("Amount too low") may be escalated to a
                                // full close. Any other revert (oracle fault, paused controller)
                                // must surface rather than silently socialize exit costs.
                                if (keccak256(bytes(reason)) != _DUST_REVERT_HASH) revert PartialUnwindFailed();
                                escalate = true;
                            } catch {
                                // Non-string revert (Vyper Panic / empty returndata) — fail safe.
                                revert PartialUnwindFailed();
                            }
                            if (!escalate) {
                                try llamaLend.remove_collateral(toRemove) {
                                // success
                                } catch Error(string memory reason) {
                                    if (keccak256(bytes(reason)) != _DUST_REVERT_HASH) revert PartialUnwindFailed();
                                    escalate = true;
                                } catch {
                                    revert PartialUnwindFailed();
                                }
                            }
                            if (escalate) {
                                fullyClose = true;
                                collateralNeeded = type(uint256).max;
                                uint256 residual = llamaLend.debt(address(this));
                                if (residual > 0) {
                                    uint256 flashloanAmount = (residual * 10300) / 10000;
                                    bytes memory dataEsc = abi.encode(collateralNeeded, fullyClose);
                                    IERC3156FlashLender(DEBT_FLASH_LENDER)
                                        .flashLoan(
                                            IERC3156FlashBorrower(address(this)),
                                            address(debtToken),
                                            flashloanAmount,
                                            dataEsc
                                        );
                                }
                            }
                        }
                    }
                }
            }
        }

        // 7. Full close only: swap any remaining debt → collateral. In the emergency path this
        //    is best-effort: the swapper's oracle floor would revert on a stale feed and take
        //    the whole exit down with it, so skip the conversion and let the vault recover the
        //    debt token. Partial unwinds leave the surplus (the vault's 5% withdraw buffer) as
        //    debt token for the vault to recover and redeposit into the strategy — the
        //    debt→collateral route cannot absorb large surpluses within its oracle floor
        //    (see WhaleExitUnwindRepro), and AaveLoanManager's direct path behaves the same.
        if (fullyClose && (!emergency || _oracleIsFresh())) {
            _swapRemainingDebt();
        }

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
            collateralToken.safeTransfer(vault, totalCollateral);
        }
    }

    // NOTE: onFlashLoan deliberately keeps its verbose shape (two-pass repay, duplicated
    // swap + defensive sweep, extra balanceOf reads) — this is the audited, PoC-verified
    // path and refactoring it buys no behavior change. AaveLoanManager.executeOperation
    // shows the streamlined equivalent (single max-amount repay, capped 1-wei residual)
    // if this is ever revisited in a future audited release.

    /// @notice ERC3156 flashloan callback for position unwinding
    /// @dev Called during unwindPosition when available debt can't cover the debt.
    ///      Repays remaining debt, removes collateral, swaps collateral->debt for repayment.
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
        if (amount == 0) revert ZeroAmount(); // L-10: defensive guard; zero-amount callbacks corrupt repay logic

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
        debtToken.safeTransfer(msg.sender, repaymentNeeded);

        return FLASH_LOAN_CALLBACK;
    }

    // ============ View Functions ============

    /// @inheritdoc ILoanManager
    function getCurrentLTV() external view returns (uint256 ltv) {
        if (!llamaLend.loan_exists(address(this))) return 0;

        uint256[4] memory state = llamaLend.user_state(address(this));
        uint256 collateralValue = _getCollateralValue(state[0]);
        uint256 debt = llamaLend.debt(address(this));

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
    function maxLtvBps() external pure returns (uint256) {
        // LlamaLend uses a band-based risk model with no single LTV ceiling.
        // Return max to signal no Aave-style cap applies.
        return type(uint256).max;
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
        collateralToken.safeTransfer(to, amount);
    }

    /// @inheritdoc ILoanManager
    function transferDebt(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert InvalidAddress();
        debtToken.safeTransfer(to, amount);
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
        return OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            maxOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken
        );
    }

    /// @notice Get debt value in collateral terms using Chainlink oracles
    /// @dev Accounts for debt/USD peg deviation: value = (debt_amount * debt_USD) / collateral_USD
    function _getDebtValue(uint256 debtAmount) internal view returns (uint256) {
        return OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            maxOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken
        );
    }

    /// @notice Check oracle freshness (both collateral/USD and debt/USD)
    function _checkOracleFreshness() internal view {
        OracleLib.checkOracleFreshness(
            collateralOracle, maxOracleStaleness, debtOracle, MAX_DEBT_ORACLE_STALENESS
        );
    }

    /// @notice Non-reverting freshness probe for the best-effort emergency swap. The swapper's
    ///         price floor is derived from the same Chainlink feeds checked here.
    function _oracleIsFresh() internal view returns (bool) {
        try this.checkOracleFreshness() {
            return true;
        } catch {
            return false;
        }
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
    /// @dev I-02: the post-swap balanceOf read is an intentional check-AFTER-transfer slippage
    ///      measurement, not a security-relevant read — it computes the actual received amount and
    ///      reverts if below the oracle floor. The vault entry points are nonReentrant and crvUSD
    ///      has no transfer callbacks, so the Slither reentrancy-balance flag is benign.
    function _swapCollateralForDebt(uint256 collateralAmount) internal returns (uint256) {
        if (address(swapper) == address(0)) revert InvalidAddress();
        uint256 debtBefore = debtToken.balanceOf(address(this));
        uint256 expectedDebt = (_getCollateralValue(collateralAmount) * MIN_SWAP_OUT_BPS) / 10000;
        collateralToken.safeTransfer(address(swapper), collateralAmount);
        swapper.swapCollateralForDebt(collateralAmount);
        // slither-disable-next-line reentrancy-benign,reentrancy-events
        uint256 debtAfter = debtToken.balanceOf(address(this));
        uint256 debtDelta = debtAfter - debtBefore;
        if (debtDelta < expectedDebt) revert SwapperUnderperformed(expectedDebt, debtDelta);
        emit CollateralSwapped(collateralAmount, debtDelta);
        return debtDelta;
    }

    /// @notice Swap debt to collateral
    /// @dev I-02: intentional check-after-transfer slippage measurement (see _swapCollateralForDebt).
    function _swapDebtForCollateral(uint256 debtAmount) internal returns (uint256) {
        if (address(swapper) == address(0)) revert InvalidAddress();
        uint256 collateralBefore = collateralToken.balanceOf(address(this));
        uint256 expectedCollateral = (_getDebtValue(debtAmount) * MIN_SWAP_OUT_BPS) / 10000;
        debtToken.safeTransfer(address(swapper), debtAmount);
        swapper.swapDebtForCollateral(debtAmount);
        // slither-disable-next-line reentrancy-benign,reentrancy-events
        uint256 collateralAfter = collateralToken.balanceOf(address(this));
        uint256 collateralDelta = collateralAfter - collateralBefore;
        if (collateralDelta < expectedCollateral) {
            revert SwapperUnderperformed(expectedCollateral, collateralDelta);
        }
        emit DebtSwapped(debtAmount, collateralDelta);
        return collateralDelta;
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
