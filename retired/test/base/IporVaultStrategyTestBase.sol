// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { AaveBackedStrategyTestBase } from "./AaveBackedStrategyTestBase.sol";
import { IYieldVault } from "../../src/interfaces/IYieldVault.sol";

/// @title IporVaultStrategyTestBase
/// @notice Strategy-specific base for Aave-collateralised IPOR PlasmaVault deployments.
///         Inherits the full Aave-side test suite (dust unwind, access control, donation
///         resilience, decimal scaling) from AaveBackedStrategyTestBase and adds the
///         IPOR-specific integration check.
abstract contract IporVaultStrategyTestBase is AaveBackedStrategyTestBase {
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    function _assertStrategyIntegration() internal override {
        uint256 iporShares = IYieldVault(IPOR_PLASMA_VAULT).balanceOf(address(yieldStrategy));
        assertGt(iporShares, 0, "Strategy should hold IPOR vault shares");
    }

    // ============ IPOR-specific tests ============

    function test_iporVault_receivesDebtTokenDeposit() public {
        _deployVault();
        _depositAs(user1, _unit());
        uint256 iporShares = IYieldVault(IPOR_PLASMA_VAULT).balanceOf(address(yieldStrategy));
        assertGt(iporShares, 0, "Strategy should hold IPOR vault shares after deposit");
    }
}
