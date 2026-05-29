// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseLPStrategy } from "./BaseLPStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { IAccountant } from "../../interfaces/IAccountant.sol";
import { ICrvSwapper } from "../../interfaces/ICrvSwapper.sol";
import { ICurveStableSwapTwoLP } from "../../interfaces/ICurveStableSwapTwoLP.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";
import { IStakeDaoRewardVault } from "../../interfaces/IStakeDaoRewardVault.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";

/// @dev Minimal interface for propagating slippage to the CRV reward swapper.
interface ICrvSwapperWithSlippage {
    function setSlippage(uint256 newSlippage) external;
}

/// @title CrvUsdLpStakeDaoStrategy
/// @notice crvUSD → (any legacy 2-coin Curve StableSwap pool with crvUSD on one side) →
///         Stake DAO RewardVault.
/// @dev Pairs with LlamaLoanManager (Llama lends crvUSD natively, so debt == lpAsset == crvUSD;
///      no entry/exit swap layer needed). The strategy adds crvUSD single-sided into the pool,
///      stakes the LP token in Stake DAO, and compounds CRV rewards back into crvUSD via a
///      pair-specific CRV reward swapper.
///
///      Pool-agnostic: the strategy never references the "other" pool coin, so the same contract
///      works for USDT/crvUSD, USDC/crvUSD, or any other legacy 2-coin StableSwap with crvUSD as
///      one side. Each deployment supplies the pool, gauge, staking vault, crvUSD index, and a
///      human-readable display name via constructor args.
contract CrvUsdLpStakeDaoStrategy is BaseLPStrategy {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    IERC20 public constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public constant crv = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours

    // ============ Immutables ============

    /// @notice Curve pool. Legacy 2-coin StableSwap; pool == LP token.
    ICurveStableSwapTwoLP public immutable lpPool;

    /// @notice crvUSD coin index in the pool. The strategy never holds the other coin in
    ///         normal flow, so its identity is irrelevant to the strategy logic.
    int128 public immutable crvUsdIndex;

    address public immutable gauge;
    ICrvSwapper public immutable crvSwapper;

    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable crvOracle;

    /// @notice Human-readable strategy name (set at deploy, e.g. "crvUSD -> USDT/crvUSD").
    string public override name;

    // ============ Events ============

    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdReceived);
    event CrvSwapDeferred(uint256 crvAmount);

    // ============ Constructor ============

    /// @param _crvUsd       crvUSD token address (debt asset == lpAsset).
    /// @param _vault        Zenji vault address.
    /// @param _owner        Initial owner.
    /// @param _lpPool       Curve crvUSD-anchored 2-coin pool (e.g. USDT/crvUSD, USDC/crvUSD).
    /// @param _rewardVault  Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper   CRV → crvUSD swapper.
    /// @param _gauge        Curve gauge for accountant claims.
    /// @param _crvUsdIndex  crvUSD coin index in the pool (0 or 1).
    /// @param _crvUsdOracle Chainlink crvUSD/USD oracle (for the pendingRewards denominator).
    /// @param _crvOracle    Chainlink CRV/USD oracle.
    /// @param _name         Human-readable name, e.g. "crvUSD -> USDT/crvUSD LP Strategy".
    constructor(
        address _crvUsd,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _crvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle,
        string memory _name
    ) BaseLPStrategy(_crvUsd, _vault, _owner, _crvUsd, _rewardVault) {
        if (_lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _crvOracle == address(0)) revert InvalidAddress();

        lpPool = ICurveStableSwapTwoLP(_lpPool);
        crvUsdIndex = _crvUsdIndex;
        gauge = _gauge;
        crvSwapper = ICrvSwapper(_crvSwapper);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        crvOracle = IChainlinkOracle(_crvOracle);
        name = _name;

        _initializeUnitValueCache();
    }

    // ============ Pending Rewards ============

    /// @notice Pending CRV reward value in crvUSD terms.
    /// @dev CRV/USD ÷ crvUSD/USD. Both 18-decimal — no scaling. Falls back to swap-quote when
    ///      either oracle is stale.
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
                return crvSwapper.quote(pendingCrv);
            }

            (uint80 cuRoundId, int256 cuPrice,, uint256 cuUpdatedAt, uint80 cuAnswered) =
                crvUsdOracle.latestRoundData();
            if (
                cuPrice <= 0 || cuAnswered < cuRoundId
                    || block.timestamp - cuUpdatedAt > MAX_ORACLE_STALENESS
            ) {
                return crvSwapper.quote(pendingCrv);
            }
            return (pendingCrv * uint256(crvPrice)) / uint256(cuPrice);
        } catch {
            return 0;
        }
    }

    // ============ BaseLPStrategy Hook Implementations ============

    /// @notice Single-sided crvUSD add. Curve handles the internal rebalance toward the pool's
    ///         curve; LP_SLIPPAGE caps the implicit "swap" portion, and the cached-VP oracle
    ///         floor caps it independently to defend against same-block price manipulation.
    function _addLiquidity(uint256 crvUsdAmount)
        internal
        override
        returns (uint256 lpReceived)
    {
        if (crvUsdAmount == 0) return 0;
        _ensureApprove(address(CRVUSD), address(lpPool), crvUsdAmount);

        uint256[2] memory amounts;
        amounts[uint256(uint128(crvUsdIndex))] = crvUsdAmount;

        uint256 expectedLp = lpPool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        uint256 safeVP = _getSafeUnitValue();
        uint256 oracleMinLp =
            (crvUsdAmount * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = lpPool.add_liquidity(amounts, minLp);
    }

    /// @notice Single-sided crvUSD exit.
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        override
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, crvUsdIndex);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;
        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        crvUsdReceived = lpPool.remove_liquidity_one_coin(lpAmount, crvUsdIndex, minOut);
    }

    function _lpUnitValue() internal view override returns (uint256) {
        return lpPool.get_virtual_price();
    }

    /// @inheritdoc BaseLPStrategy
    /// @dev Uses min(VP-based, calc_withdraw_one_coin) so that pool imbalance (e.g. paired-asset
    ///      depeg) is reflected in reported balance. VP alone overstates when the pool is skewed
    ///      because it measures fee accumulation, not single-sided crvUSD exit value.
    ///      The min() is always conservative — it can only understate, never inflate.
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _stakedLpBalance();
        if (lpTokens < 1) return 0;
        uint256 vpBased = (lpTokens * _getSafeUnitValue()) / PRECISION;
        uint256 exitBased = lpPool.calc_withdraw_one_coin(lpTokens, crvUsdIndex);
        uint256 lpAssetValue = exitBased < vpBased ? exitBased : vpBased;
        return _convertLpAssetValueToDebt(lpAssetValue);
    }

    /// @notice Claim CRV via Stake DAO accountant and swap to crvUSD. Swap failure leaves CRV
    ///         at the swapper for the next compound cycle.
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

    function _onSlippageUpdate(uint256, /*old*/ uint256 newSlippage) internal override {
        try ICrvSwapperWithSlippage(address(crvSwapper)).setSlippage(newSlippage) { } catch { }
    }

    // ============ Protected Tokens ============

    /// @dev Add CRV on top of the base's lpToken / lpAsset / stakingVault / debtAsset set.
    function _isProtectedToken(address token) internal view override returns (bool) {
        return super._isProtectedToken(token) || token == address(crv);
    }
}
