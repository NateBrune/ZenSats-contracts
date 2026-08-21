// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveStakeDaoStrategy } from "./BaseCurveStakeDaoStrategy.sol";
import { UsdtCrvUsdSwapMixin } from "../UsdtCrvUsdSwapMixin.sol";
import { ICurveStableSwapTwoLP } from "../../interfaces/ICurveStableSwapTwoLP.sol";

/// @title UsdtCrvUsdLpStakeDaoStrategy
/// @notice USDT → crvUSD → (any legacy 2-coin Curve StableSwap pool with crvUSD on one side) →
///         Stake DAO RewardVault.
/// @dev The USDT↔crvUSD swap layer is provided by UsdtCrvUsdSwapMixin; this contract wires the
///      three unified yield-asset hooks to the mixin helpers, supplies the legacy 2-coin
///      single-sided add (fixed `uint256[2]`, copied verbatim from CrvUsdLpStakeDaoStrategy), and
///      the USDT-specific pendingRewards denominator (CRV value divided to USDT's 6-decimal
///      precision).
///
///      Pool-agnostic like its siblings: the same contract works for any legacy 2-coin StableSwap
///      with crvUSD as one side, with the entry/exit USDT<->crvUSD swap pool supplied separately.
///
///      When `_usdtCrvUsdPool == _lpPool` (the crvUSD/USDT deployment) the deposit path swaps
///      USDT→crvUSD in the same pool it then single-side-adds crvUSD into, costing one extra
///      exchange fee each way (swap fee + add-liquidity implicit swap fee on the same pool). This
///      is accepted for base-math safety: lpAsset must stay crvUSD (18 decimals) so the inherited
///      virtual-price accounting (`lpTokens * VP / 1e18`) remains correct, and reusing the base's
///      legacy-pool `_addLiquidity` (rather than special-casing a two-sided USDT+crvUSD add for
///      this one deployment) keeps the math identical and audited across every legacy-pool
///      deployment of this strategy class.
contract UsdtCrvUsdLpStakeDaoStrategy is BaseCurveStakeDaoStrategy, UsdtCrvUsdSwapMixin {
    /// @notice Human-readable strategy name (set at deploy, e.g. "USDT -> USDT/crvUSD").
    string public override name;

    /// @param _usdt           USDT token address (debt asset).
    /// @param _vault          Zenji vault address.
    /// @param _owner          Initial owner.
    /// @param _usdtCrvUsdPool Curve USDT/crvUSD pool used for the entry/exit swap leg.
    /// @param _lpPool         Curve crvUSD-anchored legacy 2-coin pool the strategy deposits into.
    /// @param _rewardVault    Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper     CRV → crvUSD swapper.
    /// @param _gauge          Curve gauge for accountant claims.
    /// @param _usdtIndex      USDT coin index in `_usdtCrvUsdPool` (0 or 1).
    /// @param _crvUsdIndex    crvUSD coin index in `_usdtCrvUsdPool` (0 or 1).
    /// @param _lpCrvUsdIndex  crvUSD coin index in `_lpPool` (0 or 1).
    /// @param _crvUsdOracle   Chainlink crvUSD/USD oracle.
    /// @param _usdtOracle     Chainlink USDT/USD oracle.
    /// @param _crvOracle      Chainlink CRV/USD oracle.
    /// @param _name           Human-readable name, e.g. "USDT -> USDT/crvUSD LP Strategy".
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
        address _crvOracle,
        string memory _name
    )
        BaseCurveStakeDaoStrategy(
            _usdt,
            _vault,
            _owner,
            address(CRVUSD), // lpAsset == crvUSD (18-dec base math)
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
    {
        name = _name;
    }

    /// @notice Single-sided crvUSD add into a legacy 2-coin StableSwap (fixed `uint256[2]`).
    /// @dev LP_SLIPPAGE caps the implicit swap portion; the cached-VP oracle floor independently
    ///      defends against same-block price manipulation. Copied verbatim from
    ///      CrvUsdLpStakeDaoStrategy — the math is pool-agnostic and identical here.
    function _addLiquidity(uint256 crvUsdAmount) internal override returns (uint256 lpReceived) {
        if (crvUsdAmount == 0) return 0;
        ICurveStableSwapTwoLP pool = ICurveStableSwapTwoLP(address(lpPool));
        _ensureApprove(address(CRVUSD), address(pool), crvUsdAmount);

        uint256[2] memory amounts;
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;

        uint256 expectedLp = pool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        uint256 safeVP = _getSafeUnitValue();
        uint256 oracleMinLp =
            (crvUsdAmount * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = pool.add_liquidity(amounts, minLp);
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
