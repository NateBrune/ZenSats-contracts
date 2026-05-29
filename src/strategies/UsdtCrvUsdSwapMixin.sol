// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { CurveUsdtSwapLib } from "../libraries/CurveUsdtSwapLib.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title UsdtCrvUsdSwapMixin
/// @notice Reusable USDT↔crvUSD swap layer shared by every USDT-debt strategy, regardless of
///         which strategy tree it lives in (vault/ or lp/).
/// @dev Self-contained on purpose — it does NOT inherit a strategy base, so it can be mixed into
///      either `BaseVaultStrategy` or `BaseLPStrategy` descendants without diamond-override pain.
///      A concrete strategy inherits this mixin alongside its tree base and wires the three unified
///      yield-asset hooks (_swapDebtToYieldAsset / _swapYieldAssetToDebt /
///      _convertYieldAssetValueToDebt) to the three helpers below. The actual swap math lives in
///      CurveUsdtSwapLib; this mixin only owns the pool/oracle/index configuration and approvals.
abstract contract UsdtCrvUsdSwapMixin {
    using SafeTransferLib for IERC20;

    /// Chainlink heartbeat is 24h; 25h gives one heartbeat of safety margin.
    uint256 internal constant MAX_USDT_CRVUSD_STALENESS = 90000;

    IERC20 internal immutable _usdt;
    IERC20 internal immutable _crvUsd;
    ICurveStableSwap internal immutable _usdtCrvUsdPool;
    IChainlinkOracle internal immutable _usdtOracle;
    IChainlinkOracle internal immutable _crvUsdOracle;
    int128 internal immutable _usdtIndex;
    int128 internal immutable _crvUsdIndex;

    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);

    error UsdtSwapInvalidAddress();

    constructor(
        address usdt_,
        address crvUsd_,
        address usdtCrvUsdPool_,
        address usdtOracle_,
        address crvUsdOracle_,
        int128 usdtIndex_,
        int128 crvUsdIndex_
    ) {
        if (
            usdt_ == address(0) || crvUsd_ == address(0) || usdtCrvUsdPool_ == address(0)
                || usdtOracle_ == address(0) || crvUsdOracle_ == address(0)
        ) {
            revert UsdtSwapInvalidAddress();
        }
        _usdt = IERC20(usdt_);
        _crvUsd = IERC20(crvUsd_);
        _usdtCrvUsdPool = ICurveStableSwap(usdtCrvUsdPool_);
        _usdtOracle = IChainlinkOracle(usdtOracle_);
        _crvUsdOracle = IChainlinkOracle(crvUsdOracle_);
        _usdtIndex = usdtIndex_;
        _crvUsdIndex = crvUsdIndex_;
    }

    /// @notice Swap USDT → crvUSD with the library's oracle-floored slippage check.
    function _usdtToCrvUsd(uint256 usdtAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        if (usdtAmount == 0) return 0;
        _usdt.ensureApproval(address(_usdtCrvUsdPool), usdtAmount);
        crvUsdReceived = CurveUsdtSwapLib.swapUsdtToCrvUsd(
            _usdtCrvUsdPool,
            _usdtIndex,
            _crvUsdIndex,
            usdtAmount,
            slippage,
            _usdtOracle,
            _crvUsdOracle,
            MAX_USDT_CRVUSD_STALENESS
        );
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    /// @notice Swap crvUSD → USDT with the library's oracle-floored slippage check.
    function _crvUsdToUsdt(uint256 crvUsdAmount, uint256 slippage)
        internal
        returns (uint256 usdtReceived)
    {
        if (crvUsdAmount == 0) return 0;
        _crvUsd.ensureApproval(address(_usdtCrvUsdPool), crvUsdAmount);
        usdtReceived = CurveUsdtSwapLib.swapCrvUsdToUsdt(
            _usdtCrvUsdPool,
            _crvUsdIndex,
            _usdtIndex,
            crvUsdAmount,
            slippage,
            _crvUsdOracle,
            _usdtOracle,
            MAX_USDT_CRVUSD_STALENESS
        );
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }

    /// @notice Oracle-based crvUSD → USDT valuation (no token transfer). Used by balanceOf().
    function _crvUsdValueToUsdt(uint256 crvUsdAmount) internal view returns (uint256) {
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdAmount, _crvUsdOracle, _usdtOracle, MAX_USDT_CRVUSD_STALENESS
        );
    }
}
