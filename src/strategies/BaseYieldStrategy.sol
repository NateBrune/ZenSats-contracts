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

    /// @notice Precision for percentage calculations (100% = 1e18)
    uint256 public constant PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice crvUSD token (asset accepted by strategy)
    IERC20 public immutable crvUSD;

    /// @notice The vault that owns this strategy
    address public immutable override vault;

    // ============ State ============

    /// @notice Total crvUSD deposited (cost basis for profit calculation)
    uint256 internal _costBasis;

    /// @notice Whether the strategy is paused
    bool public override paused;

    /// @notice Reentrancy guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert StrategyPaused();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Unauthorized();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ============ Constructor ============

    constructor(address _crvUSD, address _vault) {
        if (_crvUSD == address(0) || _vault == address(0)) {
            revert InvalidAddress();
        }
        crvUSD = IERC20(_crvUSD);
        vault = _vault;
        _status = _NOT_ENTERED;
    }

    // ============ Core Functions ============

    /// @inheritdoc IYieldStrategy
    function deposit(uint256 crvUsdAmount)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 underlyingDeposited)
    {
        if (crvUsdAmount == 0) revert ZeroAmount();

        // Transfer crvUSD from vault
        if (!crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount)) {
            revert TransferFailed();
        }

        // Update cost basis
        _costBasis += crvUsdAmount;

        // Deposit to underlying protocol
        underlyingDeposited = _deposit(crvUsdAmount);

        emit Deposited(crvUsdAmount, underlyingDeposited);
    }

    /// @inheritdoc IYieldStrategy
    function withdraw(uint256 crvUsdAmount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 crvUsdReceived)
    {
        if (crvUsdAmount == 0) revert ZeroAmount();

        uint256 currentValue = this.balanceOf();
        if (currentValue == 0) return 0;
        if (crvUsdAmount > currentValue) {
            crvUsdAmount = currentValue;
        }

        // Calculate proportional cost basis reduction
        uint256 basisReduction = (_costBasis * crvUsdAmount) / currentValue;

        // Withdraw from underlying protocol
        crvUsdReceived = _withdraw(crvUsdAmount);

        // Update cost basis
        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;

        // Transfer crvUSD to vault
        if (crvUsdReceived > 0) {
            if (!crvUSD.transfer(vault, crvUsdReceived)) {
                revert TransferFailed();
            }
        }

        emit Withdrawn(crvUsdAmount, crvUsdReceived);
    }

    /// @inheritdoc IYieldStrategy
    function withdrawAll()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 crvUsdReceived)
    {
        crvUsdReceived = _withdrawAll();

        // Reset cost basis
        _costBasis = 0;

        // Transfer all crvUSD to vault
        uint256 balance = crvUSD.balanceOf(address(this));
        if (balance > 0) {
            if (!crvUSD.transfer(vault, balance)) {
                revert TransferFailed();
            }
        }

        emit Withdrawn(type(uint256).max, crvUsdReceived);
    }

    /// @inheritdoc IYieldStrategy
    function harvest()
        external
        override
        onlyVault
        whenNotPaused
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
        returns (uint256 crvUsdReceived)
    {
        crvUsdReceived = _emergencyWithdraw();

        // Reset cost basis
        _costBasis = 0;

        // Transfer all crvUSD to vault
        uint256 balance = crvUSD.balanceOf(address(this));
        if (balance > 0) {
            if (!crvUSD.transfer(vault, balance)) {
                revert TransferFailed();
            }
        }

        emit EmergencyWithdrawn(crvUsdReceived);
    }

    /// @inheritdoc IYieldStrategy
    function pauseStrategy()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 crvUsdReceived)
    {
        paused = !paused;

        if (paused) {
            crvUsdReceived = _withdrawAll();

            // Reset cost basis
            _costBasis = 0;

            // Transfer all crvUSD to vault
            uint256 balance = crvUSD.balanceOf(address(this));
            if (balance > 0) {
                if (!crvUSD.transfer(vault, balance)) {
                    revert TransferFailed();
                }
            }
        }

        emit StrategyPauseToggled(paused, crvUsdReceived);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function asset() external view override returns (address) {
        return address(crvUSD);
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

    // ============ Internal Functions (to be implemented by derived contracts) ============

    /// @notice Internal deposit logic - implement in derived contract
    /// @param crvUsdAmount Amount of crvUSD to deposit
    /// @return underlyingDeposited Amount deposited to underlying protocol
    function _deposit(uint256 crvUsdAmount)
        internal
        virtual
        returns (uint256 underlyingDeposited);

    /// @notice Internal withdraw logic - implement in derived contract
    /// @param crvUsdAmount Amount of crvUSD to withdraw
    /// @return crvUsdReceived Actual crvUSD received
    function _withdraw(uint256 crvUsdAmount) internal virtual returns (uint256 crvUsdReceived);

    /// @notice Internal withdraw all logic - implement in derived contract
    /// @return crvUsdReceived Total crvUSD received
    function _withdrawAll() internal virtual returns (uint256 crvUsdReceived);

    /// @notice Internal harvest logic - implement in derived contract
    /// @return rewardsValue Value of rewards harvested
    function _harvest() internal virtual returns (uint256 rewardsValue);

    /// @notice Internal emergency withdraw logic - implement in derived contract
    /// @return crvUsdReceived Total crvUSD received
    function _emergencyWithdraw() internal virtual returns (uint256 crvUsdReceived);

    // ============ Helper Functions ============

    /// @notice Ensure token approval for spender
    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
