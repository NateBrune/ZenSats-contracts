// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseNgScrvUsdLpStakeDaoStrategy } from "./BaseNgScrvUsdLpStakeDaoStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title NgScrvUsdLpStakeDaoStrategy
/// @notice crvUSD → scrvUSD → (any 2-coin Curve StableSwapNG pool with scrvUSD on one side) →
///         Stake DAO.
/// @dev Debt asset == lpAsset == crvUSD, so the swap/conversion hooks inherit the 1:1 defaults and
///      the pendingRewards denominator inherits the base's crvUSD default — the crvUSD⇄scrvUSD wrap
///      is internal to the base's add/remove hooks. Pairs with LlamaLend (native crvUSD debt).
///      Pool-agnostic: scrvUSD/sUSDe, reUSD/scrvUSD, scrvUSD/sDOLA, or any other 2-coin NG scrvUSD
///      pool.
contract NgScrvUsdLpStakeDaoStrategy is BaseNgScrvUsdLpStakeDaoStrategy {
    constructor(
        address _crvUsd,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpScrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    )
        BaseNgScrvUsdLpStakeDaoStrategy(
            _crvUsd,
            _vault,
            _owner,
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _lpScrvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    { }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "crvUSD -> NG scrvUSD/token LP Strategy";
    }
}
