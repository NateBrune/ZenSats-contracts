// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BasePmUsdCrvUsdStrategy } from "./BasePmUsdCrvUsdStrategy.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { CurveUsdtSwapLib } from "../libraries/CurveUsdtSwapLib.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title UsdtPmUsdCrvUsdStrategy
/// @notice USDT → crvUSD → pmUSD/crvUSD LP → Stake DAO RewardVault
/// @dev Adds a USDT↔crvUSD swap layer on top of BasePmUsdCrvUsdStrategy.
///      All LP operations, CRV harvesting, and VP-cache logic live in the base.
///      This contract holds only USDT-specific state and the six hook overrides that
///      add/remove the conversion layer at entry and exit.
contract UsdtPmUsdCrvUsdStrategy is BasePmUsdCrvUsdStrategy {
    using SafeTransferLib for IERC20;

    // ============ USDT-specific Immutables ============

    /// @notice Curve USDT/crvUSD StableSwap pool
    ICurveStableSwap public immutable usdtCrvUsdPool;
    /// @notice Chainlink USDT/USD oracle
    IChainlinkOracle public immutable usdtOracle;
    /// @notice USDT coin index in the USDT/crvUSD pool
    int128 public immutable usdtIndex;
    /// @notice crvUSD coin index in the USDT/crvUSD pool
    int128 public immutable crvUsdIndex;

    // ============ Events ============

    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);

    // ============ Constructor ============

    /// @param _usdt           USDT token address (debt asset)
    /// @param _vault          Zenji vault address
    /// @param _owner          Initial owner (vault gov at deploy time)
    /// @param _usdtCrvUsdPool Curve USDT/crvUSD StableSwap pool
    /// @param _lpPool         Curve pmUSD/crvUSD StableSwapNG pool
    /// @param _rewardVault    Stake DAO ERC4626 reward vault
    /// @param _crvSwapper     CRV → crvUSD swapper
    /// @param _gauge          Curve gauge for accountant claims
    /// @param _usdtIndex      USDT coin index in the USDT/crvUSD pool
    /// @param _crvUsdIndex    crvUSD coin index in the USDT/crvUSD pool
    /// @param _lpCrvUsdIndex  crvUSD coin index in the pmUSD/crvUSD pool
    /// @param _crvUsdOracle   Chainlink crvUSD/USD oracle
    /// @param _usdtOracle     Chainlink USDT/USD oracle
    /// @param _crvOracle      Chainlink CRV/USD oracle
    constructor(
        address _usdt,
        address _vault,
        address _owner,
        address _usdtCrvUsdPool,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _usdtIndex,
        int128 _crvUsdIndex,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _usdtOracle,
        address _crvOracle
    )
        BasePmUsdCrvUsdStrategy(
            _usdt, // debtAsset = USDT
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
    {
        if (_usdtCrvUsdPool == address(0)) revert InvalidAddress();
        if (_usdtOracle == address(0)) revert InvalidAddress();

        usdtCrvUsdPool = ICurveStableSwap(_usdtCrvUsdPool);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
    }

    // ============ Hook Overrides ============

    function name() external pure override returns (string memory) {
        return "USDT -> pmUSD/crvUSD LP Strategy";
    }

    /// @dev Also protect crvUSD from rescue (debtAsset check covers USDT only).
    function _isProtectedToken(address token) internal view override returns (bool) {
        return super._isProtectedToken(token) || token == address(CRVUSD);
    }

    /// @dev Oracle-based crvUSD→USDT conversion (view, no token transfer).
    ///      Used by balanceOf() and _harvest() to report values in USDT.
    ///      Reverts with `StaleOrInvalidOracle` when either the crvUSD or USDT Chainlink oracle
    ///      is stale or invalid, causing balanceOf() to revert transiently. No funds are at risk —
    ///      all callers revert atomically. Operations resume once the oracle is refreshed.
    function _convertCrvUsdValueToDebt(uint256 crvUsdAmount)
        internal
        view
        override
        returns (uint256)
    {
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdAmount, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
    }

    /// @dev Actual Curve swap: crvUSD tokens → USDT tokens. Called on all withdrawals.
    /// Reverts with `StaleOrInvalidOracle` when the crvUSD or USDT Chainlink oracle is stale.
    /// This also causes `balanceOf()` to revert transiently. No funds are permanently stuck —
    /// all state changes are atomic. Operations resume once the oracle is refreshed.
    function _swapCrvUsdToDebt(uint256 crvUsdAmount, uint256 slippage)
        internal
        override
        returns (uint256 usdtReceived)
    {
        if (crvUsdAmount == 0) return 0;
        _ensureApprove(address(CRVUSD), address(usdtCrvUsdPool), crvUsdAmount);
        usdtReceived = CurveUsdtSwapLib.swapCrvUsdToUsdt(
            usdtCrvUsdPool,
            crvUsdIndex,
            usdtIndex,
            crvUsdAmount,
            slippage,
            crvUsdOracle,
            usdtOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }

    /// @dev Pre-deposit: swap incoming USDT → crvUSD before LP operations.
    function _beforeDeposit(uint256 usdtAmount, uint256 slippage) internal override {
        _ensureApprove(address(debtAsset), address(usdtCrvUsdPool), usdtAmount);
        uint256 crvUsdReceived = CurveUsdtSwapLib.swapUsdtToCrvUsd(
            usdtCrvUsdPool,
            usdtIndex,
            crvUsdIndex,
            usdtAmount,
            slippage,
            usdtOracle,
            crvUsdOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    /// @dev CRV/USD ÷ USDT/USD, divided by 1e12 for USDT's 6-decimal precision.
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        override
        returns (uint256)
    {
        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
            usdtOracle.latestRoundData();
        if (
            usdtPrice <= 0 || usdtAnswered < usdtRoundId
                || block.timestamp - usdtUpdatedAt > MAX_ORACLE_STALENESS
        ) {
            return crvSwapper.quote(pendingCrv) / 1e12; // fallback: LP quote, /1e12 for USDT
        }
        return (pendingCrv * crvPrice) / (uint256(usdtPrice) * 1e12);
    }

    /// @dev CRV oracle stale fallback: swap-quote divided by 1e12 for USDT decimals.
    function _pendingRewardsFallback(uint256 pendingCrv)
        internal
        view
        override
        returns (uint256)
    {
        return crvSwapper.quote(pendingCrv) / 1e12;
    }
}
