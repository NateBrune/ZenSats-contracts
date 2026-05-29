// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BasePmUsdCrvUsdStrategy } from "./BasePmUsdCrvUsdStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";
import { ICurveStableSwap } from "../../interfaces/ICurveStableSwap.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { CurveUsdtSwapLib } from "../../libraries/CurveUsdtSwapLib.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";

/// @title UsdtPmUsdCrvUsdStakeDaoStrategy
/// @notice USDT → crvUSD → pmUSD/crvUSD LP → Stake DAO RewardVault.
/// @dev Adds the USDT↔crvUSD swap layer on top of BasePmUsdCrvUsdStrategy via three hook
///      overrides plus the USDT-specific pendingRewards denominator.
contract UsdtPmUsdCrvUsdStakeDaoStrategy is BasePmUsdCrvUsdStrategy {
    using SafeTransferLib for IERC20;

    // ============ USDT-specific Immutables ============

    ICurveStableSwap public immutable usdtCrvUsdPool;
    IChainlinkOracle public immutable usdtOracle;
    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;

    // ============ Events ============

    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);

    // ============ Constructor ============

    constructor(
        address _usdt,
        address _vault,
        address _owner,
        address _usdtCrvUsdPool,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _usdtIndex,
        int128 _crvUsdIndex,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _usdtOracle,
        address _crvOracle
    )
        BasePmUsdCrvUsdStrategy(
            _usdt,
            _vault,
            _owner,
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _lpCrvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    {
        if (_usdtCrvUsdPool == address(0) || _usdtOracle == address(0)) revert InvalidAddress();
        usdtCrvUsdPool = ICurveStableSwap(_usdtCrvUsdPool);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> pmUSD/crvUSD LP Strategy";
    }

    // ============ Swap / Conversion Hooks ============

    /// @dev Oracle-based crvUSD→USDT conversion (no token transfer).
    function _convertLpAssetValueToDebt(uint256 crvUsdAmount)
        internal
        view
        override
        returns (uint256)
    {
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdAmount, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
    }

    /// @dev Pre-deposit: swap USDT → crvUSD before LP operations.
    function _swapDebtToLpAsset(uint256 usdtAmount, uint256 slippage)
        internal
        override
        returns (uint256 crvUsdReceived)
    {
        if (usdtAmount == 0) return 0;
        _ensureApprove(address(debtAsset), address(usdtCrvUsdPool), usdtAmount);
        crvUsdReceived = CurveUsdtSwapLib.swapUsdtToCrvUsd(
            usdtCrvUsdPool,
            usdtIndex,
            crvUsdIndex,
            usdtAmount,
            slippage,
            usdtOracle,
            crvUsdOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    /// @dev Post-exit: swap crvUSD → USDT after LP exit.
    function _swapLpAssetToDebt(uint256 crvUsdAmount, uint256 slippage)
        internal
        override
        returns (uint256 usdtReceived)
    {
        if (crvUsdAmount == 0) return 0;
        _ensureApprove(address(CRVUSD), address(usdtCrvUsdPool), crvUsdAmount);
        usdtReceived = CurveUsdtSwapLib.swapCrvUsdToUsdt(
            usdtCrvUsdPool,
            crvUsdIndex,
            usdtIndex,
            crvUsdAmount,
            slippage,
            crvUsdOracle,
            usdtOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }

    /// @dev CRV/USD ÷ USDT/USD with /1e12 for USDT's 6-decimal precision.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        override
        returns (uint256)
    {
        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
            usdtOracle.latestRoundData();
        if (
            usdtPrice <= 0 || usdtAnswered < usdtRoundId
                || block.timestamp - usdtUpdatedAt > MAX_ORACLE_STALENESS
        ) {
            return crvSwapper.quote(pendingCrv) / 1e12;
        }
        return (pendingCrv * crvPrice) / (uint256(usdtPrice) * 1e12);
    }

    /// @dev CRV oracle stale fallback: swap-quote divided by 1e12 for USDT decimals.
    function _pendingRewardsFallback(uint256 pendingCrv) internal view override returns (uint256) {
        return crvSwapper.quote(pendingCrv) / 1e12;
    }
}
