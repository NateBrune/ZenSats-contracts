// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseYieldStrategy } from "./BaseYieldStrategy.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { ITokemakAutopool } from "../interfaces/ITokemakAutopool.sol";
import { IAutopilotRouter } from "../interfaces/IAutopilotRouter.sol";
import { IMainRewarder } from "../interfaces/IMainRewarder.sol";
import { IUniswapV2Router } from "../interfaces/IUniswapV2Router.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

/// @title TokemakYieldStrategy
/// @notice Yield strategy that swaps crvUSD to USDC, deposits into Tokemak autoUSD,
///         and stakes autopool shares via the AutopilotRouter to earn TOKE rewards.
///         The real MainRewarder.stake() is restricted to onlyStakingToken, so
///         staking must go through Tokemak's router contract.
contract TokemakYieldStrategy is BaseYieldStrategy {
    // ============ Constants ============

    /// @notice Default slippage tolerance (1%)
    uint256 public constant DEFAULT_SLIPPAGE = 1e16;

    /// @notice Maximum slippage tolerance (5%)
    uint256 public constant MAX_SLIPPAGE = 5e16;

    /// @notice Emergency slippage tolerance (10%)
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17;

    /// @notice Curve pool coin indices (USDC/crvUSD pool - index 0 = USDC, index 1 = crvUSD)
    int128 public constant USDC_INDEX = 0;
    int128 public constant CRVUSD_INDEX = 1;

    /// @notice WETH address (mainnet)
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============ Immutables ============

    /// @notice USDC token
    IERC20 public immutable usdc;

    /// @notice Curve crvUSD/USDC StableSwap pool
    ICurveStableSwap public immutable curvePool;

    /// @notice Tokemak autoUSD vault
    ITokemakAutopool public immutable tokemakVault;

    /// @notice Tokemak AutopilotRouter for staking/unstaking
    IAutopilotRouter public immutable router;

    /// @notice Tokemak MainRewarder for staked share accounting
    IMainRewarder public immutable rewarder;

    /// @notice TOKE reward token
    IERC20 public immutable toke;

    /// @notice SushiSwap V2 Router for TOKE swaps
    IUniswapV2Router public immutable sushiRouter;

    // ============ State ============

    /// @notice Current slippage tolerance
    uint256 public slippageTolerance;

    // ============ Events ============

    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedCrvUsdToUsdc(uint256 crvUsdAmount, uint256 usdcReceived);
    event SwappedUsdcToCrvUsd(uint256 usdcAmount, uint256 crvUsdReceived);
    event RewardsCompounded(uint256 tokeAmount, uint256 usdcAmount);

    // ============ Constructor ============

    /// @param _crvUSD crvUSD token address
    /// @param _vault Zenji address
    /// @param _usdc USDC token address
    /// @param _curvePool Curve crvUSD/USDC pool address
    /// @param _tokemakVault Tokemak autoUSD vault address
    /// @param _router Tokemak AutopilotRouter address
    /// @param _rewarder Tokemak MainRewarder address
    /// @param _sushiRouter SushiSwap V2 Router address
    constructor(
        address _crvUSD,
        address _vault,
        address _usdc,
        address _curvePool,
        address _tokemakVault,
        address _router,
        address _rewarder,
        address _sushiRouter
    ) BaseYieldStrategy(_crvUSD, _vault) {
        if (
            _usdc == address(0) || _curvePool == address(0) || _tokemakVault == address(0)
                || _router == address(0) || _rewarder == address(0) || _sushiRouter == address(0)
        ) {
            revert InvalidAddress();
        }
        usdc = IERC20(_usdc);
        curvePool = ICurveStableSwap(_curvePool);
        tokemakVault = ITokemakAutopool(_tokemakVault);
        router = IAutopilotRouter(_router);
        rewarder = IMainRewarder(_rewarder);
        sushiRouter = IUniswapV2Router(_sushiRouter);
        toke = IERC20(IMainRewarder(_rewarder).rewardToken());
        slippageTolerance = DEFAULT_SLIPPAGE;
    }

    // ============ Admin Functions ============

    /// @notice Update slippage tolerance (only vault can call)
    /// @param newSlippage New slippage tolerance (max 5%)
    function setSlippage(uint256 newSlippage) external onlyVault {
        if (newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(usdc);
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        // Shares are staked in the rewarder via the router
        uint256 stakedShares = rewarder.balanceOf(address(this));
        // Also count any unstaked shares held directly (e.g. mid-transaction)
        uint256 heldShares = IERC20(address(tokemakVault)).balanceOf(address(this));
        uint256 totalShares = stakedShares + heldShares;
        if (totalShares == 0) return 0;

        uint256 usdcValue = tokemakVault.convertToAssets(totalShares);
        if (usdcValue == 0) return 0;

        // Convert USDC value to crvUSD terms using Curve pool quote
        return curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcValue);
    }

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external view override returns (uint256) {
        return rewarder.earned(address(this));
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "Tokemak autoUSD Strategy";
    }

    // ============ Internal Functions ============

    /// @inheritdoc BaseYieldStrategy
    function _deposit(uint256 crvUsdAmount)
        internal
        override
        returns (uint256 underlyingDeposited)
    {
        // Step 1: Swap crvUSD to USDC
        uint256 usdcReceived = _swapCrvUsdToUsdc(crvUsdAmount);

        // Step 2: Deposit USDC into autoUSD vault
        _ensureApprove(address(usdc), address(tokemakVault), usdcReceived);
        uint256 shares = tokemakVault.deposit(usdcReceived, address(this));

        // Step 3: Stake autopool shares via router
        // Transfer shares to router, approve rewarder to pull from router, then stake
        if (!IERC20(address(tokemakVault)).transfer(address(router), shares)) {
            revert TransferFailed();
        }
        router.approve(IERC20(address(tokemakVault)), address(rewarder), shares);
        router.stakeVaultToken(IERC20(address(tokemakVault)), shares);

        underlyingDeposited = usdcReceived;
    }

    /// @inheritdoc BaseYieldStrategy
    function _withdraw(uint256 crvUsdAmount) internal override returns (uint256 crvUsdReceived) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares == 0) return 0;

        // Calculate how much USDC we need to withdraw to get crvUsdAmount of crvUSD
        uint256 usdcNeeded = curvePool.get_dy(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount);

        // Calculate shares to redeem
        uint256 sharesToRedeem = tokemakVault.convertToShares(usdcNeeded);
        if (sharesToRedeem > stakedShares) {
            sharesToRedeem = stakedShares;
        }

        if (sharesToRedeem == 0) return 0;

        // Step 1: Unstake from rewarder via router (don't claim rewards)
        router.withdrawVaultToken(tokemakVault, rewarder, sharesToRedeem, false);

        // Step 2: Redeem from autoUSD vault
        uint256 usdcReceived = tokemakVault.redeem(sharesToRedeem, address(this), address(this));

        // Step 3: Swap USDC back to crvUSD
        if (usdcReceived > 0) {
            crvUsdReceived = _swapUsdcToCrvUsd(usdcReceived);
        }
    }

    /// @inheritdoc BaseYieldStrategy
    function _withdrawAll() internal override returns (uint256 crvUsdReceived) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares == 0) return 0;

        // Step 1: Unstake all from rewarder via router (don't claim rewards)
        router.withdrawVaultToken(tokemakVault, rewarder, stakedShares, false);

        // Step 2: Redeem all from autoUSD vault
        uint256 shares = IERC20(address(tokemakVault)).balanceOf(address(this));
        uint256 usdcReceived = tokemakVault.redeem(shares, address(this), address(this));

        // Step 3: Swap all USDC to crvUSD
        if (usdcReceived > 0) {
            crvUsdReceived = _swapUsdcToCrvUsd(usdcReceived);
        }
    }

    /// @inheritdoc BaseYieldStrategy
    function _harvest() internal override returns (uint256 rewardsValue) {
        // Step 1: Claim TOKE rewards
        rewarder.getReward();
        uint256 tokeBalance = toke.balanceOf(address(this));
        if (tokeBalance == 0) return 0;

        // Step 2: Swap TOKE → WETH → USDC via SushiSwap V2 Router
        address[] memory path = new address[](3);
        path[0] = address(toke);
        path[1] = WETH;
        path[2] = address(usdc);

        uint256[] memory expectedAmounts = sushiRouter.getAmountsOut(tokeBalance, path);
        uint256 minUsdcOut = (expectedAmounts[2] * (PRECISION - slippageTolerance)) / PRECISION;

        _ensureApprove(address(toke), address(sushiRouter), tokeBalance);
        uint256[] memory amounts = sushiRouter.swapExactTokensForTokens(
            tokeBalance, minUsdcOut, path, address(this), block.timestamp
        );
        uint256 usdcReceived = amounts[amounts.length - 1];

        // Step 3: Deposit USDC into Tokemak autoUSD and stake
        _ensureApprove(address(usdc), address(tokemakVault), usdcReceived);
        uint256 shares = tokemakVault.deposit(usdcReceived, address(this));

        if (!IERC20(address(tokemakVault)).transfer(address(router), shares)) {
            revert TransferFailed();
        }
        router.approve(IERC20(address(tokemakVault)), address(rewarder), shares);
        router.stakeVaultToken(IERC20(address(tokemakVault)), shares);

        emit RewardsCompounded(tokeBalance, usdcReceived);

        // Return crvUSD-equivalent value of compounded USDC
        rewardsValue = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcReceived);
    }

    /// @inheritdoc BaseYieldStrategy
    function _emergencyWithdraw() internal override returns (uint256 crvUsdReceived) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares == 0) return 0;

        // Step 1: Unstake all from rewarder via router (don't claim rewards)
        router.withdrawVaultToken(tokemakVault, rewarder, stakedShares, false);

        // Step 2: Redeem all from autoUSD vault (bypassing slippage checks)
        uint256 shares = IERC20(address(tokemakVault)).balanceOf(address(this));
        uint256 usdcReceived = tokemakVault.redeem(shares, address(this), address(this));

        // Step 3: Swap USDC to crvUSD with 10% emergency slippage protection
        if (usdcReceived > 0) {
            _ensureApprove(address(usdc), address(curvePool), usdcReceived);
            uint256 expectedOut = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcReceived);
            uint256 minOut = (expectedOut * (PRECISION - EMERGENCY_SLIPPAGE)) / PRECISION;
            crvUsdReceived = curvePool.exchange(USDC_INDEX, CRVUSD_INDEX, usdcReceived, minOut);
            emit SwappedUsdcToCrvUsd(usdcReceived, crvUsdReceived);
        }
    }

    // ============ Internal Swap Functions ============

    /// @notice Swap crvUSD to USDC via Curve
    function _swapCrvUsdToUsdc(uint256 crvUsdAmount) internal returns (uint256 usdcReceived) {
        uint256 expectedOut = curvePool.get_dy(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippageTolerance)) / PRECISION;

        _ensureApprove(address(crvUSD), address(curvePool), crvUsdAmount);
        usdcReceived = curvePool.exchange(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount, minOut);

        emit SwappedCrvUsdToUsdc(crvUsdAmount, usdcReceived);
    }

    /// @notice Swap USDC to crvUSD via Curve
    function _swapUsdcToCrvUsd(uint256 usdcAmount) internal returns (uint256 crvUsdReceived) {
        uint256 expectedOut = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippageTolerance)) / PRECISION;

        _ensureApprove(address(usdc), address(curvePool), usdcAmount);
        crvUsdReceived = curvePool.exchange(USDC_INDEX, CRVUSD_INDEX, usdcAmount, minOut);

        emit SwappedUsdcToCrvUsd(usdcAmount, crvUsdReceived);
    }
}
