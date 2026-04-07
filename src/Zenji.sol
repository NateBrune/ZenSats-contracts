// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { ZenjiCoreLib } from "./libraries/ZenjiCoreLib.sol";
import { ZenjiViewHelper } from "./ZenjiViewHelper.sol";

/// @dev Minimal interface for propagating slippage to swappers (avoids adding setSlippage to ISwapper).
interface ISwapperSlippageConfig {
    function setSlippage(uint256 newSlippage) external;
}


/// @title Zenji
/// @notice ERC4626-compliant conservative collateral yield vault using loan managers and yield strategies
/// @dev Deposits collateral to a loan manager, borrows debt asset, deposits to yield strategy

contract Zenji is ERC20, IERC4626 {
    using TimelockLib for TimelockLib.AddressTimelockData;
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADBAND_SPREAD = 3e16; // 3%
    uint256 public constant MIN_TARGET_LTV = 15e16; // 15%
    // MAX_TARGET_LTV is a virtual function — implementations override for per-vault ceilings
    uint256 internal constant DEFAULT_LOAN_BANDS = 4; // TODO: This should live in llamaloanmanager
    uint256 public constant MAX_FEE_RATE = 2e17; // 20%
    // VIRTUAL_SHARE_OFFSET is now a virtual function — see bottom of contract
    uint256 public constant COOLDOWN_BLOCKS = 1;
    uint256 public constant MAX_REBALANCE_BOUNTY = 1e18; // 100%
    uint256 public constant TIMELOCK_DELAY = 1 weeks;
    uint256 public constant MAX_VAULT_SLIPPAGE = 1e17; // 10% cap
    uint256 public constant ROLE_TRANSFER_DELAY = 1 weeks;

    // ============ Immutables ============

    IERC20 public immutable collateralAsset;
    IERC20 public immutable debtAsset;
    ZenjiViewHelper public immutable viewHelper;
    ILoanManager public immutable loanManager;
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
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
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
    IYieldStrategy public immutable yieldStrategy;

    // Timelock state (using TimelockLib)
    TimelockLib.AddressTimelockData internal _swapperTimelock;

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

    // ============ Constructor ============

    /// @param _yieldStrategy Yield strategy address (immutable)
    /// @param _swapper Swapper contract address (required)
    /// @param _owner Initial address for all three roles (strategist, gov, guardian)
    constructor(
        address _collateralAsset,
        address _debtAsset,
        address _loanManager,
        address _yieldStrategy,
        address _swapper,
        address _owner,
        address _viewHelper
    ) ERC20("Zen WBTC", "zenWBTC") {
        if (
            _collateralAsset == address(0) || _debtAsset == address(0) || _loanManager == address(0)
                || _yieldStrategy == address(0) || _swapper == address(0) || _owner == address(0)
                || _viewHelper == address(0)
        ) {
            revert InvalidAddress();
        }

        collateralAsset = IERC20(_collateralAsset);
        debtAsset = IERC20(_debtAsset);
        loanManager = ILoanManager(_loanManager);
        swapper = ISwapper(_swapper);
        viewHelper = ZenjiViewHelper(_viewHelper);

        // Validate loan manager assets match vault assets
        if (
            loanManager.collateralAsset() != address(collateralAsset)
                || loanManager.debtAsset() != address(debtAsset)
        ) {
            revert InvalidAddress();
        }

        // Validate strategy accepts the debt asset and is bound (or bindable) to this vault
        if (IYieldStrategy(_yieldStrategy).asset() != address(debtAsset)) {
            revert InvalidStrategy();
        }
        address stratVault = IYieldStrategy(_yieldStrategy).vault();
        if (stratVault != address(0) && stratVault != address(this)) {
            revert InvalidStrategy();
        }
        yieldStrategy = IYieldStrategy(_yieldStrategy);
        strategist = _owner;
        gov = _owner;
        guardian = _owner;
        idle = false;
        targetLtv = MAX_TARGET_LTV(); // set to per-vault ceiling at construction
        // Liquidation starts at ~90%
        // Vault can handle about 25% price move in testing without rebalancing.
        rebalanceBountyRate = 2e17; // 20% default rebalance bounty
        feeRate = 0; // Default fee rate disabled
        maxSlippage = 1e16; // 1% default vault slippage
        _status = _NOT_ENTERED;

        // Loan manager is provided externally and immutable for this vault
    }

    // ============ ERC4626 Required Functions ============

    /// @notice Returns the address of the underlying collateral asset
    function asset() external view override returns (address) {
        return address(collateralAsset);
    }

    /// @notice Returns total collateral managed by the vault
    function totalAssets() public view override returns (uint256) {
        return getTotalCollateral();
    }

    /// @notice Convert assets to shares
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _calculateSharesForDeposit(assets);
    }

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shareAmount) public view override returns (uint256) {
        return _calculateCollateralForShares(shareAmount);
    }

    /// @notice Maximum deposit allowed for receiver
    function maxDeposit(address) external view override returns (uint256) {
        if (emergencyMode) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 totalCollateral = getTotalCollateral();
        return totalCollateral >= depositCap ? 0 : depositCap - totalCollateral;
    }

    /// @notice Maximum mint allowed for receiver
    function maxMint(address receiver) external view override returns (uint256) {
        uint256 maxAssets = this.maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxAssets);
    }

    /// @notice Maximum withdraw allowed for share holder
    function maxWithdraw(address owner_) external view override returns (uint256) {
        if (emergencyMode && !liquidationComplete) return 0;
        if (emergencyMode && liquidationComplete) {
            uint256 supply = totalSupply();
            if (supply < 1) return 0;
            return (collateralAsset.balanceOf(address(this)) * balanceOf(owner_)) / supply;
        }
        return convertToAssets(balanceOf(owner_));
    }

    /// @notice Maximum redeem allowed for share holder
    function maxRedeem(address owner_) external view override returns (uint256) {
        if (emergencyMode && !liquidationComplete) return 0;
        return balanceOf(owner_);
    }

    /// @notice Preview shares for deposit
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview assets for mint (rounds up per ERC4626)
    function previewMint(uint256 shareAmount) external view override returns (uint256) {
        return _convertToAssetsRoundUp(shareAmount);
    }

    /// @notice Preview shares for withdraw
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        uint256 supply = totalSupply();
        if (emergencyMode && liquidationComplete) {
            uint256 availableCollateral = collateralAsset.balanceOf(address(this));
            if (availableCollateral < 1 || supply < 1) return 0;
            return (assets * supply + availableCollateral - 1) / availableCollateral;
        }
        uint256 totalCollateral = getTotalCollateral();
        if (totalCollateral < 1 || supply < 1) return assets;
        return (assets * (supply + VIRTUAL_SHARE_OFFSET()) + totalCollateral - 1)
            / (totalCollateral + VIRTUAL_SHARE_OFFSET());
    }

    /// @notice Preview assets for redeem
    function previewRedeem(uint256 shareAmount) external view override returns (uint256) {
        if (emergencyMode && liquidationComplete) {
            uint256 supply = totalSupply();
            if (supply < 1) return 0;
            return (collateralAsset.balanceOf(address(this)) * shareAmount) / supply;
        }
        return convertToAssets(shareAmount);
    }

    /// @notice ERC4626 deposit - deposit assets and receive shares
    function deposit(uint256 assets, address receiver)
        external
        override
        nonReentrant
        returns (uint256 sharesMinted)
    {
        _accrueYieldFees();
        sharesMinted = _calculateSharesForDeposit(assets);
        _deposit(assets, sharesMinted, receiver);
    }

    /// @notice ERC4626 mint - mint exact shares by depositing assets
    function mint(uint256 shareAmount, address receiver)
        external
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shareAmount == 0) revert ZeroAmount();
        _accrueYieldFees();
        assets = _convertToAssetsRoundUp(shareAmount);
        _deposit(assets, shareAmount, receiver);
    }

    /// @notice ERC4626 withdraw - withdraw exact assets by burning shares
    function withdraw(uint256 assets, address receiver, address owner_)
        external
        override
        nonReentrant
        returns (uint256 shareAmount)
    {
        if (assets == 0) revert ZeroAmount();

        if (emergencyMode && !liquidationComplete) revert EmergencyModeActive();

        if (emergencyMode && liquidationComplete) {
            uint256 availableCollateral = collateralAsset.balanceOf(address(this));
            if (availableCollateral < 1) revert ZeroAmount();
            shareAmount = (assets * totalSupply() + availableCollateral - 1) / availableCollateral;
        } else {
            // Accrue fees before pricing to prevent fee bypass
            _accrueYieldFees();
            // Calculate shares to burn (round up)
            uint256 totalCollateral = getTotalCollateral();
            uint256 supply = totalSupply();
            shareAmount = (assets * (supply + VIRTUAL_SHARE_OFFSET()) + totalCollateral - 1)
                / (totalCollateral + VIRTUAL_SHARE_OFFSET());

            // If requested assets correspond to (or exceed) all holder shares,
            // snap to full share burn so the final-withdraw path can execute.
            // This avoids rounding edge-cases where withdraw(convertToAssets(allShares))
            // computes slightly fewer shares and falls into partial unwind.
            uint256 ownerShares = balanceOf(owner_);
            if (ownerShares > 0 && assets >= convertToAssets(ownerShares)) {
                shareAmount = ownerShares;
            }
        }

        (, shareAmount) = _redeem(shareAmount, receiver, owner_);
    }

    /// @notice ERC4626 redeem - redeem exact shares for assets
    function redeem(uint256 shareAmount, address receiver, address owner_)
        external
        override
        nonReentrant
        returns (uint256 collateralAmount)
    {
        if (emergencyMode && !liquidationComplete) revert EmergencyModeActive();
        (collateralAmount,) = _redeem(shareAmount, receiver, owner_);
    }

    // ============ Keeper Functions ============

    /// @notice Deploy idle collateral into yield strategy
    function _deployCapital() internal {
        if (idle || emergencyMode) return;
        uint256 idleCollateral = collateralAsset.balanceOf(address(this));
        if (idleCollateral < 1) revert ZeroAmount();

        uint256 borrowAmount = loanManager.calculateBorrowAmount(idleCollateral, targetLtv);
        if (borrowAmount < 1) return;

        loanManager.checkOracleFreshness();

        collateralAsset.safeTransfer(address(loanManager), idleCollateral);

        if (!loanManager.loanExists()) {
            loanManager.createLoan(idleCollateral, borrowAmount, DEFAULT_LOAN_BANDS);
        } else {
            loanManager.addCollateral(idleCollateral);
            loanManager.borrowMore(0, borrowAmount);
        }

        // Get debt asset from loan manager and deploy to yield vault
        uint256 debtBalance = loanManager.getDebtBalance();
        if (debtBalance > 0) {
            loanManager.transferDebt(address(this), debtBalance);
            _deployDebtToYield(debtBalance);
        }

        emit CapitalDeployed(idleCollateral, borrowAmount);
    }

    /// @notice Rebalance LTV and/or strategy-debt coverage
    function rebalance() external nonReentrant {
        if (!loanManager.loanExists()) revert RebalanceNotNeeded();

        uint256 currentLtv = 0;
        uint256 lowerBand = targetLtv - DEADBAND_SPREAD;
        uint256 upperBand = targetLtv + DEADBAND_SPREAD;
        uint256 strategyDebtRatio = strategyToDebtRatio();
        uint256 minStrategyRatio = PRECISION - DEADBAND_SPREAD;
        uint256 maxStrategyRatio = PRECISION + DEADBAND_SPREAD;
        bool ratioTooLow =
            strategyDebtRatio != type(uint256).max
            && strategyDebtRatio < minStrategyRatio;
        bool ratioTooHigh =
            strategyDebtRatio != type(uint256).max
            && strategyDebtRatio > maxStrategyRatio;

        loanManager.checkOracleFreshness();
        currentLtv = loanManager.getCurrentLTV();
        bool ltvOutOfBand = currentLtv < lowerBand || currentLtv > upperBand;

        if (!ltvOutOfBand && !ratioTooLow && !ratioTooHigh) {
            revert RebalanceNotNeeded();
        }

        // Advance the strategy's cached virtual price before fee accrual so
        // _accrueYieldFees() sees an up-to-date strategy balance. This prevents
        // VP drift from causing phantom fee accrual during catch-up steps.
        yieldStrategy.updateCachedVirtualPrice();

        // Accrue fees and pay keeper bounty before adjusting LTV
        // (must happen before deposit to avoid IPOR lock conflict)
        _accrueYieldFees();

        uint256 bountyPaid;
        (feesAtLastRebalance, lastStrategyBalance, bountyPaid) = ZenjiCoreLib.processRebalanceBounty(
            yieldStrategy,
            debtAsset,
            accumulatedFees,
            feesAtLastRebalance,
            rebalanceBountyRate,
            PRECISION,
            msg.sender
        );
        if (bountyPaid > 0) {
            accumulatedFees -= bountyPaid;
        }

        uint256 newLtv = 0;
        bool increased = false;

        if (ltvOutOfBand && currentLtv < lowerBand) {
            increased = true;
            _adjustLtv(targetLtv, true, true);
            newLtv = loanManager.getCurrentLTV();
        } else if (ltvOutOfBand && currentLtv > upperBand) {
            increased = false;
            _adjustLtv(targetLtv, false, true);
            newLtv = loanManager.getCurrentLTV();
        } else if (ratioTooLow) {
            increased = false;
            lastStrategyBalance = ZenjiCoreLib.rebalanceCoverageUp(
                loanManager, yieldStrategy, debtAsset, maxSlippage, PRECISION
            );
            newLtv = loanManager.getCurrentLTV();
        } else if (ratioTooHigh) {
            increased = true;
            lastStrategyBalance = ZenjiCoreLib.rebalanceCoverageDown(
                loanManager,
                yieldStrategy,
                debtAsset,
                maxStrategyRatio,
                upperBand,
                maxSlippage,
                PRECISION
            );
            newLtv = loanManager.getCurrentLTV();
        }

        emit Rebalance(currentLtv, newLtv, increased);
    }

    /// @notice Accrue outstanding fees from yield vault profits
    /// @dev Permissionless - anyone can trigger fee accrual
    function accrueYieldFees() external nonReentrant {
        _accrueYieldFees();
    }

    /// @notice Harvest and compound yield strategy rewards
    /// @dev Permissionless - anyone can trigger harvest
    function harvestYield() external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (address(yieldStrategy) == address(0)) revert InvalidStrategy();
        _accrueYieldFees();
        uint256 harvested = yieldStrategy.harvest();
        _accrueYieldFees();
        emit YieldHarvested(msg.sender, harvested);
    }

    // ============ Strategist Functions ============

    /// @notice Enter/exit idle mode (unwind carry trade, hold collateral)
    /// @dev Strategist-only. Entering idle automatically unwinds position. Exiting idle redeploys.
    function setIdle(bool idle_) external nonReentrant onlyStrategist {
        if (idle_ == idle) return;

        if (idle_) {
            _accrueYieldFees();

            uint256 debtBefore = debtAsset.balanceOf(address(this));
            uint256 withdrawn = 0;
            if (address(yieldStrategy) != address(0)) {
                uint256 strategyBalance = yieldStrategy.balanceOf();
                if (strategyBalance > 0) {
                    withdrawn = yieldStrategy.withdrawAll();
                }
            }
            lastStrategyBalance = 0;

            uint256 debtBalance = debtBefore + withdrawn;
            if (debtBalance > 0) {
                debtAsset.safeTransfer(address(loanManager), debtBalance);
            }

            if (loanManager.loanExists()) {
                loanManager.unwindPosition(type(uint256).max);
            }

            _swapRemainingDebtToCollateral(true);

            idle = true;
            emit IdleModeEntered();
        } else {
            idle = false;
            emit IdleModeExited();
            _deployCapital();
        }
    }

    // ============ Gov Functions ============

    /// @notice Propose a new swapper contract (requires timelock)
    /// @dev Gov-only. 1-week timelock for critical infrastructure changes.
    function proposeSwapper(address newSwapper) external onlyGov {
        if (newSwapper == address(0)) revert InvalidAddress();
        if (newSwapper == address(swapper)) revert InvalidAddress();
        _swapperTimelock.proposeAddress(newSwapper, TIMELOCK_DELAY);
        emit SwapperChangeProposed(address(swapper), newSwapper, _swapperTimelock.timestamp);
    }

    /// @notice Execute pending swapper change after timelock
    function executeSwapper() external onlyGov {
        address oldSwapper = address(swapper);
        swapper = ISwapper(_swapperTimelock.executeAddress());
        emit SwapperUpdated(oldSwapper, address(swapper));
    }

    /// @notice Cancel pending swapper change
    function cancelSwapper() external onlyGov {
        address cancelled = _swapperTimelock.cancelAddress();
        emit SwapperChangeCancelled(cancelled);
    }

    // ============ Role Management (Gov-only) ============

    /// @notice Transfer role: 0=strategist, 1=gov, 2=guardian (only gov can initiate all transfers)
    /// @dev Starts a 2-day timelock; new address must call acceptRole after the delay.
    function transferRole(uint8 role, address to) external onlyGov {
        if (to == address(0)) revert InvalidAddress();
        if (role == 0) {
            pendingStrategist = to;
            pendingStrategistTimestamp = block.timestamp + ROLE_TRANSFER_DELAY;
            emit StrategistTransferStarted(strategist, to);
        } else if (role == 1) {
            pendingGov = to;
            pendingGovTimestamp = block.timestamp + ROLE_TRANSFER_DELAY;
            emit GovernanceTransferStarted(gov, to);
        } else {
            pendingGuardian = to;
            pendingGuardianTimestamp = block.timestamp + ROLE_TRANSFER_DELAY;
            emit GuardianTransferStarted(guardian, to);
        }
    }

    /// @notice Accept role: 0=strategist, 1=gov, 2=guardian
    /// @dev Caller must be the pending address and 2-day timelock must have passed.
    function acceptRole(uint8 role) external {
        if (role == 0) {
            if (msg.sender != pendingStrategist) revert Unauthorized();
            if (block.timestamp < pendingStrategistTimestamp) revert TimelockLib.TimelockNotReady();
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
            // Propagate to strategy if it supports vault-initiated ownership transfer
            yieldStrategy.transferOwnerFromVault(msg.sender);
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
        if (role == 0) {
            pendingStrategist = address(0);
            pendingStrategistTimestamp = 0;
        } else if (role == 1) {
            pendingGov = address(0);
            pendingGovTimestamp = 0;
        } else {
            pendingGuardian = address(0);
            pendingGuardianTimestamp = 0;
        }
    }

    /// @notice Withdraw accumulated strategy fees
    /// @dev Strategist-only. Accrues pending fees before withdrawal.
    function withdrawFees(address recipient) external nonReentrant onlyStrategist {
        if (recipient == address(0)) revert InvalidAddress();
        _accrueYieldFees();

        (accumulatedFees, lastStrategyBalance) =
            ZenjiCoreLib.processWithdrawFees(recipient, yieldStrategy, debtAsset, accumulatedFees);
        feesAtLastRebalance = accumulatedFees;
    }

    // ============ Guardian Functions ============

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
    /// @param step 0 (skip yield withdraw) or 1 (skip loan unwind)
    function emergencySkipStep(uint8 step) external nonReentrant onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        if (step > 1) revert InvalidEmergencyStep();
        emergencyStepsCompleted |= (step == 0 ? uint8(0x1) : uint8(0x2));
        emit EmergencyStepSkipped(step);
    }

    /// @notice Rescue stuck tokens from the vault (emergency mode only)
    /// @dev Cannot rescue collateral after liquidation — that belongs to shareholders
    function rescueAssets(address token, address recipient) external onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
        ZenjiCoreLib.executeRescueAssets(token, recipient, collateralAsset, debtAsset);
    }

    /// @notice Emergency rescue: 0=transferCollateral, 1=transferDebt, 2=redeemYield
    /// @dev Guardian-only fallback when standard emergency steps fail.
    function emergencyRescue(uint8 action) external nonReentrant onlyGuardian {
        if (!emergencyMode) revert EmergencyModeNotActive();
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

    /// @notice Set vault parameter:
    /// 0=feeRate, 1=targetLtv, 2=depositCap, 3=bountyRate, 4=maxSlippage (propagates to strategy and swapper)
    /// @dev Gov-only. All parameter changes take effect immediately.
    function setParam(uint8 p, uint256 v) external onlyGov {
        if (p == 0) {
            if (v > MAX_FEE_RATE) revert InvalidFeeRate();
            emit ParamUpdated(p, feeRate, v);
            feeRate = v;
        } else if (p == 1) {
            if (v < MIN_TARGET_LTV || v > MAX_TARGET_LTV()) {
                revert InvalidTargetLtv();
            }
            // Cross-check against the loan manager's Aave maxLtvBps cap.
            // LlamaLend returns type(uint256).max — no cap. Aave returns the actual BPS ceiling.
            uint256 lmMaxBps = loanManager.maxLtvBps();
            if (lmMaxBps != type(uint256).max && v > lmMaxBps * 1e14) {
                revert InvalidTargetLtv();
            }
            emit ParamUpdated(p, targetLtv, v);
            targetLtv = v;
        } else if (p == 2) {
            emit ParamUpdated(p, depositCap, v);
            depositCap = v;
        } else if (p == 3) {
            if (v > MAX_REBALANCE_BOUNTY) revert InvalidBountyRate();
            emit ParamUpdated(p, rebalanceBountyRate, v);
            rebalanceBountyRate = v;
        } else if (p == 4) {
            if (v == 0 || v > MAX_VAULT_SLIPPAGE) revert InvalidSlippage();
            emit ParamUpdated(p, maxSlippage, v);
            maxSlippage = v;
            yieldStrategy.setSlippage(v);
            if (address(swapper) != address(0)) ISwapperSlippageConfig(address(swapper)).setSlippage(v);
        }
    }

    // ============ View Functions ============

    /// @notice Estimate total value locked in collateral terms
    function getTotalCollateral() public view returns (uint256 totalCollateral) {
        if (idle) {
            return collateralAsset.balanceOf(address(this));
        }
        return viewHelper.getTotalCollateralValue(address(this));
    }

    /// @notice Strategy balance to loan debt ratio in debt-asset terms (1e18 = 1.0)
    /// @dev Returns max uint when debt is zero.
    function strategyToDebtRatio() public view returns (uint256 ratio) {
        uint256 debt = loanManager.getCurrentDebt();
        if (debt == 0) return type(uint256).max;
        uint256 strategyBalance = yieldStrategy.balanceOf();
        return (strategyBalance * PRECISION) / debt;
    }

    /// @notice True when strategy/debt coverage deviates beyond the LTV deadband from 100%
    function strategyDebtRebalanceNeeded() public view returns (bool) {
        uint256 ratio = strategyToDebtRatio();
        return ratio != type(uint256).max
            && (ratio < PRECISION - DEADBAND_SPREAD || ratio > PRECISION + DEADBAND_SPREAD);
    }

    // ============ Internal Functions ============

    /// @notice Swap debt asset in the vault to collateral using swapper (if set)
    /// @param force If true, swap any positive debt balance (used on full unwind/final exits)
    function _swapRemainingDebtToCollateral(bool force) internal {
        if (address(swapper) == address(0)) return;

        uint256 debtBal = debtAsset.balanceOf(address(this));
        if (debtBal == 0) return;
        uint256 oneDebtUnit = 10 ** debtAsset.decimals();
        if (!force && debtBal <= oneDebtUnit) return;
        bool allowZeroOut = force && debtBal <= oneDebtUnit;

        uint256 collateralBefore = collateralAsset.balanceOf(address(this));
        debtAsset.safeTransfer(address(swapper), debtBal);
        swapper.swapDebtForCollateral(debtBal);
        uint256 collateralAfter = collateralAsset.balanceOf(address(this));
        uint256 collateralReceived = collateralAfter - collateralBefore;
        if (!allowZeroOut) {
            uint256 oracleExpected = loanManager.getDebtValue(debtBal);
            // Use 2x maxSlippage for the vault-level check. The swapper already
            // enforces its own oracle floor per hop. Multi-hop swappers (e.g. cbBTC
            // via WBTC) compound slippage across hops and use different oracle
            // price paths than loanManager.getDebtValue, causing small divergence.
            uint256 effectiveSlippage = maxSlippage * 2;
            if (effectiveSlippage > PRECISION) effectiveSlippage = PRECISION;
            uint256 minOut = (oracleExpected * (PRECISION - effectiveSlippage)) / PRECISION;
            if (collateralReceived < minOut) {
                revert SwapperUnderperformed(minOut, collateralReceived);
            }
        }
    }

    /// @notice Calculate shares to mint for a deposit
    function _calculateSharesForDeposit(uint256 collateralAmount) internal view returns (uint256) {
        return (collateralAmount * (totalSupply() + VIRTUAL_SHARE_OFFSET()))
            / (getTotalCollateral() + VIRTUAL_SHARE_OFFSET());
    }

    /// @notice Calculate collateral to return for shares (rounds down)
    function _calculateCollateralForShares(uint256 shareAmount) internal view returns (uint256) {
        return (shareAmount * (getTotalCollateral() + VIRTUAL_SHARE_OFFSET()))
            / (totalSupply() + VIRTUAL_SHARE_OFFSET());
    }

    /// @notice Convert shares to assets rounding up (for mint/previewMint per ERC4626)
    function _convertToAssetsRoundUp(uint256 shareAmount) internal view returns (uint256) {
        uint256 supply = totalSupply() + VIRTUAL_SHARE_OFFSET();
        uint256 totalCollateral = getTotalCollateral() + VIRTUAL_SHARE_OFFSET();
        return (shareAmount * totalCollateral + supply - 1) / supply;
    }

    /// @notice Internal deposit logic shared by deposit() and mint()
    function _deposit(uint256 assets, uint256 sharesToMint, address receiver) internal {
        if (assets < MIN_DEPOSIT()) revert AmountTooSmall();
        if (sharesToMint == 0) revert AmountTooSmall();
        if (emergencyMode) revert EmergencyModeActive();
        if (depositCap > 0 && getTotalCollateral() + assets > depositCap) {
            revert DepositCapExceeded();
        }

        collateralAsset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, sharesToMint);

        if (!idle) {
            _deployCapital();
        }

        emit Deposit(msg.sender, receiver, assets, sharesToMint);
    }

    /// @notice Internal redeem logic shared by withdraw(), redeem(), and legacy withdraw()
    /// @return collateralAmount Amount of collateral returned
    /// @return actualShareAmount Amount of shares actually burned
    function _redeem(uint256 shareAmount, address receiver, address owner_)
        internal
        returns (uint256 collateralAmount, uint256 actualShareAmount)
    {
        if (shareAmount < 1) revert ZeroAmount();
        if (balanceOf(owner_) < shareAmount) revert InsufficientShares();
        if (_cooling(owner_)) {
            revert ActionDelayActive();
        }
        if (emergencyMode) {
            (collateralAmount, actualShareAmount) = _redeemEmergency(shareAmount, receiver, owner_);
            return (collateralAmount, actualShareAmount);
        }

        (collateralAmount, actualShareAmount) = _redeemStandard(shareAmount, receiver, owner_);
        return (collateralAmount, actualShareAmount);
    }

    function _cooling(address a) internal view returns (bool) {
        uint256 b = lastInBlock[a];
        return b != 0 && block.number <= b + COOLDOWN_BLOCKS - 1;
    }

    function _redeemEmergency(uint256 shareAmount, address receiver, address owner_)
        internal
        returns (uint256 collateralAmount, uint256 actualShareAmount)
    {
        if (!liquidationComplete) revert EmergencyModeActive();

        // Handle allowance if caller is not share holder
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shareAmount);
        }

        actualShareAmount = shareAmount;
        uint256 supply = totalSupply();
        if (supply < 1) return (0, 0);
        uint256 availableCollateral = collateralAsset.balanceOf(address(this));
        uint256 availableDebt = debtAsset.balanceOf(address(this));
        collateralAmount = (availableCollateral * actualShareAmount) / supply;
        uint256 debtAmount = (availableDebt * actualShareAmount) / supply;

        _burn(owner_, actualShareAmount);

        if (collateralAmount > 0) {
            collateralAsset.safeTransfer(receiver, collateralAmount);
        }
        if (debtAmount > 0) {
            debtAsset.safeTransfer(receiver, debtAmount);
        }

        emit Withdraw(msg.sender, receiver, owner_, collateralAmount, actualShareAmount);
        return (collateralAmount, actualShareAmount);
    }

    function _redeemStandard(uint256 shareAmount, address receiver, address owner_)
        internal
        returns (uint256 collateralAmount, uint256 actualShareAmount)
    {
        // Accrue fees before pricing to prevent fee bypass on redemption
        _accrueYieldFees();

        // Detect final withdrawal: only when this redemption burns every real share.
        // Note: allowance-based redemptions (msg.sender != share holder) must also trigger final
        // withdrawal when burning the entire supply, otherwise residual value is stranded
        // with totalSupply() == 0 and can be captured by the next depositor.
        bool isFinalWithdraw = (totalSupply() == shareAmount);

        // Handle allowance if caller is not share holder
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shareAmount);
        }

        actualShareAmount = isFinalWithdraw ? balanceOf(owner_) : shareAmount;
        collateralAmount = _calculateCollateralForShares(actualShareAmount);

        _burn(owner_, actualShareAmount);

        if (isFinalWithdraw) {
            _unwindPosition(type(uint256).max);
            collateralAmount = collateralAsset.balanceOf(address(this));

            if (collateralAmount > 0) {
                collateralAsset.safeTransfer(receiver, collateralAmount);
            }
        } else {
            uint256 availableCollateral = collateralAsset.balanceOf(address(this));

            if (availableCollateral < collateralAmount) {
                uint256 needed = collateralAmount - availableCollateral;

                // Ensure we unwind at least the withdrawer's proportional share
                // of the LM's gross Aave position. Without this, the LM residual
                // remains oversized relative to remaining depositors, causing the
                // re-pricing below to expect more collateral than the vault holds.
                if (loanManager.loanExists()) {
                    (uint256 posCol,) = loanManager.getPositionValues();
                    uint256 virtualSupply =
                        totalSupply() + actualShareAmount + VIRTUAL_SHARE_OFFSET();
                    uint256 proportionalLM =
                        (posCol * actualShareAmount) / virtualSupply;
                    if (proportionalLM > needed) {
                        needed = proportionalLM;
                    }
                }

                uint256 balanceBefore = collateralAsset.balanceOf(address(this));

                _unwindPosition(needed);

                uint256 balanceAfter = collateralAsset.balanceOf(address(this));

                // Re-price shares using post-unwind realized value so the
                // withdrawer absorbs strategy unwind slippage proportionally,
                // not remaining depositors. Without this, oracle-priced shares
                // let the withdrawer claim more collateral than was actually
                // recovered, socializing slippage onto remaining shareholders.
                uint256 remainingShares = totalSupply(); // shares already burned above
                if (remainingShares > 0) {
                    uint256 postUnwindTotal = getTotalCollateral();
                    // Reconstruct total supply as if shares weren't burned yet
                    uint256 virtualSupply =
                        remainingShares + actualShareAmount + VIRTUAL_SHARE_OFFSET();
                    uint256 realizedCollateral = (actualShareAmount
                        * (postUnwindTotal + VIRTUAL_SHARE_OFFSET())) / virtualSupply;
                    if (realizedCollateral < collateralAmount) {
                        collateralAmount = realizedCollateral;
                    }
                }

                uint256 totalAvailable = balanceAfter;
                if (totalAvailable < collateralAmount) {
                    // Even after re-pricing, if vault balance is insufficient
                    // (e.g. dust rounding), allow slippage-adjusted withdrawal.
                    uint256 minAcceptable =
                        (collateralAmount * (PRECISION - maxSlippage)) / PRECISION;
                    if (totalAvailable < minAcceptable) {
                        revert InsufficientCollateral();
                    }
                    collateralAmount = totalAvailable;
                }
            }

            collateralAsset.safeTransfer(receiver, collateralAmount);
        }

        emit Withdraw(msg.sender, receiver, owner_, collateralAmount, actualShareAmount);
    }

    /// @notice Accrue fees from yield strategy profits using checkpoint delta
    /// @dev Fees are only charged on incremental balance gains since the last checkpoint.
    ///      The checkpoint (lastStrategyBalance) always updates regardless of feeRate,
    ///      so changing feeRate from 0 to non-zero never retroactively charges old gains.
    function _accrueYieldFees() internal {
        if (address(yieldStrategy) == address(0)) return;
        uint256 currentBalance = yieldStrategy.balanceOf();
        if (feeRate > 0 && currentBalance > lastStrategyBalance) {
            uint256 delta = currentBalance - lastStrategyBalance;
            uint256 fees = (delta * feeRate) / PRECISION;
            if (fees > 0) {
                accumulatedFees += fees;
                emit FeesAccrued(delta, fees, accumulatedFees);
            }
        }
        lastStrategyBalance = currentBalance;
        // Cap fees to actual strategy balance to prevent phantom fee accumulation after losses
        if (accumulatedFees > currentBalance) {
            accumulatedFees = currentBalance;
        }
        if (feesAtLastRebalance > accumulatedFees) {
            feesAtLastRebalance = accumulatedFees;
        }
    }

    /// @notice Deploy debt asset to yield strategy
    function _deployDebtToYield(uint256 debtAmount) internal {
        if (idle) return;
        address stratVault = yieldStrategy.vault();
        if (stratVault != address(0) && stratVault != address(this)) revert InvalidStrategy();
        _accrueYieldFees();

        IERC20(address(debtAsset)).ensureApproval(address(yieldStrategy), debtAmount);
        uint256 balBefore = yieldStrategy.balanceOf();
        yieldStrategy.deposit(debtAmount);
        uint256 balAfter = yieldStrategy.balanceOf();
        uint256 deposited = balAfter > balBefore ? balAfter - balBefore : 0;
        if (deposited < (debtAmount * (PRECISION - maxSlippage)) / PRECISION) {
            revert InsufficientDeposit();
        }
        emit StrategyDeposit(address(yieldStrategy), debtAmount, deposited);
        lastStrategyBalance = balAfter;
    }

    /// @notice Withdraw debt asset from yield strategy
    function _withdrawFromYieldStrategy(uint256 debtNeeded) internal returns (uint256) {
        if (address(yieldStrategy) == address(0)) return 0;
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance == 0) return 0;

        _accrueYieldFees();

        uint256 toWithdraw = debtNeeded > strategyBalance ? strategyBalance : debtNeeded;
        uint256 received = 0;
        if (toWithdraw > 0) {
            received = yieldStrategy.withdraw(toWithdraw);
            uint256 minReceived = (toWithdraw * (PRECISION - maxSlippage)) / PRECISION;
            if (received < minReceived) revert InsufficientWithdrawal();
        }
        lastStrategyBalance = yieldStrategy.balanceOf();
        return received;
    }

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @param collateralNeeded Amount of collateral to free, or type(uint256).max for full close
    function _unwindPosition(uint256 collateralNeeded) internal {
        bool fullyClose = (collateralNeeded >= type(uint256).max);

        // 1. Accrue yield fees
        _accrueYieldFees();

        // 2. Withdraw from yield strategy
        uint256 debtBalance;
        if (fullyClose) {
            uint256 debtBefore = debtAsset.balanceOf(address(this));
            uint256 withdrawn = 0;
            if (address(yieldStrategy) != address(0)) {
                withdrawn = yieldStrategy.withdrawAll();
                lastStrategyBalance = 0;
            }
            debtBalance = debtBefore + withdrawn;
        } else {
            if (loanManager.loanExists()) {
                (uint256 positionCollateral, uint256 positionDebt) = loanManager.getPositionValues();
                uint256 debtToRepay = positionCollateral > 0
                    ? (positionDebt * collateralNeeded) / positionCollateral
                    : 0;
                if (debtToRepay > 0) {
                    // Add 5% buffer for slippage/rounding — multi-hop strategies
                    // (e.g. PmUsd: LP → crvUSD → USDT) need headroom to cover
                    // swap slippage so the loan manager can repay proportional debt.
                    uint256 debtNeeded = (debtToRepay * 105) / 100;
                    _withdrawFromYieldStrategy(debtNeeded);
                }
            }
            debtBalance = debtAsset.balanceOf(address(this));
        }

        // 3. Transfer idle debt asset to loan manager
        if (debtBalance > 0) {
            debtAsset.safeTransfer(address(loanManager), debtBalance);
        }

        // 4. Loan manager handles everything and sends collateral back
        loanManager.unwindPosition(collateralNeeded);

        // 5. Recover surplus debt from loan manager (yield profits / buffer surplus)
        uint256 lmDebtBalance = loanManager.getDebtBalance();
        if (lmDebtBalance > 0) {
            loanManager.transferDebt(address(this), lmDebtBalance);
        }
        _swapRemainingDebtToCollateral(fullyClose);

        emit CapitalUnwound(collateralNeeded, collateralAsset.balanceOf(address(this)));
    }

    /// @notice Adjust LTV toward target by borrowing more or repaying debt
    function _adjustLtv(uint256 _targetLtv, bool increase, bool enforceCoverageAfterIncrease)
        internal
    {
        lastStrategyBalance = ZenjiCoreLib.adjustLtv(
            loanManager,
            yieldStrategy,
            debtAsset,
            _targetLtv,
            PRECISION - DEADBAND_SPREAD,
            maxSlippage,
            PRECISION,
            increase,
            enforceCoverageAfterIncrease
        );
    }

    // Cooldown is enforced at transfer time to block same-block transfer->redeem bypasses.
    // Caveat: any third party can send dust shares to an address and set its cooldown for
    // the current block (dust-grief). Keep COOLDOWN_BLOCKS minimal (1 block) and prefer
    // private orderflow for sensitive exits.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && value > 0 && _cooling(from)) revert ActionDelayActive();

        super._update(from, to, value);

        if (to != address(0) && value > 0) {
            lastInBlock[to] = block.number;
        }
    }

    // ============ ERC20 Overrides for decimals ============

    /// @notice Returns collateral decimals to match ERC4626 asset
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(address(collateralAsset)).decimals();
    }

    // ============ Virtual share offset & deposit floor ============

    /// @notice Per-vault ceiling for targetLtv, used both in setParam validation and
    ///         as the constructor default. Override in implementation contracts whose
    ///         Aave maxLtvBps is lower than the base 65%.
    function MAX_TARGET_LTV() public pure virtual returns (uint256) {
        return 65e16; // 65% default — safe for BTC/ETH vaults (Aave maxLtv ≥ 73%)
    }

    /// @notice Virtual share offset for ERC4626 inflation attack mitigation
    /// @dev Override in implementation contracts to customize per collateral type
    function VIRTUAL_SHARE_OFFSET() public pure virtual returns (uint256) {
        return 1e5;
    }

    /// @notice Minimum deposit in collateral base units
    /// @dev Override in implementation contracts to tune per collateral type.
    ///      Should be >= VIRTUAL_SHARE_OFFSET() to preserve inflation-attack economics.
    function MIN_DEPOSIT() public pure virtual returns (uint256) {
        return 1e4;
    }
}
