// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { IUniversalRouter } from "../../interfaces/IUniversalRouter.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { ICurveTriCrypto } from "../../interfaces/ICurveTriCrypto.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @dev Minimal wstETH interface for the V3-hop floor (stETH per wstETH, 1e18-scaled).
interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

/// @title UniswapMixedCurveSwapper
/// @notice Two-hop swapper: collateral ↔ WETH via Uniswap V3, WETH ↔ crvUSD via Curve TriCrypto.
/// @dev Designed for the LlamaLend wstETH/crvUSD vault.
///
///      Token flow — collateral (wstETH) → debt (crvUSD):
///        1. V3_SWAP_EXACT_IN  wstETH → WETH  (output to this contract)
///        2. Curve exchange    WETH   → crvUSD (TriCRV pool, use_eth=false)
///
///      Token flow — debt (crvUSD) → collateral (wstETH):
///        1. Curve exchange    crvUSD → WETH   (TriCRV pool, use_eth=false)
///        2. V3_SWAP_EXACT_IN  WETH   → wstETH (output to this contract)
contract UniswapMixedCurveSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    uint8 internal constant CMD_V3_SWAP_EXACT_IN = 0x00;

    /// @notice Swap inputs below this (in base units) execute with minOut = 0.
    uint256 public constant DUST_SWAP_THRESHOLD = 1000;

    IERC20 public immutable collateralToken; // wstETH
    IERC20 public immutable debtToken; // crvUSD
    IERC20 public immutable weth;
    IUniversalRouter public immutable universalRouter;

    /// @notice Curve TriCrypto pool (crvUSD/WETH/CRV at 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14).
    ICurveTriCrypto public immutable triCryptoPool;

    /// @notice Uniswap V3 fee tier for the collateral ↔ WETH pool (e.g. 100 = 0.01%).
    uint24 public immutable v3Fee;

    /// @notice WETH coin index in the Curve TriCrypto pool (1 for the TriCRV pool).
    uint256 public immutable wethCurveIndex;

    /// @notice crvUSD coin index in the Curve TriCrypto pool (0 for the TriCRV pool).
    uint256 public immutable crvUsdCurveIndex;

    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    uint256 public immutable maxCollateralOracleStaleness;

    /// @notice Max age for the crvUSD oracle — 25 h.
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90_000;

    constructor(
        address _gov,
        address _collateralToken, // wstETH
        address _debtToken, // crvUSD
        address _weth,
        address _universalRouter,
        uint24 _v3Fee, // 100 (0.01%)
        address _triCryptoPool, // 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14
        uint256 _wethCurveIndex, // 1 (WETH index in TriCRV)
        uint256 _crvUsdCurveIndex, // 0 (crvUSD index in TriCRV)
        address _collateralOracle,
        address _debtOracle,
        uint256 _maxCollateralStaleness
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0) || _weth == address(0)
                || _universalRouter == address(0) || _triCryptoPool == address(0)
                || _collateralOracle == address(0) || _debtOracle == address(0)
        ) revert InvalidAddress();
        if (_maxCollateralStaleness == 0) revert InvalidAddress();

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        weth = IERC20(_weth);
        universalRouter = IUniversalRouter(_universalRouter);
        triCryptoPool = ICurveTriCrypto(_triCryptoPool);
        v3Fee = _v3Fee;
        wethCurveIndex = _wethCurveIndex;
        crvUsdCurveIndex = _crvUsdCurveIndex;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
        maxCollateralOracleStaleness = _maxCollateralStaleness;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ISwapper
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ISwapper
    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralOut = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        if (collateralOut == 0) return 0;
        return (collateralOut * PRECISION) / (PRECISION - slippage) + 1;
    }

    /// @inheritdoc ISwapper
    /// @dev wstETH → WETH (V3) → crvUSD (Curve TriCrypto)
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;

        // Step 1: V3 — wstETH → WETH, output to this contract.
        // M-07: bound this hop by the exact wstETH→stETH protocol rate (stETH ≈ ETH ≈ WETH), so a
        // sandwich cannot drain more than `slippage` of WETH before the Curve leg. This uses the
        // wstETH:ETH relationship directly — NOT the crvUSD/composite path — so it does not hit the
        // peg/level divergence that over-constrains the final leg. Dust inputs keep minOut = 0.
        // SOFT call: this swapper also serves non-wstETH collateral (e.g. WBTC) that has no
        // stEthPerToken(). For wstETH it returns the exact wstETH→stETH rate and we bound the
        // hop; for other collateral the call fails and we leave minOut = 0 (the Curve get_dy
        // floor and the LoanManager end-to-end 95% floor still apply). M-07 targets the wstETH
        // vault specifically.
        uint256 v3MinOut;
        if (collateralAmount >= DUST_SWAP_THRESHOLD) {
            (bool ok, bytes memory data) =
                address(collateralToken).staticcall(abi.encodeWithSelector(IWstETH.stEthPerToken.selector));
            if (ok && data.length >= 32) {
                uint256 ratio = abi.decode(data, (uint256)); // stETH per wstETH (1e18)
                uint256 expectedWeth = (collateralAmount * ratio) / PRECISION; // stETH ≈ WETH (18 dec)
                if (expectedWeth > 0) v3MinOut = (expectedWeth * (PRECISION - slippage)) / PRECISION;
            }
        }
        collateralToken.safeTransfer(address(universalRouter), collateralAmount);
        {
            bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
            bytes[] memory inputs = new bytes[](1);
            bytes memory v3Path = abi.encodePacked(address(collateralToken), v3Fee, address(weth));
            inputs[0] = abi.encode(
                address(this), // recipient: WETH to this contract
                collateralAmount,
                v3MinOut, // amountOutMin: wstETH-rate floor (M-07); Curve step adds its own floor
                v3Path,
                false // payerIsUser: tokens were pre-transferred
            );
            universalRouter.execute(commands, inputs);
        }

        // Step 2: Curve TriCrypto — WETH → crvUSD.
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance == 0) return 0;

        // Per-hop slippage floor: use get_dy as best-effort estimate, fall back to 0 on failure.
        // get_dy can diverge from actual output on large swaps (EMA oracle), so this is soft
        // protection; the hard end-to-end floor is the loan manager's SwapperUnderperformed check
        // (95% of the oracle-implied value), which covers a sandwich on the amountOutMin=0 V3 hop.
        // A tighter swapper-level oracle floor was tried but over-constrains small swaps where the
        // oracle/pool price level diverges by more than `slippage` (crvUSD peg + composite vs spot).
        uint256 minCrvUsd;
        (bool ok, bytes memory dyData) = address(triCryptoPool)
            .staticcall(
                abi.encodeWithSelector(
                    ICurveTriCrypto.get_dy.selector, wethCurveIndex, crvUsdCurveIndex, wethBalance
                )
            );
        if (ok && dyData.length >= 32) {
            uint256 expected = abi.decode(dyData, (uint256));
            if (expected > 0) minCrvUsd = (expected * (PRECISION - slippage)) / PRECISION;
        }

        weth.ensureApproval(address(triCryptoPool), wethBalance);
        uint256 crvUsdBefore = debtToken.balanceOf(address(this));
        debtReceived =
            triCryptoPool.exchange(wethCurveIndex, crvUsdCurveIndex, wethBalance, minCrvUsd, false);
        // Fallback: some pools return 0 despite transferring tokens.
        if (debtReceived == 0) {
            uint256 crvUsdAfter = debtToken.balanceOf(address(this));
            debtReceived = crvUsdAfter > crvUsdBefore ? crvUsdAfter - crvUsdBefore : 0;
        }

        if (debtReceived > 0) {
            debtToken.safeTransfer(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    /// @dev crvUSD → WETH (Curve TriCrypto) → wstETH (V3)
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;

        uint256 expectedWstEth = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 minWstEth = expectedWstEth >= DUST_SWAP_THRESHOLD
            ? (expectedWstEth * (PRECISION - slippage)) / PRECISION
            : 0;

        // Step 1: Curve TriCrypto — crvUSD → WETH.
        debtToken.ensureApproval(address(triCryptoPool), debtAmount);
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 wethReceived =
            triCryptoPool.exchange(crvUsdCurveIndex, wethCurveIndex, debtAmount, 0, false);
        // Fallback: some pools return 0 despite transferring tokens.
        if (wethReceived == 0) {
            uint256 wethAfter = weth.balanceOf(address(this));
            wethReceived = wethAfter > wethBefore ? wethAfter - wethBefore : 0;
        }
        if (wethReceived == 0) return 0;

        // Step 2: V3 — WETH → wstETH, output to this contract.
        weth.safeTransfer(address(universalRouter), wethReceived);
        {
            bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
            bytes[] memory inputs = new bytes[](1);
            bytes memory v3Path = abi.encodePacked(address(weth), v3Fee, address(collateralToken));
            inputs[0] = abi.encode(
                address(this), // recipient: wstETH to this contract
                wethReceived, // exact WETH in
                minWstEth, // end-to-end oracle floor on final output
                v3Path,
                false // payerIsUser: tokens were pre-transferred
            );
            uint256 balanceBefore = collateralToken.balanceOf(address(this));
            universalRouter.execute(commands, inputs);
            collateralReceived = collateralToken.balanceOf(address(this)) - balanceBefore;
        }

        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }
}
