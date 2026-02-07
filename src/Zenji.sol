    /// @notice Emitted when loan unwinding is attempted in emergency mode
    event EmergencyLoanUnwound(uint256 collateralRecovered, uint256 debtRecovered);
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { IVaultTracker } from "./interfaces/IVaultTracker.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { ZenjiViewHelper } from "./ZenjiViewHelper.sol";
 
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
    uint256 public constant MAX_TARGET_LTV = 73e16; // 73%
    uint256 public constant DEFAULT_LOAN_BANDS = 4;
    uint256 public constant MIN_DEPOSIT = 1e4;
    uint256 public constant MAX_FEE_RATE = 2e17; // 20%
    uint256 public constant VIRTUAL_SHARE_OFFSET = 1e5;
    uint256 public constant MAX_REBALANCE_BOUNTY = 2e17; // 20%
    uint256 public constant TIMELOCK_DELAY = 1 minutes; //TODO: Change before deployment to 2 days;

    // ============ Immutables ============

    IERC20 public immutable collateralAsset;
    IERC20 public immutable debtAsset;
    ZenjiViewHelper public immutable viewHelper;
    ILoanManager public loanManager;
    ISwapper public swapper;

    // ============ State ============

    uint256 public targetLtv;
    address public owner;
    bool public idle;
    bool public yieldEnabled;
    bool public emergencyMode;
    bool public liquidationComplete;
    uint256 public accumulatedFees;
    uint256 public feeRate;
    uint256 public lastStrategyBalance;
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    address public pendingOwner;
    uint256 public rebalanceBountyRate;
    uint256 public depositCap;

    // Yield strategy
    IYieldStrategy public yieldStrategy;

    // Timelock state (using TimelockLib)
    TimelockLib.AddressTimelockData internal _strategyTimelock;
    TimelockLib.AddressTimelockData internal _loanManagerTimelock;

    // ============ Events ============

    // Keeper actions
    event Rebalance(uint256 oldLtv, uint256 newLtv, bool increased);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);

    // Capital management
    event CapitalDeployed(uint256 collateralAmount, uint256 debtBorrowed);
    event CapitalUnwound(uint256 collateralNeeded, uint256 collateralReceived);

    // Admin config changes
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnerUpdated(address indexed newOwner);
    event TrackerUpdated(address indexed newTracker);
    event IdleModeEntered();
    event IdleModeExited();
    event YieldToggled(bool enabled);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event RebalanceBountyRateUpdated(uint256 oldRate, uint256 newRate);
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);

    // Fee/LTV change events (instant, no timelock)
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);
    event TargetLtvUpdated(uint256 oldLtv, uint256 newLtv);

    // Strategy events
    event StrategyChangeProposed(
        address indexed currentStrategy, address indexed newStrategy, uint256 effectiveTime
    );
    event StrategyChangeExecuted(address indexed oldStrategy, address indexed newStrategy);
    event StrategyChangeCancelled(address indexed cancelledStrategy);
    event StrategyPauseToggled(bool paused, uint256 debtAssetReceived);

    // Loan manager events
    event LoanManagerChangeProposed(
        address indexed currentLoanManager, address indexed newLoanManager, uint256 effectiveTime
    );
    event LoanManagerChangeExecuted(address indexed oldLoanManager, address indexed newLoanManager);
    event LoanManagerChangeCancelled(address indexed cancelledLoanManager);

    // Emergency
    event EmergencyModeEntered();
    event LiquidationComplete(uint256 collateralRecovered, uint256 flashloanAmount);
    event AssetsRescued(address indexed token, address indexed recipient, uint256 amount);
    event FeesAccrued(uint256 profit, uint256 fees, uint256 totalAccumulatedFees);
    event YieldHarvested(address indexed caller);
    event EmergencyCollateralTransferred(uint256 amount);
    event EmergencyDebtTransferred(uint256 amount);
    event EmergencyYieldRedeemed();

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
    error StrategyAlreadySet();
    error LiquidationAlreadyComplete();
    error ActiveLoanExists();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyError();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ============ Constructor ============

    /// @param _yieldStrategy Yield strategy address (can be zero, set later via setInitialStrategy)
    constructor(
        address _collateralAsset,
        address _debtAsset,
        address _loanManager,
        address _yieldStrategy,
        address _owner,
        address _viewHelper
    ) ERC20("SiloBooster Vault", "sbVault") {
        if (
            _collateralAsset == address(0) || _debtAsset == address(0) || _loanManager == address(0)
                || _owner == address(0) || _viewHelper == address(0)
        ) {
            revert InvalidAddress();
        }

        collateralAsset = IERC20(_collateralAsset);
        debtAsset = IERC20(_debtAsset);
        viewHelper = ZenjiViewHelper(_viewHelper);
        loanManager = ILoanManager(_loanManager);
        // Strategy can be set later via setInitialStrategy if zero
        if (_yieldStrategy != address(0)) {
            yieldStrategy = IYieldStrategy(_yieldStrategy);
        }
        owner = _owner;
        yieldEnabled = _yieldStrategy != address(0);
        targetLtv = 70e16; // 70% default target LTV
        // Liquidation starts at ~90%
        // Vault can handle about 25% price move in testing without rebalancing.
        rebalanceBountyRate = 2e17; // 20% default rebalance bounty
        feeRate = 1e17; // 10% fee on yield
        _status = _NOT_ENTERED;

        // Loan manager is provided externally and can be swapped via timelock
    }

    /// @notice Set initial yield strategy (can only be called once if strategy not set in constructor)
    /// @param _strategy The yield strategy address
    function setInitialStrategy(address _strategy) external onlyOwner {
        if (address(yieldStrategy) != address(0)) revert StrategyAlreadySet();
        if (_strategy == address(0)) revert InvalidAddress();
        if (IYieldStrategy(_strategy).vault() != address(this)) revert InvalidStrategy();
        yieldStrategy = IYieldStrategy(_strategy);
        emit StrategyChangeExecuted(address(0), _strategy);
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

    /// @notice Maximum withdraw allowed for owner
    function maxWithdraw(address _owner) external view override returns (uint256) {
        if (emergencyMode && !liquidationComplete) return 0;
        if (emergencyMode && liquidationComplete) {
            uint256 supply = totalSupply();
            if (supply == 0) return 0;
            return (collateralAsset.balanceOf(address(this)) * balanceOf(_owner)) / supply;
        }
        return convertToAssets(balanceOf(_owner));
    }

    /// @notice Maximum redeem allowed for owner
    function maxRedeem(address _owner) external view override returns (uint256) {
        if (emergencyMode && !liquidationComplete) return 0;
        return balanceOf(_owner);
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
            if (availableCollateral == 0 || supply == 0) return 0;
            return (assets * supply + availableCollateral - 1) / availableCollateral;
        }

        // Round up for withdrawals
        uint256 totalCollateral = getTotalCollateral();
        if (totalCollateral == 0 || supply == 0) return assets;
        return (assets * (supply + VIRTUAL_SHARE_OFFSET) + totalCollateral - 1)
            / (totalCollateral + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Preview assets for redeem
    function previewRedeem(uint256 shareAmount) external view override returns (uint256) {
        if (emergencyMode && liquidationComplete) {
            uint256 supply = totalSupply();
            if (supply == 0) return 0;
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
        assets = _convertToAssetsRoundUp(shareAmount);
        _deposit(assets, shareAmount, receiver);
    }

    /// @notice ERC4626 withdraw - withdraw exact assets by burning shares
    function withdraw(uint256 assets, address receiver, address _owner)
        external
        override
        nonReentrant
        returns (uint256 shareAmount)
    {
        if (assets == 0) revert ZeroAmount();

        if (emergencyMode && liquidationComplete) {
            uint256 availableCollateral = collateralAsset.balanceOf(address(this));
            if (availableCollateral == 0) revert ZeroAmount();
            shareAmount = (assets * totalSupply() + availableCollateral - 1) / availableCollateral;
        } else {
            // Calculate shares to burn (round up)
            uint256 totalCollateral = getTotalCollateral();
            uint256 supply = totalSupply();
            shareAmount = (assets * (supply + VIRTUAL_SHARE_OFFSET) + totalCollateral - 1)
                / (totalCollateral + VIRTUAL_SHARE_OFFSET);
        }

        (, shareAmount) = _redeem(shareAmount, receiver, _owner);
    }

    /// @notice ERC4626 redeem - redeem exact shares for assets
    function redeem(uint256 shareAmount, address receiver, address _owner)
        external
        override
        nonReentrant
        returns (uint256 collateralAmount)
    {
        (collateralAmount,) = _redeem(shareAmount, receiver, _owner);
    }

    // ============ Keeper Functions ============

    /// @notice Deploy idle collateral into yield strategy
    function _deployCapital() internal {
        if (idle || emergencyMode) return;
        uint256 idleCollateral = collateralAsset.balanceOf(address(this));
        if (idleCollateral == 0) revert ZeroAmount();

        uint256 borrowAmount = loanManager.calculateBorrowAmount(idleCollateral, targetLtv);
        if (borrowAmount == 0) return;

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

    /// @notice Rebalance LTV if outside deadband
    function rebalance() external nonReentrant {
        if (!loanManager.loanExists()) revert RebalanceNotNeeded();

        loanManager.checkOracleFreshness();

        uint256 currentLtv = loanManager.getCurrentLTV();
        uint256 lowerBand = targetLtv - DEADBAND_SPREAD;
        uint256 upperBand = targetLtv + DEADBAND_SPREAD;

        if (currentLtv >= lowerBand && currentLtv <= upperBand) {
            revert RebalanceNotNeeded();
        }

        uint256 newLtv = 0;
        bool increased = false;

        if (currentLtv < lowerBand) {
            increased = true;
            _increaseLtv(targetLtv);
            newLtv = loanManager.getCurrentLTV();
        } else if (currentLtv > upperBand) {
            increased = false;
            _decreaseLtv(targetLtv);
            newLtv = loanManager.getCurrentLTV();
        }

        // Accrue fees and pay keeper bounty
        _accrueYieldFees();

        if (rebalanceBountyRate > 0 && accumulatedFees > 0) {
            uint256 bounty = (accumulatedFees * rebalanceBountyRate) / PRECISION;
            if (bounty > 0) {
                // Withdraw bounty from yield strategy
                uint256 strategyBalance = yieldStrategy.balanceOf();
                if (strategyBalance > 0) {
                    uint256 toWithdraw = bounty > strategyBalance ? strategyBalance : bounty;

                    uint256 received = yieldStrategy.withdraw(toWithdraw);

                    uint256 actualBounty = received > bounty ? bounty : received;
                    accumulatedFees -= actualBounty;
                    lastStrategyBalance = yieldStrategy.balanceOf();
                    debtAsset.safeTransfer(msg.sender, actualBounty);
                    emit RebalanceBountyPaid(msg.sender, actualBounty);
                }
            }
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
        yieldStrategy.harvest();
        lastStrategyBalance = yieldStrategy.balanceOf();
        emit YieldHarvested(msg.sender);
    }

    // ============ Admin Functions ============

    /// @notice Toggle yield deployment on/off
    function toggleYield(bool enabled) external onlyOwner {
        yieldEnabled = enabled;
        emit YieldToggled(enabled);
    }

    /// @notice Enter/exit idle mode (unwind carry trade, hold collateral)
    function setIdle(bool idle_) external onlyOwner nonReentrant {
        if (idle_ == idle) return;

        if (idle_) {
            _accrueYieldFees();

            if (address(yieldStrategy) != address(0)) {
                uint256 strategyBalance = yieldStrategy.balanceOf();
                if (strategyBalance > 0) {
                    yieldStrategy.withdrawAll();
                }
            }
            lastStrategyBalance = 0;

            uint256 debtBalance = debtAsset.balanceOf(address(this));
            if (debtBalance > 0) {
                debtAsset.safeTransfer(address(loanManager), debtBalance);
            }

            if (loanManager.loanExists()) {
                loanManager.unwindPosition(type(uint256).max);
            }

            _swapRemainingDebtToCollateral();

            idle = true;
            yieldEnabled = false;
            emit IdleModeEntered();
        } else {
            idle = false;
            emit IdleModeExited();
            _deployCapital();
        }
    }

    /// @notice Pause/unpause the yield strategy
    /// @dev When pausing: withdraws all from strategy. When unpausing: redeploys idle debt asset.
    // function pauseStrategy() external onlyOwner nonReentrant returns (uint256 debtAssetReceived) {
    //     if (address(yieldStrategy) == address(0)) revert InvalidStrategy();

    //     _accrueYieldFees();
    //     debtAssetReceived = yieldStrategy.pauseStrategy();

    //     // If we just unpaused, redeploy idle debt asset into the strategy
    //     if (!yieldStrategy.paused()) {
    //         uint256 idleDebt = debtAsset.balanceOf(address(this));
    //         if (idleDebt > 0) {
    //             _ensureApprove(address(debtAsset), address(yieldStrategy), idleDebt);
    //             yieldStrategy.deposit(idleDebt);
    //         }
    //     }

    //     lastStrategyBalance = yieldStrategy.balanceOf();
    //     emit StrategyPauseToggled(yieldStrategy.paused(), debtAssetReceived);
    // }

    /// @notice Set swapper contract (optional)
    function setSwapper(address newSwapper) external onlyOwner {
        address oldSwapper = address(swapper);
        swapper = ISwapper(newSwapper);
        emit SwapperUpdated(oldSwapper, newSwapper);
    }

    /// @notice Start ownership transfer
    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert InvalidAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferStarted(owner, newOwner_);
    }

    /// @notice Accept ownership transfer
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerUpdated(msg.sender);
    }

    /// @notice Withdraw accumulated fees
    function withdrawFees(address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidAddress();

        // Accrue any outstanding fees first
        _accrueYieldFees();

        uint256 fees = accumulatedFees;
        if (fees == 0) return;

        accumulatedFees = 0;

        // Withdraw from yield strategy to get actual debt asset
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance > 0 && fees > 0) {
            uint256 toWithdraw = fees > strategyBalance ? strategyBalance : fees;
            if (toWithdraw > 0) {
                yieldStrategy.withdraw(toWithdraw);
            }
        }
        lastStrategyBalance = yieldStrategy.balanceOf();

        // Transfer fees (includes any idle debt asset)
        uint256 debtBalance = debtAsset.balanceOf(address(this));
        uint256 toTransfer = fees > debtBalance ? debtBalance : fees;

        if (toTransfer > 0) {
            debtAsset.safeTransfer(recipient, toTransfer);
        }

        emit FeesWithdrawn(recipient, toTransfer);
    }

    // ============ Emergency Functions ============

    /// @notice Enter emergency mode - one-way latch, no exit
    /// @dev Pauses all user-facing ERC-4626 operations permanently
    function enterEmergencyMode() external onlyOwner {
        if (emergencyMode) revert EmergencyModeActive();
        emergencyMode = true;
        yieldEnabled = false;
        emit EmergencyModeEntered();
    }


    /// @notice Step 1: Withdraw all from yield strategy (resilient if bricked)
    /// @dev Can be called multiple times until successful. Does not set liquidationComplete.
    function emergencyWithdrawYield() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        if (address(yieldStrategy) != address(0)) {
            try yieldStrategy.withdrawAll() { }
            catch {
                try yieldStrategy.emergencyWithdraw() { } catch { }
            }
        }
        lastStrategyBalance = 0;
        accumulatedFees = 0;
        emit EmergencyYieldRedeemed();
    }


    /// @notice Step 2: Unwind loan and recover all assets to vault. Does NOT set liquidationComplete.
    /// @dev Can be called after yield is withdrawn. Allows manual asset recovery even if loan manager fails.
    function emergencyUnwindLoanAndRecover() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();

        // If no active loan, just recover and finish
        if (!loanManager.loanExists()) {
            _recoverLoanManagerFunds();
            _swapRemainingDebtToCollateral();
            emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
            return;
        }

        // Calculate debt vs available debt asset
        uint256 totalDebt = loanManager.getCurrentDebt();
        uint256 availableDebt = debtAsset.balanceOf(address(this));

        if (availableDebt >= totalDebt) {
            // Yield covers full debt - no flashloan needed
            debtAsset.safeTransfer(address(loanManager), totalDebt);
            loanManager.repayDebt(totalDebt);
        } else {
            if (availableDebt > 0) {
                debtAsset.safeTransfer(address(loanManager), availableDebt);
            }
            loanManager.unwindPosition(type(uint256).max);
        }

        _recoverLoanManagerFunds();
        _swapRemainingDebtToCollateral();
        emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
    }

    /// @notice Mark liquidation as complete, allowing withdrawals in emergency mode
    /// @dev Can be called by anyone after asset recovery. One-way latch.
    function setLiquidationComplete() external {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();
        liquidationComplete = true;
        emit LiquidationComplete(collateralAsset.balanceOf(address(this)), 0);
    }

    /// @notice Rescue stuck tokens from the vault (emergency mode only)
    /// @dev Cannot rescue collateral after liquidation — that belongs to shareholders
    function rescueAssets(address token, address recipient) external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (recipient == address(0)) revert InvalidAddress();
        if (liquidationComplete && token == address(collateralAsset)) {
            revert LiquidationAlreadyComplete();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
        emit AssetsRescued(token, recipient, balance);
    }

    // ============ Emergency Rescue (Fallback) ============

    function transferCollateral() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        uint256 amount = collateralAsset.balanceOf(address(loanManager));
        loanManager.transferCollateral(address(this), amount);
        emit EmergencyCollateralTransferred(amount);
    }

    function transferDebt() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        uint256 amount = debtAsset.balanceOf(address(loanManager));
        loanManager.transferDebt(address(this), amount);
        emit EmergencyDebtTransferred(amount);
    }

    function emergencyRedeemYield() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        yieldStrategy.emergencyWithdraw();
        lastStrategyBalance = 0;
        // Convert recovered debt asset to collateral so it's included in pro-rata distribution
        _swapRemainingDebtToCollateral();
        emit EmergencyYieldRedeemed();
    }

    // ============ Instant Parameter Setters ============

    function setFeeRate(uint256 newFeeRate) external onlyOwner {
        if (newFeeRate > MAX_FEE_RATE) revert InvalidFeeRate();
        uint256 oldFeeRate = feeRate;
        feeRate = newFeeRate;
        emit FeeRateUpdated(oldFeeRate, newFeeRate);
    }

    function setTargetLtv(uint256 newTargetLtv) external onlyOwner {
        if (newTargetLtv < MIN_TARGET_LTV || newTargetLtv > MAX_TARGET_LTV) {
            revert InvalidTargetLtv();
        }
        uint256 oldTargetLtv = targetLtv;
        targetLtv = newTargetLtv;
        emit TargetLtvUpdated(oldTargetLtv, newTargetLtv);
    }

    function setDepositCap(uint256 newCap) external onlyOwner {
        uint256 oldCap = depositCap;
        depositCap = newCap;
        emit DepositCapUpdated(oldCap, newCap);
    }

    function setRebalanceBountyRate(uint256 newRate) external onlyOwner {
        if (newRate > MAX_REBALANCE_BOUNTY) revert InvalidBountyRate();
        uint256 oldRate = rebalanceBountyRate;
        rebalanceBountyRate = newRate;
        emit RebalanceBountyRateUpdated(oldRate, newRate);
    }

    // ============ Strategy Switching Functions ============

    /// @notice Propose a new yield strategy (requires timelock)
    /// @param newStrategy Address of the new strategy
    function proposeStrategy(address newStrategy) external onlyOwner {
        if (newStrategy == address(0)) revert InvalidAddress();
        if (newStrategy == address(yieldStrategy)) revert InvalidStrategy();

        // Verify the new strategy accepts the debt asset and points to this vault
        if (IYieldStrategy(newStrategy).asset() != address(debtAsset)) {
            revert InvalidStrategy();
        }
        if (IYieldStrategy(newStrategy).vault() != address(this)) {
            revert InvalidStrategy();
        }

        _strategyTimelock.proposeAddress(newStrategy, TIMELOCK_DELAY);
        emit StrategyChangeProposed(address(yieldStrategy), newStrategy, _strategyTimelock.timestamp);
    }

    /// @notice Execute pending strategy change after timelock
    function executeStrategy() external onlyOwner nonReentrant {
        address oldStrategy = address(yieldStrategy);

        // Withdraw all from old strategy
        uint256 debtBefore = debtAsset.balanceOf(address(this));
        yieldStrategy.withdrawAll();
        uint256 debtAfter = debtAsset.balanceOf(address(this));

        // Update strategy via timelock
        yieldStrategy = IYieldStrategy(_strategyTimelock.executeAddress());

        // Deposit to new strategy
        uint256 toDeposit = debtAfter - debtBefore;
        if (toDeposit > 0) {
            _ensureApprove(address(debtAsset), address(yieldStrategy), toDeposit);
            yieldStrategy.deposit(toDeposit);
        }
        lastStrategyBalance = yieldStrategy.balanceOf();

        emit StrategyChangeExecuted(oldStrategy, address(yieldStrategy));
    }

    /// @notice Cancel pending strategy change
    function cancelStrategy() external onlyOwner {
        address cancelled = _strategyTimelock.cancelAddress();
        emit StrategyChangeCancelled(cancelled);
    }

    // ============ Loan Manager Switching Functions ============

    /// @notice Propose a new loan manager (requires timelock)
    /// @param newLoanManager Address of the new loan manager
    function proposeLoanManager(address newLoanManager) external onlyOwner {
        if (newLoanManager == address(0)) revert InvalidAddress();
        if (newLoanManager == address(loanManager)) revert InvalidAddress();

        if (ILoanManager(newLoanManager).collateralAsset() != address(collateralAsset)) {
            revert InvalidAddress();
        }
        if (ILoanManager(newLoanManager).debtAsset() != address(debtAsset)) {
            revert InvalidAddress();
        }

        _loanManagerTimelock.proposeAddress(newLoanManager, TIMELOCK_DELAY);
        emit LoanManagerChangeProposed(
            address(loanManager), newLoanManager, _loanManagerTimelock.timestamp
        );
    }

    /// @notice Execute pending loan manager change after timelock
    function executeLoanManager() external onlyOwner nonReentrant {
        if (loanManager.loanExists()) revert ActiveLoanExists();

        address oldLoanManager = address(loanManager);
        loanManager = ILoanManager(_loanManagerTimelock.executeAddress());
        emit LoanManagerChangeExecuted(oldLoanManager, address(loanManager));
    }

    /// @notice Cancel pending loan manager change
    function cancelLoanManager() external onlyOwner {
        address cancelled = _loanManagerTimelock.cancelAddress();
        emit LoanManagerChangeCancelled(cancelled);
    }

    // ============ View Functions ============

    /// @notice Estimate total value locked in collateral terms
    function getTotalCollateral() public view returns (uint256 totalCollateral) {
        if (!yieldEnabled) {
            return collateralAsset.balanceOf(address(this));
        }
        return viewHelper.getTotalCollateralValue(address(this));
    }

    // ============ Internal Functions ============

    /// @notice Recover all collateral and debt assets from the loan manager
    function _recoverLoanManagerFunds() internal {
        uint256 lmCollateral = loanManager.getCollateralBalance();
        if (lmCollateral > 0) loanManager.transferCollateral(address(this), lmCollateral);
        uint256 lmDebt = loanManager.getDebtBalance();
        if (lmDebt > 0) loanManager.transferDebt(address(this), lmDebt);
    }

    /// @notice Swap all debt asset in the vault to collateral using swapper (if set)
    function _swapRemainingDebtToCollateral() internal {
        uint256 debtBal = debtAsset.balanceOf(address(this));
        if (debtBal > 1e16 && address(swapper) != address(0)) {
            debtAsset.safeTransfer(address(swapper), debtBal);
            swapper.swapDebtForCollateral(debtBal);
        }
    }

    /// @notice Calculate shares to mint for a deposit
    function _calculateSharesForDeposit(uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        return (collateralAmount * (totalSupply() + VIRTUAL_SHARE_OFFSET))
            / (getTotalCollateral() + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Calculate collateral to return for shares (rounds down)
    function _calculateCollateralForShares(uint256 shareAmount)
        internal
        view
        returns (uint256)
    {
        return (shareAmount * (getTotalCollateral() + VIRTUAL_SHARE_OFFSET))
            / (totalSupply() + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Convert shares to assets rounding up (for mint/previewMint per ERC4626)
    function _convertToAssetsRoundUp(uint256 shareAmount) internal view returns (uint256) {
        uint256 supply = totalSupply() + VIRTUAL_SHARE_OFFSET;
        uint256 totalCollateral = getTotalCollateral() + VIRTUAL_SHARE_OFFSET;
        return (shareAmount * totalCollateral + supply - 1) / supply;
    }

    /// @notice Internal deposit logic shared by deposit() and mint()
    function _deposit(uint256 assets, uint256 sharesToMint, address receiver) internal {
        if (assets < MIN_DEPOSIT) revert AmountTooSmall();
        if (emergencyMode) revert EmergencyModeActive();
        if (depositCap > 0 && getTotalCollateral() + assets > depositCap) {
            revert DepositCapExceeded();
        }

        collateralAsset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, sharesToMint);

        if (yieldEnabled) {
            _deployCapital();
        }

        emit Deposit(msg.sender, receiver, assets, sharesToMint);
    }

    /// @notice Internal redeem logic shared by withdraw(), redeem(), and legacy withdraw()
    /// @return collateralAmount Amount of collateral returned
    /// @return actualShareAmount Amount of shares actually burned
    function _redeem(uint256 shareAmount, address receiver, address _owner)
        internal
        returns (uint256 collateralAmount, uint256 actualShareAmount)
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (balanceOf(_owner) < shareAmount) revert InsufficientShares();
        if (emergencyMode) {
            if (!liquidationComplete) revert EmergencyModeActive();

            // Handle allowance if caller is not owner
            if (msg.sender != _owner) {
                _spendAllowance(_owner, msg.sender, shareAmount);
            }

            actualShareAmount = shareAmount;
            uint256 supply = totalSupply();
            if (supply == 0) return (0, 0);
            uint256 availableCollateral = collateralAsset.balanceOf(address(this));
            collateralAmount = (availableCollateral * actualShareAmount) / supply;

            _burn(_owner, actualShareAmount);

            if (collateralAmount > 0) {
                collateralAsset.safeTransfer(receiver, collateralAmount);
            }

            emit Withdraw(msg.sender, receiver, _owner, collateralAmount, actualShareAmount);
            return (collateralAmount, actualShareAmount);
        }

        // Detect final withdrawal — only the owner themselves can trigger it
        uint256 leftOverCollateral =
            _calculateCollateralForShares(totalSupply() - shareAmount);
        bool isFinalWithdraw = leftOverCollateral < MIN_DEPOSIT && msg.sender == _owner;

        // Handle allowance if caller is not owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, shareAmount);
        }

        actualShareAmount = isFinalWithdraw ? balanceOf(_owner) : shareAmount;
        collateralAmount = _calculateCollateralForShares(actualShareAmount);

        _burn(_owner, actualShareAmount);

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
                uint256 balanceBefore = collateralAsset.balanceOf(address(this));

                _unwindPosition(needed);

                uint256 balanceAfter = collateralAsset.balanceOf(address(this));
                uint256 gained = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

                uint256 totalAvailable = availableCollateral + gained;
                if (totalAvailable < collateralAmount) {
                    collateralAmount = totalAvailable;
                }
            }

            collateralAsset.safeTransfer(receiver, collateralAmount);
        }

        emit Withdraw(msg.sender, receiver, _owner, collateralAmount, actualShareAmount);
    }

    /// @notice Accrue fees from yield strategy profits using checkpoint delta
    /// @dev Fees are only charged on incremental balance gains since the last checkpoint.
    ///      The checkpoint (lastStrategyBalance) always updates regardless of feeRate,
    ///      so changing feeRate from 0 to non-zero never retroactively charges old gains.
    function _accrueYieldFees() internal {
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
    }

    /// @notice Deploy debt asset to yield strategy
    function _deployDebtToYield(uint256 debtAmount) internal {
        if (yieldStrategy.paused()) return;
        _accrueYieldFees();

        _ensureApprove(address(debtAsset), address(yieldStrategy), debtAmount);
        yieldStrategy.deposit(debtAmount);
        lastStrategyBalance = yieldStrategy.balanceOf();
    }

    /// @notice Withdraw debt asset from yield strategy
    function _withdrawFromYieldStrategy(uint256 debtNeeded) internal returns (uint256) {
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance == 0) return 0;

        _accrueYieldFees();

        uint256 toWithdraw = debtNeeded > strategyBalance ? strategyBalance : debtNeeded;
        uint256 received;
        if (toWithdraw > 0) {
            received = yieldStrategy.withdraw(toWithdraw);
        }
        lastStrategyBalance = yieldStrategy.balanceOf();
        return received;
    }

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @param collateralNeeded Amount of collateral to free, or type(uint256).max for full close
    function _unwindPosition(uint256 collateralNeeded) internal {
        bool fullyClose = (collateralNeeded == type(uint256).max);

        // 1. Accrue yield fees
        _accrueYieldFees();

        // 2. Withdraw from yield strategy
        if (fullyClose) {
            yieldStrategy.withdrawAll();
            lastStrategyBalance = 0;
        } else {
            if (loanManager.loanExists()) {
                (uint256 positionCollateral, uint256 positionDebt) = loanManager.getPositionValues();
                uint256 debtToRepay = positionCollateral > 0
                    ? (positionDebt * collateralNeeded) / positionCollateral
                    : 0;
                if (debtToRepay > 0) {
                    // Add 5% buffer for slippage/rounding
                    uint256 debtNeeded = (debtToRepay * 105) / 100;
                    _withdrawFromYieldStrategy(debtNeeded);
                }
            }
        }

        // 3. Transfer idle debt asset to loan manager
        uint256 debtBalance = debtAsset.balanceOf(address(this));
        if (debtBalance > 0) {
            debtAsset.safeTransfer(address(loanManager), debtBalance);
        }

        // 4. Loan manager handles everything and sends collateral back
        loanManager.unwindPosition(collateralNeeded);

        emit CapitalUnwound(collateralNeeded, collateralAsset.balanceOf(address(this)));
    }

    /// @notice Increase LTV by borrowing more
    function _increaseLtv(uint256 _targetLtv) internal {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);

        uint256 targetDebt = (collateralValue * _targetLtv) / PRECISION;
        if (targetDebt <= currentDebt) return;

        uint256 additionalBorrow = targetDebt - currentDebt;
        loanManager.borrowMore(0, additionalBorrow);

        // Get debt asset from loan manager and deploy to yield vault
        uint256 debtBalance = loanManager.getDebtBalance();
        if (debtBalance > 0) {
            loanManager.transferDebt(address(this), debtBalance);
            _deployDebtToYield(debtBalance);
        }
    }

    /// @notice Decrease LTV by repaying debt
    function _decreaseLtv(uint256 _targetLtv) internal {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);

        uint256 targetDebt = (collateralValue * _targetLtv) / PRECISION;
        if (targetDebt >= currentDebt) return;

        uint256 toRepay = currentDebt - targetDebt;

        // Get debt asset from yield strategy
        _withdrawFromYieldStrategy(toRepay);

        // Transfer debt asset to loan manager and repay
        uint256 debtBalance = debtAsset.balanceOf(address(this));
        uint256 repayAmount = toRepay < debtBalance ? toRepay : debtBalance;

        if (repayAmount > 0) {
            debtAsset.safeTransfer(address(loanManager), repayAmount);
            loanManager.repayDebt(repayAmount);
        }
    }

    /// @notice Ensure token approval for spender
    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }

    // ============ ERC20 Overrides for decimals ============

    /// @notice Returns collateral decimals to match ERC4626 asset
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(address(collateralAsset)).decimals();
    }
}
