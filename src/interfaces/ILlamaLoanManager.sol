// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ILlamaLoanManager
/// @notice Interface for the LlamaLoanManager contract that handles LlamaLend interactions
interface ILlamaLoanManager {
    // ============ Events ============
    event LoanCreated(uint256 collateral, uint256 debt, uint256 bands);
    event CollateralAdded(uint256 amount);
    event LoanBorrowedMore(uint256 collateral, uint256 debt);
    event LoanRepaid(uint256 amount);
    event CollateralRemoved(uint256 amount);
    event CollateralSwapped(uint256 wbtcIn, uint256 crvUsdOut);
    event DebtSwapped(uint256 crvUsdIn, uint256 wbtcOut);

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
    /// @param collateral Amount of WBTC collateral
    /// @param debt Amount of crvUSD to borrow
    /// @param bands Number of bands for the loan
    function createLoan(uint256 collateral, uint256 debt, uint256 bands) external;

    /// @notice Add collateral to an existing loan
    /// @param collateral Amount of WBTC collateral
    function addCollateral(uint256 collateral) external;

    /// @notice Borrow more against existing collateral
    /// @param collateral Additional collateral (can be 0)
    /// @param debt Additional debt to borrow
    function borrowMore(uint256 collateral, uint256 debt) external;

    /// @notice Repay debt
    /// @param amount Amount of crvUSD to repay
    function repayDebt(uint256 amount) external;

    /// @notice Remove collateral from the loan
    /// @param amount Amount of WBTC to remove
    function removeCollateral(uint256 amount) external;

    /// @notice Unified position unwind for both partial and full withdrawals
    /// @dev Pass type(uint256).max for wbtcNeeded to fully close the position.
    ///      Uses flashloan automatically when yield can't cover pro-rata debt.
    /// @param wbtcNeeded Amount of WBTC to free, or type(uint256).max for full close
    function unwindPosition(uint256 wbtcNeeded) external;

    /// @notice Swap WBTC collateral to crvUSD
    /// @param wbtcAmount Amount of WBTC to swap
    /// @return Amount of crvUSD received
    function swapCollateralForDebt(uint256 wbtcAmount) external returns (uint256);

    /// @notice Swap crvUSD to WBTC
    /// @param crvUsdAmount Amount of crvUSD to swap
    /// @return Amount of WBTC received
    function swapDebtForCollateral(uint256 crvUsdAmount) external returns (uint256);

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

    /// @notice Get vault health factor from LlamaLend
    /// @return health Health factor (positive = healthy)
    function getHealth() external view returns (int256 health);

    /// @notice Check if loan exists
    /// @return exists True if loan exists
    function loanExists() external view returns (bool exists);

    /// @notice Get collateral value in crvUSD terms
    /// @param wbtcAmount Amount of WBTC
    /// @return value Value in crvUSD (18 decimals)
    function getCollateralValue(uint256 wbtcAmount) external view returns (uint256 value);

    /// @notice Get crvUSD value in WBTC terms
    /// @param crvUsdAmount Amount of crvUSD
    /// @return value Value in WBTC (8 decimals)
    function getDebtValue(uint256 crvUsdAmount) external view returns (uint256 value);

    /// @notice Quote WBTC needed for a crvUSD amount using pool pricing
    /// @param crvUsdAmount Amount of crvUSD
    /// @return wbtcNeeded Estimated WBTC needed (8 decimals)
    function quoteWbtcForCrvUsd(uint256 crvUsdAmount) external view returns (uint256 wbtcNeeded);

    /// @notice Calculate borrow amount for given collateral and target LTV
    /// @param collateral Amount of WBTC
    /// @param targetLtv Target LTV (1e18 = 100%)
    /// @return borrowAmount Amount of crvUSD to borrow
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
    /// @return collateralValue Current collateral amount
    /// @return debtValue Current debt amount
    function getPositionValues()
        external
        view
        returns (uint256 collateralValue, uint256 debtValue);

    /// @notice Get net collateral value (collateral - debt in WBTC terms)
    /// @return value Net value in WBTC (8 decimals)
    function getNetCollateralValue() external view returns (uint256 value);

    /// @notice Check oracle freshness
    function checkOracleFreshness() external view;

    // ============ Token Management ============

    /// @notice Transfer WBTC from this contract
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferWbtc(address to, uint256 amount) external;

    /// @notice Transfer crvUSD from this contract
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferCrvUsd(address to, uint256 amount) external;

    /// @notice Get WBTC balance of this contract
    /// @return balance WBTC balance
    function getWbtcBalance() external view returns (uint256 balance);

    /// @notice Get crvUSD balance of this contract
    /// @return balance crvUSD balance
    function getCrvUsdBalance() external view returns (uint256 balance);
}
