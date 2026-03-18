// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ICurveThreeCrypto } from "../../interfaces/ICurveThreeCrypto.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title CurveThreeCryptoSwapper
/// @notice Swapper for Curve TriCrypto-style pools (3-token crypto pools)
contract CurveThreeCryptoSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    ICurveThreeCrypto public immutable pool;
    uint256 public immutable collateralIndex;
    uint256 public immutable debtIndex;
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    uint256 public constant MAX_COLLATERAL_ORACLE_STALENESS = 3600;
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000;

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _pool,
        uint256 _collateralIndex,
        uint256 _debtIndex,
        address _collateralOracle,
        address _debtOracle
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0) || _pool == address(0)
                || _collateralOracle == address(0) || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        pool = ICurveThreeCrypto(_pool);
        collateralIndex = _collateralIndex;
        debtIndex = _debtIndex;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
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

        // Oracle floor
        uint256 oracleExpected = OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        collateralToken.ensureApproval(address(pool), collateralAmount);
        uint256 balanceBefore = debtToken.balanceOf(address(this));
        debtReceived = _exchange(
            collateralIndex, debtIndex, collateralAmount, minOut, debtToken, balanceBefore
        );
        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;
        uint256 expectedOut = pool.get_dy(debtIndex, collateralIndex, debtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor
        uint256 oracleExpected = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        debtToken.ensureApproval(address(pool), debtAmount);
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralReceived = _exchange(
            debtIndex, collateralIndex, debtAmount, minOut, collateralToken, balanceBefore
        );
        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }

    function _exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minOut,
        IERC20 outToken,
        uint256 balanceBefore
    ) private returns (uint256 amountOut) {
        try pool.exchange(i, j, dx, minOut, false) returns (uint256 outAmount) {
            amountOut = outAmount;
        } catch {
            revert TransferFailed();
        }

        // Some Curve pools historically returned no value; fall back to balance delta when zero
        if (amountOut == 0) {
            uint256 balanceAfter = outToken.balanceOf(address(this));
            amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }
    }

    function _safeTransferDebt(address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(debtToken).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();
        if (data.length >= 32 && !abi.decode(data, (bool))) {
            revert TransferFailed();
        }
    }
}
