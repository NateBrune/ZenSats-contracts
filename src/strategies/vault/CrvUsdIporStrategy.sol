// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseVaultStrategy } from "./BaseVaultStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title CrvUsdIporStrategy
/// @notice Yield strategy that deposits crvUSD directly into an IPOR PlasmaVault.
/// @dev Debt asset == vault asset == crvUSD, so all swap/conversion hooks inherit the
///      BaseVaultStrategy 1:1 defaults. This contract just plugs in the constructor.
contract CrvUsdIporStrategy is BaseVaultStrategy {
    constructor(address _crvUSD, address _vault, address _iporVault)
        BaseVaultStrategy(_crvUSD, _vault, address(0), _iporVault)
    { }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "IPOR PlasmaVault Strategy";
    }
}
