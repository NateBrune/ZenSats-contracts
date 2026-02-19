// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { ICurveTwoCrypto } from "../../interfaces/ICurveTwoCrypto.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title CurveTwoCryptoSwapper
/// @notice Simple swapper for Curve TwoCrypto pools
contract CurveTwoCryptoSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    ICurveTwoCrypto public immutable pool;
    uint256 public immutable collateralIndex;
    uint256 public immutable debtIndex;

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _pool,
        uint256 _collateralIndex,
        uint256 _debtIndex
    ) BaseSwapper(_gov) {
        if (_collateralToken == address(0) || _debtToken == address(0) || _pool == address(0)) {
            revert InvalidAddress();
        }
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        pool = ICurveTwoCrypto(_pool);
        collateralIndex = _collateralIndex;
        debtIndex = _debtIndex;
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
        if (collateralOut == 0) return 0;
        return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;
        uint256 expectedOut = pool.get_dy(collateralIndex, debtIndex, collateralAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        collateralToken.ensureApproval(address(pool), collateralAmount);
        debtReceived =
            pool.exchange(collateralIndex, debtIndex, collateralAmount, minOut, msg.sender);
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;
        uint256 expectedOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        debtToken.ensureApproval(address(pool), debtAmount);
        collateralReceived =
            pool.exchange(debtIndex, collateralIndex, debtAmount, minOut, msg.sender);
    }
}
