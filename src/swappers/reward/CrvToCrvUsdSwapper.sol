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

    address public authorizedCaller;

    event Swapped(uint256 crvIn, uint256 crvUsdOut);
    event AuthorizedCallerUpdated(address indexed caller);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

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

    /// @notice Set the authorized caller for swap()
    function setAuthorizedCaller(address caller) external onlyGov {
        if (caller == address(0)) revert ISwapper.InvalidAddress();
        authorizedCaller = caller;
        emit AuthorizedCallerUpdated(caller);
    }

    /// @notice Set slippage — callable by gov, vault, or the authorized caller (strategy).
    /// @dev Overrides BaseSwapper to also allow the authorizedCaller so the strategy can
    ///      propagate vault-level slippage changes without needing a separate vault registration.
    function setSlippage(uint256 newSlippage) external override {
        if (msg.sender != gov && msg.sender != vault && msg.sender != authorizedCaller) {
            revert Unauthorized();
        }
        if (newSlippage == 0 || newSlippage >= PRECISION) revert InvalidSlippage();
        slippage = newSlippage;
        emit SlippageUpdated(newSlippage);
    }

    /// @notice Rescue tokens stuck in the swapper (gov-only)
    function rescueToken(address token, address to, uint256 amount) external onlyGov {
        if (to == address(0)) revert ISwapper.InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
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
        if (authorizedCaller != address(0) && msg.sender != authorizedCaller) {
            revert Unauthorized();
        }
        if (crvAmount == 0) return 0;

        uint256 expectedOut = triCryptoPool.get_dy(CRV_INDEX, CRVUSD_INDEX, crvAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor: CRV and crvUSD are both 18-decimal ERC20 tokens
        uint256 oracleExpected = OracleLib.getCollateralValue(
            crvAmount,
            crvOracle,
            MAX_CRV_ORACLE_STALENESS,
            crvUsdOracle,
            MAX_CRVUSD_ORACLE_STALENESS,
            crv,
            crvUSD
        );
        uint256 oracleMinOut = (oracleExpected * (PRECISION - slippage)) / PRECISION;
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        crv.ensureApproval(address(triCryptoPool), crvAmount);
        uint256 balanceBefore = crvUSD.balanceOf(address(this));
        crvUsdReceived = triCryptoPool.exchange(CRV_INDEX, CRVUSD_INDEX, crvAmount, minOut, false);

        // Fallback: older pools may return 0 despite transferring tokens
        if (crvUsdReceived == 0) {
            uint256 balanceAfter = crvUSD.balanceOf(address(this));
            crvUsdReceived = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }

        // Transfer crvUSD back to caller
        if (crvUsdReceived > 0) {
            crvUSD.safeTransfer(msg.sender, crvUsdReceived);
        }

        emit Swapped(crvAmount, crvUsdReceived);
    }
}
