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
import { ZenjiGovLib } from "./libraries/ZenjiGovLib.sol";
import { ZenjiViewHelper } from "./ZenjiViewHelper.sol";
import { ZenjiStorage } from "./ZenjiStorage.sol";

/// @dev Minimal interface for propagating slippage to swappers (avoids adding setSlippage to ISwapper).
interface ISwapperSlippageConfig {
    function setSlippage(uint256 newSlippage) external;
    function slippage() external view returns (uint256);
}

/// @dev Minimal vault-initiated gov handoff for swappers (mirrors transferOwnerFromVault on
///      strategies). Kept inline so ISwapper stays stable and mocks don't need updating.
interface ISwapperGovRotation {
    function transferGovFromVault(address newGov) external;
}

/// @dev Minimal accessor for strategy owner. Defined inline so we don't widen IYieldStrategy
///      (which would require updating every mock in the test tree).
interface IStrategyOwner {
    function owner() external view returns (address);
}

/// @dev Minimal swapper-rotation surface on the loan manager. Same rationale: keep ILoanManager
///      stable and avoid mock churn.
interface ILoanManagerSwapperRotation {
    function proposeSwapper(address newSwapper) external;
    function executeSwapper() external;
    function cancelSwapper() external;
}

/// @title Zenji
/// @notice ERC4626-compliant conservative collateral yield vault using loan managers and yield strategies
/// @dev Deposits collateral to a loan manager, borrows debt asset, deposits to yield strategy

