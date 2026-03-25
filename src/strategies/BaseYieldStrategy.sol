// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title BaseYieldStrategy
/// @notice Abstract base contract for yield strategies with cost basis tracking
/// @dev All strategies inherit from this and implement protocol-specific logic
abstract contract BaseYieldStrategy is IYieldStrategy {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;

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

    /// @notice Reentrancy guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ============ Events ============

    event VaultInitialized(address indexed vault);

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Unauthorized();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ============ Constructor ============

    /// @param _debtAsset The debt asset token address
    /// @param _vault The vault address (or zero for deferred initialization)
    constructor(address _debtAsset, address _vault) {
        if (_debtAsset == address(0)) revert InvalidAddress();
        debtAsset = IERC20(_debtAsset);
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
        _status = _NOT_ENTERED;
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

        uint256 currentValue = this.balanceOf();
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
    function harvest()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 rewardsValue)
    {
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

    /// @inheritdoc IYieldStrategy
    function unrealizedProfit() external view override returns (uint256) {
        uint256 currentValue = this.balanceOf();
        return currentValue > _costBasis ? currentValue - _costBasis : 0;
    }

    /// @inheritdoc IYieldStrategy
    /// @dev No-op for strategies that do not use a virtual price cache.
    ///      Override in strategies that maintain a cached virtual price.
    function updateCachedVirtualPrice() external virtual override { }

    // ============ Internal Functions (to be implemented by derived contracts) ============

    function _deposit(uint256 amount) internal virtual returns (uint256 underlyingDeposited);
    function _withdraw(uint256 amount) internal virtual returns (uint256 received);
    function _withdrawAll() internal virtual returns (uint256 received);
    function _harvest() internal virtual returns (uint256 rewardsValue);
    function _emergencyWithdraw() internal virtual returns (uint256 received);

    // ============ Helper Functions ============

    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
