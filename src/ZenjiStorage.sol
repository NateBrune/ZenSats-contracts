// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { ZenjiViewHelper } from "./ZenjiViewHelper.sol";
import { ZenjiConstants } from "./libraries/ZenjiConstants.sol";

/// @title ZenjiStorage
/// @notice Canonical storage layout shared by the Zenji vault core and its admin facet.
///         Both inherit this (in the same position) so they agree on every storage slot.
///         Holds the shared STATE declarations plus the shared governance CONSTANTS, which both
///         Zenji and ZenjiAdmin inherit (so `vault.X()` getters and bare `X` references resolve in
///         both, with no duplication). Constants do not occupy storage, so the slot layout is
///         unaffected. Events/errors/modifiers still live in Zenji/ZenjiAdmin (inherited
///         errors/events are not reachable as `Zenji.X`).
abstract contract ZenjiStorage is ERC20 {
    // ============ Shared constants (I-01: single source = ZenjiConstants) ============

    uint256 public constant PRECISION = ZenjiConstants.PRECISION;
    uint256 public constant DEADBAND_SPREAD = ZenjiConstants.DEADBAND_SPREAD;
    uint256 public constant MIN_TARGET_LTV = ZenjiConstants.MIN_TARGET_LTV;
    uint256 public constant MAX_FEE_RATE = ZenjiConstants.MAX_FEE_RATE;
    uint256 public constant COOLDOWN_BLOCKS = ZenjiConstants.COOLDOWN_BLOCKS;
    uint256 public constant MAX_REBALANCE_BOUNTY = ZenjiConstants.MAX_REBALANCE_BOUNTY;
    uint256 public constant TIMELOCK_DELAY = ZenjiConstants.TIMELOCK_DELAY;
    uint256 public constant MAX_VAULT_SLIPPAGE = ZenjiConstants.MAX_VAULT_SLIPPAGE;
    uint256 public constant ROLE_TRANSFER_DELAY = ZenjiConstants.ROLE_TRANSFER_DELAY;
    uint256 public constant GOV_GUARDIAN_TRANSFER_DELAY = ZenjiConstants.GOV_GUARDIAN_TRANSFER_DELAY;
    uint256 public constant PARAM_TIMELOCK_DELAY = ZenjiConstants.PARAM_TIMELOCK_DELAY;
    uint256 public constant EMERGENCY_SKIP_DELAY = ZenjiConstants.EMERGENCY_SKIP_DELAY;
    uint256 public constant GOV_EMERGENCY_DELAY = ZenjiConstants.GOV_EMERGENCY_DELAY;
    uint256 public constant MAX_USER_SLIPPAGE = ZenjiConstants.MAX_USER_SLIPPAGE;

    // ============ Immutables ============

    IERC20 public collateralAsset;
    IERC20 public debtAsset;
    ZenjiViewHelper public viewHelper;
    ILoanManager public loanManager;
    ISwapper public swapper;

    // ============ State ============

    uint256 public targetLtv;
    address public strategist;
    address public gov;
    address public guardian;
    bool public idle;
    bool public emergencyMode;
    bool public liquidationComplete;
    /// @notice Bitmask: bit 0 = step 0 resolved, bit 1 = step 1 resolved.
    /// Both bits must be set (via emergencyStep or emergencySkipStep) before step 2 is allowed.
    uint8 public emergencyStepsCompleted;
    uint256 public accumulatedFees;
    uint256 public feeRate;
    uint256 public lastStrategyBalance;
    uint256 internal _status;
    uint256 internal constant _NOT_ENTERED = 1;
    uint256 internal constant _ENTERED = 2;
    address public pendingStrategist;
    address public pendingGov;
    address public pendingGuardian;
    uint256 public pendingStrategistTimestamp;
    uint256 public pendingGovTimestamp;
    uint256 public pendingGuardianTimestamp;
    uint256 public rebalanceBountyRate;
    uint256 public depositCap;
    uint256 public maxSlippage;
    uint256 public feesAtLastRebalance;
    // Tracks the last block where an address received shares (mint or transfer).
    // Caveat: because any incoming share transfer updates this value, a third party can
    // send dust shares and force a 1-block cooldown on the recipient (dust-grief vector).
    mapping(address => uint256) public lastInBlock;

    // Yield strategy
    IYieldStrategy public yieldStrategy;

    // Timelock state (using TimelockLib)
    TimelockLib.AddressTimelockData internal _swapperTimelock;
    /// @notice Pending feeRate change (only used for adverse i.e. increasing changes)
    TimelockLib.TimelockData internal _feeRateTimelock;
    /// @notice Pending targetLtv change (only used for adverse i.e. increasing changes)
    TimelockLib.TimelockData internal _targetLtvTimelock;
    /// @notice Pending bountyRate / depositCap / maxSlippage increases (adverse changes).
    /// Decreases (or depositCap → 0 which is user-favourable in the pause sense) remain immediate.
    TimelockLib.TimelockData internal _bountyRateTimelock;
    TimelockLib.TimelockData internal _depositCapTimelock;
    TimelockLib.TimelockData internal _maxSlippageTimelock;
    /// @notice Pending change to `rescueRecipient` (gov-set, timelocked address).
    TimelockLib.AddressTimelockData internal _rescueRecipientTimelock;

    /// @notice Guardian-set flag that blocks NEW deposits but leaves withdrawals open.
    /// Separate from `emergencyMode` (one-way liquidation) and `depositCap=0` (overloaded with TVL cap).
    bool public depositsPaused;

    /// @notice Pre-set recipient for guardian-triggered `rescueAssets`. Setting this
    /// removes the "guardian picks where stuck funds go" surface. Gov-managed with 1-week timelock.
    /// Zero is sentinel for "not configured" — rescueAssets reverts until gov initialises.
    address public rescueRecipient;
    /// @notice Pending emergencySkipStep timestamps. Index 0 = step 0 (yield withdraw),
    /// index 1 = step 1 (loan unwind). Zero means no pending skip.
    uint256[2] public pendingSkipTimestamp;

    /// @notice M-06 break-glass: pending gov-proposed emergency-mode entry. Zero means no
    /// pending proposal. Set by govEnterEmergencyMode (first call), consumed by the second
    /// call after GOV_EMERGENCY_DELAY, cleared by cancelGovEmergency (gov or guardian).
    uint256 public pendingGovEmergencyTimestamp;
}
