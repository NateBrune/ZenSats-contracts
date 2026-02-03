// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface ICurveRegistry {
    function find_pool_for_coins(address, address) external view returns (address);
    function find_pool_for_coins(address, address, uint256) external view returns (address);
}
