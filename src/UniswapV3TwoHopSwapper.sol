// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { ISwapRouter } from "./interfaces/ISwapRouter.sol";
import { IChainlinkOracle } from "./interfaces/IChainlinkOracle.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";

/// @title UniswapV3TwoHopSwapper
/// @notice Two-hop Uniswap V3 swapper (collateral ↔ WETH ↔ debt)
contract UniswapV3TwoHopSwapper is ISwapper {
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
    address public immutable weth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable fee1; // collateral ↔ WETH fee
    uint24 public immutable fee2; // WETH ↔ debt fee
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

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
        address _weth,
        address _swapRouter,
        uint24 _fee1,
        uint24 _fee2,
        address _collateralOracle,
        address _debtOracle
    ) {
        if (
            _gov == address(0) || _collateralToken == address(0) || _debtToken == address(0)
                || _weth == address(0) || _swapRouter == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        gov = _gov;
        slippage = 5e16; // 5% initial slippage
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        weth = _weth;
        swapRouter = ISwapRouter(_swapRouter);
        fee1 = _fee1;
        fee2 = _fee2;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        // Use Chainlink oracles for view-compatible quoting
        (, int256 collateralPrice,,,) = collateralOracle.latestRoundData();
        (, int256 debtPrice,,,) = debtOracle.latestRoundData();
        if (collateralPrice <= 0 || debtPrice <= 0) return 0;

        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        uint8 debtDecimals = debtToken.decimals();

        // Convert debtAmount to collateral units using oracle prices
        uint256 collateralOut = (
            debtAmount * uint256(debtPrice) * (10 ** collateralOracleDecimals)
                * (10 ** collateralDecimals)
        ) / (uint256(collateralPrice) * (10 ** debtOracleDecimals) * (10 ** debtDecimals));

        if (collateralOut == 0) return 0;
        // Add slippage buffer
        return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256 debtReceived) {
        if (collateralAmount == 0) return 0;

        // Get oracle-based expected output for slippage calculation
        uint256 expectedOut = _getExpectedDebtOut(collateralAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Encode path: collateral → WETH → debt
        bytes memory path = abi.encodePacked(
            address(collateralToken), fee1, weth, fee2, address(debtToken)
        );

        collateralToken.ensureApproval(address(swapRouter), collateralAmount);

        uint256 balanceBefore = debtToken.balanceOf(address(this));
        swapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: collateralAmount,
                amountOutMinimum: minOut
            })
        );
        debtReceived = debtToken.balanceOf(address(this)) - balanceBefore;

        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256 collateralReceived) {
        if (debtAmount == 0) return 0;

        // Get oracle-based expected output for slippage calculation
        uint256 expectedOut = _getExpectedCollateralOut(debtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Encode path: debt → WETH → collateral
        bytes memory path = abi.encodePacked(
            address(debtToken), fee2, weth, fee1, address(collateralToken)
        );

        debtToken.ensureApproval(address(swapRouter), debtAmount);

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        swapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: debtAmount,
                amountOutMinimum: minOut
            })
        );
        collateralReceived = collateralToken.balanceOf(address(this)) - balanceBefore;

        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }

    // ============ Internal Helpers ============

    function _getExpectedDebtOut(uint256 collateralAmount) internal view returns (uint256) {
        (, int256 collateralPrice,,,) = collateralOracle.latestRoundData();
        (, int256 debtPrice,,,) = debtOracle.latestRoundData();
        if (collateralPrice <= 0 || debtPrice <= 0) return 0;

        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        uint8 debtDecimals = debtToken.decimals();

        return (
            collateralAmount * uint256(collateralPrice) * (10 ** debtDecimals)
                * (10 ** debtOracleDecimals)
        ) / (uint256(debtPrice) * (10 ** collateralOracleDecimals) * (10 ** collateralDecimals));
    }

    function _getExpectedCollateralOut(uint256 debtAmount) internal view returns (uint256) {
        (, int256 collateralPrice,,,) = collateralOracle.latestRoundData();
        (, int256 debtPrice,,,) = debtOracle.latestRoundData();
        if (collateralPrice <= 0 || debtPrice <= 0) return 0;

        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        uint8 debtDecimals = debtToken.decimals();

        return (
            debtAmount * uint256(debtPrice) * (10 ** collateralOracleDecimals)
                * (10 ** collateralDecimals)
        ) / (uint256(collateralPrice) * (10 ** debtOracleDecimals) * (10 ** debtDecimals));
    }

    function _safeTransferDebt(address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(debtToken).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();
        if (data.length >= 32 && !abi.decode(data, (bool))) {
            revert TransferFailed();
        }
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
