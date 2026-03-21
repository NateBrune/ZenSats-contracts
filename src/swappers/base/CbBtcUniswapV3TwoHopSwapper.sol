// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { ISwapRouter } from "../../interfaces/ISwapRouter.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title CbBtcUniswapV3TwoHopSwapper
/// @notice Two-hop Uniswap V3 swapper (cbBTC <-> WBTC <-> USDT) with slower collateral oracle cadence
contract CbBtcUniswapV3TwoHopSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    address public immutable weth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable fee1;
    uint24 public immutable fee2;
    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    uint256 public constant MAX_COLLATERAL_ORACLE_STALENESS = 90000; // 25h
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90000; // 25h

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _weth,
        address _swapRouter,
        uint24 _fee1,
        uint24 _fee2,
        address _collateralOracle,
        address _debtOracle
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0) || _weth == address(0)
                || _swapRouter == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) {
            revert InvalidAddress();
        }
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        weth = _weth;
        swapRouter = ISwapRouter(_swapRouter);
        fee1 = _fee1;
        fee2 = _fee2;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
    }

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

    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
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
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        bytes memory path =
            abi.encodePacked(address(collateralToken), fee1, weth, fee2, address(debtToken));

        collateralToken.ensureApproval(address(swapRouter), collateralAmount);

        uint256 balanceBefore = debtToken.balanceOf(address(this));
        swapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: collateralAmount,
                amountOutMinimum: minOut
            })
        );
        debtReceived = debtToken.balanceOf(address(this)) - balanceBefore;

        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
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

        bytes memory path =
            abi.encodePacked(address(debtToken), fee2, weth, fee1, address(collateralToken));

        debtToken.ensureApproval(address(swapRouter), debtAmount);

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        swapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path, recipient: address(this), amountIn: debtAmount, amountOutMinimum: minOut
            })
        );
        collateralReceived = collateralToken.balanceOf(address(this)) - balanceBefore;

        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
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
