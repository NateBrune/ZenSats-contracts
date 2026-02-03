// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
import { ILlamaLoanManager } from "./interfaces/ILlamaLoanManager.sol";
import { LlamaLoanManager } from "./LlamaLoanManager.sol";
import { IVaultTracker } from "./interfaces/IVaultTracker.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
/// @title Zenji
/// @notice ERC4626-compliant conservative WBTC yield vault using LlamaLend and yield strategies
/// @dev Deposits WBTC as collateral to LlamaLend, borrows crvUSD, deposits to yield strategy

contract Zenji is ERC20, IERC4626, IERC3156FlashBorrower {
    using TimelockLib for TimelockLib.TimelockData;
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADBAND_SPREAD = 3e16; // 3%
    uint256 public constant MIN_TARGET_LTV = 15e16; // 15%
    uint256 public constant MAX_TARGET_LTV = 75e16; // 75%
    uint256 public constant LLAMALEND_BANDS = 4;
    uint256 public constant MIN_DEPOSIT = 1e4;
    uint256 public constant MAX_FEE_RATE = 2e17; // 20%
    uint256 public constant VIRTUAL_SHARE_OFFSET = 1e5;
    uint256 public constant MAX_REBALANCE_BOUNTY = 2e17; // 20%
    uint256 public constant TIMELOCK_DELAY = 1 minutes; //TODO: Change before deployment to 2 days;
    address public constant CRVUSD_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
    bytes32 private constant FLASH_LOAN_CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // ============ Immutables ============

    IERC20 public immutable wbtc;
    IERC20 public immutable crvUSD;
    ILlamaLoanManager public immutable loanManager;

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
    IVaultTracker public tracker;
    uint256 public rebalanceBountyRate;
    uint256 public depositCap;

    // Yield strategy
    IYieldStrategy public yieldStrategy;
    address public pendingStrategy;
    uint256 public pendingStrategyTimestamp;

    // Timelock state (using TimelockLib)
    TimelockLib.TimelockData internal _feeRateTimelock;
    TimelockLib.TimelockData internal _targetLtvTimelock;

    // ============ Events ============

    // Keeper actions
    event Rebalance(uint256 oldLtv, uint256 newLtv, bool increased);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);

    // Capital management
    event CapitalDeployed(uint256 wbtcAmount, uint256 crvUsdBorrowed);
    event CapitalUnwound(uint256 wbtcNeeded, uint256 wbtcReceived);

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

    // Timelock events
    event FeeRateChangeProposed(uint256 currentRate, uint256 newRate, uint256 effectiveTime);
    event FeeRateChangeExecuted(uint256 oldRate, uint256 newRate);
    event FeeRateChangeCancelled(uint256 cancelledRate);
    event TargetLtvChangeProposed(uint256 currentLtv, uint256 newLtv, uint256 effectiveTime);
    event TargetLtvChangeExecuted(uint256 oldLtv, uint256 newLtv);
    event TargetLtvChangeCancelled(uint256 cancelledLtv);

    // Strategy events
    event StrategyChangeProposed(
        address indexed currentStrategy, address indexed newStrategy, uint256 effectiveTime
    );
    event StrategyChangeExecuted(address indexed oldStrategy, address indexed newStrategy);
    event StrategyChangeCancelled(address indexed cancelledStrategy);
    event StrategyPauseToggled(bool paused, uint256 crvUsdReceived);

    // Emergency
    event EmergencyModeEntered();
    event LiquidationComplete(uint256 wbtcRecovered, uint256 flashloanAmount);
    event AssetsRescued(address indexed token, address indexed recipient, uint256 amount);
    event FeesAccrued(uint256 profit, uint256 fees, uint256 totalAccumulatedFees);
    event YieldHarvested(address indexed caller);
    event EmergencyWbtcTransferred(uint256 amount);
    event EmergencyCrvUsdTransferred(uint256 amount);
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
    error InsufficientFlashloanRepayment();

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
        address _wbtc,
        address _crvUSD,
        address _llamaLend,
        address _yieldStrategy,
        address _wbtcCrvUsdPool,
        address _btcOracle,
        address _crvUsdOracle,
        address _owner
    ) ERC20("SiloBooster WBTC Vault", "sbWBTC") {
        if (
            _wbtc == address(0) || _crvUSD == address(0) || _llamaLend == address(0)
                || _wbtcCrvUsdPool == address(0) || _btcOracle == address(0)
                || _crvUsdOracle == address(0) || _owner == address(0)
        ) {
            revert InvalidAddress();
        }

        wbtc = IERC20(_wbtc);
        crvUSD = IERC20(_crvUSD);
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

        // Deploy the LlamaLoanManager
        loanManager = ILlamaLoanManager(
            address(
                new LlamaLoanManager(
                    _wbtc,
                    _crvUSD,
                    _llamaLend,
                    _wbtcCrvUsdPool,
                    _btcOracle,
                    _crvUsdOracle,
                    address(this)
                )
            )
        );
    }

    /// @notice Set initial yield strategy (can only be called once if strategy not set in constructor)
    /// @param _strategy The yield strategy address
    function setInitialStrategy(address _strategy) external onlyOwner {
        if (address(yieldStrategy) != address(0)) revert StrategyAlreadySet();
        if (_strategy == address(0)) revert InvalidAddress();
        yieldStrategy = IYieldStrategy(_strategy);
        emit StrategyChangeExecuted(address(0), _strategy);
    }

    // ============ ERC4626 Required Functions ============

    /// @notice Returns the address of the underlying asset (WBTC)
    function asset() external view override returns (address) {
        return address(wbtc);
    }

    /// @notice Returns total WBTC managed by the vault
    function totalAssets() public view override returns (uint256) {
        return getTotalWbtc();
    }

    /// @notice Convert assets to shares
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _calculateSharesForDeposit(assets);
    }

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shareAmount) public view override returns (uint256) {
        return _calculateWbtcForShares(shareAmount);
    }

    /// @notice Maximum deposit allowed for receiver
    function maxDeposit(address) external view override returns (uint256) {
        if (emergencyMode) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 totalWbtc = getTotalWbtc();
        return totalWbtc >= depositCap ? 0 : depositCap - totalWbtc;
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
            return (wbtc.balanceOf(address(this)) * balanceOf(_owner)) / supply;
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
            uint256 availableWbtc = wbtc.balanceOf(address(this));
            if (availableWbtc == 0 || supply == 0) return 0;
            return (assets * supply + availableWbtc - 1) / availableWbtc;
        }

        // Round up for withdrawals
        uint256 totalWbtc = getTotalWbtc();
        if (totalWbtc == 0 || supply == 0) return assets;
        return (assets * (supply + VIRTUAL_SHARE_OFFSET) + totalWbtc - 1)
            / (totalWbtc + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Preview assets for redeem
    function previewRedeem(uint256 shareAmount) external view override returns (uint256) {
        if (emergencyMode && liquidationComplete) {
            uint256 supply = totalSupply();
            if (supply == 0) return 0;
            return (wbtc.balanceOf(address(this)) * shareAmount) / supply;
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
            uint256 availableWbtc = wbtc.balanceOf(address(this));
            if (availableWbtc == 0) revert ZeroAmount();
            shareAmount = (assets * totalSupply() + availableWbtc - 1) / availableWbtc;
        } else {
            // Calculate shares to burn (round up)
            uint256 totalWbtc = getTotalWbtc();
            uint256 supply = totalSupply();
            shareAmount = (assets * (supply + VIRTUAL_SHARE_OFFSET) + totalWbtc - 1)
                / (totalWbtc + VIRTUAL_SHARE_OFFSET);
        }

        (, shareAmount) = _redeem(shareAmount, receiver, _owner);
    }

    /// @notice ERC4626 redeem - redeem exact shares for assets
    function redeem(uint256 shareAmount, address receiver, address _owner)
        external
        override
        nonReentrant
        returns (uint256 wbtcAmount)
    {
        (wbtcAmount,) = _redeem(shareAmount, receiver, _owner);
    }

    // ============ Legacy User Functions (for backwards compatibility) ============

    /// @notice Legacy deposit - deposit WBTC into the vault
    function deposit(uint256 amount) external nonReentrant returns (uint256 sharesMinted) {
        sharesMinted = _calculateSharesForDeposit(amount);
        _deposit(amount, sharesMinted, msg.sender);
    }

    /// @notice Legacy withdraw - withdraw WBTC from the vault by burning shares
    function withdraw(uint256 shareAmount) external nonReentrant returns (uint256 wbtcAmount) {
        (wbtcAmount,) = _redeem(shareAmount, msg.sender, msg.sender);
    }

    /// @notice Legacy shares function for backwards compatibility
    function shares(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /// @notice Legacy totalShares function for backwards compatibility
    function totalShares() external view returns (uint256) {
        return totalSupply();
    }

    // ============ Keeper Functions ============

    /// @notice Deploy idle WBTC into yield strategy
    function _deployCapital() internal {
        if (idle || emergencyMode) return;
        uint256 idleWbtc = wbtc.balanceOf(address(this));
        if (idleWbtc == 0) revert ZeroAmount();

        uint256 borrowAmount = loanManager.calculateBorrowAmount(idleWbtc, targetLtv);
        if (borrowAmount == 0) return;

        loanManager.checkOracleFreshness();

        wbtc.safeTransfer(address(loanManager), idleWbtc);

        if (!loanManager.loanExists()) {
            loanManager.createLoan(idleWbtc, borrowAmount, LLAMALEND_BANDS);
        } else {
            loanManager.addCollateral(idleWbtc);
            loanManager.borrowMore(0, borrowAmount);
        }

        // Get crvUSD from loan manager and deploy to yield vault
        uint256 crvUsdBalance = loanManager.getCrvUsdBalance();
        if (crvUsdBalance > 0) {
            loanManager.transferCrvUsd(address(this), crvUsdBalance);
            _deployCrvUsdToYield(crvUsdBalance);
        }

        emit CapitalDeployed(idleWbtc, borrowAmount);
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
                    crvUSD.safeTransfer(msg.sender, actualBounty);
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

    /// @notice Enter/exit idle mode (unwind carry trade, hold WBTC)
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

            uint256 crvUsdBalance = crvUSD.balanceOf(address(this));
            if (crvUsdBalance > 0) {
                crvUSD.safeTransfer(address(loanManager), crvUsdBalance);
            }

            if (loanManager.loanExists()) {
                loanManager.unwindPosition(type(uint256).max);
            }

            _swapRemainingCrvUsdToWbtc();

            idle = true;
            yieldEnabled = false;
            emit IdleModeEntered();
        } else {
            idle = false;
            emit IdleModeExited();
        }
    }

    /// @notice Pause/unpause the yield strategy and unwind when pausing
    function pauseStrategy() external onlyOwner nonReentrant returns (uint256 crvUsdReceived) {
        if (address(yieldStrategy) == address(0)) revert InvalidStrategy();

        _accrueYieldFees();
        crvUsdReceived = yieldStrategy.pauseStrategy();
        lastStrategyBalance = yieldStrategy.balanceOf();

        emit StrategyPauseToggled(yieldStrategy.paused(), crvUsdReceived);
    }

    /// @notice Set the tracker contract address
    function setTracker(address tracker_) external onlyOwner {
        tracker = IVaultTracker(tracker_);
        emit TrackerUpdated(tracker_);
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

        // Withdraw from yield strategy to get actual crvUSD
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance > 0 && fees > 0) {
            uint256 toWithdraw = fees > strategyBalance ? strategyBalance : fees;
            if (toWithdraw > 0) {
                yieldStrategy.withdraw(toWithdraw);
            }
        }
        lastStrategyBalance = yieldStrategy.balanceOf();

        // Transfer fees (includes any idle crvUSD)
        uint256 crvUsdBalance = crvUSD.balanceOf(address(this));
        uint256 toTransfer = fees > crvUsdBalance ? crvUsdBalance : fees;

        if (toTransfer > 0) {
            crvUSD.safeTransfer(recipient, toTransfer);
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

    /// @notice Atomically unwind all positions using crvUSD flashloan
    /// @dev Only callable in emergency mode. Leaves vault with only idle WBTC.
    ///      No nonReentrant: flashloan callback re-enters. Safety from onlyOwner +
    ///      liquidationComplete one-shot + callback caller validation.
    function liquidateAllWithFlashloan() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (liquidationComplete) revert LiquidationAlreadyComplete();

        // Step 1: Try to withdraw all from yield strategy (resilient if bricked)
        // Skip _accrueYieldFees() — it calls yieldStrategy.balanceOf() which makes
        // external calls that could revert and brick the entire emergency liquidation.
        // Fees are irrelevant here: accumulatedFees is zeroed out below anyway.
        if (address(yieldStrategy) != address(0)) {
            try yieldStrategy.withdrawAll() { }
            catch {
                try yieldStrategy.emergencyWithdraw() { } catch { }
            }
        }
        lastStrategyBalance = 0;
        accumulatedFees = 0;

        // Step 2: If no active loan, just recover and finish
        if (!loanManager.loanExists()) {
            _recoverLoanManagerFunds();
            _swapRemainingCrvUsdToWbtc();
            liquidationComplete = true;
            emit LiquidationComplete(wbtc.balanceOf(address(this)), 0);
            return;
        }

        // Step 3: Calculate debt vs available crvUSD
        uint256 totalDebt = loanManager.getCurrentDebt();
        uint256 availableCrvUsd = crvUSD.balanceOf(address(this));

        if (availableCrvUsd >= totalDebt) {
            // Yield covers full debt - no flashloan needed
            crvUSD.safeTransfer(address(loanManager), totalDebt);
            loanManager.repayDebt(totalDebt);
            _recoverLoanManagerFunds();
            _swapRemainingCrvUsdToWbtc();
            liquidationComplete = true;
            emit LiquidationComplete(wbtc.balanceOf(address(this)), 0);
        } else {
            // Need flashloan for the shortfall (+ 0.5% buffer for interest accrual)
            uint256 shortfall = totalDebt - availableCrvUsd;
            uint256 flashloanAmount = (shortfall * 10050) / 10000;

            // Initiate flashloan - onFlashLoan callback handles the unwind
            IERC3156FlashLender(CRVUSD_FLASH_LENDER).flashLoan(
                IERC3156FlashBorrower(address(this)), address(crvUSD), flashloanAmount, ""
            );

            liquidationComplete = true;
            emit LiquidationComplete(wbtc.balanceOf(address(this)), flashloanAmount);
        }
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        if (msg.sender != CRVUSD_FLASH_LENDER) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        if (token != address(crvUSD)) revert InvalidAddress();

        uint256 repaymentNeeded = amount + fee;

        // Step 1: Repay all LlamaLend debt
        // We now have: our crvUSD + flashloaned crvUSD
        uint256 totalDebt = loanManager.getCurrentDebt();
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        uint256 toRepay = totalDebt < crvUsdBal ? totalDebt : crvUsdBal;

        crvUSD.safeTransfer(address(loanManager), toRepay);
        loanManager.repayDebt(toRepay);

        // Step 2: Handle residual debt from rounding/interest
        if (loanManager.loanExists()) {
            uint256 residual = loanManager.getCurrentDebt();
            uint256 remaining = crvUSD.balanceOf(address(this));
            if (residual > 0 && remaining >= residual) {
                crvUSD.safeTransfer(address(loanManager), residual);
                loanManager.repayDebt(residual);
            }
        }

        // Step 3: Recover all WBTC collateral + any crvUSD from loanManager
        _recoverLoanManagerFunds();

        // Step 4: Swap WBTC -> crvUSD if we don't have enough for flashloan repayment
        uint256 crvUsdAvailable = crvUSD.balanceOf(address(this));
        if (crvUsdAvailable < repaymentNeeded) {
            uint256 shortfall = repaymentNeeded - crvUsdAvailable;
            uint256 wbtcQuote = loanManager.quoteWbtcForCrvUsd(shortfall);
            uint256 wbtcNeeded = (wbtcQuote * 105) / 100 + 1;
            uint256 wbtcBal = wbtc.balanceOf(address(this));
            uint256 toSwap = wbtcNeeded < wbtcBal ? wbtcNeeded : wbtcBal;
            if (toSwap > 0) {
                wbtc.safeTransfer(address(loanManager), toSwap);
                loanManager.swapCollateralForDebt(toSwap);
                loanManager.transferCrvUsd(address(this), loanManager.getCrvUsdBalance());
            }

            // If still short, swap additional WBTC using remaining balance
            crvUsdAvailable = crvUSD.balanceOf(address(this));
            if (crvUsdAvailable < repaymentNeeded) {
                uint256 remainingWbtc = wbtc.balanceOf(address(this));
                if (remainingWbtc > 0) {
                    wbtc.safeTransfer(address(loanManager), remainingWbtc);
                    loanManager.swapCollateralForDebt(remainingWbtc);
                    loanManager.transferCrvUsd(address(this), loanManager.getCrvUsdBalance());
                }
            }
        }

        // Step 5: Verify and transfer repayment to flash lender
        // The crvUSD flash lender uses a balance-check pattern (not transferFrom),
        // so we must transfer the repayment back explicitly.
        if (crvUSD.balanceOf(address(this)) < repaymentNeeded) {
            revert InsufficientFlashloanRepayment();
        }
        crvUSD.safeTransfer(msg.sender, repaymentNeeded);

        return FLASH_LOAN_CALLBACK;
    }

    /// @notice Rescue stuck tokens from the vault (emergency mode only)
    /// @dev Cannot rescue WBTC after liquidation — that belongs to shareholders
    function rescueAssets(address token, address recipient) external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (recipient == address(0)) revert InvalidAddress();
        if (liquidationComplete && token == address(wbtc)) revert LiquidationAlreadyComplete();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
        emit AssetsRescued(token, recipient, balance);
    }

    // ============ Emergency Rescue (Fallback) ============

    function transferWbtc() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        uint256 amount = wbtc.balanceOf(address(loanManager));
        loanManager.transferWbtc(address(this), amount);
        emit EmergencyWbtcTransferred(amount);
    }

    function transferCrvUsd() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        uint256 amount = crvUSD.balanceOf(address(loanManager));
        loanManager.transferCrvUsd(address(this), amount);
        emit EmergencyCrvUsdTransferred(amount);
    }

    function emergencyRedeemYield() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotActive();
        yieldStrategy.emergencyWithdraw();
        lastStrategyBalance = 0;
        // Convert recovered crvUSD to WBTC so it's included in pro-rata distribution
        _swapRemainingCrvUsdToWbtc();
        emit EmergencyYieldRedeemed();
    }

    // Timelock functions using TimelockLib
    function proposeFeeRate(uint256 newFeeRate) external onlyOwner {
        if (newFeeRate > MAX_FEE_RATE) revert InvalidFeeRate();
        _feeRateTimelock.propose(newFeeRate, TIMELOCK_DELAY);
        emit FeeRateChangeProposed(feeRate, newFeeRate, _feeRateTimelock.timestamp);
    }

    function executeFeeRate() external onlyOwner {
        uint256 oldFeeRate = feeRate;
        feeRate = _feeRateTimelock.execute();
        emit FeeRateChangeExecuted(oldFeeRate, feeRate);
    }

    function cancelFeeRate() external onlyOwner {
        uint256 cancelledRate = _feeRateTimelock.cancel();
        emit FeeRateChangeCancelled(cancelledRate);
    }

    function proposeTargetLtv(uint256 newTargetLtv) external onlyOwner {
        if (newTargetLtv < MIN_TARGET_LTV || newTargetLtv > MAX_TARGET_LTV) {
            revert InvalidTargetLtv();
        }
        _targetLtvTimelock.propose(newTargetLtv, TIMELOCK_DELAY);
        emit TargetLtvChangeProposed(targetLtv, newTargetLtv, _targetLtvTimelock.timestamp);
    }

    function executeTargetLtv() external onlyOwner {
        uint256 oldTargetLtv = targetLtv;
        targetLtv = _targetLtvTimelock.execute();
        emit TargetLtvChangeExecuted(oldTargetLtv, targetLtv);
    }

    function cancelTargetLtv() external onlyOwner {
        uint256 cancelledLtv = _targetLtvTimelock.cancel();
        emit TargetLtvChangeCancelled(cancelledLtv);
    }

    // Timelock getters for backwards compatibility
    function pendingFeeRate() external view returns (uint256) {
        return _feeRateTimelock.pendingValue;
    }

    function pendingFeeRateTimestamp() external view returns (uint256) {
        return _feeRateTimelock.timestamp;
    }

    function pendingTargetLtv() external view returns (uint256) {
        return _targetLtvTimelock.pendingValue;
    }

    function pendingTargetLtvTimestamp() external view returns (uint256) {
        return _targetLtvTimelock.timestamp;
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

        // Verify the new strategy accepts crvUSD and points to this vault
        if (IYieldStrategy(newStrategy).asset() != address(crvUSD)) {
            revert InvalidStrategy();
        }
        if (IYieldStrategy(newStrategy).vault() != address(this)) {
            revert InvalidStrategy();
        }

        pendingStrategy = newStrategy;
        pendingStrategyTimestamp = block.timestamp + TIMELOCK_DELAY;
        emit StrategyChangeProposed(address(yieldStrategy), newStrategy, pendingStrategyTimestamp);
    }

    /// @notice Execute pending strategy change after timelock
    function executeStrategy() external onlyOwner nonReentrant {
        if (pendingStrategy == address(0)) revert TimelockLib.NoTimelockPending();
        if (block.timestamp < pendingStrategyTimestamp) revert TimelockLib.TimelockNotReady();
        if (block.timestamp > pendingStrategyTimestamp + TimelockLib.TIMELOCK_EXPIRY) {
            revert TimelockLib.TimelockExpired();
        }

        address oldStrategy = address(yieldStrategy);
        address newStrategy = pendingStrategy;

        // Withdraw all from old strategy
        uint256 crvUsdBefore = crvUSD.balanceOf(address(this));
        yieldStrategy.withdrawAll();
        uint256 crvUsdAfter = crvUSD.balanceOf(address(this));

        // Update strategy
        yieldStrategy = IYieldStrategy(newStrategy);
        pendingStrategy = address(0);
        pendingStrategyTimestamp = 0;

        // Deposit to new strategy
        uint256 toDeposit = crvUsdAfter - crvUsdBefore;
        if (toDeposit > 0) {
            _ensureApprove(address(crvUSD), address(yieldStrategy), toDeposit);
            yieldStrategy.deposit(toDeposit);
        }
        lastStrategyBalance = yieldStrategy.balanceOf();

        emit StrategyChangeExecuted(oldStrategy, newStrategy);
    }

    /// @notice Cancel pending strategy change
    function cancelStrategy() external onlyOwner {
        if (pendingStrategy == address(0)) revert TimelockLib.NoTimelockPending();
        address cancelled = pendingStrategy;
        pendingStrategy = address(0);
        pendingStrategyTimestamp = 0;
        emit StrategyChangeCancelled(cancelled);
    }

    // ============ View Functions ============

    /// @notice Get current LTV ratio
    function getCurrentLTV() public view returns (uint256 ltv) {
        return loanManager.getCurrentLTV();
    }

    /// @notice Get current amount of Collateral
    function getCurrentCollateral() public view returns (uint256 collateral) {
        return loanManager.getCurrentCollateral();
    }

    /// @notice Estimate total value locked in WBTC terms
    function getTotalWbtc() public view returns (uint256 totalWbtc) {
        if (!yieldEnabled) {
            return _getEmergencyValue();
        }
        return loanManager.getDebtValue(this.getTotalValue());
    }

    /// @notice Get total value of vault in crvUSD terms
    function getTotalValue() public view returns (uint256 totalValue) {
        if (!yieldEnabled) {
            return loanManager.getCollateralValue(_getEmergencyValue());
        }
        return _getNormalValue();
    }

    function _getEmergencyValue() internal view returns (uint256 totalValue) {
        return wbtc.balanceOf(address(this));
    }

    function _getNormalValue() internal view returns (uint256 totalValue) {
        // Idle WBTC value
        uint256 idleWbtc = wbtc.balanceOf(address(this));
        totalValue = loanManager.getCollateralValue(idleWbtc);

        // Collateral in LlamaLend (via loan manager)
        if (loanManager.loanExists()) {
            (uint256 collateral, uint256 debt) = loanManager.getPositionValues();
            totalValue += loanManager.getCollateralValue(collateral);
            // Saturating subtraction: if soft-liquidation makes debt > value, clamp to 0
            if (debt < totalValue) {
                totalValue -= debt;
            } else {
                totalValue = 0;
            }
        }

        // crvUSD in yield strategy (excluding accumulated fees which belong to protocol)
        if (address(yieldStrategy) != address(0)) {
            uint256 strategyBalance = yieldStrategy.balanceOf();
            if (strategyBalance > accumulatedFees) {
                totalValue += strategyBalance - accumulatedFees;
            }
        }

        // Idle crvUSD
        totalValue += crvUSD.balanceOf(address(this));

        // WBTC in loan manager
        uint256 loanManagerWbtc = loanManager.getWbtcBalance();
        if (loanManagerWbtc > 0) {
            totalValue += loanManager.getCollateralValue(loanManagerWbtc);
        }

        // crvUSD in loan manager
        totalValue += loanManager.getCrvUsdBalance();
    }

    /// @notice Get user's share value in WBTC
    function getUserValue(address user) external view returns (uint256 wbtcValue) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 userShares = balanceOf(user);
        return (getTotalWbtc() * userShares) / supply;
    }

    /// @notice Get vault health factor from LlamaLend
    function getHealth() external view returns (int256 health) {
        return loanManager.getHealth();
    }

    /// @notice Check if rebalance is needed
    function isRebalanceNeeded() external view returns (bool needed) {
        if (!loanManager.loanExists()) return false;
        uint256 ltv = loanManager.getCurrentLTV();
        return ltv < (targetLtv - DEADBAND_SPREAD) || ltv > (targetLtv + DEADBAND_SPREAD);
    }

    /// @notice Get LTV bounds
    function getLtvBounds() external view returns (uint256 lowerBand, uint256 upperBand) {
        lowerBand = targetLtv - DEADBAND_SPREAD;
        upperBand = targetLtv + DEADBAND_SPREAD;
    }

    /// @notice Get total fees (accumulated + pending from balance gains since last checkpoint)
    /// @return totalFees Total fees including unrealized
    /// @return pendingFees Fees not yet accrued
    function getPendingFees() external view returns (uint256 totalFees, uint256 pendingFees) {
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance > lastStrategyBalance) {
            uint256 delta = strategyBalance - lastStrategyBalance;
            pendingFees = (delta * feeRate) / PRECISION;
        }

        totalFees = accumulatedFees + pendingFees;
    }

    /// @notice Get yield cost basis (legacy - for backwards compatibility)
    /// @dev Reads from the current yield strategy
    function yieldCostBasis() external view returns (uint256) {
        return yieldStrategy.costBasis();
    }

    /// @notice Get yield strategy statistics
    /// @return strategyName Name of the current strategy
    /// @return currentValue Current redeemable crvUSD
    /// @return costBasis Original deposited amount
    /// @return unrealizedProfit Profit not yet realized
    function getYieldStrategyStats()
        external
        view
        returns (
            string memory strategyName,
            uint256 currentValue,
            uint256 costBasis,
            uint256 unrealizedProfit
        )
    {
        strategyName = yieldStrategy.name();
        currentValue = yieldStrategy.balanceOf();
        costBasis = yieldStrategy.costBasis();
        unrealizedProfit = yieldStrategy.unrealizedProfit();
    }

    /// @notice Get yield vault statistics (legacy - for backwards compatibility)
    function getYieldVaultStats()
        external
        view
        returns (
            uint256 yieldShares,
            uint256 currentValue,
            uint256 costBasis,
            uint256 unrealizedProfit
        )
    {
        return (
            0,
            yieldStrategy.balanceOf(),
            yieldStrategy.costBasis(),
            yieldStrategy.unrealizedProfit()
        );
    }

    // ============ Internal Functions ============

    /// @notice Recover all WBTC and crvUSD from the loan manager
    function _recoverLoanManagerFunds() internal {
        uint256 lmWbtc = loanManager.getWbtcBalance();
        if (lmWbtc > 0) loanManager.transferWbtc(address(this), lmWbtc);
        uint256 lmCrvUsd = loanManager.getCrvUsdBalance();
        if (lmCrvUsd > 0) loanManager.transferCrvUsd(address(this), lmCrvUsd);
    }

    /// @notice Swap all crvUSD in the vault to WBTC via loanManager
    function _swapRemainingCrvUsdToWbtc() internal {
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        if (crvUsdBal > 1e16) {
            crvUSD.safeTransfer(address(loanManager), crvUsdBal);
            loanManager.swapDebtForCollateral(crvUsdBal);
            uint256 lmWbtc = loanManager.getWbtcBalance();
            if (lmWbtc > 0) loanManager.transferWbtc(address(this), lmWbtc);
        }
    }

    /// @notice Calculate shares to mint for a deposit
    function _calculateSharesForDeposit(uint256 wbtcAmount) internal view returns (uint256) {
        return (wbtcAmount * (totalSupply() + VIRTUAL_SHARE_OFFSET))
            / (getTotalWbtc() + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Calculate WBTC to return for shares (rounds down)
    function _calculateWbtcForShares(uint256 shareAmount) internal view returns (uint256) {
        return (shareAmount * (getTotalWbtc() + VIRTUAL_SHARE_OFFSET))
            / (totalSupply() + VIRTUAL_SHARE_OFFSET);
    }

    /// @notice Convert shares to assets rounding up (for mint/previewMint per ERC4626)
    function _convertToAssetsRoundUp(uint256 shareAmount) internal view returns (uint256) {
        uint256 supply = totalSupply() + VIRTUAL_SHARE_OFFSET;
        uint256 totalWbtc = getTotalWbtc() + VIRTUAL_SHARE_OFFSET;
        return (shareAmount * totalWbtc + supply - 1) / supply;
    }

    /// @notice Internal deposit logic shared by deposit() and mint()
    function _deposit(uint256 assets, uint256 sharesToMint, address receiver) internal {
        if (assets < MIN_DEPOSIT) revert AmountTooSmall();
        if (emergencyMode) revert EmergencyModeActive();
        if (depositCap > 0 && getTotalWbtc() + assets > depositCap) revert DepositCapExceeded();

        wbtc.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, sharesToMint);

        if (yieldEnabled) {
            _deployCapital();
        }

        emit Deposit(msg.sender, receiver, assets, sharesToMint);
    }

    /// @notice Internal redeem logic shared by withdraw(), redeem(), and legacy withdraw()
    /// @return wbtcAmount Amount of WBTC returned
    /// @return actualShareAmount Amount of shares actually burned
    function _redeem(uint256 shareAmount, address receiver, address _owner)
        internal
        returns (uint256 wbtcAmount, uint256 actualShareAmount)
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
            uint256 availableWbtc = wbtc.balanceOf(address(this));
            wbtcAmount = (availableWbtc * actualShareAmount) / supply;

            _burn(_owner, actualShareAmount);

            if (wbtcAmount > 0) {
                wbtc.safeTransfer(receiver, wbtcAmount);
            }

            emit Withdraw(msg.sender, receiver, _owner, wbtcAmount, actualShareAmount);
            return (wbtcAmount, actualShareAmount);
        }

        // Detect final withdrawal — only the owner themselves can trigger it
        uint256 leftOverWbtc = _calculateWbtcForShares(totalSupply() - shareAmount);
        bool isFinalWithdraw = leftOverWbtc < MIN_DEPOSIT && msg.sender == _owner;

        // Handle allowance if caller is not owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, shareAmount);
        }

        actualShareAmount = isFinalWithdraw ? balanceOf(_owner) : shareAmount;
        wbtcAmount = _calculateWbtcForShares(actualShareAmount);

        _burn(_owner, actualShareAmount);

        if (isFinalWithdraw) {
            _unwindPosition(type(uint256).max);
            wbtcAmount = wbtc.balanceOf(address(this));

            if (wbtcAmount > 0) {
                wbtc.safeTransfer(receiver, wbtcAmount);
            }
        } else {
            uint256 availableWbtc = wbtc.balanceOf(address(this));

            if (availableWbtc < wbtcAmount) {
                uint256 needed = wbtcAmount - availableWbtc;
                uint256 balanceBefore = wbtc.balanceOf(address(this));

                _unwindPosition(needed);

                uint256 balanceAfter = wbtc.balanceOf(address(this));
                uint256 gained = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

                uint256 totalAvailable = availableWbtc + gained;
                if (totalAvailable < wbtcAmount) {
                    wbtcAmount = totalAvailable;
                }
            }

            wbtc.safeTransfer(receiver, wbtcAmount);
        }

        emit Withdraw(msg.sender, receiver, _owner, wbtcAmount, actualShareAmount);
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

    /// @notice Deploy crvUSD to yield strategy
    function _deployCrvUsdToYield(uint256 crvUsdAmount) internal {
        if (yieldStrategy.paused()) return;
        _accrueYieldFees();

        _ensureApprove(address(crvUSD), address(yieldStrategy), crvUsdAmount);
        yieldStrategy.deposit(crvUsdAmount);
        lastStrategyBalance = yieldStrategy.balanceOf();
    }

    /// @notice Withdraw crvUSD from yield strategy
    function _withdrawFromYieldStrategy(uint256 crvUsdNeeded) internal returns (uint256) {
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance == 0) return 0;

        _accrueYieldFees();

        uint256 toWithdraw = crvUsdNeeded > strategyBalance ? strategyBalance : crvUsdNeeded;
        uint256 received;
        if (toWithdraw > 0) {
            received = yieldStrategy.withdraw(toWithdraw);
        }
        lastStrategyBalance = yieldStrategy.balanceOf();
        return received;
    }

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @param wbtcNeeded Amount of WBTC to free, or type(uint256).max for full close
    function _unwindPosition(uint256 wbtcNeeded) internal {
        bool fullyClose = (wbtcNeeded == type(uint256).max);

        // 1. Accrue yield fees
        _accrueYieldFees();

        // 2. Withdraw from yield strategy
        if (fullyClose) {
            yieldStrategy.withdrawAll();
            lastStrategyBalance = 0;
        } else {
            if (loanManager.loanExists()) {
                (uint256 positionCollateral, uint256 positionDebt) = loanManager.getPositionValues();
                uint256 debtToRepay =
                    positionCollateral > 0 ? (positionDebt * wbtcNeeded) / positionCollateral : 0;
                if (debtToRepay > 0) {
                    // Add 5% buffer for slippage/rounding
                    uint256 crvUsdNeeded = (debtToRepay * 105) / 100;
                    _withdrawFromYieldStrategy(crvUsdNeeded);
                }
            }
        }

        // 3. Transfer idle crvUSD to loan manager
        uint256 crvUsdBalance = crvUSD.balanceOf(address(this));
        if (crvUsdBalance > 0) {
            crvUSD.safeTransfer(address(loanManager), crvUsdBalance);
        }

        // 4. Loan manager handles everything and sends WBTC back
        loanManager.unwindPosition(wbtcNeeded);

        emit CapitalUnwound(wbtcNeeded, wbtc.balanceOf(address(this)));
    }

    /// @notice Increase LTV by borrowing more
    function _increaseLtv(uint256 _targetLtv) internal {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);

        uint256 targetDebt = (collateralValue * _targetLtv) / PRECISION;
        if (targetDebt <= currentDebt) return;

        uint256 additionalBorrow = targetDebt - currentDebt;
        loanManager.borrowMore(0, additionalBorrow);

        // Get crvUSD from loan manager and deploy to yield vault
        uint256 crvUsdBalance = loanManager.getCrvUsdBalance();
        if (crvUsdBalance > 0) {
            loanManager.transferCrvUsd(address(this), crvUsdBalance);
            _deployCrvUsdToYield(crvUsdBalance);
        }
    }

    /// @notice Decrease LTV by repaying debt
    function _decreaseLtv(uint256 _targetLtv) internal {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);

        uint256 targetDebt = (collateralValue * _targetLtv) / PRECISION;
        if (targetDebt >= currentDebt) return;

        uint256 toRepay = currentDebt - targetDebt;

        // Get crvUSD from yield strategy
        _withdrawFromYieldStrategy(toRepay);

        // Transfer crvUSD to loan manager and repay
        uint256 crvUsdBalance = crvUSD.balanceOf(address(this));
        uint256 repayAmount = toRepay < crvUsdBalance ? toRepay : crvUsdBalance;

        if (repayAmount > 0) {
            crvUSD.safeTransfer(address(loanManager), repayAmount);
            loanManager.repayDebt(repayAmount);
        }
    }

    /// @notice Ensure token approval for spender
    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }

    // ============ ERC20 Overrides for decimals ============

    /// @notice Returns 8 decimals to match WBTC
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 8;
    }
}
