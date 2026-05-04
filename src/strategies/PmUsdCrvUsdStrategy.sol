// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BasePmUsdCrvUsdStrategy } from "./BasePmUsdCrvUsdStrategy.sol";

/// @title PmUsdCrvUsdStrategy
/// @notice crvUSD → pmUSD/crvUSD LP → Stake DAO RewardVault
/// @dev Accepts crvUSD debt directly — no USDT swap layer. The debt asset IS crvUSD, so the
///      three conversion hooks (_convertCrvUsdValueToDebt, _swapCrvUsdToDebt, _beforeDeposit)
///      all use the default no-op/1:1 implementations in BasePmUsdCrvUsdStrategy.
///      Only _crvToPendingRewards() and name() require an override.
contract PmUsdCrvUsdStrategy is BasePmUsdCrvUsdStrategy {
    // ============ Constructor ============

    /// @param _crvUsd  crvUSD token address (debt asset)
    /// @param _vault   Zenji vault address
    /// @param _owner   Initial owner (vault gov at deploy time)
    /// @param _lpPool  Curve pmUSD/crvUSD StableSwapNG pool
    /// @param _rewardVault  Stake DAO ERC4626 reward vault
    /// @param _crvSwapper   CRV → crvUSD swapper
    /// @param _gauge    Curve gauge for accountant claims
    /// @param _lpCrvUsdIndex  crvUSD coin index in the pmUSD/crvUSD pool
    /// @param _crvUsdOracle  Chainlink crvUSD/USD oracle
    /// @param _crvOracle     Chainlink CRV/USD oracle
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
            _crvUsd, // debtAsset = crvUSD
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
    {}

    // ============ Hook Overrides ============

    function name() external pure override returns (string memory) {
        return "crvUSD -> pmUSD/crvUSD LP Strategy";
    }

    /// @dev CRV/USD ÷ crvUSD/USD.  Both tokens are 18-decimal — no adjustment needed.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        override
        returns (uint256)
    {
        (uint80 crvUsdRoundId, int256 crvUsdPrice,, uint256 crvUsdUpdatedAt, uint80 crvUsdAnswered) =
            crvUsdOracle.latestRoundData();
        if (
            crvUsdPrice <= 0 || crvUsdAnswered < crvUsdRoundId
                || block.timestamp - crvUsdUpdatedAt > MAX_ORACLE_STALENESS
        ) {
            return crvSwapper.quote(pendingCrv); // fallback: swap quote
        }
        return (pendingCrv * crvPrice) / uint256(crvUsdPrice);
    }

    // Remaining hooks use BasePmUsdCrvUsdStrategy defaults:
    //   _convertCrvUsdValueToDebt → 1:1 pass-through
    //   _swapCrvUsdToDebt         → no-op pass-through
    //   _beforeDeposit            → no-op
    //   _pendingRewardsFallback   → crvSwapper.quote() in crvUSD
    //   _isProtectedToken         → standard set (debtAsset covers crvUSD)
}
