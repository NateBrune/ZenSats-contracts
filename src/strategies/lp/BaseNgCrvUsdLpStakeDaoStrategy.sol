// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveStakeDaoStrategy } from "./BaseCurveStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../../interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";

/// @title BaseNgCrvUsdLpStakeDaoStrategy
/// @notice Pool-agnostic layer for any **2-coin Curve StableSwapNG** pool with crvUSD on one side,
///         staked in Stake DAO. Works for pmUSD/crvUSD or any other 2-coin NG crvUSD pool — the
///         non-crvUSD coin and its index are derived from the pool at deploy, not hardcoded.
/// @dev All generic Curve + Stake DAO machinery (exit, balance, harvest, pendingRewards) lives in
///      BaseCurveStakeDaoStrategy. This contract only supplies the StableSwapNG dynamic-array add
///      (single-sided crvUSD, also draining any residual of the other coin) and protects that coin.
///
///      Restricted to N_COINS == 2 on purpose: the oracle-floor uses the sum of both coin amounts
///      as a USD proxy, which is only valid for two same-class (~$1) coins. A 3+ coin pool would
///      need a per-coin valuation and is rejected at construction.
abstract contract BaseNgCrvUsdLpStakeDaoStrategy is BaseCurveStakeDaoStrategy {
    /// @notice The non-crvUSD coin in the pool (e.g. pmUSD, USDC), derived from the pool at deploy.
    IERC20 public immutable otherCoin;

    /// @notice The non-crvUSD coin's index (the complement of lpCrvUsdIndex).
    uint256 public immutable lpOtherIndex;

    error UnsupportedCoinCount();

    /// @param _debtAsset     Debt token accepted by the vault (crvUSD or USDT depending on variant).
    /// @param _vault         Zenji vault address.
    /// @param _owner         Initial owner.
    /// @param _lpPool        Curve 2-coin StableSwapNG pool with crvUSD on one side.
    /// @param _rewardVault   Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper    CRV → crvUSD swapper.
    /// @param _gauge         Curve gauge for accountant claims.
    /// @param _lpCrvUsdIndex crvUSD coin index in the pool.
    /// @param _crvUsdOracle  Chainlink crvUSD/USD oracle.
    /// @param _crvOracle     Chainlink CRV/USD oracle.
    constructor(
        address _debtAsset,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    )
        BaseCurveStakeDaoStrategy(
            _debtAsset,
            _vault,
            _owner,
            address(CRVUSD), // lpAsset == crvUSD
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _lpCrvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    {
        if (ICurveStableSwapNG(_lpPool).N_COINS() != 2) revert UnsupportedCoinCount();
        uint256 otherIdx = _lpCrvUsdIndex == int128(0) ? 1 : 0;
        lpOtherIndex = otherIdx;
        otherCoin = IERC20(ICurveStableSwapNG(_lpPool).coins(otherIdx));
    }

    // ============ BaseLPStrategy Hook: Add Liquidity ============

    /// @notice Add crvUSD single-sided via the StableSwapNG dynamic-array API, also draining any
    ///         residual balance of the other coin.
    /// @dev Residuals of the other coin are not produced by normal operation, but the two-sided
    ///      add absorbs them if a donation leaves the coin in the contract.
    function _addLiquidity(uint256 lpAssetAmount) internal override returns (uint256 lpReceived) {
        ICurveStableSwapNG pool = ICurveStableSwapNG(address(lpPool));
        uint256 crvUsdAmount = lpAssetAmount;
        uint256 otherAmount = otherCoin.balanceOf(address(this));
        if (crvUsdAmount == 0 && otherAmount == 0) return 0;

        if (crvUsdAmount > 0) _ensureApprove(address(CRVUSD), address(pool), crvUsdAmount);
        if (otherAmount > 0) _ensureApprove(address(otherCoin), address(pool), otherAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;
        amounts[lpOtherIndex] = otherAmount;

        uint256 expectedLp = pool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        // Oracle floor via cached unit value — immune to same-block manipulation.
        uint256 safeVP = _getSafeUnitValue();
        uint256 totalValue = crvUsdAmount + otherAmount;
        uint256 oracleMinLp =
            (totalValue * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = pool.add_liquidity(amounts, minLp);
    }

    // ============ Protected Tokens ============

    /// @dev Add the other pool coin on top of the base's CRV / lpToken / lpAsset / stakingVault /
    ///      debtAsset set.
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(otherCoin);
    }
}
