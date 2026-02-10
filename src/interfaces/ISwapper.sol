// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ISwapper
/// @notice Optional swapper for collateral/debt conversions
interface ISwapper {
    error SlippageExceeded();
    error InvalidAddress();
    error TransferFailed();

    /// @notice Quote collateral needed for a given debt amount
    /// @param debtAmount Amount of debt asset
    /// @return collateralNeeded Estimated collateral required
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256);

    /// @notice Swap collateral for debt asset
    /// @param collateralAmount Amount of collateral to swap
    /// @return debtReceived Amount of debt asset received
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived);

    /// @notice Swap debt asset for collateral
    /// @param debtAmount Amount of debt asset to swap
    /// @return collateralReceived Amount of collateral received
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived);
}
