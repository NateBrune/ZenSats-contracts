// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IChainlinkOracle } from "./interfaces/IChainlinkOracle.sol";

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

/// @title WstEthOracle
/// @notice Chainlink-compatible oracle that reports wstETH/USD price
/// @dev Computes: wstETH/USD = stEthPerToken() * stETH/ETH * ETH/USD
contract WstEthOracle is IChainlinkOracle {
    IWstETH public immutable wstETH;
    IChainlinkOracle public immutable stEthEthFeed;
    IChainlinkOracle public immutable ethUsdFeed;

    constructor(address _wstETH, address _stEthEthFeed, address _ethUsdFeed) {
        wstETH = IWstETH(_wstETH);
        stEthEthFeed = IChainlinkOracle(_stEthEthFeed);
        ethUsdFeed = IChainlinkOracle(_ethUsdFeed);
    }

    /// @inheritdoc IChainlinkOracle
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Get stETH/ETH price (18 decimals)
        (uint80 stEthRoundId, int256 stEthEthPrice,, uint256 stEthEthUpdatedAt, uint80 stEthAnsweredInRound) =
            stEthEthFeed.latestRoundData();
        require(stEthEthPrice > 0, "stETH/ETH: invalid price");
        require(stEthAnsweredInRound >= stEthRoundId, "stETH/ETH: stale round");

        // Get ETH/USD price (8 decimals)
        (uint80 ethUsdRoundId, int256 ethUsdPrice, uint256 ethUsdStartedAt, uint256 ethUsdUpdatedAt, uint80 ethUsdAnsweredInRound) =
            ethUsdFeed.latestRoundData();

        // stEthPerToken is 18 decimals
        uint256 ratio = wstETH.stEthPerToken();

        // wstETH/USD = ratio * stETH/ETH * ETH/USD
        // ratio: 18 dec, stEthEthPrice: 18 dec, ethUsdPrice: 8 dec
        // result should be 8 dec
        // (ratio * stEthEthPrice * ethUsdPrice) / (1e18 * 1e18) = 8 dec
        answer = int256((ratio * uint256(stEthEthPrice) * uint256(ethUsdPrice)) / (1e18 * 1e18));

        // Use the most stale updatedAt (minimum) for conservative freshness
        updatedAt = stEthEthUpdatedAt < ethUsdUpdatedAt ? stEthEthUpdatedAt : ethUsdUpdatedAt;
        startedAt = ethUsdStartedAt;
        roundId = ethUsdRoundId;
        answeredInRound = ethUsdAnsweredInRound;
    }

    /// @inheritdoc IChainlinkOracle
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IChainlinkOracle
    function description() external pure override returns (string memory) {
        return "wstETH / USD";
    }

    /// @inheritdoc IChainlinkOracle
    function latestAnswer() external view override returns (int256) {
        (, int256 stEthEthPrice,,,) = stEthEthFeed.latestRoundData();
        (, int256 ethUsdPrice,,,) = ethUsdFeed.latestRoundData();
        uint256 ratio = wstETH.stEthPerToken();
        return int256((ratio * uint256(stEthEthPrice) * uint256(ethUsdPrice)) / (1e18 * 1e18));
    }
}
