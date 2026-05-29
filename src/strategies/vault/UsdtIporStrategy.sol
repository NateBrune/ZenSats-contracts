// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseVaultStrategy } from "./BaseVaultStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ICurveStableSwap } from "../../interfaces/ICurveStableSwap.sol";
import { IERC20 } from "../../interfaces/IERC20.sol";
import { CurveUsdtSwapLib } from "../../libraries/CurveUsdtSwapLib.sol";

/// @title UsdtIporStrategy
/// @notice Swaps USDT to crvUSD on Curve, then deposits crvUSD into an IPOR PlasmaVault.
/// @dev Adds the USDT↔crvUSD swap layer on top of BaseVaultStrategy via three hook overrides.
contract UsdtIporStrategy is BaseVaultStrategy {
    // ============ Constants ============

    /// Chainlink heartbeat is 24h; 25h gives one heartbeat of safety margin.
    uint256 public constant MAX_CRVUSD_ORACLE_STALENESS = 90000;
    uint256 public constant MAX_USDT_ORACLE_STALENESS = 90000;

    // ============ Immutables ============

    IERC20 public immutable crvUSD;
    ICurveStableSwap public immutable curvePool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable usdtOracle;
    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;

    // ============ Events ============

    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);

    // ============ Constructor ============

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
    ) BaseVaultStrategy(_usdt, _vault, address(0), _iporVault) {
        if (_crvUSD == address(0) || _curvePool == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _usdtOracle == address(0)) revert InvalidAddress();
        crvUSD = IERC20(_crvUSD);
        curvePool = ICurveStableSwap(_curvePool);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> crvUSD IPOR Strategy";
    }

    // ============ Hook Overrides ============

    /// @dev Oracle-based crvUSD→USDT conversion (no token transfer). Used by balanceOf().
    function _convertVaultAssetValueToDebt(uint256 crvUsdAmount)
        internal
        view
        override
        returns (uint256)
    {
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdAmount, crvUsdOracle, usdtOracle, MAX_CRVUSD_ORACLE_STALENESS
        );
    }

    /// @dev Curve swap: USDT → crvUSD before depositing into the IPOR vault.
    function _swapDebtToVaultAsset(uint256 usdtAmount, uint256 slippage)
        internal
        override
        returns (uint256 crvUsdReceived)
    {
        if (usdtAmount == 0) return 0;
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

    /// @dev Curve swap: crvUSD → USDT after redeeming from the IPOR vault.
    function _swapVaultAssetToDebt(uint256 crvUsdAmount, uint256 slippage)
        internal
        override
        returns (uint256 usdtReceived)
    {
        if (crvUsdAmount == 0) return 0;
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

    /// @dev Protect crvUSD from rescue (debtAsset/vault checks cover USDT and shares only).
    function _isProtectedToken(address token) internal view override returns (bool) {
        return super._isProtectedToken(token) || token == address(crvUSD);
    }
}
