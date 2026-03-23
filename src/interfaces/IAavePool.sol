// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

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
