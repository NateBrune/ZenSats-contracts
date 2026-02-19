// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "../../interfaces/IERC20.sol";
import {ICurveTriCrypto} from "../../interfaces/ICurveTriCrypto.sol";
import {ISwapper} from "../../interfaces/ISwapper.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {BaseSwapper} from "../base/BaseSwapper.sol";

/// @title CrvToCrvUsdSwapper
/// @notice Swaps CRV rewards to crvUSD via Curve TriCrypto pool
/// @dev Used by PmUsdCrvUsdStrategy to compound CRV harvest rewards
contract CrvToCrvUsdSwapper is BaseSwapper {
    using SafeTransferLib for IERC20;

    uint256 public constant CRV_INDEX = 2;
    uint256 public constant CRVUSD_INDEX = 0;

    IERC20 public immutable crv;
    IERC20 public immutable crvUSD;
    ICurveTriCrypto public immutable triCryptoPool;

    event Swapped(uint256 crvIn, uint256 crvUsdOut);

    error SwapFailed();

    constructor(address _gov, address _crv, address _crvUsd, address _triCryptoPool)
        BaseSwapper(_gov)
    {
        if (_crv == address(0) || _crvUsd == address(0) || _triCryptoPool == address(0)) {
            revert ISwapper.InvalidAddress();
        }
        crv = IERC20(_crv);
        crvUSD = IERC20(_crvUsd);
        triCryptoPool = ICurveTriCrypto(_triCryptoPool);
    }

    /// @notice Swap CRV held by this contract for crvUSD
    /// @dev Called by strategy after transferring CRV to this contract
    /// @param crvAmount Amount of CRV to swap
    /// @return crvUsdReceived Amount of crvUSD received
    function swap(uint256 crvAmount) external returns (uint256 crvUsdReceived) {
        if (crvAmount == 0) return 0;

        uint256 expectedOut = triCryptoPool.get_dy(CRV_INDEX, CRVUSD_INDEX, crvAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        crv.ensureApproval(address(triCryptoPool), crvAmount);
        crvUsdReceived = triCryptoPool.exchange(CRV_INDEX, CRVUSD_INDEX, crvAmount, minOut, false);

        // Transfer crvUSD back to caller
        crvUSD.safeTransfer(msg.sender, crvUsdReceived);

        emit Swapped(crvAmount, crvUsdReceived);
    }
}
