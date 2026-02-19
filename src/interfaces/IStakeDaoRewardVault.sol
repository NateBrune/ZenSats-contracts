// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ICurveRewardVault} from "./ICurveRewardVault.sol";

/// @title IStakeDaoRewardVault
/// @notice Minimal extension for Stake DAO reward vaults exposing the accountant address
interface IStakeDaoRewardVault is ICurveRewardVault {
    /// @notice Stake DAO accountant contract
    /// @return accountant address
    function ACCOUNTANT() external view returns (address);
}
