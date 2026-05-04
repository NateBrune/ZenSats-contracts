// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../../interfaces/IERC20.sol";
import { ISwapper } from "../../interfaces/ISwapper.sol";
import { IUniversalRouter } from "../../interfaces/IUniversalRouter.sol";
import { IChainlinkOracle } from "../../interfaces/IChainlinkOracle.sol";
import { OracleLib } from "../../libraries/OracleLib.sol";
import { SafeTransferLib } from "../../libraries/SafeTransferLib.sol";
import { BaseSwapper } from "./BaseSwapper.sol";

/// @title UniswapMixedTwoHopSwapper
/// @notice Two-hop swapper: collateral ↔ WETH via Uniswap V3, ETH ↔ debt via Uniswap V4.
/// @dev Hop 1: V3 pool  (collateral / WETH, fee = v3Fee)
///      Hop 2: V4 pool  (native ETH / debt,  fee = v4Fee)
///      Between hops: WETH is unwrapped to ETH (collateral→debt) or ETH is wrapped to WETH
///      (debt→collateral).  All three steps are batched in a single Universal Router execute().
///
///      Token flow — collateral → debt:
///        1. V3_SWAP_EXACT_IN   collateral → WETH  (output stays in router)
///        2. UNWRAP_WETH        WETH → native ETH  (stays in router)
///        3. V4_SWAP            ETH  → debt        (debt sent to this contract)
///
///      Token flow — debt → collateral:
///        1. V4_SWAP            debt → native ETH  (ETH stays in router)
///        2. WRAP_ETH           ETH  → WETH        (stays in router)
///        3. V3_SWAP_EXACT_IN   WETH → collateral  (collateral sent to this contract)
contract UniswapMixedTwoHopSwapper is BaseSwapper, ISwapper {
    using SafeTransferLib for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    //  Universal Router top-level command bytes  (Commands.sol)
    // ─────────────────────────────────────────────────────────────────────────
    uint8 internal constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant CMD_WRAP_ETH = 0x0b;
    uint8 internal constant CMD_UNWRAP_WETH = 0x0c;
    uint8 internal constant CMD_V4_SWAP = 0x10;

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 action codes  (Actions.sol)
    // ─────────────────────────────────────────────────────────────────────────
    uint8 internal constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACT_SETTLE = 0x0b;
    uint8 internal constant ACT_TAKE = 0x0e;
    uint8 internal constant ACT_TAKE_ALL = 0x0f;

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 ActionConstants  (ActionConstants.sol)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev amountIn / settle-amount sentinel: resolve to the full open delta for this currency.
    uint128 internal constant OPEN_DELTA = 0;

    /// @dev amount sentinel: use the full token (or ETH) balance of this contract.
    uint256 internal constant CONTRACT_BALANCE =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @dev recipient sentinel: address(this) within the V4 router — maps to the Universal Router.
    address internal constant ADDRESS_THIS = address(2);

    // ─────────────────────────────────────────────────────────────────────────
    //  Dust threshold
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Swap inputs below this (in base units) execute with minOut = 0.
    ///         Mirrors AaveLoanManager.DUST_SWAP_THRESHOLD — integer fee rounding
    ///         in small swaps makes any oracle-based floor unreliable.
    uint256 public constant DUST_SWAP_THRESHOLD = 1000;

    // ─────────────────────────────────────────────────────────────────────────
    //  Immutables
    // ─────────────────────────────────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    address public immutable weth;
    IUniversalRouter public immutable universalRouter;

    /// @notice Uniswap V3 fee tier for the collateral ↔ WETH pool (e.g. 100 = 0.01 %).
    uint24 public immutable v3Fee;

    /// @notice Uniswap V4 fee tier for the ETH ↔ debt pool (e.g. 500 = 0.05 %).
    uint24 public immutable v4Fee;

    /// @notice Tick spacing of the V4 pool (e.g. 10 for a 0.05 % pool).
    int24 public immutable v4TickSpacing;

    IChainlinkOracle public immutable collateralOracle;
    IChainlinkOracle public immutable debtOracle;

    /// @notice Max age (seconds) for collateral-oracle answers.
    uint256 public immutable maxCollateralOracleStaleness;

    /// @notice Max age for the debt (USDT/USD) oracle — 25 h to accommodate weekends.
    uint256 public constant MAX_DEBT_ORACLE_STALENESS = 90_000;

    // ─────────────────────────────────────────────────────────────────────────
    //  Pre-computed V4 PoolKey fields
    //  (stored individually to avoid a dependency on v4-core Currency / IHooks)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev currency0 of the V4 pool = native ETH = address(0).  Always the lower address.
    address internal immutable v4Currency0; // address(0)

    /// @dev currency1 of the V4 pool = debtToken (USDT).
    address internal immutable v4Currency1;

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _gov,
        address _collateralToken,
        address _debtToken,
        address _weth,
        address _universalRouter,
        uint24 _v3Fee,
        uint24 _v4Fee,
        int24 _v4TickSpacing,
        address _collateralOracle,
        address _debtOracle,
        uint256 _maxCollateralStaleness
    ) BaseSwapper(_gov) {
        if (
            _collateralToken == address(0) || _debtToken == address(0) || _weth == address(0)
                || _universalRouter == address(0) || _collateralOracle == address(0)
                || _debtOracle == address(0)
        ) revert InvalidAddress();
        if (_maxCollateralStaleness == 0) revert InvalidAddress();

        // V4 PoolKey requires currency0 < currency1 by address value.
        // Native ETH (address(0)) is always the lowest possible address, so any ERC-20
        // debt token satisfies this constraint automatically.

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        weth = _weth;
        universalRouter = IUniversalRouter(_universalRouter);
        v3Fee = _v3Fee;
        v4Fee = _v4Fee;
        v4TickSpacing = _v4TickSpacing;
        collateralOracle = IChainlinkOracle(_collateralOracle);
        debtOracle = IChainlinkOracle(_debtOracle);
        maxCollateralOracleStaleness = _maxCollateralStaleness;

        v4Currency0 = address(0); // native ETH
        v4Currency1 = _debtToken; // USDT
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
    /// @dev collateral → WETH (V3) → ETH (unwrap) → debt (V4)
    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        if (collateralAmount == 0) return 0;

        uint256 expectedOut = OracleLib.getCollateralValue(
            collateralAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 minOut = collateralAmount >= DUST_SWAP_THRESHOLD
            ? (expectedOut * (PRECISION - slippage)) / PRECISION
            : 0;

        // Push collateral directly to the Universal Router (no ERC-20 approval needed).
        collateralToken.safeTransfer(address(universalRouter), collateralAmount);

        bytes memory commands =
            abi.encodePacked(CMD_V3_SWAP_EXACT_IN, CMD_UNWRAP_WETH, CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](3);

        // 1. V3: collateral → WETH, output remains in the router for the next step.
        bytes memory v3Path = abi.encodePacked(address(collateralToken), v3Fee, weth);
        inputs[0] = abi.encode(
            address(universalRouter), // recipient: keep WETH in router
            collateralAmount, // amountIn
            uint256(0), // amountOutMin: 0 — the V4 step enforces the overall minOut
            v3Path,
            false // payerIsUser: tokens were pre-transferred to the router
        );

        // 2. UNWRAP_WETH: all WETH in the router → native ETH, stays in the router.
        inputs[1] = abi.encode(
            address(universalRouter), // recipient: ETH stays in router
            uint256(0) // amountMin: 0
        );

        // 3. V4_SWAP: ETH → debt.
        //    Sequence inside the V4 lock:
        //      SETTLE(ETH, CONTRACT_BALANCE)  →  creates +ETH credit equal to router's ETH balance
        //      SWAP_EXACT_IN_SINGLE(ETH→debt, amountIn=OPEN_DELTA)  →  uses that credit
        //      TAKE_ALL(debt)  →  debt sent to msgSender() = this swapper
        uint128 minOut128 = minOut > type(uint128).max ? type(uint128).max : uint128(minOut);
        inputs[2] = _buildV4CollateralToDebt(minOut128);

        uint256 balanceBefore = debtToken.balanceOf(address(this));
        universalRouter.execute(commands, inputs);
        debtReceived = debtToken.balanceOf(address(this)) - balanceBefore;

        if (debtReceived > 0) {
            _safeTransferDebt(msg.sender, debtReceived);
        }
    }

    /// @inheritdoc ISwapper
    /// @dev debt → ETH (V4) → WETH (wrap) → collateral (V3)
    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        if (debtAmount == 0) return 0;

        uint256 expectedOut = OracleLib.getDebtValue(
            debtAmount,
            collateralOracle,
            maxCollateralOracleStaleness,
            debtOracle,
            MAX_DEBT_ORACLE_STALENESS,
            collateralToken,
            debtToken
        );
        uint256 minOut = expectedOut >= DUST_SWAP_THRESHOLD
            ? (expectedOut * (PRECISION - slippage)) / PRECISION
            : 0;

        // Push debt token directly to the Universal Router.
        debtToken.safeTransfer(address(universalRouter), debtAmount);

        bytes memory commands =
            abi.encodePacked(CMD_V4_SWAP, CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](3);

        // 1. V4_SWAP: debt → ETH, native ETH output goes to the Universal Router.
        //    Sequence inside the V4 lock:
        //      SWAP_EXACT_IN_SINGLE(debt→ETH, amountIn=debtAmount)
        //      SETTLE(debt, OPEN_DELTA)   →  router pays its debt-token balance to the pool
        //      TAKE(ETH, ADDRESS_THIS)    →  ETH credit sent to the Universal Router
        uint128 debtAmount128 =
            debtAmount > type(uint128).max ? type(uint128).max : uint128(debtAmount);
        inputs[0] = _buildV4DebtToCollateral(debtAmount128);

        // 2. WRAP_ETH: all native ETH in the router → WETH, stays in the router.
        inputs[1] = abi.encode(
            address(universalRouter), // recipient: keep WETH in router
            CONTRACT_BALANCE // amount: wrap everything
        );

        // 3. V3: WETH → collateral, output goes to this contract.
        //    amountIn = CONTRACT_BALANCE so the router uses whatever WETH it received from WRAP_ETH.
        bytes memory v3Path = abi.encodePacked(weth, v3Fee, address(collateralToken));
        inputs[2] = abi.encode(
            address(this), // recipient: collateral sent to swapper
            CONTRACT_BALANCE, // amountIn: use all WETH (amount unknown ahead of time)
            minOut, // amountOutMin: collateral slippage check
            v3Path,
            false // payerIsUser: tokens were pre-transferred to router
        );

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        universalRouter.execute(commands, inputs);
        collateralReceived = collateralToken.balanceOf(address(this)) - balanceBefore;

        if (collateralReceived > 0) {
            collateralToken.safeTransfer(msg.sender, collateralReceived);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Build the V4_SWAP input bytes for the ETH → debt direction.
    ///
    ///      Action sequence:
    ///        1. SETTLE(ETH, CONTRACT_BALANCE, payerIsUser=false)
    ///           Router's entire ETH balance is settled to the pool manager,
    ///           creating a positive ETH delta (credit) in the V4 accounting.
    ///        2. SWAP_EXACT_IN_SINGLE(ETH→debt, amountIn=OPEN_DELTA, amountOutMin=minOut)
    ///           OPEN_DELTA resolves to _getFullCredit(ETH) = the amount just settled.
    ///        3. TAKE_ALL(debt, minAmount=0)
    ///           Sends the full debt credit to msgSender() (= this swapper).
    ///           The amountOutMinimum in the SWAP already enforces slippage.
    function _buildV4CollateralToDebt(uint128 minAmountOut)
        internal
        view
        returns (bytes memory)
    {
        bytes memory v4Actions =
            abi.encodePacked(ACT_SETTLE, ACT_SWAP_EXACT_IN_SINGLE, ACT_TAKE_ALL);

        bytes[] memory v4Params = new bytes[](3);

        // SETTLE(currency=ETH, amount=CONTRACT_BALANCE, payerIsUser=false)
        v4Params[0] = abi.encode(v4Currency0, CONTRACT_BALANCE, false);

        // SWAP_EXACT_IN_SINGLE(zeroForOne=true [ETH→debt], amountIn=OPEN_DELTA, amountOutMin)
        v4Params[1] = _encodeExactInSingle(
            true, // zeroForOne: ETH is currency0
            OPEN_DELTA, // amountIn: resolve to full ETH credit from SETTLE
            minAmountOut
        );

        // TAKE_ALL(currency=debt, minAmount=0) → sent to msgSender() = this swapper
        v4Params[2] = abi.encode(v4Currency1, uint256(0));

        return abi.encode(v4Actions, v4Params);
    }

    /// @dev Build the V4_SWAP input bytes for the debt → ETH direction.
    ///
    ///      Action sequence:
    ///        1. SWAP_EXACT_IN_SINGLE(debt→ETH, amountIn=debtAmount, amountOutMin=0)
    ///           Creates a negative debt delta (you owe) and positive ETH delta (credit).
    ///           No per-hop slippage check here — the final wstETH output (V3) is what matters.
    ///        2. SETTLE(debt, OPEN_DELTA, payerIsUser=false)
    ///           OPEN_DELTA resolves to _getFullDebt(debt) = debtAmount.
    ///           Router pays its debt-token balance to the pool manager.
    ///        3. TAKE(ETH, ADDRESS_THIS, OPEN_DELTA)
    ///           ADDRESS_THIS maps to the Universal Router.
    ///           OPEN_DELTA resolves to _getFullCredit(ETH) = ethOut from the swap.
    ///           Native ETH is sent to the router for the subsequent WRAP_ETH command.
    function _buildV4DebtToCollateral(uint128 amountIn)
        internal
        view
        returns (bytes memory)
    {
        bytes memory v4Actions =
            abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE);

        bytes[] memory v4Params = new bytes[](3);

        // SWAP_EXACT_IN_SINGLE(zeroForOne=false [debt→ETH], amountIn, amountOutMin=0)
        v4Params[0] = _encodeExactInSingle(
            false, // zeroForOne=false: debt is currency1, ETH is currency0
            amountIn, // exact debt input
            0 // amountOutMin: slippage enforced on wstETH output in the V3 step
        );

        // SETTLE(currency=debt, amount=OPEN_DELTA=0, payerIsUser=false)
        // OPEN_DELTA → _getFullDebt(debt) = amountIn (the swap just created this debt)
        v4Params[1] = abi.encode(v4Currency1, uint256(0), false);

        // TAKE(currency=ETH, recipient=ADDRESS_THIS, amount=OPEN_DELTA=0)
        // ADDRESS_THIS → Universal Router;  OPEN_DELTA → _getFullCredit(ETH) = ethOut
        v4Params[2] = abi.encode(v4Currency0, ADDRESS_THIS, uint256(0));

        return abi.encode(v4Actions, v4Params);
    }

    /// @dev ABI-encode an IV4Router.ExactInputSingleParams without importing v4-core types.
    ///
    ///      The V4 router decodes this via a raw calldata pointer cast, so the layout must
    ///      exactly match the ABI encoding of IV4Router.ExactInputSingleParams:
    ///
    ///        PoolKey {
    ///          Currency currency0   (address, 32 bytes)
    ///          Currency currency1   (address, 32 bytes)
    ///          uint24   fee         (32 bytes, padded)
    ///          int24    tickSpacing (32 bytes, padded)
    ///          IHooks   hooks       (address, 32 bytes)
    ///        }
    ///        bool    zeroForOne        (32 bytes)
    ///        uint128 amountIn          (32 bytes)
    ///        uint128 amountOutMinimum  (32 bytes)
    ///        uint256 minHopPriceX36    (32 bytes) — 0 = no per-hop price limit
    ///        bytes   hookData          (dynamic, empty)
    ///
    ///      abi.encode of 10 values (9 static + 1 dynamic bytes) produces:
    ///        head: 9 × 32 static fields + 1 × 32 offset pointer = 320 bytes
    ///        tail: 32 bytes length (= 0) for the empty hookData
    ///      Total: 352 bytes.
    function _encodeExactInSingle(bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            v4Currency0, // PoolKey.currency0  (ETH)
            v4Currency1, // PoolKey.currency1  (debt)
            v4Fee, // PoolKey.fee
            v4TickSpacing, // PoolKey.tickSpacing
            address(0), // PoolKey.hooks  (none)
            zeroForOne,
            amountIn,
            amountOutMinimum,
            uint256(0), // minHopPriceX36 = 0
            bytes("") // hookData = empty (makes this a dynamic tuple)
        );
    }

    /// @dev USDT-safe transfer — USDT on mainnet does not return a bool.
    function _safeTransferDebt(address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(debtToken).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();
        if (data.length >= 32 && !abi.decode(data, (bool))) revert TransferFailed();
    }
}
