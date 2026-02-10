// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ICurveTwoCrypto } from "./interfaces/ICurveTwoCrypto.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";

/// @title CurveTwoCryptoSwapper
/// @notice Simple swapper for Curve TwoCrypto pools
contract CurveTwoCryptoSwapper is ISwapper {
    using SafeTransferLib for IERC20;
    using TimelockLib for TimelockLib.TimelockData;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public slippage; // Initially 5%

    address public gov;
    address public pendingGov;
    TimelockLib.TimelockData private _slippageTimelock;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    ICurveTwoCrypto public immutable pool;
    uint256 public immutable collateralIndex;
    uint256 public immutable debtIndex;

    event GovernanceTransferStarted(address indexed previousGov, address indexed newGov);
    event GovernanceUpdated(address indexed newGov);
    event SlippageProposed(uint256 newSlippage, uint256 executeAfter);
    event SlippageExecuted(uint256 newSlippage);
    event SlippageCancelled();

    error Unauthorized();
    error InvalidSlippage();

    modifier onlyGov() {
        if (msg.sender != gov) revert Unauthorized();
        _;
    }

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _pool,
        uint256 _collateralIndex,
        uint256 _debtIndex
    ) {
        if (
            _gov == address(0) || _collateralToken == address(0) || _debtToken == address(0)
                || _pool == address(0)
        ) {
            revert InvalidAddress();
        }
        gov = _gov;
        slippage = 5e16; // 5% initial slippage
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        pool = ICurveTwoCrypto(_pool);
        collateralIndex = _collateralIndex;
        debtIndex = _debtIndex;
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
        if (collateralOut == 0) return 0;
        return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;
        uint256 expectedOut = pool.get_dy(collateralIndex, debtIndex, collateralAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        collateralToken.ensureApproval(address(pool), collateralAmount);
        debtReceived =
            pool.exchange(collateralIndex, debtIndex, collateralAmount, minOut, msg.sender);
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;
        uint256 expectedOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        debtToken.ensureApproval(address(pool), debtAmount);
        collateralReceived =
            pool.exchange(debtIndex, collateralIndex, debtAmount, minOut, msg.sender);
    }

    // ============ Governance Functions ============

    /// @notice Propose new slippage tolerance
    /// @param newSlippage New slippage in 1e18 precision (e.g., 5e16 = 5%)
    function proposeSlippage(uint256 newSlippage) external onlyGov {
        if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
        _slippageTimelock.propose(newSlippage, TIMELOCK_DELAY);
        emit SlippageProposed(newSlippage, block.timestamp + TIMELOCK_DELAY);
    }

    /// @notice Execute slippage change after timelock
    function executeSlippage() external onlyGov {
        uint256 newSlippage = _slippageTimelock.execute();
        slippage = newSlippage;
        emit SlippageExecuted(newSlippage);
    }

    /// @notice Cancel pending slippage change
    function cancelSlippage() external onlyGov {
        _slippageTimelock.cancel();
        emit SlippageCancelled();
    }

    /// @notice Start governance transfer
    function transferGovernance(address newGov_) external onlyGov {
        if (newGov_ == address(0)) revert InvalidAddress();
        pendingGov = newGov_;
        emit GovernanceTransferStarted(gov, newGov_);
    }

    /// @notice Accept governance transfer
    function acceptGovernance() external {
        if (msg.sender != pendingGov) revert Unauthorized();
        gov = msg.sender;
        pendingGov = address(0);
        emit GovernanceUpdated(msg.sender);
    }
}
