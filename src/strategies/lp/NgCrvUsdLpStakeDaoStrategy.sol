// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseNgCrvUsdLpStakeDaoStrategy } from "./BaseNgCrvUsdLpStakeDaoStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title NgCrvUsdLpStakeDaoStrategy
/// @notice crvUSD → (any 2-coin Curve StableSwapNG pool with crvUSD on one side) → Stake DAO.
/// @dev Debt asset == lpAsset == crvUSD, so the swap/conversion hooks inherit the 1:1 defaults and
///      the pendingRewards denominator inherits the base's crvUSD default. Pairs with LlamaLend
///      (native crvUSD debt). Pool-agnostic: pmUSD/crvUSD or any other 2-coin NG crvUSD pool.
contract NgCrvUsdLpStakeDaoStrategy is BaseNgCrvUsdLpStakeDaoStrategy {
    constructor(
        address _crvUsd,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    )
        BaseNgCrvUsdLpStakeDaoStrategy(
            _crvUsd,
            _vault,
            _owner,
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _lpCrvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    { }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "crvUSD -> NG crvUSD/token LP Strategy";
    }
}
