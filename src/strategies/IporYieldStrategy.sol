// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseIporStrategy} from "./BaseIporStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

/// @title IporYieldStrategy
/// @notice Yield strategy that deposits crvUSD directly into IPOR PlasmaVault
/// @dev No swaps required - IPOR vault accepts crvUSD directly
contract IporYieldStrategy is BaseIporStrategy {
    constructor(address _crvUSD, address _vault, address _iporVault)
        BaseIporStrategy(_crvUSD, _vault, _iporVault)
    {}

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(debtAsset);
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        return _iporBalance();
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "IPOR PlasmaVault Strategy";
    }

    // ============ Internal Functions ============

    function _deposit(uint256 amount) internal override returns (uint256 underlyingDeposited) {
        _depositToIpor(amount);
        underlyingDeposited = amount;
    }

    function _withdraw(uint256 amount) internal override returns (uint256 received) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        uint256 sharesToRedeem = iporVault.convertToShares(amount);
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem > 0) {
            received = _redeemFromIpor(sharesToRedeem);
        }
    }

    function _withdrawAll() internal override returns (uint256 received) {
        received = _redeemAllFromIpor();
    }

    function _emergencyWithdraw() internal override returns (uint256 received) {
        received = _redeemAllFromIpor();
    }
}
