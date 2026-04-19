// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ILoanManager
/// @notice Interface for loan managers that handle collateralized borrowing
interface ILoanManager {
    // ============ Events ============
    event LoanCreated(uint256 collateral, uint256 debt, uint256 bands);
    event CollateralAdded(uint256 amount);
    event LoanBorrowedMore(uint256 collateral, uint256 debt);
    event LoanRepaid(uint256 amount);
    event CollateralRemoved(uint256 amount);

    // ============ Errors ============
    error Unauthorized();
    error InvalidAddress();
    error InvalidPrice();
    error StaleOracle();
    error DebtNotFullyRepaid();
    error ZeroAmount();
    error TransferFailed();

    // ============ Loan Management Functions ============

    /// @notice Create a new loan with collateral
    /// @param collateral Amount of collateral asset
    /// @param debt Amount of debt asset to borrow
    function createLoan(uint256 collateral, uint256 debt) external;

    /// @notice Add collateral to an existing loan
    /// @param collateral Amount of collateral asset
    function addCollateral(uint256 collateral) external;

    /// @notice Borrow more against existing collateral
    /// @param collateral Additional collateral (can be 0)
    /// @param debt Additional debt to borrow
    function borrowMore(uint256 collateral, uint256 debt) external;

    /// @notice Repay debt
    /// @param amount Amount of debt asset to repay
    function repayDebt(uint256 amount) external;

    /// @notice Remove collateral from the loan
    /// @param amount Amount of collateral asset to remove
    function removeCollateral(uint256 amount) external;

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @dev Pass type(uint256).max for collateralNeeded to fully close the position.
    /// @param collateralNeeded Amount of collateral to free, or type(uint256).max for full close
    function unwindPosition(uint256 collateralNeeded) external;

    // ============ View Functions ============

    /// @notice Get current LTV ratio
    /// @return ltv Current LTV (1e18 = 100%)
    function getCurrentLTV() external view returns (uint256 ltv);

    /// @notice Get current collateral amount
    /// @return collateral Current collateral amount
    function getCurrentCollateral() external view returns (uint256 collateral);

    /// @notice Get current debt amount
    /// @return debt Current debt amount
    function getCurrentDebt() external view returns (uint256 debt);

    /// @notice Collateral asset used by this loan manager
    function collateralAsset() external view returns (address);

    /// @notice Debt asset used by this loan manager
    function debtAsset() external view returns (address);

    /// @notice Get vault health factor
    /// @return health Health factor (positive = healthy)
    function getHealth() external view returns (int256 health);

    /// @notice Check if loan exists
    /// @return exists True if loan exists
    function loanExists() external view returns (bool exists);

    /// @notice Get collateral value in debt asset terms
    /// @param collateralAmount Amount of collateral asset
    /// @return value Value in debt asset (18 decimals unless specified by implementation)
    function getCollateralValue(uint256 collateralAmount) external view returns (uint256 value);

    /// @notice Get debt asset value in collateral terms
    /// @param debtAmount Amount of debt asset
    /// @return value Value in collateral asset (collateral decimals)
    function getDebtValue(uint256 debtAmount) external view returns (uint256 value);

    /// @notice Calculate borrow amount for given collateral and target LTV
    /// @param collateral Amount of collateral asset
    /// @param targetLtv Target LTV (1e18 = 100%)
    /// @return borrowAmount Amount of debt asset to borrow
    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        view
        returns (uint256 borrowAmount);

    /// @notice Calculate health after hypothetical changes
    /// @param dCollateral Change in collateral
    /// @param dDebt Change in debt
    /// @return health Projected health factor
    function healthCalculator(int256 dCollateral, int256 dDebt)
        external
        view
        returns (int256 health);

    /// @notice Get minimum collateral required for a debt amount
    /// @param debt_ Desired debt amount
    /// @param bands Number of bands
    /// @return Minimum collateral required
    function minCollateral(uint256 debt_, uint256 bands) external view returns (uint256);

    /// @notice Get position values (collateral and debt)
    /// @return collateralValue Current collateral value
    /// @return debtValue Current debt value
    function getPositionValues() external view returns (uint256 collateralValue, uint256 debtValue);

    /// @notice Get net collateral value (collateral - debt in collateral terms)
    /// @return value Net value in collateral asset
    function getNetCollateralValue() external view returns (uint256 value);

    /// @notice Check oracle freshness
    function checkOracleFreshness() external view;

    /// @notice Maximum LTV in basis points (100% = 10000). Returns type(uint256).max for managers
    ///         with no fixed LTV cap (e.g. LlamaLend band-based risk model).
    function maxLtvBps() external view returns (uint256);

    // ============ Token Management ============

    /// @notice Transfer collateral from this contract
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferCollateral(address to, uint256 amount) external;

    /// @notice Transfer debt asset from this contract
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferDebt(address to, uint256 amount) external;

    /// @notice Get collateral balance of this contract
    /// @return balance Collateral balance
    function getCollateralBalance() external view returns (uint256 balance);

    /// @notice Get debt balance of this contract
    /// @return balance Debt balance
    function getDebtBalance() external view returns (uint256 balance);
}
