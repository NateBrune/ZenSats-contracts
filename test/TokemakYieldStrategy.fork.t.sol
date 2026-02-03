// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { TokemakYieldStrategy } from "../src/strategies/TokemakYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ICurveStableSwap } from "../src/interfaces/ICurveStableSwap.sol";
import { ITokemakAutopool } from "../src/interfaces/ITokemakAutopool.sol";
import { IMainRewarder } from "../src/interfaces/IMainRewarder.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @title TokemakYieldStrategyForkTest
/// @notice Fork tests for TokemakYieldStrategy against real mainnet contracts
contract TokemakYieldStrategyForkTest is Test {
    // Mainnet addresses
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE_CRVUSD_USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address constant TOKEMAK_AUTOPOOL = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address constant TOKEMAK_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address constant SUSHI_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address constant REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;

    // Whales for getting tokens
    address constant CRVUSD_WHALE = 0x0a7b9483030994016567b3B1B4bbB865578901Cb;

    // Contracts
    IERC20 crvUSD;
    IERC20 usdc;
    ICurveStableSwap curvePool;
    ITokemakAutopool tokemakVault;
    IMainRewarder rewarder;
    TokemakYieldStrategy strategy;

    // Test accounts
    address vault = makeAddr("vault");

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        require(bytes(rpcUrl).length > 0, "RPC URL required");
        vm.createSelectFork(rpcUrl);

        // Set up token references
        crvUSD = IERC20(CRVUSD);
        usdc = IERC20(USDC);
        curvePool = ICurveStableSwap(CURVE_CRVUSD_USDC_POOL);
        tokemakVault = ITokemakAutopool(TOKEMAK_AUTOPOOL);
        rewarder = IMainRewarder(REWARDER);

        // Log Tokemak vault info
        console.log("Tokemak vault asset:", tokemakVault.asset());
        console.log("USDC address:", USDC);
        console.log("Router:", TOKEMAK_ROUTER);
        console.log("Rewarder:", REWARDER);

        // Deploy strategy
        strategy = new TokemakYieldStrategy(
            CRVUSD,
            vault,
            USDC,
            CURVE_CRVUSD_USDC_POOL,
            TOKEMAK_AUTOPOOL,
            TOKEMAK_ROUTER,
            REWARDER,
            SUSHI_ROUTER
        );

        // Fund vault with crvUSD from whale
        uint256 whaleBalance = crvUSD.balanceOf(CRVUSD_WHALE);
        console.log("Whale crvUSD balance:", whaleBalance);

        vm.prank(CRVUSD_WHALE);
        crvUSD.transfer(vault, 100_000e18); // 100k crvUSD

        // Approve strategy from vault
        vm.prank(vault);
        crvUSD.approve(address(strategy), type(uint256).max);
    }

    // ============ Core Staking Tests ============

    function test_deposit_stakesViaRouter() public {
        if (tokemakVault.asset() != USDC) {
            console.log("SKIPPING: Tokemak vault doesn't accept USDC");
            return;
        }

        uint256 depositAmount = 1000e18;

        console.log("=== Before Deposit ===");
        console.log("Rewarder staked:", rewarder.balanceOf(address(strategy)));
        console.log("Autopool held:", IERC20(address(tokemakVault)).balanceOf(address(strategy)));

        vm.prank(vault);
        uint256 deposited = strategy.deposit(depositAmount);

        uint256 staked = rewarder.balanceOf(address(strategy));
        uint256 held = IERC20(address(tokemakVault)).balanceOf(address(strategy));

        console.log("=== After Deposit ===");
        console.log("USDC deposited:", deposited);
        console.log("Rewarder staked:", staked);
        console.log("Autopool held:", held);
        console.log("Strategy balanceOf:", strategy.balanceOf());

        assertGt(deposited, 0, "Should deposit USDC");
        assertGt(staked, 0, "Should have staked shares in rewarder");
        assertEq(held, 0, "Should have no unstaked shares (all staked via router)");
    }

    function test_depositAndWithdraw_stakesAndUnstakes() public {
        if (tokemakVault.asset() != USDC) {
            console.log("SKIPPING: Tokemak vault doesn't accept USDC");
            return;
        }

        uint256 depositAmount = 10_000e18;

        // Deposit
        vm.prank(vault);
        strategy.deposit(depositAmount);

        uint256 stakedAfterDeposit = rewarder.balanceOf(address(strategy));
        console.log("After deposit - Staked:", stakedAfterDeposit);
        console.log("After deposit - Balance:", strategy.balanceOf());

        // Withdraw half
        vm.prank(vault);
        uint256 received = strategy.withdraw(5000e18);

        uint256 stakedAfterWithdraw = rewarder.balanceOf(address(strategy));
        console.log("After withdraw - Received:", received);
        console.log("After withdraw - Staked:", stakedAfterWithdraw);
        console.log("After withdraw - Balance:", strategy.balanceOf());

        assertGt(received, 0, "Should receive crvUSD");
        assertLt(stakedAfterWithdraw, stakedAfterDeposit, "Staked shares should decrease");
        assertGt(stakedAfterWithdraw, 0, "Should still have some staked");

        // Withdraw all
        vm.prank(vault);
        uint256 finalReceived = strategy.withdrawAll();

        console.log("After withdrawAll - Received:", finalReceived);
        console.log("After withdrawAll - Staked:", rewarder.balanceOf(address(strategy)));

        uint256 totalReceived = received + finalReceived;
        console.log("=== Summary ===");
        console.log("Deposited:", depositAmount);
        console.log("Total received:", totalReceived);

        assertGt(totalReceived, depositAmount * 99 / 100, "Should recover at least 99%");
        assertEq(rewarder.balanceOf(address(strategy)), 0, "No staked shares after withdrawAll");
    }

    function test_emergencyWithdraw_unstakesAll() public {
        if (tokemakVault.asset() != USDC) {
            console.log("SKIPPING: Tokemak vault doesn't accept USDC");
            return;
        }

        vm.prank(vault);
        strategy.deposit(5000e18);

        console.log("Before emergency - Staked:", rewarder.balanceOf(address(strategy)));

        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();

        console.log("After emergency - Received:", received);
        console.log("After emergency - Staked:", rewarder.balanceOf(address(strategy)));

        assertGt(received, 0, "Should receive crvUSD");
        assertEq(strategy.costBasis(), 0);
        assertEq(rewarder.balanceOf(address(strategy)), 0, "No staked shares");
    }

    // ============ Curve Pool Tests ============

    function test_curvePool_canSwapCrvUsdToUsdc() public view {
        uint256 expectedOut = curvePool.get_dy(1, 0, 1000e18);
        console.log("Expected USDC for 1000 crvUSD:", expectedOut);
        assertGt(expectedOut, 990e6);
        assertLt(expectedOut, 1010e6);
    }

    function test_curvePool_canSwapUsdcToCrvUsd() public view {
        uint256 expectedOut = curvePool.get_dy(0, 1, 1000e6);
        console.log("Expected crvUSD for 1000 USDC:", expectedOut);
        assertGt(expectedOut, 990e18);
        assertLt(expectedOut, 1010e18);
    }

    // ============ Harvest / Rewards Tests ============

    function test_harvest_noRewardsIsNoOp() public {
        if (tokemakVault.asset() != USDC) return;

        vm.prank(vault);
        strategy.deposit(10_000e18);

        uint256 staked = rewarder.balanceOf(address(strategy));

        vm.prank(vault);
        uint256 harvested = strategy.harvest();

        assertEq(harvested, 0, "Harvest with no rewards should return 0");
        assertEq(rewarder.balanceOf(address(strategy)), staked, "Staked should not change");
    }

    function test_harvest_compoundsTokeRewards() public {
        if (tokemakVault.asset() != USDC) return;

        vm.prank(vault);
        strategy.deposit(10_000e18);

        uint256 stakedBefore = rewarder.balanceOf(address(strategy));

        // Give strategy some TOKE to simulate rewards
        address tokeAddr = rewarder.rewardToken();
        deal(tokeAddr, address(strategy), 1000e18);

        vm.prank(vault);
        uint256 harvested = strategy.harvest();

        assertGt(harvested, 0, "Should have compounded rewards");
        assertGt(rewarder.balanceOf(address(strategy)), stakedBefore, "Staked should increase");
        assertEq(IERC20(tokeAddr).balanceOf(address(strategy)), 0, "TOKE should be fully swapped");
    }

    function test_pendingRewards_afterDeposit() public {
        if (tokemakVault.asset() != USDC) return;

        vm.prank(vault);
        strategy.deposit(10_000e18);

        uint256 rewards = strategy.pendingRewards();
        console.log("Pending rewards right after deposit:", rewards);

        vm.warp(block.timestamp + 1 days);

        uint256 rewardsAfter = strategy.pendingRewards();
        console.log("Pending rewards after 1 day:", rewardsAfter);
    }

    // ============ Slippage Tests ============

    function test_slippage_defaultValue() public view {
        assertEq(strategy.slippageTolerance(), 1e16);
    }

    function test_slippage_canBeUpdated() public {
        vm.prank(vault);
        strategy.setSlippage(2e16);
        assertEq(strategy.slippageTolerance(), 2e16);
    }

    // ============ Large Deposit Tests ============

    function test_largeDeposit_stakesSuccessfully() public {
        if (tokemakVault.asset() != USDC) return;

        uint256 maxDeposit = tokemakVault.maxDeposit(address(strategy));
        if (maxDeposit == 0) {
            console.log("SKIPPING: Tokemak vault at capacity");
            return;
        }

        vm.prank(vault);
        uint256 deposited = strategy.deposit(50_000e18);

        console.log("Large deposit - USDC:", deposited);
        console.log("Staked:", rewarder.balanceOf(address(strategy)));

        assertGt(deposited, 0);
        assertGt(rewarder.balanceOf(address(strategy)), 0, "Should have staked shares");
    }

    // ============ View Function Tests ============

    function test_viewFunctions_afterDeposit() public {
        if (tokemakVault.asset() != USDC) return;

        vm.prank(vault);
        strategy.deposit(10_000e18);

        console.log("=== View Functions ===");
        console.log("balanceOf():", strategy.balanceOf());
        console.log("costBasis():", strategy.costBasis());
        console.log("pendingRewards():", strategy.pendingRewards());
        console.log("staked shares:", rewarder.balanceOf(address(strategy)));

        assertEq(strategy.asset(), CRVUSD);
        assertEq(strategy.underlyingAsset(), USDC);
        assertGt(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 10_000e18);
        assertEq(strategy.name(), "Tokemak autoUSD Strategy");
    }
}
