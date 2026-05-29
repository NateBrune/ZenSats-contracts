// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseVaultStrategy } from "./BaseVaultStrategy.sol";
import { UsdtCrvUsdSwapMixin } from "../UsdtCrvUsdSwapMixin.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title UsdtIporStrategy
/// @notice Swaps USDT to crvUSD on Curve, then deposits crvUSD into an IPOR PlasmaVault.
/// @dev The USDT↔crvUSD swap layer is provided by UsdtCrvUsdSwapMixin; this contract only wires
///      the three unified yield-asset hooks to the mixin helpers.
contract UsdtIporStrategy is BaseVaultStrategy, UsdtCrvUsdSwapMixin {
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
    )
        BaseVaultStrategy(_usdt, _vault, address(0), _iporVault)
        UsdtCrvUsdSwapMixin(
            _usdt, _crvUSD, _curvePool, _usdtOracle, _crvUsdOracle, _usdtIndex, _crvUsdIndex
        )
    { }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> crvUSD IPOR Strategy";
    }

    // ============ Yield-Asset Hooks (delegate to mixin) ============

    function _convertYieldAssetValueToDebt(uint256 crvUsdAmount)
        internal
        view
        override
        returns (uint256)
    {
        return _crvUsdValueToUsdt(crvUsdAmount);
    }

    function _swapDebtToYieldAsset(uint256 usdtAmount, uint256 slippage)
        internal
        override
        returns (uint256)
    {
        return _usdtToCrvUsd(usdtAmount, slippage);
    }

    function _swapYieldAssetToDebt(uint256 crvUsdAmount, uint256 slippage)
        internal
        override
        returns (uint256)
    {
        return _crvUsdToUsdt(crvUsdAmount, slippage);
    }

    /// @dev Protect crvUSD from rescue (debtAsset/vault checks cover USDT and shares only).
    function _isProtectedToken(address token) internal view override returns (bool) {
        return super._isProtectedToken(token) || token == address(_crvUsd);
    }
}
