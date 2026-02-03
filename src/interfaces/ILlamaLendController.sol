// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ILlamaLendController
/// @notice Interface for Curve LlamaLend Controller (WBTC/crvUSD market)
interface ILlamaLendController {
    /// @notice Create a new loan
    /// @param collateral Amount of collateral to deposit
    /// @param debtAmount Amount of crvUSD to borrow
    /// @param N Number of bands for the loan
    function create_loan(uint256 collateral, uint256 debtAmount, uint256 N) external payable;

    /// @notice Add more collateral to an existing loan
    /// @param collateral Amount of collateral to add
    function add_collateral(uint256 collateral) external payable;

    /// @notice Add collateral for another user
    /// @param collateral Amount of collateral to add
    /// @param _for Address to add collateral for
    function add_collateral(uint256 collateral, address _for) external payable;

    /// @notice Remove collateral from an existing loan
    /// @param collateral Amount of collateral to remove
    function remove_collateral(uint256 collateral) external;

    /// @notice Borrow more crvUSD against existing collateral
    /// @param collateral Additional collateral (can be 0)
    /// @param debtAmount Additional debt to borrow
    function borrow_more(uint256 collateral, uint256 debtAmount) external payable;

    /// @notice Repay debt
    /// @param _d_debt Amount of debt to repay
    function repay(uint256 _d_debt) external;

    /// @notice Repay debt for another user
    /// @param _d_debt Amount of debt to repay
    /// @param _for Address to repay for
    function repay(uint256 _d_debt, address _for) external;

    /// @notice Get user's current debt
    /// @param user User address
    /// @return Current debt amount
    function debt(address user) external view returns (uint256);

    /// @notice Check if a loan exists for a user
    /// @param user User address
    /// @return True if loan exists
    function loan_exists(address user) external view returns (bool);

    /// @notice Get total debt across all loans
    /// @return Total debt
    function total_debt() external view returns (uint256);

    /// @notice Calculate maximum borrowable amount
    /// @param collateral Amount of collateral
    /// @param N Number of bands
    /// @return Maximum borrowable amount
    function max_borrowable(uint256 collateral, uint256 N) external view returns (uint256);

    /// @notice Calculate maximum borrowable with existing debt
    /// @param collateral Amount of collateral
    /// @param N Number of bands
    /// @param current_debt Existing debt amount
    /// @return Maximum borrowable amount
    function max_borrowable(uint256 collateral, uint256 N, uint256 current_debt)
        external
        view
        returns (uint256);

    /// @notice Calculate minimum collateral needed for a debt
    /// @param debt_ Desired debt amount
    /// @param N Number of bands
    /// @return Minimum collateral required
    function min_collateral(uint256 debt_, uint256 N) external view returns (uint256);

    /// @notice Get user's health factor
    /// @param user User address
    /// @return Health factor (positive = healthy, negative = unhealthy)
    function health(address user) external view returns (int256);

    /// @notice Get user's health factor with option for full calculation
    /// @param user User address
    /// @param full Whether to use full calculation
    /// @return Health factor
    function health(address user, bool full) external view returns (int256);

    /// @notice Calculate health after hypothetical changes
    /// @param user User address
    /// @param d_collateral Change in collateral (positive = add, negative = remove)
    /// @param d_debt Change in debt (positive = borrow, negative = repay)
    /// @param full Whether to use full calculation
    /// @return Projected health factor
    function health_calculator(address user, int256 d_collateral, int256 d_debt, bool full)
        external
        view
        returns (int256);

    /// @notice Get user's loan state
    /// @param user User address
    /// @return [collateral, stablecoin, debt, N]
    function user_state(address user) external view returns (uint256[4] memory);

    /// @notice Get AMM price
    /// @return Current AMM price
    function amm_price() external view returns (uint256);

    /// @notice Get user's price range
    /// @param user User address
    /// @return [price_low, price_high]
    function user_prices(address user) external view returns (uint256[2] memory);

    /// @notice Get the collateral token address
    /// @return Collateral token address
    function collateral_token() external view returns (address);

    /// @notice Get the AMM address
    /// @return AMM address
    function amm() external view returns (address);

    /// @notice Get liquidation discount for a user
    /// @param user User address
    /// @return Liquidation discount
    function liquidation_discounts(address user) external view returns (uint256);

    /// @notice Get global liquidation discount
    /// @return Liquidation discount
    function liquidation_discount() external view returns (uint256);

    /// @notice Get loan discount
    /// @return Loan discount
    function loan_discount() external view returns (uint256);
}
