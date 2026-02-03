// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IChainlinkOracle
/// @notice Interface for Chainlink price feeds
interface IChainlinkOracle {
    /// @notice Get the latest round data
    /// @return roundId The round ID
    /// @return answer The price answer
    /// @return startedAt Timestamp when the round started
    /// @return updatedAt Timestamp when the round was updated
    /// @return answeredInRound The round in which the answer was computed
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /// @notice Get decimals of the price feed
    /// @return Decimals
    function decimals() external view returns (uint8);

    /// @notice Get description of the price feed
    /// @return Description string
    function description() external view returns (string memory);

    /// @notice Get the latest answer
    /// @return Latest price
    function latestAnswer() external view returns (int256);
}
