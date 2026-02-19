// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";

/// @title OracleLib
/// @notice Unified Chainlink oracle helpers for both Aave and Llama loan managers
library OracleLib {
    error InvalidPrice();
    error StaleOracle();

    function _validatedPrice(IChainlinkOracle oracle, uint256 maxStaleness)
        private
        view
        returns (uint256)
    {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StaleOracle();
        if (block.timestamp - updatedAt > maxStaleness) revert StaleOracle();
        return uint256(price);
    }

    function checkOracleFreshness(
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness
    ) external view {
        _validatedPrice(collateralOracle, maxCollateralStaleness);
        _validatedPrice(debtOracle, maxDebtStaleness);
    }

    // ============ Aave overloads (both token decimals explicit) ============

    function getCollateralValue(
        uint256 collateralAmount,
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness,
        IERC20 collateralToken,
        IERC20 debtToken
    ) external view returns (uint256) {
        if (collateralAmount == 0) return 0;
        uint256 collateralPrice = _validatedPrice(collateralOracle, maxCollateralStaleness);
        uint256 debtPrice = _validatedPrice(debtOracle, maxDebtStaleness);
        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        uint8 debtDecimals = debtToken.decimals();
        return (
            collateralAmount * collateralPrice * (10 ** debtDecimals) * (10 ** debtOracleDecimals)
        ) / ((10 ** collateralOracleDecimals) * (10 ** collateralDecimals) * debtPrice);
    }

    function getDebtValue(
        uint256 debtAmount,
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness,
        IERC20 collateralToken,
        IERC20 debtToken
    ) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralPrice = _validatedPrice(collateralOracle, maxCollateralStaleness);
        uint256 debtPrice = _validatedPrice(debtOracle, maxDebtStaleness);
        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        uint8 debtDecimals = debtToken.decimals();
        return (
            debtAmount * debtPrice * (10 ** collateralOracleDecimals) * (10 ** collateralDecimals)
        ) / ((10 ** debtOracleDecimals) * collateralPrice * (10 ** debtDecimals));
    }

    // ============ Llama overloads (debt is 1e18 native) ============

    function getCollateralValue(
        uint256 collateralAmount,
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness,
        IERC20 collateralToken
    ) external view returns (uint256) {
        if (collateralAmount == 0) return 0;
        uint256 collateralPrice = _validatedPrice(collateralOracle, maxCollateralStaleness);
        uint256 debtPrice = _validatedPrice(debtOracle, maxDebtStaleness);
        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        return (collateralAmount * collateralPrice * 1e18 * (10 ** debtOracleDecimals))
            / ((10 ** collateralOracleDecimals) * (10 ** collateralDecimals) * debtPrice);
    }

    function getDebtValue(
        uint256 debtAmount,
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness,
        IERC20 collateralToken
    ) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralPrice = _validatedPrice(collateralOracle, maxCollateralStaleness);
        uint256 debtPrice = _validatedPrice(debtOracle, maxDebtStaleness);
        uint8 collateralOracleDecimals = collateralOracle.decimals();
        uint8 debtOracleDecimals = debtOracle.decimals();
        uint8 collateralDecimals = collateralToken.decimals();
        return (
            debtAmount * debtPrice * (10 ** collateralOracleDecimals) * (10 ** collateralDecimals)
        ) / ((10 ** debtOracleDecimals) * collateralPrice * 1e18);
    }

    // ============ USD value helpers (Aave only) ============

    function getCollateralUsdValue(
        uint256 collateralAmount,
        IChainlinkOracle collateralOracle,
        uint256 maxCollateralStaleness,
        IERC20 collateralToken
    ) external view returns (uint256) {
        if (collateralAmount == 0) return 0;
        uint256 price = _validatedPrice(collateralOracle, maxCollateralStaleness);
        uint8 oracleDecimals = collateralOracle.decimals();
        uint8 tokenDecimals = collateralToken.decimals();
        return (collateralAmount * price * 1e18) / ((10 ** oracleDecimals) * (10 ** tokenDecimals));
    }

    function getDebtUsdValue(
        uint256 debtAmount,
        IChainlinkOracle debtOracle,
        uint256 maxDebtStaleness,
        IERC20 debtToken
    ) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 price = _validatedPrice(debtOracle, maxDebtStaleness);
        uint8 oracleDecimals = debtOracle.decimals();
        uint8 tokenDecimals = debtToken.decimals();
        return (debtAmount * price * 1e18) / ((10 ** oracleDecimals) * (10 ** tokenDecimals));
    }
}
