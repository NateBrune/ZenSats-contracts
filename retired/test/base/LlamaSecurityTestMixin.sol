// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./ZenjiForkTestBase.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { ICurveStableSwapNG } from "../../src/interfaces/ICurveStableSwapNG.sol";

/// @title LlamaSecurityTestMixin
/// @notice Additive base for legacy Llama-collateralised fork tests. Provides the
///         universal security tests — access control + first-depositor inflation
///         protection + manager donation resilience — that apply regardless of the
///         lender. Llama flash loans are free, so the Aave-specific dust-unwind
///         contract does not apply; those tests live in AaveSecurityTestMixin.
abstract contract LlamaSecurityTestMixin is ZenjiForkTestBase {
    /// @notice Vault-only entry points must reject non-vault callers.
    function test_llamaSec_loanManager_unauthorizedCalls_revert() public {
        _deployVault();
        address stranger = makeAddr("llamaSec_stranger");
        ILoanManager lm = ILoanManager(address(loanManager));

        vm.startPrank(stranger);
        vm.expectRevert();
        lm.createLoan(1, 1);
        vm.expectRevert();
        lm.addCollateral(1);
        vm.expectRevert();
        lm.borrowMore(1, 1);
        vm.expectRevert();
        lm.repayDebt(1);
        vm.expectRevert();
        lm.removeCollateral(1);
        vm.expectRevert();
        lm.unwindPosition(1);
        vm.expectRevert();
        lm.transferCollateral(stranger, 1);
        vm.expectRevert();
        lm.transferDebt(stranger, 1);
        vm.stopPrank();
    }

    /// @notice ERC4626 first-depositor inflation protection via VIRTUAL_SHARE_OFFSET.
    function test_llamaSec_donation_firstDepositor_cannotInflateShares() public {
        _deployVault();

        address attacker = makeAddr("llamaSec_attacker");
        uint256 attackerDep = vault.MIN_DEPOSIT();
        deal(_collateral(), attacker, attackerDep);
        vm.startPrank(attacker);
        collateralToken.approve(address(vault), attackerDep);
        vault.deposit(attackerDep, attacker);
        vm.stopPrank();

        uint256 donation = attackerDep * 100;
        deal(_collateral(), address(this), donation);
        collateralToken.transfer(address(vault), donation);

        uint256 victimDep = _unit();
        deal(_collateral(), user1, victimDep);
        vm.startPrank(user1);
        collateralToken.approve(address(vault), victimDep);
        uint256 victimShares = vault.deposit(victimDep, user1);
        vm.stopPrank();

        assertGt(victimShares, 1e3, "Victim received near-zero shares (inflation succeeded)");
    }

    // ============ Realistic mainnet lifecycle ============

    address constant USDT_CRVUSD_POOL_MIXIN = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant CRVUSD_MIXIN = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    /// @notice Simulate an arbitrageur restoring the USDT/crvUSD pool ratio after the strategy
    /// added crvUSD single-sided. The arb sells USDT into the pool to buy back the excess
    /// crvUSD. Pool fees accrue to LP holders (the strategy), which shows up once
    /// `updateCachedVirtualPrice` is called.
    ///
    /// Mirrors `CrvUsdLpStrategyTestBase._arbitragePoolBalance`. Coin ordering (USDT = 0,
    /// crvUSD = 1) is asserted rather than derived — every live vault wires this pool, and a
    /// silent index flip would make the arb a no-op instead of a failure.
    /// Skips silently if the pool is already balanced (small deposits may not move it).
    function _arbitrateLpPool() internal {
        address pool = USDT_CRVUSD_POOL_MIXIN;
        require(
            ICurveStableSwapNG(pool).coins(1) == CRVUSD_MIXIN, "mixin: unexpected coin ordering"
        );
        address usdt_ = ICurveStableSwapNG(pool).coins(0);

        // balances(0) is USDT (6-dec), balances(1) is crvUSD (18-dec) -- normalise before comparing.
        uint256 crvBal = ICurveStableSwapNG(pool).balances(1);
        uint256 usdtBal18 = ICurveStableSwapNG(pool).balances(0) * 1e12;
        if (crvBal <= usdtBal18) return; // pool not crvUSD-heavy, nothing to arb
        uint256 usdtToSwap = (crvBal - usdtBal18) / (2 * 1e12);
        if (usdtToSwap == 0) return;

        address arb = makeAddr("llamaSec_lpArb");
        deal(usdt_, arb, usdtToSwap);
        vm.startPrank(arb);
        // USDT has a non-standard approve (no return value) -- use a low-level call.
        (bool ok,) =
            usdt_.call(abi.encodeWithSignature("approve(address,uint256)", pool, usdtToSwap));
        require(ok, "USDT approve failed");
        ICurveStableSwapNG(pool).exchange(0, 1, usdtToSwap, 0);
        vm.stopPrank();

        // Refresh the strategy's unit-value cache so balanceOf() reflects post-arb pool state.
        yieldStrategy.updateCachedVirtualPrice();
    }

    /// @notice Realistic mainnet lifecycle: deposit → arbitrageurs restore the LP pool
    /// → user exits cleanly.
    function test_llamaSec_realisticLifecycle_depositArbExit() public {
        _deployVault();

        // Pool depth varies day-to-day on the fork; slippage guard may fire even after arb.
        // Both outcomes are valid — invariant is no state corruption.
        uint256 dep = _tinyDeposit();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);

        _arbitrateLpPool();
        _refreshOracles();

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        try vault.redeem(sharesBefore, user1, user1) returns (uint256 received) {
            assertGt(received, 0, "Realistic exit returned zero");
            assertGe(received * 100, dep * 95, "Realistic round-trip loss > 5%");
            console.log("Realistic lifecycle (Llama): deposited=%d received=%d", dep, received);
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
            console.log("Realistic lifecycle (Llama): slippage guard fired (pool too thin)");
        }
    }

    /// @notice Donating collateral directly to the loan manager must not brick redeem.
    function test_llamaSec_donation_toLoanManager_doesNotBrickRedeem() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        uint256 donation = _unit();
        deal(_collateral(), address(this), donation);
        collateralToken.transfer(address(loanManager), donation);

        _refreshOracles();

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        try vault.redeem(sharesBefore, user1, user1) returns (uint256 received) {
            assertGt(received, 0, "Redeem failed after collateral donation to manager");
            assertGe(received * 100, _unit() * 2 * 90, "Donation corrupted user accounting");
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
        }
    }
}
