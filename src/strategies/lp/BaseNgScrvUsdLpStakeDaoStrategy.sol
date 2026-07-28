// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveStakeDaoStrategy } from "./BaseCurveStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../../interfaces/ICurveStableSwapNG.sol";
import { IYieldVault } from "../../interfaces/IYieldVault.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";

/// @title BaseNgScrvUsdLpStakeDaoStrategy
/// @notice Pool-agnostic layer for any **2-coin Curve StableSwapNG** pool with scrvUSD (Savings
///         crvUSD, the crvUSD ERC-4626) on one side, staked in Stake DAO. Works for scrvUSD/sUSDe,
///         reUSD/scrvUSD, scrvUSD/sDOLA, or any other 2-coin NG scrvUSD pool — the non-scrvUSD coin
///         and its index are derived from the pool at deploy, not hardcoded.
/// @dev scrvUSD pools contain NO crvUSD, so this layer inserts a lossless ERC-4626 wrap leg between
///      the strategy's crvUSD lpAsset and the pool's scrvUSD coin:
///        - add:    crvUSD --SCRVUSD.deposit--> scrvUSD --single-sided add--> LP
///        - remove: LP --single-sided exit--> scrvUSD --SCRVUSD.redeem--> crvUSD
///      The wrap is exact-rate (no slippage, no cooldown, no new oracle), so `lpAsset` stays crvUSD
///      and all crvUSD-denominated machinery in BaseCurveStakeDaoStrategy (CRV reward swap, pending
///      rewards, cost basis, debt conversion) is inherited unchanged. Only three things differ from
///      the crvUSD-pool sibling and are handled here: the wrap in `_addLiquidity`, the unwrap in
///      `_removeLiquidity`, and a `balanceOf` override that bridges the two units the pool reports
///      in (VP is rate-normalized ~crvUSD; `calc_withdraw_one_coin` is raw scrvUSD).
///
///      Restricted to N_COINS == 2 on purpose: it bounds the strategy to a single paired
///      counterparty asset (the other coin), matching the risk profile of the crvUSD-pool sibling.
///      A 3+ coin pool would expose multiple counterparties and is rejected at construction.
abstract contract BaseNgScrvUsdLpStakeDaoStrategy is BaseCurveStakeDaoStrategy {
    /// @notice Savings crvUSD (scrvUSD) — the crvUSD ERC-4626. The single coin the strategy
    ///         adds/exits in the pool. crvUSD is wrapped into it on the way in and unwrapped out.
    IYieldVault public constant SCRVUSD = IYieldVault(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);

    /// @notice The non-scrvUSD coin in the pool (e.g. sUSDe, reUSD, sDOLA), derived at deploy.
    IERC20 public immutable otherCoin;

    /// @notice The non-scrvUSD coin's index (the complement of lpScrvUsdIndex).
    uint256 public immutable lpOtherIndex;

    error UnsupportedCoinCount();
    error ScrvUsdIndexMismatch();

    /// @param _debtAsset      Debt token accepted by the vault (crvUSD or USDT depending on variant).
    /// @param _vault          Zenji vault address.
    /// @param _owner          Initial owner.
    /// @param _lpPool         Curve 2-coin StableSwapNG pool with scrvUSD on one side.
    /// @param _rewardVault    Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper     CRV → crvUSD swapper.
    /// @param _gauge          Curve gauge for accountant claims.
    /// @param _lpScrvUsdIndex scrvUSD coin index in the pool.
    /// @param _crvUsdOracle   Chainlink crvUSD/USD oracle.
    /// @param _crvOracle      Chainlink CRV/USD oracle.
    /// @dev The base immutable `lpCrvUsdIndex` is (re)used to store the scrvUSD index — it is simply
    ///      "the coin index the strategy adds/exits", and both base consumers (`balanceOf`,
    ///      `_removeLiquidity`) are overridden below to read it as scrvUSD.
    constructor(
        address _debtAsset,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpScrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    )
        BaseCurveStakeDaoStrategy(
            _debtAsset,
            _vault,
            _owner,
            address(CRVUSD), // lpAsset == crvUSD; scrvUSD wrap is internal to add/remove
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _lpScrvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    {
        ICurveStableSwapNG pool = ICurveStableSwapNG(_lpPool);
        if (pool.N_COINS() != 2) revert UnsupportedCoinCount();
        // scrvUSD must actually sit at the declared index — guards a deploy-time index mistake
        // that would otherwise make the strategy add/exit on the wrong coin.
        if (pool.coins(uint256(uint128(_lpScrvUsdIndex))) != address(SCRVUSD)) {
            revert ScrvUsdIndexMismatch();
        }
        uint256 otherIdx = _lpScrvUsdIndex == int128(0) ? 1 : 0;
        lpOtherIndex = otherIdx;
        otherCoin = IERC20(pool.coins(otherIdx));
    }

    // ============ BaseLPStrategy Hook: Add Liquidity ============

    /// @notice Wrap crvUSD into scrvUSD (exact-rate ERC-4626 deposit), then add scrvUSD to the pool,
    ///         also draining any residual balance of the other coin.
    /// @dev Adds the full scrvUSD balance so that any donated/dust scrvUSD is absorbed rather than
    ///      stranded, and includes any other-coin residual for the same reason (residuals are not
    ///      produced by normal operation, but the two-sided add absorbs them if a donation leaves
    ///      the coin in the contract — it is protected from rescue, so this is its only way out).
    ///      The oracle floor is keyed to the crvUSD capital actually deposited (`crvUsdAmount`,
    ///      the value the pool VP is denominated in) and is immune to same-block VP manipulation;
    ///      the spot LP_SLIPPAGE floor from calc_token_amount covers the residual portions on top.
    function _addLiquidity(uint256 crvUsdAmount) internal override returns (uint256 lpReceived) {
        if (crvUsdAmount > 0) {
            _ensureApprove(address(CRVUSD), address(SCRVUSD), crvUsdAmount);
            SCRVUSD.deposit(crvUsdAmount, address(this));
        }

        uint256 scrvAmount = SCRVUSD.balanceOf(address(this));
        uint256 otherAmount = otherCoin.balanceOf(address(this));
        if (scrvAmount == 0 && otherAmount == 0) return 0;

        ICurveStableSwapNG pool = ICurveStableSwapNG(address(lpPool));
        if (scrvAmount > 0) _ensureApprove(address(SCRVUSD), address(pool), scrvAmount);
        if (otherAmount > 0) _ensureApprove(address(otherCoin), address(pool), otherAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = scrvAmount;
        amounts[lpOtherIndex] = otherAmount;

        uint256 expectedLp = pool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        // Oracle floor via cached unit value. VP is rate-normalized crvUSD-per-LP, so the expected
        // LP for `crvUsdAmount` of deposited value is crvUsdAmount / VP. Applied to the crvUSD
        // capital only (the scrvUSD wrap preserves value exactly); residual scrvUSD is a donated
        // windfall covered by the spot LP_SLIPPAGE floor above.
        if (crvUsdAmount > 0) {
            uint256 safeVP = _getSafeUnitValue();
            uint256 oracleMinLp =
                (crvUsdAmount * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
            if (oracleMinLp > minLp) minLp = oracleMinLp;
        }

        lpReceived = pool.add_liquidity(amounts, minLp);
    }

    // ============ BaseLPStrategy Hook: Remove Liquidity ============

    /// @notice Single-sided scrvUSD exit, then unwrap scrvUSD → crvUSD (exact-rate ERC-4626 redeem).
    /// @dev `slippage` guards the Curve leg (LP → scrvUSD); the redeem leg is exact-rate so no
    ///      second slippage bound is needed. Returns crvUSD (the strategy's lpAsset).
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        override
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedScrv = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);
        uint256 minOut = (expectedScrv * (PRECISION - slippage)) / PRECISION;
        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        uint256 scrvReceived = lpPool.remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut);
        if (scrvReceived == 0) return 0;
        crvUsdReceived = SCRVUSD.redeem(scrvReceived, address(this), address(this));
    }

    // ============ Balance Reporting ============

    /// @notice Manipulation-aware balance in debt-asset terms, bridging the pool's two unit systems.
    /// @dev The pool reports value two ways that live in different units for an scrvUSD pool:
    ///        - `get_virtual_price()` (via the cached unit value) is RATE-NORMALIZED — already in
    ///          ~crvUSD terms, so `lpTokens * safeVP / PRECISION` is a crvUSD value directly.
    ///        - `calc_withdraw_one_coin` returns RAW scrvUSD, converted to crvUSD via the exact
    ///          ERC-4626 rate (`convertToAssets`).
    ///      Taking min() keeps the conservative pattern from the base: pool imbalance (paired-asset
    ///      depeg) surfaces through the exit leg and can only understate, never inflate.
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _stakedLpBalance();
        if (lpTokens < 1) return 0;
        uint256 vpBased = (lpTokens * _getSafeUnitValue()) / PRECISION;
        uint256 exitScrv = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex);
        uint256 exitBased = SCRVUSD.convertToAssets(exitScrv);
        uint256 crvUsdValue = exitBased < vpBased ? exitBased : vpBased;
        return _convertYieldAssetValueToDebt(crvUsdValue);
    }

    // ============ Protected Tokens ============

    /// @dev Add scrvUSD (transient wrap holding) and the other pool coin on top of the base's
    ///      CRV / lpToken / lpAsset / stakingVault / debtAsset set.
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(SCRVUSD)
            || token == address(otherCoin);
    }
}
