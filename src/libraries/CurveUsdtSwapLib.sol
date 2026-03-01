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
    error StaleOrInvalidOracle();

    /// @notice Swap USDT to crvUSD via Curve StableSwap with oracle floor
    /// @param pool Curve pool
    /// @param usdtIndex USDT coin index
    /// @param crvUsdIndex crvUSD coin index
    /// @param usdtAmount Amount of USDT to swap
    /// @param slippage Slippage tolerance (1e16 = 1%)
    /// @param usdtOracle Chainlink USDT/USD oracle
    /// @param crvUsdOracle Chainlink crvUSD/USD oracle
    /// @param maxOracleStaleness Max oracle staleness in seconds
    function swapUsdtToCrvUsd(
        ICurveStableSwap pool,
        int128 usdtIndex,
        int128 crvUsdIndex,
        uint256 usdtAmount,
        uint256 slippage,
        IChainlinkOracle usdtOracle,
        IChainlinkOracle crvUsdOracle,
        uint256 maxOracleStaleness
    ) internal returns (uint256 crvUsdReceived) {
        uint256 expectedOut = pool.get_dy(usdtIndex, crvUsdIndex, usdtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor: USDT (6 dec) -> crvUSD (18 dec)
        uint256 oracleMinOut = _oracleFloor6to18(usdtAmount, slippage, usdtOracle, crvUsdOracle, maxOracleStaleness);
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        crvUsdReceived = exchange(pool, usdtIndex, crvUsdIndex, usdtAmount, minOut);
    }

    /// @notice Swap crvUSD to USDT via Curve StableSwap with oracle floor
    function swapCrvUsdToUsdt(
        ICurveStableSwap pool,
        int128 crvUsdIndex,
        int128 usdtIndex,
        uint256 crvUsdAmount,
        uint256 slippage,
        IChainlinkOracle crvUsdOracle,
        IChainlinkOracle usdtOracle,
        uint256 maxOracleStaleness
    ) internal returns (uint256 usdtReceived) {
        uint256 expectedOut = pool.get_dy(crvUsdIndex, usdtIndex, crvUsdAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor: crvUSD (18 dec) -> USDT (6 dec)
        uint256 oracleMinOut = _oracleFloor18to6(crvUsdAmount, slippage, crvUsdOracle, usdtOracle, maxOracleStaleness);
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        usdtReceived = exchange(pool, crvUsdIndex, usdtIndex, crvUsdAmount, minOut);
    }

    /// @notice Legacy: Swap USDT to crvUSD without oracle floor (spot-quote only)
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

    /// @notice Legacy: Swap crvUSD to USDT without oracle floor (spot-quote only)
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
            revert StaleOrInvalidOracle();
        }

        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
            usdtOracle.latestRoundData();
        if (
            usdtPrice <= 0 || usdtAnswered < usdtRoundId
                || block.timestamp - usdtUpdatedAt > maxStaleness
        ) {
            revert StaleOrInvalidOracle();
        }

        return (crvUsdValue * uint256(crvUsdPrice)) / (uint256(usdtPrice) * 1e12);
    }

    // ============ Private Helpers ============

    /// @notice Oracle floor for 6-decimal -> 18-decimal stablecoin swap (e.g., USDT -> crvUSD)
    function _oracleFloor6to18(
        uint256 amountIn,
        uint256 slippage,
        IChainlinkOracle inOracle,
        IChainlinkOracle outOracle,
        uint256 maxStaleness
    ) private view returns (uint256) {
        (uint256 inPrice, uint256 outPrice) = _getOraclePrices(inOracle, outOracle, maxStaleness);
        // amountIn is 6-dec, output is 18-dec. Both oracles are 8-dec USD.
        // oracleExpected = amountIn * inPrice * 1e18 / (outPrice * 1e6)
        //                = amountIn * inPrice * 1e12 / outPrice
        uint256 oracleExpected = (amountIn * inPrice * 1e12) / outPrice;
        return (oracleExpected * (PRECISION - slippage)) / PRECISION;
    }

    /// @notice Oracle floor for 18-decimal -> 6-decimal stablecoin swap (e.g., crvUSD -> USDT)
    function _oracleFloor18to6(
        uint256 amountIn,
        uint256 slippage,
        IChainlinkOracle inOracle,
        IChainlinkOracle outOracle,
        uint256 maxStaleness
    ) private view returns (uint256) {
        (uint256 inPrice, uint256 outPrice) = _getOraclePrices(inOracle, outOracle, maxStaleness);
        // amountIn is 18-dec, output is 6-dec. Both oracles are 8-dec USD.
        // oracleExpected = amountIn * inPrice / (outPrice * 1e12)
        uint256 oracleExpected = (amountIn * inPrice) / (outPrice * 1e12);
        return (oracleExpected * (PRECISION - slippage)) / PRECISION;
    }

    function _getOraclePrices(IChainlinkOracle oracleA, IChainlinkOracle oracleB, uint256 maxStaleness)
        private
        view
        returns (uint256 priceA, uint256 priceB)
    {
        (uint80 rA, int256 pA,, uint256 uA, uint80 aA) = oracleA.latestRoundData();
        if (pA <= 0 || aA < rA || block.timestamp - uA > maxStaleness) revert StaleOrInvalidOracle();

        (uint80 rB, int256 pB,, uint256 uB, uint80 aB) = oracleB.latestRoundData();
        if (pB <= 0 || aB < rB || block.timestamp - uB > maxStaleness) revert StaleOrInvalidOracle();

        priceA = uint256(pA);
        priceB = uint256(pB);
    }
}
