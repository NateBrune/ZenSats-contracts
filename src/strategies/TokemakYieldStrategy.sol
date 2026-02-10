// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTokemakStrategy} from "./BaseTokemakStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";
import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title TokemakYieldStrategy
/// @notice Yield strategy that swaps crvUSD to USDC, deposits into Tokemak autoUSD,
///         and stakes autopool shares via the AutopilotRouter to earn TOKE rewards.
contract TokemakYieldStrategy is BaseTokemakStrategy {
    // ============ Constants ============

    uint256 public constant DEFAULT_SLIPPAGE = 1e16;
    uint256 public constant MAX_SLIPPAGE = 5e16;
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17;

    int128 public constant USDC_INDEX = 0;
    int128 public constant CRVUSD_INDEX = 1;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============ Immutables ============

    IERC20 public immutable usdc;
    ICurveStableSwap public immutable curvePool;
    IERC20 public immutable toke;
    IUniswapV2Router public immutable sushiRouter;

    // ============ State ============

    uint256 public slippageTolerance;

    // ============ Events ============

    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedCrvUsdToUsdc(uint256 crvUsdAmount, uint256 usdcReceived);
    event SwappedUsdcToCrvUsd(uint256 usdcAmount, uint256 crvUsdReceived);
    event RewardsCompounded(uint256 tokeAmount, uint256 usdcAmount);

    // ============ Constructor ============

    constructor(
        address _crvUSD,
        address _vault,
        address _usdc,
        address _curvePool,
        address _tokemakVault,
        address _router,
        address _rewarder,
        address _sushiRouter
    ) BaseTokemakStrategy(_crvUSD, _vault, _tokemakVault, _router, _rewarder) {
        if (_usdc == address(0) || _curvePool == address(0) || _sushiRouter == address(0)) {
            revert InvalidAddress();
        }
        usdc = IERC20(_usdc);
        curvePool = ICurveStableSwap(_curvePool);
        sushiRouter = IUniswapV2Router(_sushiRouter);
        toke = IERC20(rewarder.rewardToken());
        slippageTolerance = DEFAULT_SLIPPAGE;
    }

    // ============ Admin Functions ============

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
        uint256 usdcValue = _tokemakBalance();
        if (usdcValue == 0) return 0;
        // Convert USDC value to crvUSD terms using Curve pool quote
        return curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcValue);
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "Tokemak autoUSD Strategy";
    }

    // ============ Internal Functions ============

    function _deposit(uint256 crvUsdAmount) internal override returns (uint256 underlyingDeposited) {
        // Swap crvUSD to USDC
        uint256 usdcReceived = _swapCrvUsdToUsdc(crvUsdAmount);
        // Deposit USDC into Tokemak and stake
        _depositAndStake(usdcReceived);
        underlyingDeposited = usdcReceived;
    }

    function _withdraw(uint256 crvUsdAmount) internal override returns (uint256 crvUsdReceived) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares == 0) return 0;

        uint256 usdcNeeded = curvePool.get_dy(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount);
        uint256 sharesToRedeem = tokemakVault.convertToShares(usdcNeeded);
        if (sharesToRedeem > stakedShares) sharesToRedeem = stakedShares;
        if (sharesToRedeem == 0) return 0;

        uint256 usdcReceived = _unstakeAndRedeem(sharesToRedeem);
        if (usdcReceived > 0) {
            crvUsdReceived = _swapUsdcToCrvUsd(usdcReceived);
        }
    }

    function _withdrawAll() internal override returns (uint256 crvUsdReceived) {
        uint256 usdcReceived = _unstakeAndRedeemAll();
        if (usdcReceived > 0) {
            crvUsdReceived = _swapUsdcToCrvUsd(usdcReceived);
        }
    }

    function _harvest() internal override returns (uint256 rewardsValue) {
        // Claim TOKE rewards
        rewarder.getReward();
        uint256 tokeBalance = toke.balanceOf(address(this));
        if (tokeBalance == 0) return 0;

        // Swap TOKE → WETH → USDC via SushiSwap V2 Router
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

        // Deposit USDC into Tokemak and stake
        _depositAndStake(usdcReceived);

        emit RewardsCompounded(tokeBalance, usdcReceived);

        // Return crvUSD-equivalent value
        rewardsValue = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcReceived);
    }

    function _emergencyWithdraw() internal override returns (uint256 crvUsdReceived) {
        uint256 usdcReceived = _unstakeAndRedeemAll();
        if (usdcReceived > 0) {
            _ensureApprove(address(usdc), address(curvePool), usdcReceived);
            uint256 expectedOut = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcReceived);
            uint256 minOut = (expectedOut * (PRECISION - EMERGENCY_SLIPPAGE)) / PRECISION;
            crvUsdReceived = curvePool.exchange(USDC_INDEX, CRVUSD_INDEX, usdcReceived, minOut);
            emit SwappedUsdcToCrvUsd(usdcReceived, crvUsdReceived);
        }
    }

    // ============ Internal Swap Functions ============

    function _swapCrvUsdToUsdc(uint256 crvUsdAmount) internal returns (uint256 usdcReceived) {
        uint256 expectedOut = curvePool.get_dy(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippageTolerance)) / PRECISION;

        _ensureApprove(address(debtAsset), address(curvePool), crvUsdAmount);
        usdcReceived = curvePool.exchange(CRVUSD_INDEX, USDC_INDEX, crvUsdAmount, minOut);

        emit SwappedCrvUsdToUsdc(crvUsdAmount, usdcReceived);
    }

    function _swapUsdcToCrvUsd(uint256 usdcAmount) internal returns (uint256 crvUsdReceived) {
        uint256 expectedOut = curvePool.get_dy(USDC_INDEX, CRVUSD_INDEX, usdcAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippageTolerance)) / PRECISION;

        _ensureApprove(address(usdc), address(curvePool), usdcAmount);
        crvUsdReceived = curvePool.exchange(USDC_INDEX, CRVUSD_INDEX, usdcAmount, minOut);

        emit SwappedUsdcToCrvUsd(usdcAmount, crvUsdReceived);
    }
}
