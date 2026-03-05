// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ICurveTriCrypto } from "../../interfaces/ICurveTriCrypto.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "../base/BaseSwapper.sol";

/// @title CrvToCrvUsdSwapper
/// @notice Swaps CRV rewards to crvUSD via Curve TriCrypto pool
/// @dev Used by PmUsdCrvUsdStrategy to compound CRV harvest rewards
contract CrvToCrvUsdSwapper is BaseSwapper {
    using SafeTransferLib for IERC20;

    uint256 public constant CRV_INDEX = 2;
    uint256 public constant CRVUSD_INDEX = 0;
    uint256 public constant MAX_CRV_ORACLE_STALENESS = 90000; // 25h — CRV/USD has 24h heartbeat
    uint256 public constant MAX_CRVUSD_ORACLE_STALENESS = 90000;

    IERC20 public immutable crv;
    IERC20 public immutable crvUSD;
    ICurveTriCrypto public immutable triCryptoPool;
    IChainlinkOracle public immutable crvOracle;
    IChainlinkOracle public immutable crvUsdOracle;

    event Swapped(uint256 crvIn, uint256 crvUsdOut);

    error SwapFailed();

    constructor(
        address _gov,
        address _crv,
        address _crvUsd,
        address _triCryptoPool,
        address _crvOracle,
        address _crvUsdOracle
    ) BaseSwapper(_gov) {
        if (
            _crv == address(0) || _crvUsd == address(0) || _triCryptoPool == address(0)
                || _crvOracle == address(0) || _crvUsdOracle == address(0)
        ) {
            revert ISwapper.InvalidAddress();
        }
        crv = IERC20(_crv);
        crvUSD = IERC20(_crvUsd);
        triCryptoPool = ICurveTriCrypto(_triCryptoPool);
        crvOracle = IChainlinkOracle(_crvOracle);
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
    }

    /// @notice Quote CRV -> crvUSD via Curve LP price (no Chainlink dependency)
    /// @param crvAmount Amount of CRV to quote
    /// @return crvUsdOut Expected crvUSD output
    function quote(uint256 crvAmount) external view returns (uint256 crvUsdOut) {
        if (crvAmount == 0) return 0;
        return triCryptoPool.get_dy(CRV_INDEX, CRVUSD_INDEX, crvAmount);
    }

    /// @notice Swap CRV held by this contract for crvUSD
    /// @dev Called by strategy after transferring CRV to this contract
    /// @param crvAmount Amount of CRV to swap
    /// @return crvUsdReceived Amount of crvUSD received
    function swap(uint256 crvAmount) external returns (uint256 crvUsdReceived) {
        if (crvAmount == 0) return 0;

        uint256 expectedOut = triCryptoPool.get_dy(CRV_INDEX, CRVUSD_INDEX, crvAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor: CRV and crvUSD are both 18-decimal ERC20 tokens
        uint256 oracleExpected = OracleLib.getCollateralValue(
            crvAmount, crvOracle, MAX_CRV_ORACLE_STALENESS, crvUsdOracle, MAX_CRVUSD_ORACLE_STALENESS, crv, crvUSD
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        crv.ensureApproval(address(triCryptoPool), crvAmount);
        crvUsdReceived = triCryptoPool.exchange(CRV_INDEX, CRVUSD_INDEX, crvAmount, minOut, false);

        // Transfer crvUSD back to caller
        crvUSD.safeTransfer(msg.sender, crvUsdReceived);

        emit Swapped(crvAmount, crvUsdReceived);
    }
}
