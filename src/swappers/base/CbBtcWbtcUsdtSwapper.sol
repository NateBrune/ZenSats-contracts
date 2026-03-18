// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ICurveTwoCrypto } from "../../interfaces/ICurveTwoCrypto.sol";
import { ICurveTwoCryptoInt128 } from "../../interfaces/ICurveTwoCryptoInt128.sol";
import { ICurveThreeCrypto } from "../../interfaces/ICurveThreeCrypto.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title CbBtcWbtcUsdtSwapper
/// @notice Two-hop swapper: cbBTC <-> WBTC via TwoCrypto, then WBTC <-> USDT via TriCrypto
contract CbBtcWbtcUsdtSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    IERC20 public immutable wbtcToken;
    ICurveTwoCrypto public immutable cbBtcPool;
    ICurveThreeCrypto public immutable triCryptoPool;
    uint256 public immutable cbBtcIndex;
    uint256 public immutable wbtcIndex;
    uint256 public immutable triWbtcIndex;
    uint256 public immutable triUsdtIndex;
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    uint256 public constant MAX_COLLATERAL_ORACLE_STALENESS = 3600;
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000;

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _wbtcToken,
        address _cbBtcPool,
        uint256 _cbBtcIndex,
        uint256 _wbtcIndex,
        address _triCryptoPool,
        uint256 _triWbtcIndex,
        uint256 _triUsdtIndex,
        address _collateralOracle,
        address _debtOracle
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0) || _wbtcToken == address(0)
                || _cbBtcPool == address(0) || _triCryptoPool == address(0)
                || _collateralOracle == address(0) || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        wbtcToken = IERC20(_wbtcToken);
        cbBtcPool = ICurveTwoCrypto(_cbBtcPool);
        triCryptoPool = ICurveThreeCrypto(_triCryptoPool);
        cbBtcIndex = _cbBtcIndex;
        wbtcIndex = _wbtcIndex;
        triWbtcIndex = _triWbtcIndex;
        triUsdtIndex = _triUsdtIndex;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 wbtcOut = _safeGetDyThree(triUsdtIndex, triWbtcIndex, debtAmount);
        if (wbtcOut == 0) return 0;
        uint256 cbBtcOut = _safeGetDyTwo(wbtcIndex, cbBtcIndex, wbtcOut);
        if (cbBtcOut == 0) return 0;
        return _applySlippageUp(cbBtcOut, 2);
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;

        uint256 expectedWbtc = _safeGetDyTwo(cbBtcIndex, wbtcIndex, collateralAmount);
        uint256 minWbtc = expectedWbtc > 0 ? _applySlippageDown(expectedWbtc) : 0;
        collateralToken.ensureApproval(address(cbBtcPool), collateralAmount);
        uint256 wbtcBefore = wbtcToken.balanceOf(address(this));
        _exchangeTwo(cbBtcIndex, wbtcIndex, collateralAmount, minWbtc, address(this));
        uint256 wbtcAfter = wbtcToken.balanceOf(address(this));
        uint256 wbtcReceived = wbtcAfter > wbtcBefore ? wbtcAfter - wbtcBefore : 0;

        if (wbtcReceived == 0) return 0;

        uint256 expectedUsdt = _safeGetDyThree(triWbtcIndex, triUsdtIndex, wbtcReceived);
        uint256 minUsdt = expectedUsdt > 0 ? _applySlippageDown(expectedUsdt) : 0;

        // Oracle floor (end-to-end check across both hops)
        uint256 oracleExpected = OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minUsdt) minUsdt = oracleMinOut;

        wbtcToken.ensureApproval(address(triCryptoPool), wbtcReceived);
        uint256 debtBefore = debtToken.balanceOf(address(this));
        debtReceived = _exchangeThree(
            triWbtcIndex, triUsdtIndex, wbtcReceived, minUsdt, debtToken, debtBefore
        );
        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;

        uint256 expectedWbtc = _safeGetDyThree(triUsdtIndex, triWbtcIndex, debtAmount);
        uint256 minWbtc = expectedWbtc > 0 ? _applySlippageDown(expectedWbtc) : 0;
        debtToken.ensureApproval(address(triCryptoPool), debtAmount);
        uint256 wbtcBefore = wbtcToken.balanceOf(address(this));
        uint256 wbtcReceived = _exchangeThree(
            triUsdtIndex, triWbtcIndex, debtAmount, minWbtc, wbtcToken, wbtcBefore
        );
        if (wbtcReceived == 0) return 0;

        uint256 expectedCbBtc = _safeGetDyTwo(wbtcIndex, cbBtcIndex, wbtcReceived);
        uint256 minCbBtc = expectedCbBtc > 0 ? _applySlippageDown(expectedCbBtc) : 0;

        // Oracle floor (end-to-end check across both hops)
        uint256 oracleExpected = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minCbBtc) minCbBtc = oracleMinOut;

        wbtcToken.ensureApproval(address(cbBtcPool), wbtcReceived);
        uint256 cbBtcBefore = collateralToken.balanceOf(address(this));
        _exchangeTwo(wbtcIndex, cbBtcIndex, wbtcReceived, minCbBtc, address(this));
        uint256 cbBtcAfter = collateralToken.balanceOf(address(this));
        collateralReceived = cbBtcAfter > cbBtcBefore ? cbBtcAfter - cbBtcBefore : 0;
        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }

    // ============ Internal Helpers ============

    function _applySlippageDown(uint256 amount) private view returns (uint256) {
        if (amount == 0) return 0;
        return (amount * (PRECISION - slippage)) / PRECISION;
    }

    function _applySlippageUp(uint256 amount, uint256 hops) private view returns (uint256) {
        uint256 adjusted = amount;
        for (uint256 i = 0; i < hops; i++) {
            adjusted = (adjusted * PRECISION) / (PRECISION - slippage) + 1;
        }
        return adjusted;
    }

    function _safeGetDyTwo(uint256 i, uint256 j, uint256 dx)
        private
        view
        returns (uint256 amountOut)
    {
        try cbBtcPool.get_dy(i, j, dx) returns (uint256 dy) {
            amountOut = dy;
        } catch {
            try ICurveTwoCryptoInt128(address(cbBtcPool))
                .get_dy(int128(int256(i)), int128(int256(j)), dx) returns (
                uint256 legacyDy
            ) {
                amountOut = legacyDy;
            } catch {
                return 0;
            }
        }
    }

    function _safeGetDyThree(uint256 i, uint256 j, uint256 dx)
        private
        view
        returns (uint256 amountOut)
    {
        (bool ok, bytes memory data) = address(triCryptoPool)
            .staticcall(abi.encodeWithSelector(ICurveThreeCrypto.get_dy.selector, i, j, dx));
        if (!ok || data.length < 32) return 0;
        amountOut = abi.decode(data, (uint256));
    }

    function _exchangeTwo(uint256 i, uint256 j, uint256 dx, uint256 minOut, address receiver)
        private
    {
        try cbBtcPool.exchange(i, j, dx, minOut, receiver) {
            return;
        } catch {
            try ICurveTwoCryptoInt128(address(cbBtcPool))
                .exchange(int128(int256(i)), int128(int256(j)), dx, minOut, receiver) {
                return;
            } catch {
                revert TransferFailed();
            }
        }
    }

    function _exchangeThree(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minOut,
        IERC20 outToken,
        uint256 balanceBefore
    ) private returns (uint256 amountOut) {
        try triCryptoPool.exchange(i, j, dx, minOut, false) returns (uint256 outAmount) {
            amountOut = outAmount;
        } catch {
            revert TransferFailed();
        }

        // Handle older pools that might not return amountOut
        if (amountOut == 0) {
            uint256 balanceAfter = outToken.balanceOf(address(this));
            amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }
    }

    function _safeTransferDebt(address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(debtToken).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();
        if (data.length >= 32 && !abi.decode(data, (bool))) {
            revert TransferFailed();
        }
    }
}
