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

    /// @notice stETH/ETH Chainlink heartbeat is 24 hours
    uint256 public constant STETH_ETH_MAX_STALENESS = 90000; // 25 hours
    /// @notice ETH/USD Chainlink heartbeat is 1 hour
    uint256 public constant ETH_USD_MAX_STALENESS = 7200; // 2 hours

    constructor(address _wstETH, address _stEthEthFeed, address _ethUsdFeed) {
        wstETH = IWstETH(_wstETH);
        stEthEthFeed = IChainlinkOracle(_stEthEthFeed);
        ethUsdFeed = IChainlinkOracle(_ethUsdFeed);
        // L-08: the price math hardcodes an 18-decimal stETH/ETH feed and an 8-decimal ETH/USD
        // feed. Assert the assumption at deploy time to catch a misconfigured or decimal-migrated
        // feed (cannot guard against a same-address decimal change after deployment).
        require(stEthEthFeed.decimals() == 18, "stETH/ETH: expected 18 decimals");
        require(ethUsdFeed.decimals() == 8, "ETH/USD: expected 8 decimals");
    }

    /// @inheritdoc IChainlinkOracle
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Get stETH/ETH price (18 decimals) — 24h heartbeat, validated here
        (
            uint80 stEthRoundId,
            int256 stEthEthPrice,,
            uint256 stEthEthUpdatedAt,
            uint80 stEthAnsweredInRound
        ) = stEthEthFeed.latestRoundData();
        require(stEthEthPrice > 0, "stETH/ETH: invalid price");
        require(stEthAnsweredInRound >= stEthRoundId, "stETH/ETH: stale round");
        require(block.timestamp - stEthEthUpdatedAt <= STETH_ETH_MAX_STALENESS, "stETH/ETH: stale");

        // Get ETH/USD price (8 decimals) — 1h heartbeat
        (
            uint80 ethUsdRoundId,
            int256 ethUsdPrice,
            uint256 ethUsdStartedAt,
            uint256 ethUsdUpdatedAt,
            uint80 ethUsdAnsweredInRound
        ) = ethUsdFeed.latestRoundData();
        require(ethUsdPrice > 0, "ETH/USD: invalid price");
        require(ethUsdAnsweredInRound >= ethUsdRoundId, "ETH/USD: stale round");
        require(block.timestamp - ethUsdUpdatedAt <= ETH_USD_MAX_STALENESS, "ETH/USD: stale");

        // stEthPerToken is 18 decimals
        uint256 ratio = wstETH.stEthPerToken();

        // wstETH/USD = ratio * stETH/ETH * ETH/USD
        // ratio: 18 dec, stEthEthPrice: 18 dec, ethUsdPrice: 8 dec
        // result should be 8 dec
        // (ratio * stEthEthPrice * ethUsdPrice) / (1e18 * 1e18) = 8 dec
        answer = int256((ratio * uint256(stEthEthPrice) * uint256(ethUsdPrice)) / (1e18 * 1e18));

        // Report the OLDEST of the two component timestamps so a consumer's staleness check
        // reflects the true age of the composite price. The stETH/ETH leg has a 24h Chainlink
        // heartbeat, so consumers must allow up to ~25h staleness for wstETH. Both legs remain
        // independently bounded above (stETH/ETH <= 25h, ETH/USD <= 2h, validated here).
        //
        // L-07: roundId/answeredInRound deliberately track the ETH/USD leg only (a composite has
        // no single comparable roundId, and switching feeds would break cross-call monotonicity).
        // This is safe to rely on because the stETH/ETH leg's round completeness AND staleness are
        // already enforced INTERNALLY above (require answeredInRound >= roundId + staleness bound),
        // so any data returned here has been fully validated across BOTH legs. A consumer doing the
        // standard `answeredInRound >= roundId` check is therefore backed by both legs.
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
        (
            uint80 stEthRoundId,
            int256 stEthEthPrice,,
            uint256 stEthEthUpdatedAt,
            uint80 stEthAnsweredInRound
        ) = stEthEthFeed.latestRoundData();
        require(stEthEthPrice > 0, "stETH/ETH: invalid price");
        require(stEthAnsweredInRound >= stEthRoundId, "stETH/ETH: stale round");
        require(block.timestamp - stEthEthUpdatedAt <= STETH_ETH_MAX_STALENESS, "stETH/ETH: stale");

        (
            uint80 ethUsdRoundId,
            int256 ethUsdPrice,,
            uint256 ethUsdUpdatedAt,
            uint80 ethUsdAnsweredInRound
        ) = ethUsdFeed.latestRoundData();
        require(ethUsdPrice > 0, "ETH/USD: invalid price");
        require(ethUsdAnsweredInRound >= ethUsdRoundId, "ETH/USD: stale round");
        require(block.timestamp - ethUsdUpdatedAt <= ETH_USD_MAX_STALENESS, "ETH/USD: stale");

        uint256 ratio = wstETH.stEthPerToken();
        return int256((ratio * uint256(stEthEthPrice) * uint256(ethUsdPrice)) / (1e18 * 1e18));
    }
}
