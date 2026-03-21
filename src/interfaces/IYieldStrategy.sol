// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IYieldStrategy
/// @notice Interface for yield strategies used by Zenji
/// @dev All strategies accept the debt asset from the vault and deploy to yield-generating protocols
interface IYieldStrategy {
    // ============ Events ============

    event Deposited(uint256 debtAssetAmount, uint256 underlyingDeposited);
    event Withdrawn(uint256 debtAssetAmount, uint256 debtAssetReceived);
    event Harvested(uint256 rewardsValue);
    event EmergencyWithdrawn(uint256 debtAssetReceived);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAmount();
    error SlippageExceeded();
    error TransferFailed();
    error InvalidAddress();

    // ============ Core Functions ============

    /// @notice Deposit debt asset into the yield strategy
    /// @param debtAssetAmount Amount of debt asset to deposit
    /// @return underlyingDeposited Amount deposited into the underlying protocol
    function deposit(uint256 debtAssetAmount) external returns (uint256 underlyingDeposited);

    /// @notice Withdraw debt asset from the yield strategy
    /// @param debtAssetAmount Amount of debt asset to withdraw
    /// @return debtAssetReceived Actual debt asset received (may differ due to slippage)
    function withdraw(uint256 debtAssetAmount) external returns (uint256 debtAssetReceived);

    /// @notice Withdraw all assets from the yield strategy
    /// @return debtAssetReceived Total debt asset received
    function withdrawAll() external returns (uint256 debtAssetReceived);

    /// @notice Harvest rewards and compound them back into the strategy
    /// @return rewardsValue Value of rewards harvested (in debt asset terms)
    function harvest() external returns (uint256 rewardsValue);

    /// @notice Emergency withdraw all assets, bypassing slippage checks
    /// @return debtAssetReceived Total debt asset received
    function emergencyWithdraw() external returns (uint256 debtAssetReceived);

    // ============ View Functions ============

    /// @notice Returns the asset accepted by the strategy (debt asset)
    function asset() external view returns (address);

    /// @notice Returns the underlying asset of the yield protocol (debt asset or swapped asset)
    function underlyingAsset() external view returns (address);

    /// @notice Returns the current value of the strategy holdings in debt asset terms
    function balanceOf() external view returns (uint256);

    /// @notice Returns the total debt asset deposited (cost basis)
    function costBasis() external view returns (uint256);

    /// @notice Returns unrealized profit (current value - cost basis)
    function unrealizedProfit() external view returns (uint256);

    /// @notice Returns pending rewards value in debt asset terms
    function pendingRewards() external view returns (uint256);

    /// @notice Returns the strategy name
    function name() external view returns (string memory);

    /// @notice Returns the vault address
    function vault() external view returns (address);
}
