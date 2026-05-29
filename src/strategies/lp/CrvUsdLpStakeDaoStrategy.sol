// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveStakeDaoStrategy } from "./BaseCurveStakeDaoStrategy.sol";
import { ICurveStableSwapTwoLP } from "../../interfaces/ICurveStableSwapTwoLP.sol";

/// @title CrvUsdLpStakeDaoStrategy
/// @notice crvUSD → (any legacy 2-coin Curve StableSwap pool with crvUSD on one side) →
///         Stake DAO RewardVault.
/// @dev Pairs with LlamaLoanManager (Llama lends crvUSD natively, so debt == lpAsset == crvUSD;
///      no entry/exit swap layer needed). All generic Curve+Stake DAO machinery lives in
///      BaseCurveStakeDaoStrategy; this contract only supplies the legacy 2-coin single-sided add.
///
///      Pool-agnostic: the strategy never references the "other" pool coin, so the same contract
///      works for USDT/crvUSD, USDC/crvUSD, or any other legacy 2-coin StableSwap with crvUSD as
///      one side. Each deployment supplies the pool, gauge, staking vault, crvUSD index, and a
///      human-readable display name via constructor args.
contract CrvUsdLpStakeDaoStrategy is BaseCurveStakeDaoStrategy {
    /// @notice Human-readable strategy name (set at deploy, e.g. "crvUSD -> USDT/crvUSD").
    string public override name;

    /// @param _crvUsd       crvUSD token address (debt asset == lpAsset).
    /// @param _vault        Zenji vault address.
    /// @param _owner        Initial owner.
    /// @param _lpPool       Curve crvUSD-anchored 2-coin pool (e.g. USDT/crvUSD, USDC/crvUSD).
    /// @param _rewardVault  Stake DAO ERC4626 reward vault wrapping the LP token.
    /// @param _crvSwapper   CRV → crvUSD swapper.
    /// @param _gauge        Curve gauge for accountant claims.
    /// @param _crvUsdIndex  crvUSD coin index in the pool (0 or 1).
    /// @param _crvUsdOracle Chainlink crvUSD/USD oracle (for the pendingRewards denominator).
    /// @param _crvOracle    Chainlink CRV/USD oracle.
    /// @param _name         Human-readable name, e.g. "crvUSD -> USDT/crvUSD LP Strategy".
    constructor(
        address _crvUsd,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _crvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle,
        string memory _name
    )
        BaseCurveStakeDaoStrategy(
            _crvUsd,
            _vault,
            _owner,
            _crvUsd, // lpAsset == debt == crvUSD
            _lpPool,
            _rewardVault,
            _crvSwapper,
            _gauge,
            _crvUsdIndex,
            _crvUsdOracle,
            _crvOracle
        )
    {
        name = _name;
    }

    /// @notice Single-sided crvUSD add into a legacy 2-coin StableSwap (fixed `uint256[2]`).
    /// @dev LP_SLIPPAGE caps the implicit swap portion; the cached-VP oracle floor independently
    ///      defends against same-block price manipulation.
    function _addLiquidity(uint256 crvUsdAmount) internal override returns (uint256 lpReceived) {
        if (crvUsdAmount == 0) return 0;
        ICurveStableSwapTwoLP pool = ICurveStableSwapTwoLP(address(lpPool));
        _ensureApprove(address(CRVUSD), address(pool), crvUsdAmount);

        uint256[2] memory amounts;
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;

        uint256 expectedLp = pool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        uint256 safeVP = _getSafeUnitValue();
        uint256 oracleMinLp =
            (crvUsdAmount * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = pool.add_liquidity(amounts, minLp);
    }
}
