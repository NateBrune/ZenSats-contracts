// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseCurveRewardVaultStrategy} from "./BaseCurveRewardVaultStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";
import {IChainlinkOracle} from "../interfaces/IChainlinkOracle.sol";
import {IAccountant} from "../interfaces/IAccountant.sol";
import {ICrvSwapper} from "../interfaces/ICrvSwapper.sol";
import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStakeDaoRewardVault} from "../interfaces/IStakeDaoRewardVault.sol";
import {CurveUsdtSwapLib} from "../libraries/CurveUsdtSwapLib.sol";

/// @title PmUsdCrvUsdStrategy
/// @notice USDT -> crvUSD -> pmUSD/crvUSD LP -> Stake DAO RewardVault
/// @dev Accepts USDT debt, swaps to crvUSD, provides single-sided liquidity to pmUSD/crvUSD pool,
///      stakes LP in Stake DAO reward vault, and harvests CRV rewards back into the strategy
contract PmUsdCrvUsdStrategy is BaseCurveRewardVaultStrategy {
    error SwapFailed();
    // ============ Constants ============

    uint256 public constant DEFAULT_SLIPPAGE = 1e16; // 1% for stablecoin swaps
    uint256 public constant MAX_SLIPPAGE = 5e16; // 5% governance max
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17; // 10% emergency
    uint256 public constant LP_SLIPPAGE = 5e15; // 0.5% for LP ops (stable pairs)
    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV minimum
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours

    // ============ Immutables ============

    IERC20 public immutable crvUSD;
    IERC20 public immutable crv;
    ICurveStableSwap public immutable usdtCrvUsdPool;
    ICurveStableSwapNG public immutable lpPool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable usdtOracle;
    IChainlinkOracle public immutable crvOracle;
    ICrvSwapper public immutable crvSwapper;
    address public immutable gauge;

    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;
    int128 public immutable lpCrvUsdIndex;

    // ============ State ============

    uint256 public slippageTolerance = DEFAULT_SLIPPAGE;

    // ============ Events ============

    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);
    event LiquidityAdded(uint256 crvUsdAmount, uint256 lpReceived);
    event LiquidityRemoved(uint256 lpBurned, uint256 crvUsdReceived);
    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdCompounded);

    // ============ Constructor ============

    /// @param _usdt USDT token address (debt asset)
    /// @param _crvUsd crvUSD token address
    /// @param _crv CRV token address
    /// @param _vault Zenji vault address
    /// @param _usdtCrvUsdPool Curve USDT/crvUSD StableSwap pool
    /// @param _lpPool Curve pmUSD/crvUSD StableSwapNG pool
    /// @param _rewardVault Stake DAO ERC4626 reward vault
    /// @param _crvSwapper CRV -> crvUSD swapper address
    /// @param _gauge Curve gauge for pmUSD/crvUSD LP (for accountant claims)
    /// @param _usdtIndex USDT coin index in USDT/crvUSD pool
    /// @param _crvUsdIndex crvUSD coin index in USDT/crvUSD pool
    /// @param _lpCrvUsdIndex crvUSD coin index in pmUSD/crvUSD pool
    /// @param _crvUsdOracle Chainlink crvUSD/USD oracle
    /// @param _usdtOracle Chainlink USDT/USD oracle
    /// @param _crvOracle Chainlink CRV/USD oracle
    constructor(
        address _usdt,
        address _crvUsd,
        address _crv,
        address _vault,
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
    ) BaseCurveRewardVaultStrategy(_usdt, _vault, _rewardVault) {
        if (_crvUsd == address(0) || _crv == address(0)) revert InvalidAddress();
        if (_usdtCrvUsdPool == address(0) || _lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _usdtOracle == address(0) || _crvOracle == address(0)) revert InvalidAddress();

        crvUSD = IERC20(_crvUsd);
        crv = IERC20(_crv);
        usdtCrvUsdPool = ICurveStableSwap(_usdtCrvUsdPool);
        lpPool = ICurveStableSwapNG(_lpPool);
        crvSwapper = ICrvSwapper(_crvSwapper);
        gauge = _gauge;
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
        lpCrvUsdIndex = _lpCrvUsdIndex;
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        crvOracle = IChainlinkOracle(_crvOracle);
    }

    // ============ Admin ============

    function setSlippage(uint256 newSlippage) external onlyVault {
        if (newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(lpToken);
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> pmUSD/crvUSD LP Strategy";
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _rewardVaultBalance();
        if (lpTokens < 1) return 0;

        // LP -> crvUSD value via virtual_price (manipulation-resistant)
        uint256 virtualPrice = lpPool.get_virtual_price();
        uint256 crvUsdValue = (lpTokens * virtualPrice) / 1e18;

        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdValue, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
    }

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external view override returns (uint256) {
        address accountant = rewardVault.ACCOUNTANT();
        try IAccountant(accountant).getPendingRewards(address(rewardVault), address(this)) returns (uint256 pendingCrv)
        {
            if (pendingCrv < 1) return 0;

            // CRV (18 dec) -> USDT (6 dec) using CRV/USD and USDT/USD Chainlink oracles
            (uint80 crvRoundId, int256 crvPrice,, uint256 crvUpdatedAt, uint80 crvAnswered) =
                crvOracle.latestRoundData();
            if (crvPrice <= 0 || crvAnswered < crvRoundId || block.timestamp - crvUpdatedAt > MAX_ORACLE_STALENESS) {
                return pendingCrv / 2e12; // fallback: ~$0.50/CRV rough estimate
            }

            (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
                usdtOracle.latestRoundData();
            if (usdtPrice <= 0 || usdtAnswered < usdtRoundId || block.timestamp - usdtUpdatedAt > MAX_ORACLE_STALENESS) {
                return pendingCrv / 2e12; // fallback: ~$0.50/CRV rough estimate
            }

            return (pendingCrv * uint256(crvPrice)) / (uint256(usdtPrice) * 1e12);
        } catch {
            return 0;
        }
    }

    // ============ Internal: Core Strategy ============

    function _deposit(uint256 usdtAmount) internal override returns (uint256 underlyingDeposited) {
        // Auto-compound any pending CRV rewards
        _claimAndCompound();

        // 1. Swap USDT -> crvUSD
        uint256 crvUsdReceived = _swapUsdtToCrvUsd(usdtAmount, slippageTolerance);

        // 2. Add single-sided liquidity to pmUSD/crvUSD pool
        uint256 lpReceived = _addLiquidity(crvUsdReceived);

        // 3. Stake LP tokens in reward vault
        _depositToRewardVault(lpReceived);

        // Return value in USDT terms
        underlyingDeposited = lpReceived;
    }

    function _withdraw(uint256 usdtAmount) internal override returns (uint256 usdtReceived) {
        // Auto-compound any pending CRV rewards
        _claimAndCompound();

        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;

        uint256 shares = rewardVault.balanceOf(address(this));
        if (shares < 1) return 0;

        // Calculate proportional shares to redeem
        uint256 sharesToRedeem = (shares * usdtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem < 1) return 0;

        // 1. Unstake from reward vault
        uint256 lpReceived = _redeemFromRewardVault(sharesToRedeem);

        // 2. Remove liquidity (single-sided crvUSD)
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);

        // 3. Swap crvUSD -> USDT
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }
    }

    function _withdrawAll() internal override returns (uint256 usdtReceived) {
        // 1. Unstake all LP tokens
        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        // 2. Remove all liquidity for crvUSD
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);

        // 3. Swap all crvUSD -> USDT
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }
    }

    function _harvest() internal override returns (uint256 rewardsValue) {
        uint256 crvUsdCompounded = _claimAndCompound();
        rewardsValue = CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdCompounded, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
    }

    /// @notice Claim CRV from accountant, swap to crvUSD, and compound back into LP
    /// @return crvUsdCompounded Amount of crvUSD compounded (0 if nothing to harvest)
    function _claimAndCompound() internal returns (uint256 crvUsdCompounded) {
        _accountantClaim();

        uint256 crvBalance = crv.balanceOf(address(this));
        if (crvBalance < MIN_HARVEST_THRESHOLD) return 0;

        crv.transfer(address(crvSwapper), crvBalance);
        uint256 crvUsdReceived = _swapCrv(crvBalance);
        if (crvUsdReceived < 1) return 0;

        emit RewardsHarvested(crvBalance, crvUsdReceived);

        uint256 lpReceived = _addLiquidity(crvUsdReceived);
        _depositToRewardVault(lpReceived);

        crvUsdCompounded = crvUsdReceived;
    }

    function _swapCrv(uint256 amount) internal returns (uint256 crvUsdReceived) {
        try crvSwapper.swap(amount) returns (uint256 received) {
            crvUsdReceived = received;
        } catch {
            revert SwapFailed();
        }
    }

    function _accountantClaim() internal {
        address accountant = rewardVault.ACCOUNTANT();
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        bytes[] memory harvestData = new bytes[](1);
        harvestData[0] = bytes("");
        // NoPendingRewards is expected when nothing has accrued yet
        try IAccountant(accountant).claim(gauges, harvestData, address(this)) {} catch {}
    }

    function _emergencyWithdraw() internal override returns (uint256 usdtReceived) {
        // 1. Unstake all LP tokens
        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        // 2. Remove all liquidity with emergency slippage
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, EMERGENCY_SLIPPAGE);

        // 3. Swap all crvUSD -> USDT with emergency slippage
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, EMERGENCY_SLIPPAGE);
        }
    }

    // ============ Internal: LP Operations ============

    /// @notice Add single-sided crvUSD liquidity to pmUSD/crvUSD pool
    function _addLiquidity(uint256 crvUsdAmount) internal returns (uint256 lpReceived) {
        _ensureApprove(address(crvUSD), address(lpPool), crvUsdAmount);

        // Build amounts array: only crvUSD side
        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;

        uint256 expectedLp = lpPool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        lpReceived = lpPool.add_liquidity(amounts, minLp);
        emit LiquidityAdded(crvUsdAmount, lpReceived);
    }

    /// @notice Remove single-sided crvUSD liquidity from pmUSD/crvUSD pool
    function _removeLiquidity(uint256 lpAmount, uint256 slippage) internal returns (uint256 crvUsdReceived) {
        uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        crvUsdReceived = lpPool.remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut);
        emit LiquidityRemoved(lpAmount, crvUsdReceived);
    }

    // ============ Internal: USDT/crvUSD Swaps ============

    function _swapUsdtToCrvUsd(uint256 usdtAmount, uint256 slippage) internal returns (uint256 crvUsdReceived) {
        _ensureApprove(address(debtAsset), address(usdtCrvUsdPool), usdtAmount);
        crvUsdReceived =
            CurveUsdtSwapLib.swapUsdtToCrvUsd(usdtCrvUsdPool, usdtIndex, crvUsdIndex, usdtAmount, slippage);
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    function _swapCrvUsdToUsdt(uint256 crvUsdAmount, uint256 slippage) internal returns (uint256 usdtReceived) {
        _ensureApprove(address(crvUSD), address(usdtCrvUsdPool), crvUsdAmount);
        usdtReceived =
            CurveUsdtSwapLib.swapCrvUsdToUsdt(usdtCrvUsdPool, crvUsdIndex, usdtIndex, crvUsdAmount, slippage);
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }
}
