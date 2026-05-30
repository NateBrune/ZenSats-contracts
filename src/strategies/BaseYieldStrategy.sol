// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BaseYieldStrategy
/// @notice Abstract base for all yield strategies. Owns the IYieldStrategy plumbing
///         (vault wiring, cost basis, reentrancy) plus the admin surface shared by every
///         concrete strategy: owner role, slippage tolerance, and ERC20 rescue.
/// @dev Two abstract families inherit this contract:
///         - BaseVaultStrategy (vault/) — deposit one asset into an external ERC4626 vault.
///         - BaseLPStrategy   (lp/)    — deposit single-sided into an LP and stake the LP token.
///       Subclasses implement the five core hooks (_deposit/_withdraw/_withdrawAll/_harvest/
///       _emergencyWithdraw) and may override _onSlippageUpdate / _isProtectedToken.
abstract contract BaseYieldStrategy is IYieldStrategy, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;

    /// @notice Slippage tolerance bounds and presets shared by all strategies.
    uint256 public constant MIN_SLIPPAGE = 1e15; // 0.1%
    uint256 public constant DEFAULT_SLIPPAGE = 1e16; // 1%
    uint256 public constant MAX_SLIPPAGE = 5e16; // 5%
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17; // 10%

    // ============ Immutables ============

    /// @notice The debt asset token (asset accepted/returned by this strategy)
    IERC20 public immutable debtAsset;

    // ============ State ============

    /// @notice The vault that owns this strategy
    address public override vault;

    /// @notice Deployer address for deferred vault initialization
    address public initializer;

    /// @notice Total debt asset deposited (cost basis for profit calculation)
    uint256 internal _costBasis;

    /// @notice Strategy admin (rotated automatically when vault gov rotates).
    address public owner;

    /// @notice Slippage tolerance applied to swap and LP-exit operations.
    uint256 public slippageTolerance;

    // ============ Events ============

    event VaultInitialized(address indexed vault);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    /// @param _debtAsset The debt asset token address
    /// @param _vault The vault address (or zero for deferred initialization)
    /// @param _owner Initial owner. Pass `address(0)` to default to `msg.sender`.
    constructor(address _debtAsset, address _vault, address _owner) {
        if (_debtAsset == address(0)) revert InvalidAddress();
        debtAsset = IERC20(_debtAsset);
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
        owner = _owner == address(0) ? msg.sender : _owner;
        slippageTolerance = DEFAULT_SLIPPAGE;
    }

    // ============ Deferred Initialization ============

    /// @notice Initialize the vault address (can only be called once by deployer)
    function initializeVault(address newVault) external {
        if (vault != address(0)) revert InvalidAddress();
        if (newVault == address(0)) revert InvalidAddress();
        if (msg.sender != initializer) revert Unauthorized();

        vault = newVault;
        initializer = address(0);
        emit VaultInitialized(newVault);
    }

    // ============ Admin ============

    /// @notice Transfer strategy ownership directly, initiated by the vault upon gov transfer.
    /// @dev Bypasses any timelock. Only callable by the vault. The vault enforces a 2-day timelock
    ///      before any gov role transfer completes (see Zenji.transferRole / acceptRole), so this
    ///      function is effectively timelocked at the vault level.
    function transferOwnerFromVault(address newOwner) external override {
        if (msg.sender != vault) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Owner-callable ownership transfer for the deployment window.
    /// @dev Strategies are typically deployed with `vault = predictedAddress` (via
    ///      `computeCreateAddress`), so the vault field is non-zero but the actual
    ///      vault contract code does not yet exist. We gate this setter on
    ///      `vault.code.length == 0` so the deployer can hand off to gov BEFORE
    ///      `new Zenji(...)` runs (which enforces `strategy.owner == vault.gov`).
    ///      Once the vault contract is deployed, this path locks out — further
    ///      ownership changes must go through `transferOwnerFromVault`, which the
    ///      vault gates with its multi-role governance.
    function transferOwner(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidAddress();
        if (vault != address(0) && vault.code.length > 0) revert Unauthorized();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Update strategy slippage tolerance.
    /// @dev Callable by vault (normal operations) or owner (manual recovery/ops).
    ///      Calls _onSlippageUpdate so subclasses can propagate to nested swappers.
    function setSlippage(uint256 newSlippage) external virtual override {
        if (msg.sender != vault && msg.sender != owner) revert Unauthorized();
        if (newSlippage < MIN_SLIPPAGE || newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 old = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(old, newSlippage);
        _onSlippageUpdate(old, newSlippage);
    }

    /// @notice Rescue ERC20 tokens that are not core strategy assets.
    /// @dev Subclasses extend the protected set by overriding _isProtectedToken.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (_isProtectedToken(token)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ============ Core Functions ============

    /// @inheritdoc IYieldStrategy
    function deposit(uint256 amount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 underlyingDeposited)
    {
        if (amount == 0) revert ZeroAmount();

        debtAsset.safeTransferFrom(msg.sender, address(this), amount);
        _costBasis += amount;
        underlyingDeposited = _deposit(amount);
        emit Deposited(amount, underlyingDeposited);
    }

    /// @inheritdoc IYieldStrategy
    function withdraw(uint256 amount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 received)
    {
        if (amount == 0) revert ZeroAmount();

        // Advance any cached unit value FIRST so basisReduction below and the share math inside
        // _withdraw() read one consistent snapshot (otherwise they can diverge by up to the VP
        // clamp, skewing cost-basis decay). No-op for cacheless strategies (e.g. IPOR).
        _syncValueCache();
        uint256 currentValue = balanceOf();
        if (currentValue == 0) return 0;
        if (amount > currentValue) amount = currentValue;

        uint256 basisReduction = (_costBasis * amount) / currentValue;
        received = _withdraw(amount);
        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;

        if (received > 0) {
            debtAsset.safeTransfer(vault, received);
        }

        emit Withdrawn(amount, received);
    }

    /// @inheritdoc IYieldStrategy
    function withdrawAll() external override onlyVault nonReentrant returns (uint256 received) {
        received = _withdrawAll();
        _costBasis = 0;

        uint256 balance = debtAsset.balanceOf(address(this));
        if (balance > 0) {
            debtAsset.safeTransfer(vault, balance);
        }

        emit Withdrawn(type(uint256).max, received);
    }

    /// @inheritdoc IYieldStrategy
    function harvest() external override onlyVault nonReentrant returns (uint256 rewardsValue) {
        rewardsValue = _harvest();
        emit Harvested(rewardsValue);
    }

    /// @inheritdoc IYieldStrategy
    function emergencyWithdraw()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 received)
    {
        received = _emergencyWithdraw();
        _costBasis = 0;

        uint256 balance = debtAsset.balanceOf(address(this));
        if (balance > 0) {
            debtAsset.safeTransfer(vault, balance);
        }

        emit EmergencyWithdrawn(received);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function asset() external view override returns (address) {
        return address(debtAsset);
    }

    /// @inheritdoc IYieldStrategy
    function costBasis() external view override returns (uint256) {
        return _costBasis;
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view virtual override returns (uint256);

    /// @dev Refresh any cached unit value before it is read for cost-basis accounting.
    ///      No-op by default (cacheless strategies); LP strategies override to ratchet their
    ///      virtual-price cache so withdraw's basisReduction and share math agree.
    function _syncValueCache() internal virtual { }

    /// @inheritdoc IYieldStrategy
    function unrealizedProfit() external view override returns (uint256) {
        uint256 currentValue = balanceOf();
        return currentValue > _costBasis ? currentValue - _costBasis : 0;
    }

    /// @inheritdoc IYieldStrategy
    /// @dev No-op for strategies that do not maintain a unit-value cache.
    ///      BaseLPStrategy overrides to ratchet its cached LP unit value.
    function updateCachedVirtualPrice() external virtual override { }

    // ============ Subclass Hooks ============

    function _deposit(uint256 amount) internal virtual returns (uint256 underlyingDeposited);
    function _withdraw(uint256 amount) internal virtual returns (uint256 received);
    function _withdrawAll() internal virtual returns (uint256 received);
    function _harvest() internal virtual returns (uint256 rewardsValue);
    function _emergencyWithdraw() internal virtual returns (uint256 received);

    /// @notice Hook fired after slippageTolerance is updated. Default: no-op.
    /// @dev Override to propagate the new slippage to nested swappers (e.g. CRV reward swapper).
    function _onSlippageUpdate(uint256 oldSlippage, uint256 newSlippage) internal virtual { }

    /// @notice Returns true if a token must be blocked from rescue. Default: protect debtAsset.
    /// @dev Override (with super) to add additional protected tokens (LP, vault shares, etc.).
    function _isProtectedToken(address token) internal view virtual returns (bool) {
        return token == address(debtAsset);
    }

    // ============ Helpers ============

    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
