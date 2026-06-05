// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @notice Read-only probe (NOT a unit test of our code): measures the single-sided crvUSD
///         round-trip discount on the live pmUSD/crvUSD NG pool at various deposit sizes, to see
///         where the 3% strategy/debt rebalance deadband actually trips.
///         exitOut/deposit IS the balanceOf/debt ratio that drives strategyDebtRebalanceNeeded()
///         (trips when < 1.0 - 0.03 = 0.97).
contract PmUsdPoolProbe is Test {
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    ICurveStableSwapNG pool;
    int128 crvUsdIdx;
    uint256 crvUsdIdxU;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETH_RPC_URL", string(""));
        vm.createSelectFork(rpc);
        pool = ICurveStableSwapNG(PMUSD_CRVUSD_POOL);
        crvUsdIdxU = pool.coins(0) == CRVUSD ? 0 : 1;
        crvUsdIdx = int128(uint128(crvUsdIdxU));
    }

    function test_probe_singleSidedDiscountBySize() public {
        uint256 vp = pool.get_virtual_price();
        uint256 bal0 = pool.balances(0);
        uint256 bal1 = pool.balances(1);
        console.log("=== pmUSD/crvUSD pool state ===");
        console.log("coin0:", pool.coins(0));
        console.log("coin1:", pool.coins(1));
        console.log("balance0:", bal0);
        console.log("balance1:", bal1);
        console.log("crvUSD index:", crvUsdIdxU);
        console.log("virtual_price:", vp);
        console.log("crvUSD-side reserve (the binding depth):", crvUsdIdxU == 0 ? bal0 : bal1);
        console.log("");

        uint256[5] memory sizes =
            [uint256(1_000e18), 10_000e18, 100_000e18, 250_000e18, 1_000_000e18];

        for (uint256 k = 0; k < sizes.length; k++) {
            uint256 snap = vm.snapshotState();
            uint256 size = sizes[k];

            // Single-sided crvUSD deposit -> LP.
            deal(CRVUSD, address(this), size);
            IERC20(CRVUSD).approve(PMUSD_CRVUSD_POOL, size);
            uint256[] memory amounts = new uint256[](2);
            amounts[crvUsdIdxU] = size;
            uint256 lp = pool.add_liquidity(amounts, 0);

            // What balanceOf() would value it at (the two legs of the min()).
            uint256 vpValue = (lp * vp) / 1e18;
            uint256 exitOut = pool.calc_withdraw_one_coin(lp, crvUsdIdx);

            // exitOut/deposit == balanceOf/debt (debt == deposited crvUSD). Trips rebalance < 0.97.
            uint256 ratioVsDeposit = (exitOut * 1e18) / size;
            uint256 ratioVsVp = (exitOut * 1e18) / vpValue;

            console.log("--- deposit (crvUSD):", size / 1e18);
            console.log("   LP minted:", lp);
            console.log("   vpBased value:", vpValue);
            console.log("   exitBased (calc_withdraw_one_coin):", exitOut);
            console.log("   exitOut/deposit (=balanceOf/debt, x1e18):", ratioVsDeposit);
            console.log("   exitOut/vpValue (x1e18):", ratioVsVp);
            console.log(
                "   triggers rebalance (<0.97e18)?",
                ratioVsDeposit < 970_000_000_000_000_000 ? 1 : 0
            );
            console.log("");

            vm.revertToState(snap);
        }
    }
}
