// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BasePmUsdCrvUsdStrategy } from "./BasePmUsdCrvUsdStrategy.sol";
import { IYieldStrategy } from "../../interfaces/IYieldStrategy.sol";

/// @title PmUsdCrvUsdStakeDaoStrategy
/// @notice crvUSD → pmUSD/crvUSD LP → Stake DAO RewardVault.
/// @dev Debt asset == lpAsset == crvUSD, so the three swap/conversion hooks inherit the
///      BaseLPStrategy 1:1 defaults. Only _crvToPendingRewards needs overriding to compute
///      the CRV-priced reward value with crvUSD as the denominator.
contract PmUsdCrvUsdStakeDaoStrategy is BasePmUsdCrvUsdStrategy {
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
        BasePmUsdCrvUsdStrategy(
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
        return "crvUSD -> pmUSD/crvUSD LP Strategy";
    }

    /// @dev CRV/USD ÷ crvUSD/USD. Both 18-decimal — no scaling needed.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        override
        returns (uint256)
    {
        (uint80 crvUsdRoundId, int256 crvUsdPrice,, uint256 crvUsdUpdatedAt, uint80 crvUsdAnswered)
        = crvUsdOracle.latestRoundData();
        if (
            crvUsdPrice <= 0 || crvUsdAnswered < crvUsdRoundId
                || block.timestamp - crvUsdUpdatedAt > MAX_ORACLE_STALENESS
        ) {
            return crvSwapper.quote(pendingCrv);
        }
        return (pendingCrv * crvPrice) / uint256(crvUsdPrice);
    }
}
