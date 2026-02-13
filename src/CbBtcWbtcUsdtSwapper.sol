// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ICurveTwoCrypto } from "./interfaces/ICurveTwoCrypto.sol";
import { ICurveThreeCrypto } from "./interfaces/ICurveThreeCrypto.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { TimelockLib } from "./libraries/TimelockLib.sol";

/// @title CbBtcWbtcUsdtSwapper
/// @notice Two-hop swapper: cbBTC <-> WBTC via TwoCrypto, then WBTC <-> USDT via TriCrypto
contract CbBtcWbtcUsdtSwapper is ISwapper {
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
    IERC20 public immutable wbtcToken;
    ICurveTwoCrypto public immutable cbBtcPool;
    ICurveThreeCrypto public immutable triCryptoPool;
    uint256 public immutable cbBtcIndex;
    uint256 public immutable wbtcIndex;
    uint256 public immutable triWbtcIndex;
    uint256 public immutable triUsdtIndex;

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
        address _wbtcToken,
        address _cbBtcPool,
        uint256 _cbBtcIndex,
        uint256 _wbtcIndex,
        address _triCryptoPool,
        uint256 _triWbtcIndex,
        uint256 _triUsdtIndex
    ) {
        if (
            _gov == address(0) || _collateralToken == address(0) || _debtToken == address(0)
                || _wbtcToken == address(0) || _cbBtcPool == address(0) || _triCryptoPool == address(0)
        ) {
            revert InvalidAddress();
        }
        gov = _gov;
        slippage = 5e16; // 5% initial slippage
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        wbtcToken = IERC20(_wbtcToken);
        cbBtcPool = ICurveTwoCrypto(_cbBtcPool);
        triCryptoPool = ICurveThreeCrypto(_triCryptoPool);
        cbBtcIndex = _cbBtcIndex;
        wbtcIndex = _wbtcIndex;
        triWbtcIndex = _triWbtcIndex;
        triUsdtIndex = _triUsdtIndex;
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 wbtcOut = _safeGetDyThree(triUsdtIndex, triWbtcIndex, debtAmount);
        if (wbtcOut == 0) return 0;
        uint256 cbBtcOut = _safeGetDyTwo(wbtcIndex, cbBtcIndex, wbtcOut);
        if (cbBtcOut == 0) return 0;
        return _applySlippageUp(cbBtcOut, 2);
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;

        uint256 expectedWbtc = _safeGetDyTwo(cbBtcIndex, wbtcIndex, collateralAmount);
        uint256 minWbtc = expectedWbtc > 0 ? _applySlippageDown(expectedWbtc) : 0;
        collateralToken.ensureApproval(address(cbBtcPool), collateralAmount);
        uint256 wbtcBefore = wbtcToken.balanceOf(address(this));
        _exchangeTwo(cbBtcIndex, wbtcIndex, collateralAmount, minWbtc, address(this));
        uint256 wbtcAfter = wbtcToken.balanceOf(address(this));
        uint256 wbtcReceived = wbtcAfter > wbtcBefore ? wbtcAfter - wbtcBefore : 0;

        if (wbtcReceived == 0) return 0;

        uint256 expectedUsdt = _safeGetDyThree(triWbtcIndex, triUsdtIndex, wbtcReceived);
        uint256 minUsdt = expectedUsdt > 0 ? _applySlippageDown(expectedUsdt) : 0;
        wbtcToken.ensureApproval(address(triCryptoPool), wbtcReceived);
        uint256 debtBefore = debtToken.balanceOf(address(this));
        debtReceived = _exchangeThree(
            triWbtcIndex, triUsdtIndex, wbtcReceived, minUsdt, debtToken, debtBefore
        );
        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;

        uint256 expectedWbtc = _safeGetDyThree(triUsdtIndex, triWbtcIndex, debtAmount);
        uint256 minWbtc = expectedWbtc > 0 ? _applySlippageDown(expectedWbtc) : 0;
        debtToken.ensureApproval(address(triCryptoPool), debtAmount);
        uint256 wbtcBefore = wbtcToken.balanceOf(address(this));
        uint256 wbtcReceived = _exchangeThree(
            triUsdtIndex, triWbtcIndex, debtAmount, minWbtc, wbtcToken, wbtcBefore
        );
        if (wbtcReceived == 0) return 0;

        uint256 expectedCbBtc = _safeGetDyTwo(wbtcIndex, cbBtcIndex, wbtcReceived);
        uint256 minCbBtc = expectedCbBtc > 0 ? _applySlippageDown(expectedCbBtc) : 0;
        wbtcToken.ensureApproval(address(cbBtcPool), wbtcReceived);
        _exchangeTwo(wbtcIndex, cbBtcIndex, wbtcReceived, minCbBtc, address(this));
        collateralReceived = collateralToken.balanceOf(address(this));
        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
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

    // ============ Internal Helpers ============

    function _applySlippageDown(uint256 amount) private view returns (uint256) {
        if (amount == 0) return 0;
        return (amount * (PRECISION - slippage)) / PRECISION;
    }

    function _applySlippageUp(uint256 amount, uint256 hops) private view returns (uint256) {
        uint256 adjusted = amount;
        for (uint256 i = 0; i < hops; i++) {
            adjusted = (adjusted * PRECISION) / (PRECISION - slippage) + 1;
        }
        return adjusted;
    }

    function _safeGetDyTwo(uint256 i, uint256 j, uint256 dx) private view returns (uint256 amountOut) {
        (bool ok, bytes memory data) = address(cbBtcPool).staticcall(
            abi.encodeWithSelector(ICurveTwoCrypto.get_dy.selector, i, j, dx)
        );
        if (!ok || data.length < 32) {
            (ok, data) = address(cbBtcPool).staticcall(
                abi.encodeWithSignature("get_dy(int128,int128,uint256)", i, j, dx)
            );
        }
        if (!ok || data.length < 32) return 0;
        amountOut = abi.decode(data, (uint256));
    }

    function _safeGetDyThree(uint256 i, uint256 j, uint256 dx)
        private
        view
        returns (uint256 amountOut)
    {
        (bool ok, bytes memory data) = address(triCryptoPool).staticcall(
            abi.encodeWithSelector(ICurveThreeCrypto.get_dy.selector, i, j, dx)
        );
        if (!ok || data.length < 32) return 0;
        amountOut = abi.decode(data, (uint256));
    }

    function _exchangeTwo(uint256 i, uint256 j, uint256 dx, uint256 minOut, address receiver)
        private
    {
        (bool ok,) = address(cbBtcPool).call(
            abi.encodeWithSignature(
                "exchange(uint256,uint256,uint256,uint256,address)", i, j, dx, minOut, receiver
            )
        );
        if (!ok) {
            (ok,) = address(cbBtcPool).call(
                abi.encodeWithSignature(
                    "exchange(int128,int128,uint256,uint256,address)", i, j, dx, minOut, receiver
                )
            );
        }
        if (!ok) revert TransferFailed();
    }

    function _exchangeThree(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minOut,
        IERC20 outToken,
        uint256 balanceBefore
    ) private returns (uint256 amountOut) {
        (bool ok, bytes memory data) = address(triCryptoPool).call(
            abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256,bool)", i, j, dx, minOut, false)
        );
        if (!ok) revert TransferFailed();
        if (data.length >= 32) {
            amountOut = abi.decode(data, (uint256));
        } else {
            uint256 balanceAfter = outToken.balanceOf(address(this));
            amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }
    }

    function _safeTransferDebt(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(debtToken).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok) revert TransferFailed();
        if (data.length >= 32 && !abi.decode(data, (bool))) {
            revert TransferFailed();
        }
    }
}
