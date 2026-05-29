// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseLPStrategy } from "./BaseLPStrategy.sol";
import { ICurveLpShared } from "../../interfaces/ICurveLpShared.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { IAccountant } from "../../interfaces/IAccountant.sol";
import { ICrvSwapper } from "../../interfaces/ICrvSwapper.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";
import { IStakeDaoRewardVault } from "../../interfaces/IStakeDaoRewardVault.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";

/// @dev Minimal interface for propagating slippage to the CRV reward swapper.
interface ICrvSwapperWithSlippage {
    function setSlippage(uint256 newSlippage) external;
}

/// @title BaseCurveStakeDaoStrategy
/// @notice Shared base for every "crvUSD-anchored Curve LP staked in Stake DAO" strategy. Owns the
///         pool-type-agnostic machinery that is identical across pools: single-sided crvUSD exit,
///         virtual-price unit value, manipulation-aware balance reporting, Stake DAO accountant
///         claims + CRV→crvUSD compounding, slippage propagation, and the CRV pendingRewards
///         pipeline (with a debt-denominator hook for USDT/USDC variants).
/// @dev Two concerns are left to subclasses because they genuinely differ:
///        1. `_addLiquidity` — fixed `uint256[2]` (legacy 2-coin) vs dynamic `uint256[]`
///           (StableSwapNG), and single- vs two-coin adds. Subclasses cast `address(lpPool)` to
///           their full-typed pool interface.
///        2. `_crvToPendingRewards` / `_pendingRewardsFallback` — the denominator. Default is
///           crvUSD (18-dec); USDT/USDC variants override to scale to 6-dec.
abstract contract BaseCurveStakeDaoStrategy is BaseLPStrategy {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    IERC20 public constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public constant crv = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours

    // ============ Immutables ============

    /// @notice Curve pool, typed to the shared (pool-agnostic) method set. Subclasses cast
    ///         `address(lpPool)` to their full interface for `_addLiquidity`.
    ICurveLpShared public immutable lpPool;

    /// @notice crvUSD coin index in the pool — the single coin the strategy adds/exits.
    int128 public immutable lpCrvUsdIndex;

    address public immutable gauge;
    ICrvSwapper public immutable crvSwapper;

    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable crvOracle;

    // ============ Events ============

    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdReceived);
    event CrvSwapDeferred(uint256 crvAmount);

    // ============ Constructor ============

    /// @param _debtAsset    Debt token accepted by the vault (crvUSD or USDT, by variant).
    /// @param _vault        Zenji vault address.
    /// @param _owner        Initial owner.
    /// @param _lpAsset      Single asset added to the pool (always crvUSD here).
    /// @param _lpPool       Curve crvUSD-anchored pool.
    /// @param _rewardVault  Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper   CRV → crvUSD swapper.
    /// @param _gauge        Curve gauge for accountant claims.
    /// @param _lpCrvUsdIndex crvUSD coin index in the pool (0 or 1).
    /// @param _crvUsdOracle Chainlink crvUSD/USD oracle.
    /// @param _crvOracle    Chainlink CRV/USD oracle.
    constructor(
        address _debtAsset,
        address _vault,
        address _owner,
        address _lpAsset,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    ) BaseLPStrategy(_debtAsset, _vault, _owner, _lpAsset, _rewardVault) {
        if (_lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _crvOracle == address(0)) revert InvalidAddress();

        lpPool = ICurveLpShared(_lpPool);
        lpCrvUsdIndex = _lpCrvUsdIndex;
        gauge = _gauge;
        crvSwapper = ICrvSwapper(_crvSwapper);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        crvOracle = IChainlinkOracle(_crvOracle);

        _initializeUnitValueCache();
    }

    // ============ Shared Hooks (pool-type-agnostic) ============

    function _lpUnitValue() internal view override returns (uint256) {
        return lpPool.get_virtual_price();
    }

    /// @inheritdoc BaseLPStrategy
    /// @dev Uses min(VP-based, calc_withdraw_one_coin) so pool imbalance (e.g. paired-asset depeg)
    ///      is reflected in the reported balance. VP alone overstates when the pool is skewed
    ///      because it measures fee accumulation, not single-sided crvUSD exit value. The min() is
    ///      always conservative — it can only understate, never inflate.
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _stakedLpBalance();
        if (lpTokens < 1) return 0;
        uint256 vpBased = (lpTokens * _getSafeUnitValue()) / PRECISION;
        uint256 exitBased = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex);
        uint256 lpAssetValue = exitBased < vpBased ? exitBased : vpBased;
        return _convertYieldAssetValueToDebt(lpAssetValue);
    }

    /// @notice Single-sided crvUSD exit.
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        override
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;
        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        crvUsdReceived = lpPool.remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut);
    }

    /// @notice Claim CRV via Stake DAO accountant and swap it to crvUSD via the CRV swapper.
    /// @dev Swap failure (oracle floor, slippage) leaves CRV at the swapper for the next cycle.
    function _claimAndSwapRewards() internal override returns (uint256 lpAssetReceived) {
        _accountantClaim();
        uint256 crvBalance = crv.balanceOf(address(this));
        if (crvBalance < MIN_HARVEST_THRESHOLD) return 0;

        crv.safeTransfer(address(crvSwapper), crvBalance);
        try crvSwapper.swap(crvBalance) returns (uint256 received) {
            lpAssetReceived = received;
        } catch {
            // CRV stays at swapper; retried next compound cycle.
        }
        if (lpAssetReceived > 0) emit RewardsHarvested(crvBalance, lpAssetReceived);
        else emit CrvSwapDeferred(crvBalance);
    }

    function _accountantClaim() internal {
        address accountant = IStakeDaoRewardVault(address(stakingVault)).ACCOUNTANT();
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        bytes[] memory harvestData = new bytes[](1);
        harvestData[0] = bytes("");
        // NoPendingRewards is expected when nothing has accrued.
        try IAccountant(accountant).claim(gauges, harvestData, address(this)) { } catch { }
    }

    // ============ Pending Rewards ============

    /// @notice Pending CRV reward value in debt-asset terms.
    /// @dev Reads the CRV oracle, then defers the denominator to subclass hooks so USDT/USDC
    ///      variants can scale to 6 decimals. Falls back to the swap quote when the CRV oracle
    ///      is stale or invalid.
    function pendingRewards() external view virtual override returns (uint256) {
        address accountant = IStakeDaoRewardVault(address(stakingVault)).ACCOUNTANT();
        try IAccountant(accountant).getPendingRewards(address(stakingVault), address(this))
        returns (uint256 pendingCrv) {
            if (pendingCrv < 1) return 0;

            (uint80 crvRoundId, int256 crvPrice,, uint256 crvUpdatedAt, uint80 crvAnswered) =
                crvOracle.latestRoundData();
            if (
                crvPrice <= 0 || crvAnswered < crvRoundId
                    || block.timestamp - crvUpdatedAt > MAX_ORACLE_STALENESS
            ) {
                return _pendingRewardsFallback(pendingCrv);
            }
            return _crvToPendingRewards(pendingCrv, uint256(crvPrice));
        } catch {
            return 0;
        }
    }

    /// @notice Convert a CRV amount to debt-asset value using a valid CRV/USD price.
    /// @dev Default: crvUSD denominator (CRV/USD ÷ crvUSD/USD, both 18-dec, no scaling). USDT/USDC
    ///      variants override to divide by 1e12 for 6-decimal debt assets.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        virtual
        returns (uint256)
    {
        (uint80 cuRoundId, int256 cuPrice,, uint256 cuUpdatedAt, uint80 cuAnswered) =
            crvUsdOracle.latestRoundData();
        if (
            cuPrice <= 0 || cuAnswered < cuRoundId
                || block.timestamp - cuUpdatedAt > MAX_ORACLE_STALENESS
        ) {
            return crvSwapper.quote(pendingCrv);
        }
        return (pendingCrv * crvPrice) / uint256(cuPrice);
    }

    /// @notice Fallback when the CRV oracle is stale. Default: swap quote in crvUSD (18-dec).
    ///         USDT/USDC variants override to scale to 6-dec.
    function _pendingRewardsFallback(uint256 pendingCrv) internal view virtual returns (uint256) {
        return crvSwapper.quote(pendingCrv);
    }

    // ============ Slippage Propagation ============

    /// @notice Keep the CRV reward swapper's oracle floor in sync with the strategy tolerance.
    function _onSlippageUpdate(uint256, /*old*/ uint256 newSlippage) internal override {
        try ICrvSwapperWithSlippage(address(crvSwapper)).setSlippage(newSlippage) { } catch { }
    }

    // ============ Protected Tokens ============

    /// @dev Protect CRV on top of the base's lpToken / lpAsset / stakingVault / debtAsset set.
    ///      (crvUSD is the lpAsset, already protected by BaseLPStrategy.)
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(crv);
    }
}
