// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "../BaseYieldStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";
import { IYieldVault } from "../../interfaces/IYieldVault.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";

/// @title BaseLPStrategy
/// @notice Abstract base for "LP strategies" — strategies that:
///         1. (optionally) swap the debt asset into a single LP-pool asset (`lpAsset`),
///         2. deposit `lpAsset` single-sided into a pool to mint LP tokens,
///         3. stake those LP tokens in an external ERC4626 reward vault.
/// @dev Subclasses implement four abstract hooks for the pool/reward specifics:
///        - _addLiquidity(amount)            — single-sided add, returns LP minted
///        - _removeLiquidity(lp, slippage)   — single-sided exit, returns lpAsset received
///        - _lpUnitValue()                   — lpAsset value of 1e18 LP tokens (e.g. virtual_price)
///        - _claimAndSwapRewards()           — claim rewards and swap them to lpAsset
///      and three optional swap/conversion hooks (default 1:1 pass-through):
///        - _swapDebtToYieldAsset / _swapYieldAssetToDebt / _convertYieldAssetValueToDebt
///
///      The base owns generic flow (deposit / withdraw / harvest / emergency), the unit-value
///      cache (manipulation-resistant ratchet around the LP unit value), and the staking vault
///      helpers. Slippage protection on exits is enforced per-call via `slippageTolerance` /
///      `EMERGENCY_SLIPPAGE` — no VP-based exit floor is applied, so users can always exit
///      during depeg events by accepting the market price.
abstract contract BaseLPStrategy is BaseYieldStrategy {
    // ============ Constants ============

    /// @notice Slippage applied to LP add operations (stable pool default).
    uint256 public constant LP_SLIPPAGE = 5e15; // 0.5%

    /// @notice Maximum allowed deviation between cached and current LP unit value.
    uint256 public constant MAX_VP_DEVIATION = 5e15; // 0.5%

    /// @notice Cache age beyond which clamping is bypassed (avoids stale-bound after long idle).
    uint256 public constant MAX_VP_STALENESS = 1 days;

    // ============ Immutables ============

    /// @notice LP receipt token (auto-derived from staking vault's underlying asset).
    IERC20 public immutable lpToken;

    /// @notice Pool asset deposited / withdrawn single-sided (e.g. crvUSD in pmUSD/crvUSD pool).
    IERC20 public immutable lpAsset;

    /// @notice External ERC4626 vault that holds the LP tokens and accrues rewards.
    IYieldVault public immutable stakingVault;

    // ============ State ============

    /// @notice Last ratcheted LP unit value (manipulation-resistant snapshot).
    /// @dev Public name preserved as `cachedVirtualPrice` ("virtual price" is Curve's term for
    ///      what we generically call "unit value") for compatibility with monitoring tooling.
    uint256 public cachedVirtualPrice;

    /// @notice Block timestamp of the last cache update.
    uint256 public lastVpUpdate;

    // ============ Events ============

    event LiquidityAdded(uint256 lpAssetAmount, uint256 lpReceived);
    event LiquidityRemoved(uint256 lpBurned, uint256 lpAssetReceived);
    event RewardsCompounded(uint256 lpAssetCompounded);

    // ============ Constructor ============

    /// @param _debtAsset    Token accepted from the vault.
    /// @param _vault        Zenji vault (or zero for deferred initialization).
    /// @param _owner        Initial admin (or zero to default to msg.sender).
    /// @param _lpAsset      Asset deposited single-sided into the pool.
    /// @param _stakingVault External ERC4626 vault that receives the LP tokens.
    constructor(
        address _debtAsset,
        address _vault,
        address _owner,
        address _lpAsset,
        address _stakingVault
    ) BaseYieldStrategy(_debtAsset, _vault, _owner) {
        // LP strategies require explicit owner — multi-step deployments often have deployer
        // != intended owner. Vault strategies allow zero (defaults to msg.sender via base).
        if (_owner == address(0)) revert InvalidAddress();
        if (_lpAsset == address(0) || _stakingVault == address(0)) revert InvalidAddress();
        lpAsset = IERC20(_lpAsset);
        stakingVault = IYieldVault(_stakingVault);
        lpToken = IERC20(IYieldVault(_stakingVault).asset());
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view virtual override returns (address) {
        return address(lpToken);
    }

    /// @inheritdoc IYieldStrategy
    /// @dev stakedLp → lpAsset value via cached unit value → debt via _convertYieldAssetValueToDebt.
    function balanceOf() public view virtual override returns (uint256) {
        uint256 lpTokens = _stakedLpBalance();
        if (lpTokens < 1) return 0;
        uint256 lpAssetValue = (lpTokens * _getSafeUnitValue()) / PRECISION;
        return _convertYieldAssetValueToDebt(lpAssetValue);
    }

    // ============ Unit-Value Cache ============

    /// @notice Permissionless keeper function — ratchet the cached LP unit value.
    /// @dev Implements IYieldStrategy.updateCachedVirtualPrice (legacy name kept for the
    ///      external interface; "virtual price" is Curve's term for what we call "unit value").
    function updateCachedVirtualPrice() external override {
        _updateCachedUnitValue();
    }

    /// @notice Subclass constructors call this AFTER setting their pool immutables to prime
    ///         the cache. Without it, the very first balanceOf() returns the unclamped current.
    function _initializeUnitValueCache() internal {
        cachedVirtualPrice = _lpUnitValue();
        lastVpUpdate = block.timestamp;
    }

    function _updateCachedUnitValue() internal {
        cachedVirtualPrice = _getSafeUnitValue();
        lastVpUpdate = block.timestamp;
    }

    /// @inheritdoc BaseYieldStrategy
    /// @dev Ratchet the cache before the outer withdraw() reads balanceOf() for cost-basis,
    ///      so it matches the post-update value _withdraw() uses for share redemption.
    function _syncValueCache() internal override {
        _updateCachedUnitValue();
    }

    /// @notice Manipulation-resistant unit value: clamp current to ±MAX_VP_DEVIATION around
    ///         the cache. Bypass the clamp when the cache is older than MAX_VP_STALENESS so
    ///         long idle periods don't permanently anchor balanceOf() to an outdated value.
    function _getSafeUnitValue() internal view returns (uint256) {
        uint256 cached = cachedVirtualPrice;
        uint256 current = _lpUnitValue();
        if (cached == 0) return current;
        if (block.timestamp - lastVpUpdate > MAX_VP_STALENESS) return current;

        uint256 maxDeviation = (cached * MAX_VP_DEVIATION) / PRECISION;
        uint256 upperBound = cached + maxDeviation;
        uint256 lowerBound = cached > maxDeviation ? cached - maxDeviation : 0;
        if (current > upperBound) return upperBound;
        if (current < lowerBound) return lowerBound;
        return current;
    }

    // ============ Core Flow ============

    function _deposit(uint256 debtAmount)
        internal
        virtual
        override
        returns (uint256 underlyingDeposited)
    {
        _updateCachedUnitValue();
        uint256 sharesBefore = stakingVault.balanceOf(address(this));

        // Compound first. For "debt == lpAsset" subclasses the deposit's lpAsset is already in
        // the contract and gets consumed by this step's _addLiquidityAndStake. For subclasses
        // with a separate debt asset (USDT-variant) the next step's swap brings in the lpAsset.
        _compoundRewards();
        _swapDebtToYieldAsset(debtAmount, slippageTolerance);
        _addLiquidityAndStake();

        underlyingDeposited = stakingVault.balanceOf(address(this)) - sharesBefore;
    }

    function _withdraw(uint256 debtAmount) internal virtual override returns (uint256 received) {
        _updateCachedUnitValue();

        // Snapshot share ratio BEFORE _compoundRewards inflates the pool, keeping it consistent
        // with the basisReduction computed from the outer balanceOf() call.
        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;
        uint256 shares = stakingVault.balanceOf(address(this));
        if (shares < 1) return 0;
        uint256 sharesToRedeem = (shares * debtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;

        _compoundRewards();
        if (sharesToRedeem < 1) return 0;

        uint256 lpReceived = _unstakeLp(sharesToRedeem);
        uint256 lpAssetReceived;
        if (lpReceived > 0) {
            lpAssetReceived = _removeLiquidity(lpReceived, slippageTolerance);
            emit LiquidityRemoved(lpReceived, lpAssetReceived);
        }
        received = _swapYieldAssetToDebt(lpAssetReceived, slippageTolerance);
    }

    function _withdrawAll() internal virtual override returns (uint256 received) {
        _updateCachedUnitValue();
        uint256 lpReceived = _unstakeAllLp();
        if (lpReceived < 1) return 0;
        uint256 lpAssetReceived = _removeLiquidity(lpReceived, slippageTolerance);
        emit LiquidityRemoved(lpReceived, lpAssetReceived);
        received = _swapYieldAssetToDebt(lpAssetReceived, slippageTolerance);
    }

    function _emergencyWithdraw() internal virtual override returns (uint256 received) {
        _updateCachedUnitValue();
        uint256 lpReceived = _unstakeAllLp();
        if (lpReceived < 1) return 0;
        uint256 lpAssetReceived = _removeLiquidity(lpReceived, EMERGENCY_SLIPPAGE);
        emit LiquidityRemoved(lpReceived, lpAssetReceived);
        received = _swapYieldAssetToDebt(lpAssetReceived, EMERGENCY_SLIPPAGE);
    }

    function _harvest() internal virtual override returns (uint256 rewardsValue) {
        _updateCachedUnitValue();
        uint256 lpAssetCompounded = _compoundRewards();
        rewardsValue = _convertYieldAssetValueToDebt(lpAssetCompounded);
    }

    // ============ Compounding ============

    /// @notice Claim rewards, swap them to lpAsset, then add+stake all residual lpAsset.
    /// @return lpAssetCompounded Amount of lpAsset produced by the reward swap (event metadata).
    function _compoundRewards() internal returns (uint256 lpAssetCompounded) {
        lpAssetCompounded = _claimAndSwapRewards();
        _addLiquidityAndStake();
        if (lpAssetCompounded > 0) emit RewardsCompounded(lpAssetCompounded);
    }

    // ============ Staking Helpers ============

    function _stakeLp(uint256 lpAmount) internal returns (uint256 shares) {
        _ensureApprove(address(lpToken), address(stakingVault), lpAmount);
        shares = stakingVault.deposit(lpAmount, address(this));
    }

    function _unstakeLp(uint256 shares) internal returns (uint256 lpReceived) {
        lpReceived = stakingVault.redeem(shares, address(this), address(this));
    }

    function _unstakeAllLp() internal returns (uint256 lpReceived) {
        uint256 shares = stakingVault.balanceOf(address(this));
        if (shares < 1) return 0;
        lpReceived = stakingVault.redeem(shares, address(this), address(this));
    }

    function _stakedLpBalance() internal view returns (uint256) {
        uint256 shares = stakingVault.balanceOf(address(this));
        if (shares < 1) return 0;
        return stakingVault.convertToAssets(shares);
    }

    // ============ Liquidity Helpers ============

    /// @notice Add all lpAsset balance to the pool single-sided and stake the resulting LP.
    function _addLiquidityAndStake() internal returns (uint256 lpReceived) {
        uint256 lpAssetBal = lpAsset.balanceOf(address(this));
        if (lpAssetBal == 0) return 0;
        lpReceived = _addLiquidity(lpAssetBal);
        if (lpReceived > 0) {
            _stakeLp(lpReceived);
            emit LiquidityAdded(lpAssetBal, lpReceived);
        }
    }

    // ============ Abstract Hooks (subclass MUST implement) ============

    /// @notice Add `lpAssetAmount` of lpAsset to the pool single-sided and return LP minted.
    /// @dev Subclasses may also drain other token residuals (e.g. the other pool asset) here.
    function _addLiquidity(uint256 lpAssetAmount) internal virtual returns (uint256 lpReceived);

    /// @notice Remove `lpAmount` of LP tokens single-sided to lpAsset, enforcing `slippage`.
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        virtual
        returns (uint256 lpAssetReceived);

    /// @notice Current lpAsset value of 1e18 LP tokens (e.g. Curve `get_virtual_price`).
    function _lpUnitValue() internal view virtual returns (uint256);

    /// @notice Claim rewards from the staking vault and swap them to lpAsset.
    /// @return lpAssetReceived Amount of lpAsset produced by the reward swap (0 if none).
    function _claimAndSwapRewards() internal virtual returns (uint256 lpAssetReceived);

    // ============ Optional Swap / Conversion Hooks (default 1:1 pass-through) ============

    /// @notice Convert an lpAsset-denominated amount to debt-asset terms (oracle, no swap).
    function _convertYieldAssetValueToDebt(uint256 lpAssetAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        return lpAssetAmount;
    }

    /// @notice Actual debt → lpAsset swap before LP operations.
    function _swapDebtToYieldAsset(
        uint256 debtAmount,
        uint256 /*slippage*/
    )
        internal
        virtual
        returns (uint256)
    {
        return debtAmount;
    }

    /// @notice Actual lpAsset → debt swap after LP exit.
    function _swapYieldAssetToDebt(
        uint256 lpAssetAmount,
        uint256 /*slippage*/
    )
        internal
        virtual
        returns (uint256)
    {
        return lpAssetAmount;
    }

    // ============ Protected Tokens ============

    /// @dev Protect lpToken, lpAsset, and stakingVault shares on top of the debt asset.
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(lpToken)
            || token == address(lpAsset) || token == address(stakingVault);
    }
}
