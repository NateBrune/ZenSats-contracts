// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IYieldStrategy
/// @notice Interface for yield strategies used by Zenji
/// @dev All strategies accept crvUSD from the vault and deploy to yield-generating protocols
interface IYieldStrategy {
    // ============ Events ============

    event Deposited(uint256 crvUsdAmount, uint256 underlyingDeposited);
    event Withdrawn(uint256 crvUsdAmount, uint256 crvUsdReceived);
    event Harvested(uint256 rewardsValue);
    event EmergencyWithdrawn(uint256 crvUsdReceived);
    event StrategyPauseToggled(bool paused, uint256 crvUsdReceived);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAmount();
    error StrategyPaused();
    error SlippageExceeded();
    error TransferFailed();
    error InvalidAddress();

    // ============ Core Functions ============

    /// @notice Deposit crvUSD into the yield strategy
    /// @param crvUsdAmount Amount of crvUSD to deposit
    /// @return underlyingDeposited Amount deposited into the underlying protocol
    function deposit(uint256 crvUsdAmount) external returns (uint256 underlyingDeposited);

    /// @notice Withdraw crvUSD from the yield strategy
    /// @param crvUsdAmount Amount of crvUSD to withdraw
    /// @return crvUsdReceived Actual crvUSD received (may differ due to slippage)
    function withdraw(uint256 crvUsdAmount) external returns (uint256 crvUsdReceived);

    /// @notice Withdraw all assets from the yield strategy
    /// @return crvUsdReceived Total crvUSD received
    function withdrawAll() external returns (uint256 crvUsdReceived);

    /// @notice Harvest rewards and compound them back into the strategy
    /// @return rewardsValue Value of rewards harvested (in crvUSD terms)
    function harvest() external returns (uint256 rewardsValue);

    /// @notice Emergency withdraw all assets, bypassing slippage checks
    /// @return crvUsdReceived Total crvUSD received
    function emergencyWithdraw() external returns (uint256 crvUsdReceived);

    /// @notice Toggle pause state for the strategy
    /// @dev When pausing, should unwind all deployed assets back to the vault
    /// @return crvUsdReceived Total crvUSD received if unwound (0 when unpausing)
    function pauseStrategy() external returns (uint256 crvUsdReceived);

    // ============ View Functions ============

    /// @notice Returns the asset accepted by the strategy (always crvUSD)
    function asset() external view returns (address);

    /// @notice Returns the underlying asset of the yield protocol (crvUSD or USDC)
    function underlyingAsset() external view returns (address);

    /// @notice Returns the current value of the strategy holdings in crvUSD terms
    function balanceOf() external view returns (uint256);

    /// @notice Returns the total crvUSD deposited (cost basis)
    function costBasis() external view returns (uint256);

    /// @notice Returns unrealized profit (current value - cost basis)
    function unrealizedProfit() external view returns (uint256);

    /// @notice Returns pending rewards value in crvUSD terms
    function pendingRewards() external view returns (uint256);

    /// @notice Returns whether the strategy is paused
    function paused() external view returns (bool);

    /// @notice Returns the strategy name
    function name() external view returns (string memory);

    /// @notice Returns the vault address
    function vault() external view returns (address);
}
