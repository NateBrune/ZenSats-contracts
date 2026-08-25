// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";
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
import { ZenjiAdmin } from "./ZenjiAdmin.sol";

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

/*//////////////////////////////////////////////////////////////////////////
//                                                                          //
//                                 ZENJI                                    //
//                                                                          //
//      Conservative ERC-4626 carry-trade vault for hard assets            //
//                                                                          //
//      deposit collateral ─► borrow stablecoin ─► Curve LP yield          //
//      (WBTC/wstETH/XAUT)    (Aave V3/LlamaLend)   (Stake DAO gauge)       //
//                                                                          //
//      share price accrues:  yield earned − borrow cost                   //
//                                                                          //
//////////////////////////////////////////////////////////////////////////*/

/// @title Zenji
/// @notice ERC-4626 vault that holds hard collateral, borrows a stablecoin against it
///         at a bounded LTV, and deploys the proceeds into a Curve + Stake DAO LP
///         strategy. The spread between LP yield and borrow cost accrues to share
///         price; withdrawals unwind the position pro-rata.
/// @dev    Trust architecture:
///         - LoanManager and YieldStrategy are IMMUTABLE per deployment. The swapper is
///           the only mutable dependency, rotated through a 1-week timelock.
///         - Cold-path admin logic (role rotation, emergency state machine, deposit
///           pause, rescue) lives in the storage-layout-identical ZenjiAdmin facet,
///           reached via the explicit delegatecall forwarding stubs below. This keeps
///           the vault under the EIP-170 size limit. ZenjiStorage MUST remain
///           byte-identical between Zenji and ZenjiAdmin — verify with
///           `forge inspect <contract> storageLayout` after any storage change.
///         - Three roles: Strategist (day-to-day ops), Gov (infrastructure, timelocked),
///           Guardian (emergency-only, with Gov-vetoable step skips).
///         - Concrete vaults in src/implementations/ pin the asset pair and override
///           name/symbol, VIRTUAL_SHARE_OFFSET, MIN_DEPOSIT, and MAX_TARGET_LTV.
contract Zenji is ZenjiStorage, IERC4626, Proxy {
    using TimelockLib for TimelockLib.AddressTimelockData;
    using TimelockLib for TimelockLib.TimelockData;
    using SafeTransferLib for IERC20;

    /// @notice Cold-path admin facet (self-deployed); cold selectors delegate to it.
    address public immutable adminFacet;

    // ============ Constants ============
    // I-01: the shared governance constants (PRECISION, DEADBAND_SPREAD, MIN_TARGET_LTV,
    // MAX_FEE_RATE, COOLDOWN_BLOCKS, MAX_REBALANCE_BOUNTY, TIMELOCK_DELAY, MAX_VAULT_SLIPPAGE,
    // ROLE_TRANSFER_DELAY, GOV_GUARDIAN_TRANSFER_DELAY, PARAM_TIMELOCK_DELAY, EMERGENCY_SKIP_DELAY,
    // MAX_USER_SLIPPAGE) are now declared once in ZenjiStorage (values from ZenjiConstants) and
    // inherited here and by ZenjiAdmin — public getters and bare references resolve unchanged.
    // MAX_TARGET_LTV and VIRTUAL_SHARE_OFFSET remain virtual functions (per-vault overrides).

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
    // Placeholder ERC20 metadata — concrete vaults (src/implementations/) override
    // name()/symbol() with pure functions, so these storage strings are never user-visible.
    ) ERC20("Zenji Vault", "zenVAULT") {
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
        adminFacet = address(new ZenjiAdmin());

        // Loan manager is provided externally and immutable for this vault
    }

    /// @notice Cold-path admin selectors stay in the ABI as thin stubs that delegatecall the
    ///         ZenjiAdmin facet (shared storage), keeping typed callers working while the logic
    ///         lives in the facet to save vault bytecode. Forwarding uses OpenZeppelin
    ///         `Proxy._delegate` (the audited calldatacopy/delegatecall/returndatacopy primitive).
    /// @dev OZ Proxy hook — the delegatecall target for the forwarding stubs below.
    function _implementation() internal view override returns (address) {
        return adminFacet;
    }

    /// @dev The admin facet is reached ONLY through the explicit forwarding stubs (which keep every
    ///      admin selector in this contract's ABI). OZ `Proxy` ships a catch-all `fallback()` that
    ///      would delegatecall on *any* unmatched selector; it is intentionally disabled here so
    ///      unknown selectors revert — preserving the pre-Proxy behavior and adding no payable
    ///      fallback surface.
    fallback() external payable override {
        revert();
    }

    /// @dev The vault never holds ETH. The fallback above must stay `payable` (Solidity
    ///      forbids a payable → non-payable override of OZ Proxy's fallback), which trips
    ///      compiler warning 3628 unless a receive function exists. Reject plain ETH
    ///      transfers explicitly — same outcome as before (the fallback already reverted
    ///      them), but now self-documenting and warning-free.
    receive() external payable {
        revert();
    }

    function proposeSwapper(address) external { _delegate(_implementation()); }
    function executeSwapper() external { _delegate(_implementation()); }
    function cancelSwapper() external { _delegate(_implementation()); }
    function transferRole(uint8, address) external { _delegate(_implementation()); }
    function acceptRole(uint8) external { _delegate(_implementation()); }
    function cancelRole(uint8) external { _delegate(_implementation()); }
    function guardianCancelRole(uint8) external { _delegate(_implementation()); }
    function guardianCancelSwapper() external { _delegate(_implementation()); }
    function enterEmergencyMode() external { _delegate(_implementation()); }
    function govEnterEmergencyMode() external { _delegate(_implementation()); }
    function cancelGovEmergency() external { _delegate(_implementation()); }
    function emergencyStep(uint8) external { _delegate(_implementation()); }
    function emergencySkipStep(uint8) external { _delegate(_implementation()); }
    function cancelEmergencySkip(uint8) external { _delegate(_implementation()); }
    function cancelEmergencyMode() external { _delegate(_implementation()); }
    function pauseDeposits() external { _delegate(_implementation()); }
    function resumeDeposits() external { _delegate(_implementation()); }
    function proposeRescueRecipient(address) external { _delegate(_implementation()); }
    function executeRescueRecipient() external { _delegate(_implementation()); }
    function cancelRescueRecipient() external { _delegate(_implementation()); }
    function rescueAssets(address, address) external { _delegate(_implementation()); }
    function emergencyRescue(uint8) external { _delegate(_implementation()); }

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
        if (emergencyMode || depositsPaused) return 0; // L-01: mirror _deposit's guards (ERC4626)
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
        if (supply < 1) return assets; // empty vault: first-depositor 1:1 preview is correct
        // L-09: collateral fully gone but shares still exist — withdraw() cannot be priced 1:1
        // (it would require ~assets * supply / VIRTUAL_SHARE_OFFSET shares). Signal an undefined
        // state per ERC4626 guidance rather than returning a misleading 1:1 value.
        if (totalCollateral < 1) return type(uint256).max;
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

    /// @notice Rebalance LTV and/or strategy-debt coverage.
    /// @dev Four mutually exclusive corrective arms, evaluated in this priority order. Exactly ONE
    ///      runs per call; the keeper re-evaluates each tick, so multi-step corrections converge
    ///      across successive calls rather than atomically. Reverts RebalanceNotNeeded when both
    ///      bands are satisfied.
    ///
    ///      Two independent deadbands, both +/- DEADBAND_SPREAD:
    ///        - LTV band:      targetLtv +/- spread
    ///        - Coverage band: 1.0 +/- spread, where coverage = strategyBalance / debt
    ///
    ///      | # | Trigger              | Action                | LTV effect | Coverage effect |
    ///      |---|----------------------|-----------------------|------------|-----------------|
    ///      | 1 | ltv < lowerBand      | _adjustLtv(up)        | -> target  | -> parity       |
    ///      | 2 | ltv > upperBand      | _adjustLtv(down)      | -> target  | away from parity|
    ///      | 3 | coverage < 1-spread  | rebalanceCoverageUp   | rises      | -> parity       |
    ///      | 4 | coverage > 1+spread  | rebalanceCoverageDown | falls      | -> parity       |
    ///
    ///      Arm 1 borrows and deploys the proceeds, moving numerator and denominator together, so
    ///      it pulls coverage toward parity. It is additionally guarded by
    ///      enforceCoverageAfterIncrease, which reverts StrategyDebtCoverageTooLow rather than
    ///      lever up on top of an uncovered position.
    ///
    ///      Arm 2 withdraws from the strategy and repays symmetrically, which pushes coverage AWAY
    ///      from parity whenever coverage < 1. LTV correction must therefore never be relied on to
    ///      repair coverage — that is why arms 3 and 4 exist as separate triggers.
    ///
    ///      Arm 3 funds its repay from COLLATERAL, not the strategy (Plan B — see
    ///      rebalanceCoverageUp NatSpec for why: D - S is conserved under any strategy-funded
    ///      repay, so only a collateral-funded repay can actually shrink the deficit). It converges
    ///      in a single call and is guarded by a strict-improvement postcondition
    ///      (CoverageDidNotImprove) that makes a repeat of the old non-convergent behavior
    ///      unrepresentable. Operational recovery for a degenerate case (e.g. no swapper
    ///      configured) remains setIdle(true)/setIdle(false), which drives debt to 0 (coverage
    ///      becomes type(uint256).max, excluded from both guards) and re-levers at parity; measured
    ///      cost ~1 bp at 1 WBTC.
    ///
    ///      Arm 4 skims the strategy SURPLUS into collateral (see rebalanceCoverageDown NatSpec).
    ///      It used to borrow more debt and deposit it into the same strategy, raising S and D
    ///      together — post-call coverage was `(S+X)/(D+X)`, not the intended `S/(D+X)`, so the
    ///      recurrence `c' = 2.03 - 1.03/c` converged asymptotically TOWARD the band edge and never
    ///      crossed it (measured on a live fork: 105.82% -> 103.28% over 60 calls, still out of
    ///      band). This is the exact mirror of the arm-3 fix: arm 3 funds a repay FROM collateral;
    ///      arm 4 skims TO collateral. Debt is never touched, so — unlike the replaced
    ///      implementation — LTV falls rather than rises, handing the next tick to arm 1 to
    ///      re-lever. Do not reintroduce a borrow-and-deposit design here; see
    ///      rebalanceCoverageDown's NatSpec for the full derivation.
    function rebalance() external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
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
        // (must run before any strategy deposit — some venues enforce short
        // post-deposit withdraw cooldowns that would block the bounty transfer)
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
                loanManager, yieldStrategy, debtAsset, collateralAsset, swapper, accumulatedFees, PRECISION
            );
            newLtv = loanManager.getCurrentLTV();
        } else if (ratioTooHigh) {
            // Arm 4 skims strategy surplus into collateral without touching debt, so LTV falls
            // (not rises, as the replaced borrow-and-deposit design did) — see rebalance()'s
            // dispatch table NatSpec.
            increased = false;
            lastStrategyBalance = ZenjiCoreLib.rebalanceCoverageDown(
                loanManager, yieldStrategy, debtAsset, collateralAsset, swapper, maxSlippage, PRECISION
            );
            newLtv = loanManager.getCurrentLTV();
        }

        emit Rebalance(currentLtv, newLtv, increased);
    }

    /// @notice Accrue outstanding fees from yield vault profits
    /// @dev Permissionless - anyone can trigger fee accrual
    function accrueYieldFees() external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
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
            // L-03: anchor fee baseline at idle-exit point so the residual strategy balance
            // (dust / in-flight interest from the prior idle period) isn't treated as new yield
            // by the first _accrueYieldFees() inside _deployDebtToYield.
            if (address(yieldStrategy) != address(0)) {
                try yieldStrategy.balanceOf() returns (uint256 bal) {
                    lastStrategyBalance = bal;
                } catch {}
            }
            _deployCapital();
        }
    }

    /// @notice Withdraw accumulated strategy fees
    /// @dev Strategist-only. Accrues pending fees before withdrawal.
    function withdrawFees(address recipient) external nonReentrant onlyStrategist {
        if (emergencyMode) revert EmergencyModeActive();
        if (recipient == address(0)) revert InvalidAddress();
        // Advance the strategy's cached VP before accruing fees (mirrors rebalance()), so the
        // accrual sees an up-to-date strategy balance and VP drift can't cause phantom fees.
        yieldStrategy.updateCachedVirtualPrice();
        _accrueYieldFees();

        (accumulatedFees, lastStrategyBalance) =
            ZenjiCoreLib.processWithdrawFees(recipient, yieldStrategy, debtAsset, accumulatedFees);
        // M-05: do NOT reset feesAtLastRebalance here. It is a *rebalance* checkpoint; zeroing it
        // on a fee withdrawal lets a strategist reset the keeper-bounty baseline and inflate the
        // bounty paid on the next rebalance. Only rebalance() advances this checkpoint. The
        // _accrueYieldFees clamp keeps it <= accumulatedFees after genuine losses, and
        // processRebalanceBounty guards the subtraction, so leaving it unchanged is underflow-safe.
    }

    // ============ Gov Functions (parameter timelocks) ============
    // Role management, guardian/emergency operations, deposit pause, and the rescue
    // recipient timelock live in the ZenjiAdmin facet (see forwarding stubs above).

    /// @notice Set vault parameter:
    /// 0=feeRate, 1=targetLtv, 2=depositCap, 3=bountyRate, 4=maxSlippage (propagates to strategy and swapper)
    /// @dev Gov-only. Changes adverse to depositors are timelocked and require
    ///      executeParamChange after PARAM_TIMELOCK_DELAY; favorable changes apply now.
    ///      For feeRate/targetLtv/bountyRate/maxSlippage, increases are adverse. For
    ///      depositCap (0 = unlimited), RAISING or removing the cap is adverse (exposes
    ///      existing depositors to new inflows); lowering or imposing one applies now.
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
            // Clamp swapper's self-reported slippage to 5% (BaseSwapper.MAX_SLIPPAGE) so a
            // malicious or misconfigured swapper cannot hollow out the vault-side minOut check.
            if (swapperSlippage > 5e16) swapperSlippage = 5e16;
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
        uint256 currentBalance;
        try yieldStrategy.balanceOf() returns (uint256 bal) {
            currentBalance = bal;
        } catch {
            // Oracle or strategy unavailable — skip accrual, preserve last known balance.
            return;
        }
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
        if (fullyClose) {
            _swapRemainingDebtToCollateral(true, effectiveSlippage);
        } else {
            // Partial unwind: the recovered debt is the unused 5% withdraw buffer just
            // pulled from the strategy — put it back rather than force-swapping it to
            // collateral. The debt→collateral route cannot absorb large surpluses within
            // its oracle floor, and redepositing exactly preserves strategyToDebtRatio.
            // Surplus stays visible to share pricing either way (idle debt and strategy
            // balance are both counted by getTotalCollateral).
            uint256 surplus = debtAsset.balanceOf(address(this));
            if (surplus > 10 ** debtAsset.decimals()) {
                if (!idle && address(yieldStrategy) != address(0)) {
                    _deployDebtToYield(surplus);
                } else {
                    _swapRemainingDebtToCollateral(false, effectiveSlippage);
                }
            }
        }

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
