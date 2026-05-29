// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseNgCrvUsdLpStakeDaoStrategy } from "./BaseNgCrvUsdLpStakeDaoStrategy.sol";
import { UsdtCrvUsdSwapMixin } from "../UsdtCrvUsdSwapMixin.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title UsdtNgCrvUsdLpStakeDaoStrategy
/// @notice USDT → crvUSD → (any 2-coin Curve StableSwapNG pool with crvUSD on one side) → Stake DAO.
/// @dev The USDT↔crvUSD swap layer is provided by UsdtCrvUsdSwapMixin; this contract wires the
///      three unified yield-asset hooks to the mixin helpers and supplies the USDT-specific
///      pendingRewards denominator (CRV value divided to USDT's 6-decimal precision).
contract UsdtNgCrvUsdLpStakeDaoStrategy is BaseNgCrvUsdLpStakeDaoStrategy, UsdtCrvUsdSwapMixin {
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
        BaseNgCrvUsdLpStakeDaoStrategy(
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
        UsdtCrvUsdSwapMixin(
            _usdt,
            address(CRVUSD),
            _usdtCrvUsdPool,
            _usdtOracle,
            _crvUsdOracle,
            _usdtIndex,
            _crvUsdIndex
        )
    { }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> NG crvUSD/token LP Strategy";
    }

    // ============ Yield-Asset Hooks (delegate to mixin) ============

    function _convertYieldAssetValueToDebt(uint256 crvUsdAmount)
        internal
        view
        override
        returns (uint256)
    {
        return _crvUsdValueToUsdt(crvUsdAmount);
    }

    function _swapDebtToYieldAsset(uint256 usdtAmount, uint256 slippage)
        internal
        override
        returns (uint256)
    {
        return _usdtToCrvUsd(usdtAmount, slippage);
    }

    function _swapYieldAssetToDebt(uint256 crvUsdAmount, uint256 slippage)
        internal
        override
        returns (uint256)
    {
        return _crvUsdToUsdt(crvUsdAmount, slippage);
    }

    // ============ Pending-Rewards Denominator (USDT, 6 decimals) ============

    /// @dev CRV/USD ÷ USDT/USD with /1e12 for USDT's 6-decimal precision.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        override
        returns (uint256)
    {
        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
            _usdtOracle.latestRoundData();
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
