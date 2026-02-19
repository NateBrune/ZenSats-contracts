// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {ICurveStableSwapWithReceiver} from "../interfaces/ICurveStableSwapWithReceiver.sol";
import {IChainlinkOracle} from "../interfaces/IChainlinkOracle.sol";

/// @title CurveUsdtSwapLib
/// @notice Shared USDT/crvUSD swap + oracle conversion logic
library CurveUsdtSwapLib {
    uint256 internal constant PRECISION = 1e18;

    error ExchangeFailed();

    /// @notice Swap USDT to crvUSD via Curve StableSwap
    function swapUsdtToCrvUsd(
        ICurveStableSwap pool,
        int128 usdtIndex,
        int128 crvUsdIndex,
        uint256 usdtAmount,
        uint256 slippage
    ) internal returns (uint256 crvUsdReceived) {
        uint256 expectedOut = pool.get_dy(usdtIndex, crvUsdIndex, usdtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;
        crvUsdReceived = exchange(pool, usdtIndex, crvUsdIndex, usdtAmount, minOut);
    }

    /// @notice Swap crvUSD to USDT via Curve StableSwap
    function swapCrvUsdToUsdt(
        ICurveStableSwap pool,
        int128 crvUsdIndex,
        int128 usdtIndex,
        uint256 crvUsdAmount,
        uint256 slippage
    ) internal returns (uint256 usdtReceived) {
        uint256 expectedOut = pool.get_dy(crvUsdIndex, usdtIndex, crvUsdAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;
        usdtReceived = exchange(pool, crvUsdIndex, usdtIndex, crvUsdAmount, minOut);
    }

    /// @notice Exchange on Curve with receiver fallback
    function exchange(ICurveStableSwap pool, int128 i, int128 j, uint256 dx, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        try ICurveStableSwapWithReceiver(address(pool)).exchange(i, j, dx, minOut, address(this))
        returns (uint256 outWithReceiver) {
            amountOut = outWithReceiver;
        } catch {
            try pool.exchange(i, j, dx, minOut) returns (uint256 outStandard) {
                amountOut = outStandard;
            } catch {
                revert ExchangeFailed();
            }
        }
    }

    /// @notice Convert crvUSD value (18 dec) to USDT value (6 dec) using oracles
    function convertCrvUsdToUsdt(
        uint256 crvUsdValue,
        IChainlinkOracle crvUsdOracle,
        IChainlinkOracle usdtOracle,
        uint256 maxStaleness
    ) internal view returns (uint256) {
        if (crvUsdValue < 1) return 0;

        (uint80 crvRoundId, int256 crvUsdPrice,, uint256 crvUsdUpdatedAt, uint80 crvAnswered) =
            crvUsdOracle.latestRoundData();
        if (
            crvUsdPrice <= 0 || crvAnswered < crvRoundId
                || block.timestamp - crvUsdUpdatedAt > maxStaleness
        ) {
            return crvUsdValue / 1e12; // fallback to 1:1
        }

        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
            usdtOracle.latestRoundData();
        if (
            usdtPrice <= 0 || usdtAnswered < usdtRoundId
                || block.timestamp - usdtUpdatedAt > maxStaleness
        ) {
            return crvUsdValue / 1e12; // fallback to 1:1
        }

        return (crvUsdValue * uint256(crvUsdPrice)) / (uint256(usdtPrice) * 1e12);
    }
}
