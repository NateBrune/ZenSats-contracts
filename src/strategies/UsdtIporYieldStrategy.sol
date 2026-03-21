// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseIporStrategy } from "./BaseIporStrategy.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { CurveUsdtSwapLib } from "../libraries/CurveUsdtSwapLib.sol";

/// @title UsdtIporYieldStrategy
/// @notice Swaps USDT to crvUSD and deposits into IPOR PlasmaVault
contract UsdtIporYieldStrategy is BaseIporStrategy {
    uint256 public constant DEFAULT_SLIPPAGE = 1e16;
    uint256 public constant MAX_SLIPPAGE = 5e16;
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17;

    IERC20 public immutable crvUSD;
    ICurveStableSwap public immutable curvePool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable usdtOracle;
    uint256 public constant MAX_CRVUSD_ORACLE_STALENESS = 90000; // 25 hours (Chainlink heartbeat is 24h)
    uint256 public constant MAX_USDT_ORACLE_STALENESS = 90000; // 25 hours (Chainlink heartbeat is 24h)
    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;

    uint256 public slippageTolerance = DEFAULT_SLIPPAGE;

    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);

    constructor(
        address _usdt,
        address _crvUSD,
        address _vault,
        address _curvePool,
        address _iporVault,
        int128 _usdtIndex,
        int128 _crvUsdIndex,
        address _crvUsdOracle,
        address _usdtOracle
    ) BaseIporStrategy(_usdt, _vault, _iporVault) {
        if (_crvUSD == address(0) || _curvePool == address(0)) {
            revert InvalidAddress();
        }
        if (_crvUsdOracle == address(0) || _usdtOracle == address(0)) revert InvalidAddress();
        crvUSD = IERC20(_crvUSD);
        curvePool = ICurveStableSwap(_curvePool);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
    }

    /// @notice Updates strategy slippage tolerance (vault-controlled).
    /// @param newSlippage New slippage in 1e18 precision.
    function setSlippage(uint256 newSlippage) external onlyVault {
        if (newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(crvUSD);
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        uint256 crvUsdValue = _iporBalance();
        if (crvUsdValue < 1) return 0;
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdValue, crvUsdOracle, usdtOracle, MAX_CRVUSD_ORACLE_STALENESS
        );
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> crvUSD IPOR Strategy";
    }

    // ============ Internal Functions ============

    function _deposit(uint256 usdtAmount) internal override returns (uint256 underlyingDeposited) {
        uint256 crvUsdReceived = _swapUsdtToCrvUsd(usdtAmount, slippageTolerance);
        _ensureApprove(address(crvUSD), address(iporVault), crvUsdReceived);
        uint256 sharesMinted = iporVault.deposit(crvUsdReceived, address(this));
        underlyingDeposited = iporVault.convertToAssets(sharesMinted);
    }

    function _withdraw(uint256 usdtAmount) internal override returns (uint256 usdtReceived) {
        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;

        uint256 shares = iporVault.balanceOf(address(this));
        if (shares < 1) return 0;

        uint256 sharesToRedeem = (shares * usdtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem < 1) return 0;

        uint256 crvUsdReceived = _redeemFromIpor(sharesToRedeem);
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }
    }

    function _withdrawAll() internal override returns (uint256 usdtReceived) {
        uint256 crvUsdReceived = _redeemAllFromIpor();
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }
    }

    function _emergencyWithdraw() internal override returns (uint256 usdtReceived) {
        uint256 crvUsdReceived = _redeemAllFromIpor();
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, EMERGENCY_SLIPPAGE);
        }
    }

    // ============ Internal Swap Functions ============

    function _swapUsdtToCrvUsd(uint256 usdtAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        _ensureApprove(address(debtAsset), address(curvePool), usdtAmount);
        crvUsdReceived = CurveUsdtSwapLib.swapUsdtToCrvUsd(
            curvePool,
            usdtIndex,
            crvUsdIndex,
            usdtAmount,
            slippage,
            usdtOracle,
            crvUsdOracle,
            MAX_USDT_ORACLE_STALENESS
        );
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    function _swapCrvUsdToUsdt(uint256 crvUsdAmount, uint256 slippage)
        internal
        returns (uint256 usdtReceived)
    {
        _ensureApprove(address(crvUSD), address(curvePool), crvUsdAmount);
        usdtReceived = CurveUsdtSwapLib.swapCrvUsdToUsdt(
            curvePool,
            crvUsdIndex,
            usdtIndex,
            crvUsdAmount,
            slippage,
            crvUsdOracle,
            usdtOracle,
            MAX_CRVUSD_ORACLE_STALENESS
        );
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }
}
