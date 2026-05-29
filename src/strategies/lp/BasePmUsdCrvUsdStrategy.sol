// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseLPStrategy } from "./BaseLPStrategy.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { IAccountant } from "../../interfaces/IAccountant.sol";
import { ICrvSwapper } from "../../interfaces/ICrvSwapper.sol";
import { ICurveStableSwapNG } from "../../interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";
import { IStakeDaoRewardVault } from "../../interfaces/IStakeDaoRewardVault.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";

/// @dev Minimal interface for propagating slippage to the CRV reward swapper.
interface ICrvSwapperWithSlippage {
    function setSlippage(uint256 newSlippage) external;
}

/// @title BasePmUsdCrvUsdStrategy
/// @notice Pool-specific layer for the pmUSD/crvUSD Curve LP + Stake DAO accountant pipeline.
///         All generic LP / staking / cache / flow logic lives in BaseLPStrategy. This contract
///         only implements the four LP/reward hooks against the actual Curve pool, the Stake DAO
///         accountant, and the CRV reward swapper.
/// @dev Subclasses (PmUsdCrvUsdStakeDaoStrategy, UsdtPmUsdCrvUsdStakeDaoStrategy) supply the debt-asset
///      conversion layer via three optional hooks inherited from BaseLPStrategy:
///        - _convertLpAssetValueToDebt — oracle conversion crvUSD → debt (default 1:1)
///        - _swapDebtToLpAsset         — entry swap debt → crvUSD (default 1:1 no-op)
///        - _swapLpAssetToDebt         — exit swap crvUSD → debt (default 1:1 no-op)
///      and supply the pendingRewards denominator via _crvToPendingRewards / _pendingRewardsFallback.
abstract contract BasePmUsdCrvUsdStrategy is BaseLPStrategy {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    /// crv, pmUSD, and CRVUSD are mainnet singletons shared identically across every deployment;
    /// baking them in saves storage slots and makes misconfiguration impossible. Unit tests
    /// without a fork must vm.etch ERC20 mock bytecode at these addresses.
    IERC20 public constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public constant crv = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant pmUSD = IERC20(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF);

    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV minimum to harvest
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours

    // ============ Immutables ============

    ICurveStableSwapNG public immutable lpPool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable crvOracle;
    ICrvSwapper public immutable crvSwapper;
    address public immutable gauge;

    int128 public immutable lpCrvUsdIndex;
    uint256 public immutable lpPmUsdIndex;

    // ============ Events ============

    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdReceived);
    event CrvSwapDeferred(uint256 crvAmount);

    // ============ Constructor ============

    /// @param _debtAsset       Debt token accepted by the vault (crvUSD or USDT depending on variant).
    /// @param _vault           Zenji vault address.
    /// @param _owner           Initial owner.
    /// @param _lpPool          Curve pmUSD/crvUSD StableSwapNG pool.
    /// @param _rewardVault     Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper      CRV → crvUSD swapper.
    /// @param _gauge           Curve gauge for accountant claims.
    /// @param _lpCrvUsdIndex   crvUSD coin index in the pmUSD/crvUSD pool.
    /// @param _crvUsdOracle    Chainlink crvUSD/USD oracle.
    /// @param _crvOracle       Chainlink CRV/USD oracle.
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
    ) BaseLPStrategy(_debtAsset, _vault, _owner, address(CRVUSD), _rewardVault) {
        if (_lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _crvOracle == address(0)) revert InvalidAddress();

        lpPool = ICurveStableSwapNG(_lpPool);
        crvSwapper = ICrvSwapper(_crvSwapper);
        gauge = _gauge;
        lpCrvUsdIndex = _lpCrvUsdIndex;
        lpPmUsdIndex = _lpCrvUsdIndex == int128(0) ? 1 : 0;
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        crvOracle = IChainlinkOracle(_crvOracle);

        _initializeUnitValueCache();
    }

    // ============ Pending Rewards ============

    /// @notice Pending CRV reward value in debt-asset terms.
    /// @dev Subclass-specific denominator (crvUSD or USDT) via _crvToPendingRewards /
    ///      _pendingRewardsFallback hooks.
    function pendingRewards() external view override returns (uint256) {
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

    // ============ Subclass Hooks for Pending Rewards Denominator ============

    /// @notice Fallback when CRV oracle is stale. Default: crvSwapper.quote() in crvUSD (18 dec).
    ///         USDT subclass overrides to divide by 1e12.
    function _pendingRewardsFallback(uint256 pendingCrv) internal view virtual returns (uint256) {
        return crvSwapper.quote(pendingCrv);
    }

    /// @notice Convert CRV amount to debt asset value using a valid CRV/USD price.
    /// @dev Abstract — each variant reads its own denominator oracle.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        virtual
        returns (uint256);

    // ============ BaseLPStrategy Hook Implementations ============

    /// @notice Add crvUSD to the pool, defensively also draining any pmUSD residuals.
    /// @dev pmUSD residuals are not produced by normal operation but the 2-sided add absorbs
    ///      them if a future mechanism (or donation) leaves pmUSD in the contract.
    function _addLiquidity(uint256 lpAssetAmount)
        internal
        override
        returns (uint256 lpReceived)
    {
        uint256 crvUsdAmount = lpAssetAmount;
        uint256 pmUsdAmount = pmUSD.balanceOf(address(this));
        if (crvUsdAmount == 0 && pmUsdAmount == 0) return 0;

        if (crvUsdAmount > 0) _ensureApprove(address(CRVUSD), address(lpPool), crvUsdAmount);
        if (pmUsdAmount > 0) _ensureApprove(address(pmUSD), address(lpPool), pmUsdAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;
        amounts[lpPmUsdIndex] = pmUsdAmount;

        uint256 expectedLp = lpPool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        // Oracle floor via cached unit value — immune to same-block manipulation.
        uint256 safeVP = _getSafeUnitValue();
        uint256 totalValue = crvUsdAmount + pmUsdAmount;
        uint256 oracleMinLp =
            (totalValue * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = lpPool.add_liquidity(amounts, minLp);
    }

    /// @notice Remove single-sided crvUSD liquidity from the pmUSD/crvUSD pool.
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

    function _lpUnitValue() internal view override returns (uint256) {
        return lpPool.get_virtual_price();
    }

    /// @inheritdoc BaseLPStrategy
    /// @dev Uses min(VP-based, calc_withdraw_one_coin) so pool imbalance (e.g. pmUSD depeg)
    ///      is reflected without breaking the VP-based deposit floor in _addLiquidity.
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _stakedLpBalance();
        if (lpTokens < 1) return 0;
        uint256 vpBased = (lpTokens * _getSafeUnitValue()) / PRECISION;
        uint256 exitBased = lpPool.calc_withdraw_one_coin(lpTokens, lpCrvUsdIndex);
        uint256 lpAssetValue = exitBased < vpBased ? exitBased : vpBased;
        return _convertLpAssetValueToDebt(lpAssetValue);
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

    // ============ Slippage Propagation ============

    /// @notice Propagate the new slippage to the CRV reward swapper so its oracle floor stays
    ///         in sync with the strategy's tolerance.
    function _onSlippageUpdate(uint256, /*oldSlippage*/ uint256 newSlippage) internal override {
        try ICrvSwapperWithSlippage(address(crvSwapper)).setSlippage(newSlippage) { } catch { }
    }

    // ============ Protected Tokens ============

    /// @dev Add pmUSD and CRV to the protected set on top of the base's lpToken / lpAsset /
    ///      stakingVault / debtAsset.
    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return super._isProtectedToken(token) || token == address(pmUSD) || token == address(crv);
    }
}
