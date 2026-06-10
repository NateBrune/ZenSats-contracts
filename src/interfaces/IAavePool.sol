// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Minimal Aave V3 PoolAddressesProvider surface used for emergency pricing.
interface IAavePoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}

/// @notice Minimal Aave V3 price oracle surface. getAssetPrice returns the latest answer in the
///         pool's base currency (USD, 8 decimals on mainnet) with NO staleness gate — the same
///         pricing Aave uses for health factors and liquidations.
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @notice Extra Aave V3 Pool views used only by the stale-oracle emergency exit. Kept separate
///         from IAavePool so existing IAavePool mocks are not forced to implement them.
interface IAavePoolEmergencyView {
    function ADDRESSES_PROVIDER() external view returns (address);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function setUserEMode(uint8 categoryId) external;

    function getUserEMode(address user) external view returns (uint256);

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
