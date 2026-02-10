// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseYieldStrategy} from "./BaseYieldStrategy.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";
import {ITokemakAutopool} from "../interfaces/ITokemakAutopool.sol";
import {IAutopilotRouter} from "../interfaces/IAutopilotRouter.sol";
import {IMainRewarder} from "../interfaces/IMainRewarder.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title BaseTokemakStrategy
/// @notice Abstract base for Tokemak autoUSD strategies
/// @dev Provides shared stake/unstake/balance helpers for Tokemak vault interactions
abstract contract BaseTokemakStrategy is BaseYieldStrategy {
    // ============ Immutables ============

    /// @notice Tokemak autoUSD vault
    ITokemakAutopool public immutable tokemakVault;

    /// @notice Tokemak AutopilotRouter for staking/unstaking
    IAutopilotRouter public immutable router;

    /// @notice Tokemak MainRewarder for staked share accounting
    IMainRewarder public immutable rewarder;

    // ============ Constructor ============

    constructor(
        address _debtAsset,
        address _vault,
        address _tokemakVault,
        address _router,
        address _rewarder
    ) BaseYieldStrategy(_debtAsset, _vault) {
        if (_tokemakVault == address(0) || _router == address(0) || _rewarder == address(0)) {
            revert InvalidAddress();
        }
        tokemakVault = ITokemakAutopool(_tokemakVault);
        router = IAutopilotRouter(_router);
        rewarder = IMainRewarder(_rewarder);
    }

    // ============ Tokemak Helpers ============

    /// @notice Deposit underlying into Tokemak vault and stake shares via router
    function _depositAndStake(uint256 underlyingAmount) internal returns (uint256 shares) {
        IERC20 underlying = IERC20(tokemakVault.asset());
        _ensureApprove(address(underlying), address(tokemakVault), underlyingAmount);
        shares = tokemakVault.deposit(underlyingAmount, address(this));

        if (!IERC20(address(tokemakVault)).transfer(address(router), shares)) {
            revert TransferFailed();
        }
        router.approve(IERC20(address(tokemakVault)), address(rewarder), shares);
        router.stakeVaultToken(IERC20(address(tokemakVault)), shares);
    }

    /// @notice Unstake specific shares and redeem from Tokemak vault
    function _unstakeAndRedeem(uint256 sharesToRedeem) internal returns (uint256 received) {
        if (sharesToRedeem == 0) return 0;
        router.withdrawVaultToken(tokemakVault, rewarder, sharesToRedeem, false);
        uint256 shares = IERC20(address(tokemakVault)).balanceOf(address(this));
        if (shares > sharesToRedeem) shares = sharesToRedeem;
        received = tokemakVault.redeem(shares, address(this), address(this));
    }

    /// @notice Unstake all and redeem from Tokemak vault
    function _unstakeAndRedeemAll() internal returns (uint256 received) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        if (stakedShares == 0) return 0;
        router.withdrawVaultToken(tokemakVault, rewarder, stakedShares, false);
        uint256 shares = IERC20(address(tokemakVault)).balanceOf(address(this));
        received = tokemakVault.redeem(shares, address(this), address(this));
    }

    /// @notice Get total USDC value of staked + held Tokemak shares
    function _tokemakBalance() internal view returns (uint256) {
        uint256 stakedShares = rewarder.balanceOf(address(this));
        uint256 heldShares = IERC20(address(tokemakVault)).balanceOf(address(this));
        uint256 totalShares = stakedShares + heldShares;
        if (totalShares < 1) return 0;
        return tokemakVault.convertToAssets(totalShares);
    }

    // ============ Default Implementations ============

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external view virtual override returns (uint256) {
        return rewarder.earned(address(this));
    }
}
