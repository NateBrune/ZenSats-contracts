// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { ZenjiCoreLib } from "./libraries/ZenjiCoreLib.sol";
import { ZenjiStorage } from "./ZenjiStorage.sol";

interface ISwapperGovRotation {
    function transferGovFromVault(address newGov) external;
}

interface ILoanManagerSwapperRotation {
    function proposeSwapper(address newSwapper) external;
    function executeSwapper() external;
    function cancelSwapper() external;
}

/// @title ZenjiAdmin
/// @notice Cold-path admin facet for Zenji (role/swapper/rescue timelocks, emergency, pause).
///         Reached via Zenji's forwarding stubs (delegatecall), runs in the vault's storage
///         (shared ZenjiStorage). msg.sender preserved; events emit from the vault address.
contract ZenjiAdmin is ZenjiStorage {
    using TimelockLib for TimelockLib.AddressTimelockData;
    using TimelockLib for TimelockLib.TimelockData;
    using SafeTransferLib for IERC20;

    constructor() ERC20("", "") { }

    // ============ Constants ============
    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADBAND_SPREAD = 3e16; // 3%
    uint256 public constant MIN_TARGET_LTV = 15e16; // 15%
    // MAX_TARGET_LTV is a virtual function — implementations override for per-vault ceilings
    uint256 public constant MAX_FEE_RATE = 2e17; // 20%
    // VIRTUAL_SHARE_OFFSET is now a virtual function — see bottom of contract
    uint256 public constant COOLDOWN_BLOCKS = 1;
    uint256 public constant MAX_REBALANCE_BOUNTY = 5e17; // 50% (lowered from 100% — bounds gov-compromise fee-drain risk)
    uint256 public constant TIMELOCK_DELAY = 1 weeks;
    uint256 public constant MAX_VAULT_SLIPPAGE = 5e16; // 5% cap
    uint256 public constant ROLE_TRANSFER_DELAY = 1 weeks;
    /// @notice Extended delay for gov and guardian transfers — these roles are the most powerful
    /// and a compromised gov should not be able to short-circuit the guardian veto window.
    uint256 public constant GOV_GUARDIAN_TRANSFER_DELAY = 4 weeks;
    /// @notice Delay for adverse parameter changes (feeRate increases, targetLtv increases).
    /// Decreases (user-favorable) remain immediate.
    uint256 public constant PARAM_TIMELOCK_DELAY = 1 weeks;
    /// @notice Delay for emergencySkipStep — gives gov a window to veto a malicious skip.
    /// Funds in bricked components are still recoverable on the gov side during this window.
    uint256 public constant EMERGENCY_SKIP_DELAY = 3 days;
    /// @notice Hard ceiling on user-supplied withdraw slippage tolerance.
    /// Even if a user passes a very low `minAssetsOut`, the protocol caps the
    /// effective slippage applied to internal unwind steps at 20% to limit blast
    /// radius from accidental zero/low minimums and to bound MEV-sandwich damage.
    uint256 public constant MAX_USER_SLIPPAGE = 2e17; // 20%

    // ============ Events ============
    // Keeper actions
    event Rebalance(uint256 oldLtv, uint256 newLtv, bool increased);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);

    // Capital management
    event CapitalDeployed(uint256 collateralAmount, uint256 debtBorrowed);
    event CapitalUnwound(uint256 collateralNeeded, uint256 collateralReceived);

    // Role transfers
    event StrategistTransferStarted(
        address indexed previousStrategist, address indexed newStrategist
    );
    event StrategistUpdated(address indexed newStrategist);
    event GovernanceTransferStarted(address indexed previousGov, address indexed newGov);
    event GovernanceUpdated(address indexed newGov);
    event GuardianTransferStarted(address indexed previousGuardian, address indexed newGuardian);
    event GuardianUpdated(address indexed newGuardian);
    event IdleModeEntered();
    event IdleModeExited();
    event ParamUpdated(uint8 indexed param, uint256 oldValue, uint256 newValue);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);
    event SwapperChangeProposed(
        address indexed currentSwapper, address indexed newSwapper, uint256 effectiveTime
    );
    event SwapperChangeCancelled(address indexed cancelledSwapper);
    // Fee/LTV change events use ParamUpdated above
    event FeeRateChangeProposed(uint256 currentFeeRate, uint256 newFeeRate, uint256 effectiveTime);
    event TargetLtvChangeProposed(uint256 currentLtv, uint256 newLtv, uint256 effectiveTime);
    event BountyRateChangeProposed(uint256 currentRate, uint256 newRate, uint256 effectiveTime);
    event DepositCapChangeProposed(uint256 currentCap, uint256 newCap, uint256 effectiveTime);
    event MaxSlippageChangeProposed(
        uint256 currentSlippage, uint256 newSlippage, uint256 effectiveTime
    );
    event DepositsPaused();
    event DepositsResumed();
    event RescueRecipientChangeProposed(
        address indexed currentRecipient, address indexed newRecipient, uint256 effectiveTime
    );
    event RescueRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event RescueRecipientChangeCancelled(address indexed cancelledRecipient);
    event FeeRateChangeCancelled(uint256 cancelledValue);
    event TargetLtvChangeCancelled(uint256 cancelledValue);
    event BountyRateChangeCancelled(uint256 cancelledValue);
    event DepositCapChangeCancelled(uint256 cancelledValue);
    event MaxSlippageChangeCancelled(uint256 cancelledValue);
    event RoleTransferCancelled(uint8 indexed role, address indexed cancelledAddress);
    event EmergencySkipStepProposed(uint8 indexed step, uint256 effectiveTime);
    event EmergencySkipCancelled(uint8 indexed step);
    event EmergencyModeCancelled();
    event StrategyOwnerPropagationFailed(address indexed newOwner);
    event SwapperGovPropagationFailed(address indexed newGov);

    // Strategy events
    error SwapperUnderperformed(uint256 expected, uint256 received);
    event StrategyDeposit(
        address indexed strategy, uint256 debtAssetAmount, uint256 underlyingDeposited
    );

    // Emergency
    event EmergencyModeEntered();
    event LiquidationComplete(uint256 collateralRecovered, uint256 flashloanAmount);
    event EmergencyStepSkipped(uint8 indexed step);
    event AssetsRescued(address indexed token, address indexed recipient, uint256 amount);
    event FeesAccrued(uint256 profit, uint256 fees, uint256 totalAccumulatedFees);
    event YieldHarvested(address indexed caller, uint256 rewardsValue);
    event EmergencyCollateralTransferred(uint256 amount);
    event EmergencyDebtTransferred(uint256 amount);
    event EmergencyYieldRedeemed(uint256 debtAssetReceived);
    /// @notice Emitted when loan unwinding is attempted in emergency mode
    event EmergencyLoanUnwound(uint256 collateralRecovered, uint256 debtRecovered);

    // ============ Errors ============
    error Unauthorized();
    error ZeroAmount();
    error InsufficientShares();
    error RebalanceNotNeeded();
    error InvalidAddress();
    error AmountTooSmall();
    error ReentrancyError();
    error InvalidFeeRate();
    error InvalidTargetLtv();
    error EmergencyModeActive();
    error EmergencyModeNotActive();
    error InvalidBountyRate();
    error DepositCapExceeded();
    error InvalidStrategy();
    error LiquidationAlreadyComplete();
    error InsufficientCollateral();
    error InsufficientDeposit();
    error InsufficientWithdrawal();
    error EmergencyStepsIncomplete();
    error InvalidEmergencyStep();
    error InvalidSlippage();
    error StrategyDebtCoverageTooLow(uint256 currentRatio, uint256 minRatio);
    error ActionDelayActive();
    error InvalidParam();
    error DepositsArePaused();
    error RescueRecipientNotSet();
    error EmergencyStepInProgress();
    /// @notice Thrown when a user-supplied minAssetsOut floor is not met after unwind.
    error UserSlippageExceeded(uint256 minOut, uint256 actual);

    // ============ Modifiers ============
    modifier onlyStrategist() {
        if (msg.sender != strategist) revert Unauthorized();
        _;
    }

    modifier onlyGov() {
        if (msg.sender != gov) revert Unauthorized();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyError();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ============ Cold-path admin (delegatecalled from Zenji) ============

    /// @notice Propose a new swapper contract (requires timelock).
    /// @dev Gov-only. 1-week timelock for critical infrastructure changes. The proposal
    ///      is mirrored on the loan manager so that the loan-manager-side swapper
    ///      (used by the Aave flash-unwind path) stays in lockstep with the vault.
    function proposeSwapper(address newSwapper) external onlyGov {
        if (newSwapper == address(0)) revert InvalidAddress();
        if (newSwapper == address(swapper)) revert InvalidAddress();
        _swapperTimelock.proposeAddress(newSwapper, TIMELOCK_DELAY);
        ILoanManagerSwapperRotation(address(loanManager)).proposeSwapper(newSwapper);
        emit SwapperChangeProposed(address(swapper), newSwapper, _swapperTimelock.timestamp);
    }

    /// @notice Execute pending swapper change after timelock. Updates both the vault's
    ///         own swapper reference and the loan manager's reference atomically.
    function executeSwapper() external onlyGov {
        address oldSwapper = address(swapper);
        swapper = ISwapper(_swapperTimelock.executeAddress());
        ILoanManagerSwapperRotation(address(loanManager)).executeSwapper();
        emit SwapperUpdated(oldSwapper, address(swapper));
    }

    /// @notice Cancel pending swapper change (cancels both vault and loan manager).
    function cancelSwapper() external onlyGov {
        address cancelled = _swapperTimelock.cancelAddress();
        ILoanManagerSwapperRotation(address(loanManager)).cancelSwapper();
        emit SwapperChangeCancelled(cancelled);
    }

    /// @notice Transfer role: 0=strategist, 1=gov, 2=guardian (only gov can initiate all transfers)
    /// @dev Starts a timelock; new address must call acceptRole after the delay.
    ///      Strategist uses ROLE_TRANSFER_DELAY (1 week). Gov and guardian use the
    ///      extended GOV_GUARDIAN_TRANSFER_DELAY (4 weeks) — these roles are powerful
    ///      enough that a compromised gov should not be able to short-circuit the
    ///      veto window with a quick handover.
    function transferRole(uint8 role, address to) external onlyGov {
        if (to == address(0)) revert InvalidAddress();
        // Gov and guardian transfers must be sequential — concurrent queuing would let a
        // compromised gov force guardian to cancel two transfers simultaneously, shrinking
        // the effective veto window. Each transfer must complete or be cancelled first.
        if (role == 1 && pendingGuardianTimestamp != 0) revert ActionDelayActive();
        if (role == 2 && pendingGovTimestamp != 0) revert ActionDelayActive();
        if (role == 0) {
            pendingStrategist = to;
            pendingStrategistTimestamp = block.timestamp + ROLE_TRANSFER_DELAY;
            emit StrategistTransferStarted(strategist, to);
        } else if (role == 1) {
            pendingGov = to;
            pendingGovTimestamp = block.timestamp + GOV_GUARDIAN_TRANSFER_DELAY;
            emit GovernanceTransferStarted(gov, to);
        } else {
            pendingGuardian = to;
            pendingGuardianTimestamp = block.timestamp + GOV_GUARDIAN_TRANSFER_DELAY;
            emit GuardianTransferStarted(guardian, to);
        }
    }

    /// @notice Accept role: 0=strategist, 1=gov, 2=guardian
    /// @dev Caller must be the pending address and 2-day timelock must have passed.
    function acceptRole(uint8 role) external {
        if (role == 0) {
            if (msg.sender != pendingStrategist) revert Unauthorized();
            if (block.timestamp < pendingStrategistTimestamp) {
                revert TimelockLib.TimelockNotReady();
            }
            strategist = msg.sender;
            pendingStrategist = address(0);
            pendingStrategistTimestamp = 0;
            emit StrategistUpdated(msg.sender);
        } else if (role == 1) {
            if (msg.sender != pendingGov) revert Unauthorized();
            if (block.timestamp < pendingGovTimestamp) revert TimelockLib.TimelockNotReady();
            gov = msg.sender;
            pendingGov = address(0);
            pendingGovTimestamp = 0;
            emit GovernanceUpdated(msg.sender);
            // M-02: propagate ownership to the strategy ATOMICALLY — no try/catch. If the
            // strategy can't accept the new owner, the entire rotation reverts so vault.gov
            // can never diverge from strategy.owner. The previous try/catch swallowed the
            // failure, leaving a rotated-away key with rescueERC20 / setSlippage authority and
            // no on-chain re-sync path. A paused/bricked strategy must be made transferable
            // before gov can rotate — preferred over a silent, permanent split.
            yieldStrategy.transferOwnerFromVault(msg.sender);
            // Swapper gov handoff stays best-effort: the swapper is mutable via its own 1-week
            // timelock (a stale swapper can simply be rotated out), and not every registered
            // swapper implements vault-initiated gov rotation, so it must not block the handoff.
            try ISwapperGovRotation(address(swapper)).transferGovFromVault(msg.sender) {
            // success — swapper gov is now the new gov
            }
            catch {
                emit SwapperGovPropagationFailed(msg.sender);
            }
        } else {
            if (msg.sender != pendingGuardian) revert Unauthorized();
            if (block.timestamp < pendingGuardianTimestamp) revert TimelockLib.TimelockNotReady();
            guardian = msg.sender;
            pendingGuardian = address(0);
            pendingGuardianTimestamp = 0;
            emit GuardianUpdated(msg.sender);
        }
    }

    /// @notice Cancel a pending role transfer (Gov-only)
    function cancelRole(uint8 role) external onlyGov {
        _cancelRole(role);
    }

    /// @notice Guardian veto on a pending role transfer.
    /// @dev Allows guardian to block a malicious role transfer scheduled by a
    ///      compromised gov. Without this, a compromised gov could schedule a
    ///      guardian/strategist replacement and only gov could cancel it —
    ///      meaning the legitimate guardian had no on-chain recourse.
    function guardianCancelRole(uint8 role) external onlyGuardian {
        _cancelRole(role);
    }

    function _cancelRole(uint8 role) internal {
        address cancelled;
        if (role == 0) {
            cancelled = pendingStrategist;
            if (cancelled == address(0)) revert TimelockLib.NoTimelockPending();
            pendingStrategist = address(0);
            pendingStrategistTimestamp = 0;
        } else if (role == 1) {
            cancelled = pendingGov;
            if (cancelled == address(0)) revert TimelockLib.NoTimelockPending();
            pendingGov = address(0);
            pendingGovTimestamp = 0;
        } else if (role == 2) {
            cancelled = pendingGuardian;
            if (cancelled == address(0)) revert TimelockLib.NoTimelockPending();
            pendingGuardian = address(0);
            pendingGuardianTimestamp = 0;
        } else {
            revert InvalidParam();
        }
        emit RoleTransferCancelled(role, cancelled);
    }

    /// @notice Guardian veto on a pending swapper change.
    /// @dev If gov is compromised, gov could propose a malicious swapper. Without
    ///      this veto only gov could cancel it. Guardian can now block the change
    ///      during the 1-week timelock window.
    function guardianCancelSwapper() external onlyGuardian {
        address cancelled = _swapperTimelock.cancelAddress();
        ILoanManagerSwapperRotation(address(loanManager)).cancelSwapper();
        emit SwapperChangeCancelled(cancelled);
    }

    /// @notice Enter emergency mode - one-way latch, no exit
    /// @dev Guardian-only. Blocks deposits permanently. Withdrawals resume after liquidation completes.
    function enterEmergencyMode() external onlyGuardian {
        if (emergencyMode) revert EmergencyModeActive();
        emergencyMode = true;
        emit EmergencyModeEntered();
    }

    /// @notice Emergency step: 0=withdrawYield, 1=unwindLoan, 2=completeLiquidation
    function emergencyStep(uint8 step) external nonReentrant onlyGuardian {
        if (step > 2) revert InvalidEmergencyStep();
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        // Step 2: requires both prior steps to be resolved (run or explicitly skipped)
        if (step == 2 && emergencyStepsCompleted & 0x3 != 0x3) revert EmergencyStepsIncomplete();

        (uint256 newLSB, uint256 newFees, bool setLiq) = ZenjiCoreLib.executeEmergencyStep(
            step,
            yieldStrategy,
            loanManager,
            collateralAsset,
            debtAsset,
            swapper,
            lastStrategyBalance,
            accumulatedFees
        );

        lastStrategyBalance = newLSB;
        accumulatedFees = newFees;
        if (setLiq) liquidationComplete = true;

        if (step == 0) {
            feesAtLastRebalance = 0;
            emergencyStepsCompleted |= 0x1;
        } else if (step == 1) {
            emergencyStepsCompleted |= 0x2;
        }
    }

    /// @notice Explicitly mark an emergency step as resolved without executing it.
    /// Use when a component (yield strategy or loan manager) is bricked and cannot be unwound.
    /// Guardian accepts that funds in the bricked component may be unrecoverable.
    /// After skipping step 1 (loan unwind), users can only redeem collateral already in the vault.
    /// @dev Two-call pattern: the first call proposes the skip with a 3-day delay; the
    ///      second call (after the delay) executes it. Gov can call cancelEmergencySkip
    ///      during the window to veto a malicious skip. The 3-day window is acceptable
    ///      because funds in a bricked component are inaccessible regardless of timing.
    /// @param step 0 (skip yield withdraw) or 1 (skip loan unwind)
    function emergencySkipStep(uint8 step) external nonReentrant onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        if (step > 1) revert InvalidEmergencyStep();
        // No-op if the step is already resolved (executed or previously skipped)
        uint8 mask = step == 0 ? uint8(0x1) : uint8(0x2);
        if (emergencyStepsCompleted & mask != 0) revert InvalidEmergencyStep();

        uint256 pending = pendingSkipTimestamp[step];
        if (pending == 0) {
            // First call: propose with delay
            pendingSkipTimestamp[step] = block.timestamp + EMERGENCY_SKIP_DELAY;
            emit EmergencySkipStepProposed(step, pendingSkipTimestamp[step]);
        } else {
            // Second call: execute if delay has passed
            if (block.timestamp < pending) revert TimelockLib.TimelockNotReady();
            pendingSkipTimestamp[step] = 0;
            emergencyStepsCompleted |= mask;
            emit EmergencyStepSkipped(step);
        }
    }

    /// @notice Gov veto on a pending emergencySkipStep proposal.
    /// @dev Allows gov (multisig) to block a malicious or premature skip during the
    ///      EMERGENCY_SKIP_DELAY window. After the skip is executed (bitmask set),
    ///      this is a no-op for that step.
    /// @param step 0 or 1
    function cancelEmergencySkip(uint8 step) external onlyGov {
        if (step > 1) revert InvalidEmergencyStep();
        if (pendingSkipTimestamp[step] == 0) revert TimelockLib.NoTimelockPending();
        pendingSkipTimestamp[step] = 0;
        emit EmergencySkipCancelled(step);
    }

    /// @notice Cancel emergency mode entirely.
    /// @dev Gov-only. Only valid before any emergency step has executed (or been skipped).
    ///      Once steps begin (assets withdrawn from strategy/loan), the state is too
    ///      dirty to safely return to normal operation. This is the gov veto for a
    ///      malicious or premature `enterEmergencyMode()` call by a compromised guardian.
    /// @dev L-02 (by design): `emergencyMode` and `depositsPaused` are INDEPENDENT controls.
    ///      `enterEmergencyMode` does not pause deposits, and cancelling emergency does not clear
    ///      `depositsPaused` — a guardian may have paused deposits for a reason unrelated to the
    ///      emergency, and gov should not silently undo that. If deposits were paused, gov must
    ///      call `resumeDeposits()` separately. (`maxDeposit()` correctly returns 0 while paused,
    ///      so the ERC4626 signal is consistent — see L-01.)
    function cancelEmergencyMode() external onlyGov {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (emergencyStepsCompleted != 0) revert EmergencyStepInProgress();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        emergencyMode = false;
        // Clear any pending skip proposals — they are meaningless outside emergency mode
        pendingSkipTimestamp[0] = 0;
        pendingSkipTimestamp[1] = 0;
        emit EmergencyModeCancelled();
    }

    /// @notice Guardian-set flag that blocks new deposits without entering emergency mode.
    ///         Withdrawals continue normally. Provides a non-permanent "pause" lever for
    ///         security incidents that do not require full liquidation.
    function pauseDeposits() external onlyGuardian {
        if (depositsPaused) return;
        depositsPaused = true;
        emit DepositsPaused();
    }

    /// @notice Gov clears the pause. Asymmetric authority by design — fast set, slow clear
    ///         means a compromised guardian can grief deposits but cannot drain anything,
    ///         and gov retains the final say on resumption.
    function resumeDeposits() external onlyGov {
        if (!depositsPaused) return;
        depositsPaused = false;
        emit DepositsResumed();
    }

    /// @notice Propose a new pre-set recipient for guardian-triggered `rescueAssets`.
    ///         Timelocked (TIMELOCK_DELAY = 1 week) so a compromised gov cannot redirect
    ///         rescued funds without observability. Setting to a fresh address is required
    ///         before `rescueAssets` becomes usable.
    function proposeRescueRecipient(address newRecipient) external onlyGov {
        if (newRecipient == address(0)) revert InvalidAddress();
        _rescueRecipientTimelock.proposeAddress(newRecipient, TIMELOCK_DELAY);
        emit RescueRecipientChangeProposed(
            rescueRecipient, newRecipient, _rescueRecipientTimelock.timestamp
        );
    }

    function executeRescueRecipient() external onlyGov {
        address oldRecipient = rescueRecipient;
        rescueRecipient = _rescueRecipientTimelock.executeAddress();
        emit RescueRecipientUpdated(oldRecipient, rescueRecipient);
    }

    function cancelRescueRecipient() external onlyGov {
        address cancelled = _rescueRecipientTimelock.cancelAddress();
        emit RescueRecipientChangeCancelled(cancelled);
    }

    /// @notice Rescue stuck tokens from the vault (emergency mode only).
    /// @dev Cannot rescue collateral or debt assets — those belong to shareholders.
    ///      The `recipient` argument must equal the pre-set, gov-timelocked
    ///      `rescueRecipient`. This removes the "guardian picks the destination"
    ///      attack surface while keeping the function signature backwards-compatible.
    ///      Gov must call propose/executeRescueRecipient before this is usable.
    function rescueAssets(address token, address recipient) external onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (rescueRecipient == address(0)) revert RescueRecipientNotSet();
        if (recipient != rescueRecipient) revert InvalidAddress();
        ZenjiCoreLib.executeRescueAssets(token, recipient, collateralAsset, debtAsset);
    }

    /// @notice Emergency rescue: 0=transferCollateral, 1=transferDebt, 2=redeemYield
    /// @dev Guardian-only fallback when standard emergency steps fail.
    function emergencyRescue(uint8 action) external nonReentrant onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
        // Action 2 (force-redeem yield strategy) requires step 0 to be resolved first,
        // ensuring gov had the EMERGENCY_SKIP_DELAY window to veto the emergency.
        if (action == 2 && (emergencyStepsCompleted & 0x1) == 0) revert EmergencyStepsIncomplete();
        (accumulatedFees, lastStrategyBalance) = ZenjiCoreLib.executeEmergencyRescue(
            action,
            collateralAsset,
            debtAsset,
            loanManager,
            yieldStrategy,
            swapper,
            accumulatedFees,
            lastStrategyBalance
        );
    }
}
