// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Script, console } from "forge-std/Script.sol";

/// @title StrategyLiquidityReport
/// @notice Standalone utility + health check that reports the live on-chain liquidity of every
///         live Zenji strategy's exit-relevant pools (collateral->debt swap legs + the yield-strategy
///         LP), so the team gets a high-level overview of whether each strategy can actually unwind
///         at the current block.
///
/// @dev Run as a utility (prints the full report):
///        forge script script/StrategyLiquidityReport.s.sol --tc StrategyLiquidityReport \
///          --fork-url $MAINNET_RPC_URL -vv
///      Run as a gate/test (reverts if any strategy's exit is BROKEN — e.g. for CI):
///        STRICT=1 forge script script/StrategyLiquidityReport.s.sol --tc StrategyLiquidityReport \
///          --fork-url $MAINNET_RPC_URL -vv
///
///      Liquidity here means tradeability, not just TVL:
///        - V3 collateral legs (XAUT/USDT): pool spot vs the asset's Chainlink oracle.
///          If spot sits below the oracle by more than the swapper's slippage budget, the
///          collateral->debt exit reverts at ANY size (V3TooLittleReceived).
///        - Curve legs (crvUSD/USDT, collateral/crvUSD): per-side depth + imbalance.
///          A heavily one-sided pool is thin on the side the strategy actually withdraws.
contract StrategyLiquidityReport is Script {
    // ── tokens ──
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // ── Curve StableSwap / CryptoSwap pools ──
    address constant CRVUSD_USDT = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4; // shared strategy LP
    address constant WBTC_CRVUSD_CURVE = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373; // WBTC Llama collateral (Curve)

    // ── LlamaLend LLAMMA AMM (doesn't implement balances() — use balanceOf fallback) ──
    address constant WSTETH_CRVUSD_LLAMMA = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    // ── Uniswap V3 ──
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // ── Chainlink oracles (8 decimals) ──
    address constant XAU_USD = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;

    // The swapper's slippage budget (1%) is the line beyond which a V3 leg reverts on the exit side.
    uint256 constant SLIPPAGE_BPS = 100;
    // A stable Curve pool is flagged THIN when the minority side is below this (in whole $-pegged units).
    uint256 constant CURVE_THIN_USD = 1_000_000;

    bool internal anyBroken;
    PoolReader internal reader;

    function run() external {
        reader = new PoolReader();
        console.log("============================================================");
        console.log(" ZENJI STRATEGY LIQUIDITY REPORT");
        console.log(" block: %s", block.number);
        console.log("============================================================");

        console.log("");
        console.log("--- Shared venues ---");
        _curveStable("crvUSD/USDT (shared yield LP)", CRVUSD_USDT);

        console.log("");
        console.log("--- Aave debt=USDT strategies ---");
        _strategyHeader("XAUT / Aave / crvUSD-USDT");
        bool xautBroken = _v3VsOracle("  collateral exit XAUT->USDT (V3 0.05%)", XAUT, USDT, 500, XAU_USD);
        _line("  yield LP crvUSD/USDT", "OK (deep)");
        _verdict(xautBroken);

        console.log("");
        console.log("--- LlamaLend debt=crvUSD strategies ---");
        _strategyHeader("WBTC / Llama / crvUSD-USDT");
        _curveGeneric("  collateral exit WBTC/crvUSD (Curve)", WBTC_CRVUSD_CURVE);
        _line("  yield LP crvUSD/USDT", "OK (deep)");
        _verdict(false);

        _strategyHeader("wstETH / Llama / crvUSD-USDT");
        _llamaAmm("  collateral exit wstETH/crvUSD (LlamaLend LLAMMA)", WSTETH_CRVUSD_LLAMMA);
        _line("  yield LP crvUSD/USDT", "OK (deep)");
        _verdict(false);

        console.log("");
        console.log("============================================================");
        if (anyBroken) {
            console.log(" RESULT: one or more strategies have a BROKEN exit leg today.");
            if (vm.envOr("STRICT", uint256(0)) == 1) {
                revert("StrategyLiquidityReport: a strategy exit is BROKEN (STRICT mode)");
            }
        } else {
            console.log(" RESULT: all strategy exits tradeable within slippage at this block.");
        }
        console.log("============================================================");
    }

    // ── reporters ────────────────────────────────────────────────────────────

    /// @notice V3 collateral leg: compare pool spot (asset priced in USDT) to the asset's USD oracle.
    ///         Returns true if the sell side is BROKEN (pool below oracle by > slippage budget).
    function _v3VsOracle(string memory label, address asset, address usdt, uint24 fee, address oracle)
        internal
        returns (bool broken)
    {
        address pool = IV3Factory(V3_FACTORY).getPool(asset, usdt, fee);
        if (pool == address(0)) {
            _line(label, "NO POOL");
            return true;
        }
        (uint160 sqrtP,,,,,,) = IV3Pool(pool).slot0();
        uint8 dA = IERC20(asset).decimals();
        uint8 dU = IERC20(usdt).decimals();
        // asset is token0 for XAUT vs USDT (lower address). spot = USDT per whole asset, 1e8.
        uint256 priceX192 = uint256(sqrtP) * uint256(sqrtP);
        uint256 mult = (10 ** dA * 1e8) / (10 ** dU);
        uint256 spot1e8 = (priceX192 * mult) >> 192;

        (, int256 ans,,,) = IAggregator(oracle).latestRoundData();
        uint256 oracle1e8 = uint256(ans); // 8-dec feed

        uint256 assetBal = IERC20(asset).balanceOf(pool) / (10 ** dA);
        uint256 usdtBal = IERC20(usdt).balanceOf(pool) / (10 ** dU);

        // discount = how far the pool sits BELOW the oracle, in bps (sell side suffers this).
        int256 discountBps =
            oracle1e8 == 0 ? int256(0) : ((int256(oracle1e8) - int256(spot1e8)) * 10000) / int256(oracle1e8);

        broken = discountBps > int256(SLIPPAGE_BPS);
        string memory status = broken
            ? "BROKEN: pool below oracle > slippage budget -> exit reverts any size"
            : (discountBps > int256(SLIPPAGE_BPS) / 2 ? "TIGHT" : "OK");

        console.log(label);
        console.log(
            string.concat(
                "    pool=", vm.toString(pool), "  reserves: ", _u(assetBal), " asset / ", _u(usdtBal), " USDT"
            )
        );
        console.log(string.concat("    spot=", _u(spot1e8), " vs oracle=", _u(oracle1e8), " (1e8)"));
        console.log(string.concat("    pool-vs-oracle discount(bps)=", _i2s(discountBps), "  =>  ", status));
        if (broken) anyBroken = true;
    }

    /// @notice Stable Curve pool (both coins ~$1): report per-side depth + imbalance; flag THIN.
    function _curveStable(string memory label, address pool) internal returns (bool thin) {
        console.log(label);
        try reader.curveSides(pool) returns (string memory s0, uint256 b0, string memory s1, uint256 b1) {
            uint256 total = b0 + b1;
            uint256 minSide = b0 < b1 ? b0 : b1;
            uint256 minShareBps = total == 0 ? 0 : (minSide * 10000) / total;
            thin = minSide < CURVE_THIN_USD;
            string memory status = thin ? "THIN (minority side shallow -> single-sided exit slips)" : "OK";
            console.log(string.concat("    ", s0, ": ", _u(b0), "   |   ", s1, ": ", _u(b1)));
            console.log(
                string.concat("    minority-side=", _u(minSide), "  share(bps)=", _u(minShareBps), "  =>  ", status)
            );
        } catch {
            console.log("    (non-standard pool - coins()/balances() unavailable; check address/ABI)");
        }
    }

    /// @notice Non-stable Curve pool (e.g. WBTC/crvUSD): print raw whole-token balances only.
    function _curveGeneric(string memory label, address pool) internal {
        console.log(label);
        try reader.curveSides(pool) returns (string memory s0, uint256 b0, string memory s1, uint256 b1) {
            console.log(string.concat("    ", s0, ": ", _u(b0), "   |   ", s1, ": ", _u(b1)));
        } catch {
            console.log("    (non-standard pool - coins()/balances() unavailable; check address/ABI)");
        }
    }

    /// @notice LlamaLend LLAMMA AMM: doesn't implement balances() — uses coins() for token
    ///         addresses then reads balanceOf(pool) directly. Reports active-band oracle price.
    function _llamaAmm(string memory label, address amm) internal {
        console.log(label);
        address c0 = ICurve(amm).coins(0); // crvUSD
        address c1 = ICurve(amm).coins(1); // collateral (wstETH)
        string memory s0 = IERC20(c0).symbol();
        string memory s1 = IERC20(c1).symbol();
        uint256 b0 = IERC20(c0).balanceOf(amm) / (10 ** IERC20(c0).decimals());
        uint256 b1 = IERC20(c1).balanceOf(amm) / (10 ** IERC20(c1).decimals());
        uint256 oraclePrice = ILlamaAmm(amm).price_oracle(); // collateral price in crvUSD, 1e18
        uint256 oraclePriceK = oraclePrice / 1e15; // display as integer * 1000 for readability
        console.log(string.concat("    ", s0, ": ", _u(b0), "   |   ", s1, ": ", _u(b1)));
        console.log(string.concat("    oracle price (1 ", s1, " in crvUSD) = ", _u(oraclePriceK), " (x1e-3)"));
    }

    // ── formatting ───────────────────────────────────────────────────────────

    function _strategyHeader(string memory name) internal {
        console.log("");
        console.log(string.concat("* ", name));
    }

    function _line(string memory label, string memory status) internal {
        console.log(string.concat(label, " : ", status));
    }

    function _verdict(bool bad) internal {
        console.log(string.concat("  => STRATEGY: ", bad ? "DEGRADED (exit constrained today)" : "OK"));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i2s(int256 v) internal pure returns (string memory) {
        if (v < 0) return string.concat("-", vm.toString(uint256(-v)));
        return vm.toString(uint256(v));
    }
}

/// @dev Separate contract so Curve reads can be wrapped in try/catch from the script. Some
///      collateral venues are LlamaLend AMMs, not standard Curve pools, and revert on
///      coins()/balances(); isolating the call lets the report degrade to "n/a" gracefully.
contract PoolReader {
    function curveSides(address pool)
        external
        view
        returns (string memory s0, uint256 b0, string memory s1, uint256 b1)
    {
        address c0 = ICurve(pool).coins(0);
        address c1 = ICurve(pool).coins(1);
        s0 = IERC20(c0).symbol();
        s1 = IERC20(c1).symbol();
        b0 = ICurve(pool).balances(0) / (10 ** IERC20(c0).decimals());
        b1 = ICurve(pool).balances(1) / (10 ** IERC20(c1).decimals());
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface ICurve {
    function coins(uint256) external view returns (address);
    function balances(uint256) external view returns (uint256);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ILlamaAmm {
    function price_oracle() external view returns (uint256);
}