contract Zenji is ZenjiStorage, IERC4626 {
    using TimelockLib for TimelockLib.AddressTimelockData;
    using TimelockLib for TimelockLib.TimelockData;
    using SafeTransferLib for IERC20;

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
        // NOTE: enforcing `strategy.owner == _owner` at construction would close the
        // "two different keys" risk on the strategy-side governance surface (LP exit-discount
        // knob, rescueERC20) — but it requires every deployment script and test fixture to
        // call `strategy.transferOwner(_owner)` before this constructor runs. That's a
        // larger migration than the other operational fixes in this change set. The check
        // is preserved as a view (`verifyStrategyOwnership()` below) for operational
        // monitoring; production deployments should call it post-deploy and alert on
        // mismatch. A future PR can promote this to a hard revert once all deploy paths
        // are updated to transfer ownership pre-vault.
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

    /// @notice Returns true iff `yieldStrategy.owner() == gov`. Off-chain monitoring should
    ///         call this post-deploy and on any role transfer; a `false` result means the
    ///         strategy-side governance surface (LP exit-discount knob, rescueERC20) is
    ///         controlled by a key different from `vault.gov` — a single-point-of-failure
    ///         that defeats the multi-role guarantee. Returns false on revert (strategy
    ///         without `owner()`) so callers do not need to wrap in try/catch.
    function verifyStrategyOwnership() external view returns (bool) {
        try IStrategyOwner(address(yieldStrategy)).owner() returns (address stratOwner) {
            return stratOwner == gov;
        } catch {
            return false;
        }
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

    /// @notice ERC4626 withdraw - withdraw exact assets by burning shares.
    /// @dev Uses the gov-set `maxSlippage` as the floor on internal unwind steps.
    ///      Reverts if market conditions push slippage above `maxSlippage`. Power
    ///      users who want a self-serve escape hatch under stress should use the
    ///      overloaded variant with a `minAssetsOut` parameter.
    function withdraw(uint256 assets, address receiver, address owner_)
        external
        override
        nonReentrant
        returns (uint256 shareAmount)
    {
        return _withdrawWithMin(assets, receiver, owner_, 0);
    }

    /// @notice Overloaded withdraw with caller-supplied minimum acceptable assets out.
    /// @dev `minAssetsOut == 0` is the sentinel for "use gov-set maxSlippage" — identical
    ///      to the standard ERC4626 signature. `minAssetsOut > 0` widens internal slippage
    ///      caps up to the implied tolerance (capped at MAX_USER_SLIPPAGE) and enforces
    ///      `actualOut >= minAssetsOut` via UserSlippageExceeded after the unwind.
    function withdraw(uint256 assets, address receiver, address owner_, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 shareAmount)
    {
        return _withdrawWithMin(assets, receiver, owner_, minAssetsOut);
    }

    function _withdrawWithMin(
        uint256 assets,
        address receiver,
        address owner_,
        uint256 minAssetsOut
    ) internal returns (uint256 shareAmount) {
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

        (, shareAmount) = _redeem(shareAmount, receiver, owner_, minAssetsOut);
    }

    /// @notice ERC4626 redeem - redeem exact shares for assets.
    /// @dev Uses gov-set `maxSlippage`. Use the overloaded variant for self-serve slippage.
    function redeem(uint256 shareAmount, address receiver, address owner_)
        external
        override
        nonReentrant
        returns (uint256 collateralAmount)
    {
        if (emergencyMode && !liquidationComplete) revert EmergencyModeActive();
        (collateralAmount,) = _redeem(shareAmount, receiver, owner_, 0);
    }

    /// @notice Overloaded redeem with caller-supplied minimum acceptable assets out.
    function redeem(uint256 shareAmount, address receiver, address owner_, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 collateralAmount)
    {
        if (emergencyMode && !liquidationComplete) revert EmergencyModeActive();
        (collateralAmount,) = _redeem(shareAmount, receiver, owner_, minAssetsOut);
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
            loanManager.createLoan(idleCollateral, borrowAmount);
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
            strategyDebtRatio != type(uint256).max && strategyDebtRatio < minStrategyRatio;
        bool ratioTooHigh =
            strategyDebtRatio != type(uint256).max && strategyDebtRatio > maxStrategyRatio;

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

            _swapRemainingDebtToCollateral(true, maxSlippage);

            idle = true;
            emit IdleModeEntered();
        } else {
            idle = false;
            emit IdleModeExited();
            _deployCapital();
        }
    }

    // ============ Gov Functions ============

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

    // ============ Role Management (Gov-only) ============

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
            // Propagate to strategy if it supports vault-initiated ownership transfer.
            // Wrapped in try/catch so a bricked or paused strategy can't block gov rotation.
            // Operators can re-sync ownership later via the strategy's own admin path.
            try yieldStrategy.transferOwnerFromVault(msg.sender) {
            // success — strategy owner is now the new gov
            }
            catch {
                emit StrategyOwnerPropagationFailed(msg.sender);
            }
            // Propagate gov to the registered swapper too (mirrors the strategy owner handoff),
            // so a rotated-away key cannot keep widening the swap floor via setSlippage.
            // try/catch so a swapper that doesn't recognise this vault can't block gov rotation.
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

    /// @notice Withdraw accumulated strategy fees
    /// @dev Strategist-only. Accrues pending fees before withdrawal.
    function withdrawFees(address recipient) external nonReentrant onlyStrategist {
        if (recipient == address(0)) revert InvalidAddress();
        // Advance the strategy's cached VP before accruing fees (mirrors rebalance()), so the
        // accrual sees an up-to-date strategy balance and VP drift can't cause phantom fees.
        yieldStrategy.updateCachedVirtualPrice();
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

    // ============ Deposit pause (guardian fast, gov slow) ============

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

    // ============ Rescue recipient (gov, timelocked) ============

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

    /// @notice Set vault parameter:
    /// 0=feeRate, 1=targetLtv, 2=depositCap, 3=bountyRate, 4=maxSlippage (propagates to strategy and swapper)
    /// @dev Gov-only. Adverse changes (feeRate increase, targetLtv increase) are timelocked
    ///      and require executeParamChange after PARAM_TIMELOCK_DELAY. User-favorable
    ///      changes (decreases) take effect immediately.
    function setParam(uint8 p, uint256 v) external onlyGov {
        ZenjiGovLib.ParamState memory st =
            ZenjiGovLib.ParamState(feeRate, targetLtv, depositCap, rebalanceBountyRate, maxSlippage);
        st = ZenjiGovLib.setParam(
            _feeRateTimelock,
            _targetLtvTimelock,
            _depositCapTimelock,
            _bountyRateTimelock,
            _maxSlippageTimelock,
            st,
            p,
            v,
            MAX_TARGET_LTV(),
            loanManager.maxLtvBps(),
            address(yieldStrategy),
            address(swapper)
        );
        feeRate = st.feeRate;
        targetLtv = st.targetLtv;
        depositCap = st.depositCap;
        rebalanceBountyRate = st.rebalanceBountyRate;
        maxSlippage = st.maxSlippage;
    }

    /// @notice Execute a pending param change after PARAM_TIMELOCK_DELAY.
    /// @param p 0=feeRate, 1=targetLtv, 2=depositCap, 3=bountyRate, 4=maxSlippage
    function executeParamChange(uint8 p) external onlyGov {
        // p==0 accrues outstanding fees at the OLD rate before the new rate is applied; this must
        // happen in the vault (the library cannot call the internal _accrueYieldFees).
        if (p == 0) _accrueYieldFees();
        ZenjiGovLib.ParamState memory st =
            ZenjiGovLib.ParamState(feeRate, targetLtv, depositCap, rebalanceBountyRate, maxSlippage);
        st = ZenjiGovLib.executeParamChange(
            _feeRateTimelock,
            _targetLtvTimelock,
            _depositCapTimelock,
            _bountyRateTimelock,
            _maxSlippageTimelock,
            st,
            p,
            MAX_TARGET_LTV(),
            loanManager.maxLtvBps(),
            address(yieldStrategy),
            address(swapper)
        );
        feeRate = st.feeRate;
        targetLtv = st.targetLtv;
        depositCap = st.depositCap;
        rebalanceBountyRate = st.rebalanceBountyRate;
        maxSlippage = st.maxSlippage;
    }

    /// @notice Cancel a pending param proposal.
    function cancelParamChange(uint8 p) external onlyGov {
        ZenjiGovLib.cancelParamChange(
            _feeRateTimelock,
            _targetLtvTimelock,
            _depositCapTimelock,
            _bountyRateTimelock,
            _maxSlippageTimelock,
            p
        );
    }

    /// @notice View pending param proposal state.
    function pendingParamChange(uint8 p)
        external
        view
        returns (uint256 newValue, uint256 effectiveTime)
    {
        if (p == 0) return (_feeRateTimelock.pendingValue, _feeRateTimelock.timestamp);
        if (p == 1) return (_targetLtvTimelock.pendingValue, _targetLtvTimelock.timestamp);
        if (p == 2) return (_depositCapTimelock.pendingValue, _depositCapTimelock.timestamp);
        if (p == 3) return (_bountyRateTimelock.pendingValue, _bountyRateTimelock.timestamp);
        if (p == 4) return (_maxSlippageTimelock.pendingValue, _maxSlippageTimelock.timestamp);
        revert InvalidParam();
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
    /// @param slippageOverride Per-call slippage tolerance to use instead of `maxSlippage`.
    ///        Pass `maxSlippage` (or 0 sentinel) for default behavior; pass a higher value
    ///        to widen the floor for user-opted-in withdrawals.
    function _swapRemainingDebtToCollateral(bool force, uint256 slippageOverride) internal {
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
            // Floor = max(swapper.slippage, slippageOverride*2).
            // The swapper.slippage() term ensures we never reject a swap that the
            // swapper itself considers valid (e.g. a cbBTC swapper configured at 5%
            // would be falsely penalised by a 2% vault floor).
            // The slippageOverride*2 term preserves the oracle-path divergence
            // buffer: loanManager.getDebtValue uses a direct oracle feed while the
            // swapper traverses a multi-hop path, so the two prices can differ by up
            // to ~2×slippage even on a fair swap.
            uint256 baseSlip = slippageOverride == 0 ? maxSlippage : slippageOverride;
            uint256 swapperSlippage = ISwapperSlippageConfig(address(swapper)).slippage();
            uint256 effectiveSlippage =
                swapperSlippage > baseSlip * 2 ? swapperSlippage : baseSlip * 2;
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
        if (depositsPaused) revert DepositsArePaused();
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

    /// @notice Internal redeem logic shared by withdraw(), redeem(), and overloaded variants.
    /// @param minAssetsOut User-supplied minimum acceptable collateral out. Pass 0 to use
    ///        the gov-set `maxSlippage` (existing default behavior). When > 0, the call
    ///        widens internal slippage caps to (1 - minAssetsOut/expected) up to
    ///        MAX_USER_SLIPPAGE, and reverts UserSlippageExceeded if the final amount
    ///        falls below `minAssetsOut`. Emergency redemption ignores `minAssetsOut`
    ///        because it does not unwind — distribution is pure pro-rata of vault balance.
    /// @return collateralAmount Amount of collateral returned
    /// @return actualShareAmount Amount of shares actually burned
    function _redeem(uint256 shareAmount, address receiver, address owner_, uint256 minAssetsOut)
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
            // Honor minAssetsOut floor even in emergency to make the API behavior consistent
            if (minAssetsOut > 0 && collateralAmount < minAssetsOut) {
                revert UserSlippageExceeded(minAssetsOut, collateralAmount);
            }
            return (collateralAmount, actualShareAmount);
        }

        (collateralAmount, actualShareAmount) =
            _redeemStandard(shareAmount, receiver, owner_, minAssetsOut);
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

    function _redeemStandard(
        uint256 shareAmount,
        address receiver,
        address owner_,
        uint256 minAssetsOut
    ) internal returns (uint256 collateralAmount, uint256 actualShareAmount) {
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

        // Compute the effective slippage to pass to internal unwind steps.
        // - minAssetsOut == 0 → use maxSlippage (existing default behavior)
        // - minAssetsOut > 0 → derive from user's tolerance; never tighter than maxSlippage,
        //   capped above at MAX_USER_SLIPPAGE.
        uint256 effectiveSlippage = _computeEffectiveSlippage(collateralAmount, minAssetsOut);

        _burn(owner_, actualShareAmount);

        if (isFinalWithdraw) {
            _unwindPosition(type(uint256).max, effectiveSlippage);
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
                    uint256 proportionalLM = (posCol * actualShareAmount) / virtualSupply;
                    if (proportionalLM > needed) {
                        needed = proportionalLM;
                    }
                }

                _unwindPosition(needed, effectiveSlippage);

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
                    uint256 realizedCollateral =
                        (actualShareAmount * (postUnwindTotal + VIRTUAL_SHARE_OFFSET()))
                            / virtualSupply;
                    if (realizedCollateral < collateralAmount) {
                        collateralAmount = realizedCollateral;
                    }
                }

                uint256 totalAvailable = balanceAfter;
                if (totalAvailable < collateralAmount) {
                    // Even after re-pricing, if vault balance is insufficient
                    // (e.g. dust rounding), allow slippage-adjusted withdrawal
                    // bounded by the effective slippage tolerance.
                    uint256 minAcceptable =
                        (collateralAmount * (PRECISION - effectiveSlippage)) / PRECISION;
                    if (totalAvailable < minAcceptable) {
                        revert InsufficientCollateral();
                    }
                    collateralAmount = totalAvailable;
                }
            }

            collateralAsset.safeTransfer(receiver, collateralAmount);
        }

        // Final user-slippage check — only enforced when the user opted in by passing minAssetsOut > 0.
        if (minAssetsOut > 0 && collateralAmount < minAssetsOut) {
            revert UserSlippageExceeded(minAssetsOut, collateralAmount);
        }

        emit Withdraw(msg.sender, receiver, owner_, collateralAmount, actualShareAmount);
    }

    /// @notice Compute the effective per-call slippage tolerance to pass to internal unwind steps.
    /// @dev When `minAssetsOut == 0`, returns `maxSlippage` (current default behavior).
    ///      When `minAssetsOut >= expectedAssets`, the user is asking for tighter-than-default;
    ///      we still pass `maxSlippage` to internal steps because a tighter cap would arbitrarily
    ///      revert intermediate operations — the user's tighter tolerance is enforced by the
    ///      final `UserSlippageExceeded` check after the unwind completes.
    ///      When `minAssetsOut < expectedAssets`, we derive the implied slippage and use it
    ///      (capped at MAX_USER_SLIPPAGE) so that internal steps tolerate the full amount the
    ///      user has agreed to absorb.
    function _computeEffectiveSlippage(uint256 expectedAssets, uint256 minAssetsOut)
        internal
        view
        returns (uint256)
    {
        if (minAssetsOut == 0) return maxSlippage;
        if (expectedAssets == 0 || minAssetsOut >= expectedAssets) return maxSlippage;
        uint256 implied = ((expectedAssets - minAssetsOut) * PRECISION) / expectedAssets;
        if (implied < maxSlippage) return maxSlippage;
        if (implied > MAX_USER_SLIPPAGE) return MAX_USER_SLIPPAGE;
        return implied;
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
    /// @param slippageOverride Per-call slippage tolerance. Pass `maxSlippage` for default behavior;
    ///        pass a higher value to widen the floor for user-opted-in withdrawals.
    function _withdrawFromYieldStrategy(
        uint256 debtNeeded,
        uint256 minDebtReceived,
        uint256 slippageOverride
    ) internal returns (uint256) {
        if (address(yieldStrategy) == address(0)) return 0;
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance == 0) return 0;

        _accrueYieldFees();

        uint256 toWithdraw = debtNeeded > strategyBalance ? strategyBalance : debtNeeded;
        uint256 received = 0;
        if (toWithdraw > 0) {
            received = yieldStrategy.withdraw(toWithdraw);
            uint256 effectiveSlippage = slippageOverride == 0 ? maxSlippage : slippageOverride;
            // When strategy is underfunded (toWithdraw < minDebtReceived), cap the floor at
            // toWithdraw — the shortfall is 5%-buffer drift, resolved by rebalance(), not slippage.
            uint256 floorBase = (minDebtReceived == 0 || toWithdraw < minDebtReceived)
                ? toWithdraw
                : minDebtReceived;
            uint256 minReceived = (floorBase * (PRECISION - effectiveSlippage)) / PRECISION;
            if (received < minReceived) revert InsufficientWithdrawal();
        }
        lastStrategyBalance = yieldStrategy.balanceOf();
        return received;
    }

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @param collateralNeeded Amount of collateral to free, or type(uint256).max for full close
    /// @param effectiveSlippage Slippage tolerance to use for internal strategy withdraw and
    ///        debt→collateral swap. Pass `maxSlippage` for default behavior; pass a higher value
    ///        to widen the floor for user-opted-in withdrawals.
    function _unwindPosition(uint256 collateralNeeded, uint256 effectiveSlippage) internal {
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
                    _withdrawFromYieldStrategy(debtNeeded, debtToRepay, effectiveSlippage);
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
        _swapRemainingDebtToCollateral(fullyClose, effectiveSlippage);

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
