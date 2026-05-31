// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ZenjiStorage } from "./ZenjiStorage.sol";

/// @title ZenjiAdmin
/// @notice Delegatecall facet for Zenji cold-path admin; deployed once, shared by all vaults,
///         runs in the vault's storage. Functions are moved here in Phase 2.
contract ZenjiAdmin is ZenjiStorage {
    constructor() ERC20("", "") { }
}
