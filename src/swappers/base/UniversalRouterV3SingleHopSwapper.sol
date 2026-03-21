// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { IUniversalRouter } from "../../interfaces/IUniversalRouter.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title UniversalRouterV3SingleHopSwapper
/// @notice Single-hop swapper using Uniswap Universal Router v2 command VM and a v3 pool path
contract UniversalRouterV3SingleHopSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    uint8 internal constant CMD_V3_SWAP_EXACT_IN = 0x00;
    /// @notice Collateral amounts below this (in collateral base units) swap with minOut=0.
    /// Matches AaveLoanManager.DUST_SWAP_THRESHOLD. See that constant for rationale.
    uint256 public constant DUST_SWAP_THRESHOLD = 1000;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    IUniversalRouter public immutable universalRouter;
    uint24 public immutable poolFee;
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    uint256 public constant MAX_COLLATERAL_ORACLE_STALENESS = 3600;
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000;

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _universalRouter,
        uint24 _poolFee,
        address _collateralOracle,
        address _debtOracle
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0)
                || _universalRouter == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        universalRouter = IUniversalRouter(_universalRouter);
        poolFee = _poolFee;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
    }

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;

        uint256 collateralOut = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        if (collateralOut == 0) return 0;

        return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
    }

    /// @inheritdoc ISwapper
    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256 debtReceived) {
        if (collateralAmount == 0) return 0;

        uint256 expectedOut = OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        // Waive minOut for dust amounts: integer fee rounding in the V3 pool produces
        // an effective fee >> 0.3% at tiny inputs, making any oracle-based floor unreliable.
        uint256 minOut = collateralAmount >= DUST_SWAP_THRESHOLD
            ? (expectedOut * (PRECISION - slippage)) / PRECISION
            : 0;

        collateralToken.safeTransfer(address(universalRouter), collateralAmount);

        bytes memory path = abi.encodePacked(address(collateralToken), poolFee, address(debtToken));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), collateralAmount, minOut, path, false);

        uint256 balanceBefore = debtToken.balanceOf(address(this));
        universalRouter.execute(bytes.concat(bytes1(CMD_V3_SWAP_EXACT_IN)), inputs);
        debtReceived = debtToken.balanceOf(address(this)) - balanceBefore;

        if (debtReceived > 0) {
            debtToken.safeTransfer(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256 collateralReceived) {
        if (debtAmount == 0) return 0;

        uint256 expectedOut = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            MAX_COLLATERAL_ORACLE_STALENESS,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        debtToken.safeTransfer(address(universalRouter), debtAmount);

        bytes memory path = abi.encodePacked(address(debtToken), poolFee, address(collateralToken));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), debtAmount, minOut, path, false);

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        universalRouter.execute(bytes.concat(bytes1(CMD_V3_SWAP_EXACT_IN)), inputs);
        collateralReceived = collateralToken.balanceOf(address(this)) - balanceBefore;

        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }
}
