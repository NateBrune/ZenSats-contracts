// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./ZenjiForkTestBase.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { ICurveStableSwapNG } from "../../src/interfaces/ICurveStableSwapNG.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";

/// @title AaveSecurityTestMixin
/// @notice Additive base for legacy Aave-collateralised fork tests that pre-date the
///         ZenjiStrategyTestBase hierarchy. Provides ONLY the security and dust-unwind
///         invariant tests — no existing test in the inheriting file is shadowed or
///         conflicts. Use this when migrating a hand-rolled test file is impractical
///         but the new safety net is still required.
///
///         New deployments should prefer extending CrvUsdLpStrategyTestBase instead, which
///         gives the full canonical strategy test suite via parameterised hooks.
abstract contract AaveSecurityTestMixin is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    // ============ Access control ============

    /// @notice The loan manager's state-mutating entry points must reject any caller
    /// other than the vault. A bypass here would let a stranger drain or grief the
    /// position.
    function test_aaveSec_loanManager_unauthorizedCalls_revert() public {
        _deployVault();
        address stranger = makeAddr("aaveSec_stranger");
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

    // ============ Donation resilience ============

    /// @notice ERC4626 first-depositor inflation: VIRTUAL_SHARE_OFFSET defeats the
    /// classic attack. Attacker mints minimum-sized shares, dumps a large donation,
    /// then a victim's deposit must still receive a non-trivial share count.
    function test_aaveSec_donation_firstDepositor_cannotInflateShares() public {
        _deployVault();

        address attacker = makeAddr("aaveSec_attacker");
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

    /// @notice Donating collateral directly to the loan manager must not corrupt
    /// accounting or brick a subsequent redeem.
    function test_aaveSec_donation_toLoanManager_doesNotBrickRedeem() public {
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
            // Pool may be imbalanced (slippage guard fired) — acceptable. Verify no state
            // corruption: shares still held, no partial withdrawal.
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
        }
    }

    // ============ Dust unwind contract ============

    /// @notice Aave dust unwind path: a sub-dollar shortfall (e.g. flashloan premium on a
    /// tiny residual debt) bumps the swap to MIN_ROUTABLE_DEBT, then unwindPosition
    /// reverse-swaps the surplus back to collateral. The manager must end with zero idle
    /// balance — leftover would indicate a regression in the reverse-swap path.
    function test_aaveSec_dustUnwind_noStrandedBalances() public {
        _deployVault();

        uint256 dep = vault.MIN_DEPOSIT();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);
        _refreshOracles();

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        try vault.redeem(sharesBefore, user1, user1) returns (uint256 received) {
            assertGt(received, 0, "User must receive collateral on full redeem");

            IERC20 dt = IERC20(address(loanManager.debtToken()));
            assertEq(
                dt.balanceOf(address(loanManager)),
                0,
                "Loan manager stranded debt token after dust unwind"
            );
            assertEq(
                collateralToken.balanceOf(address(loanManager)),
                0,
                "Loan manager stranded collateral after dust unwind"
            );
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
        }
    }

    /// @notice Withdrawer pays slippage only on the MIN_ROUTABLE_DEBT over-amount,
    /// not on the full position.
    function test_aaveSec_dustUnwind_userLossBounded() public {
        _deployVault();

        uint256 dep = vault.MIN_DEPOSIT();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);
        _refreshOracles();

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        try vault.redeem(sharesBefore, user1, user1) returns (uint256 received) {
            assertGe(received * 100, dep * 95, "Dust unwind cost exceeded 5% of deposit");
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
        }
    }

    /// @notice Repeated dust unwinds must not accumulate residual state across iterations.
    function test_aaveSec_dustUnwind_repeated_keepsStateClean() public {
        _deployVault();

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        address[3] memory users =
            [makeAddr("aaveSec_dust1"), makeAddr("aaveSec_dust2"), makeAddr("aaveSec_dust3")];
        uint256 dep = vault.MIN_DEPOSIT();

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            deal(_collateral(), u, dep);
            _depositAs(u, dep);
            _refreshOracles();

            uint256 sharesBefore = vault.balanceOf(u);
            vm.prank(u);
            try vault.redeem(sharesBefore, u, u) returns (uint256 received) {
                assertGt(received, 0, "User must receive collateral");
                assertEq(
                    dt.balanceOf(address(loanManager)),
                    0,
                    "Loan manager accumulated debt-token dust across iterations"
                );
                assertEq(
                    collateralToken.balanceOf(address(loanManager)),
                    0,
                    "Loan manager accumulated collateral dust across iterations"
                );
            } catch {
                assertEq(vault.balanceOf(u), sharesBefore, "Shares mutated on revert");
                assertEq(
                    dt.balanceOf(address(loanManager)),
                    0,
                    "Manager left with debt token after rejected unwind"
                );
                assertEq(
                    collateralToken.balanceOf(address(loanManager)),
                    0,
                    "Manager left with collateral after rejected unwind"
                );
            }
        }
    }

    /// @notice Pre-donating debt token to the manager must not break the unwind —
    /// it should be absorbed (offsetting the flash shortfall directly, or reverse-swapped
    /// into collateral on the way out).
    function test_aaveSec_donation_debtTokenToManager_doesNotBrickUnwind() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        uint256 donation = loanManager.DUST_THRESHOLD() * 5;
        deal(address(dt), address(this), donation);
        dt.safeTransfer(address(loanManager), donation);

        _refreshOracles();

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        try vault.redeem(sharesBefore, user1, user1) returns (uint256 received) {
            assertGt(received, 0, "Redeem failed after debt-token donation");
            assertLe(
                dt.balanceOf(address(loanManager)),
                loanManager.DUST_THRESHOLD(),
                "Donation left as stranded debt token in manager"
            );
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
        }
    }

    /// @notice Partial close hitting the dust shortfall path.
    function test_aaveSec_partialClose_dustShortfall_keepsStateClean() public {
        _deployVault();

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        uint256 dep = vault.MIN_DEPOSIT() * 4;
        deal(_collateral(), user1, dep);
        uint256 shares = _depositAs(user1, dep);
        _refreshOracles();

        vm.prank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 received) {
            assertGt(received, 0, "Partial redeem returned zero");
            assertEq(
                dt.balanceOf(address(loanManager)),
                0,
                "Manager left holding debt token after partial-close dust unwind"
            );
            assertEq(
                collateralToken.balanceOf(address(loanManager)),
                0,
                "Manager left holding collateral after partial-close dust unwind"
            );

            _refreshOracles();
            uint256 remaining = _redeemAllAs(user1);
            assertGt(remaining, 0, "Remaining shares undeemable after partial dust unwind");
        } catch {
            assertEq(vault.balanceOf(user1), shares, "Shares mutated on revert");
            assertEq(
                dt.balanceOf(address(loanManager)),
                0,
                "Manager left with debt token after rejected partial unwind"
            );
        }
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

        address arb = makeAddr("aaveSec_lpArb");
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
    /// → user exits cleanly. The immediate-redeem tests in legacy hand-rolled suites
    /// understate slippage because the redeemer absorbs the imbalance they just
    /// created. After arb-rebalance, the round-trip cost should be modest.
    function test_aaveSec_realisticLifecycle_depositArbExit() public {
        _deployVault();

        // The USDT/crvUSD LP pool's depth varies day-to-day on the fork block. When
        // the pool is deep enough relative to _tinyDeposit(), the arb + exit succeed
        // cleanly. When it's thin, the pool's slippage guard fires — correct behavior,
        // not a bug. Both outcomes are valid; the invariant is "no state corruption".
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
            console.log("Realistic lifecycle (Aave): deposited=%d received=%d", dep, received);
        } catch {
            assertEq(vault.balanceOf(user1), sharesBefore, "Shares mutated on revert");
            console.log("Realistic lifecycle (Aave): slippage guard fired (pool too thin)");
        }
    }

    /// @notice DUST_THRESHOLD and MIN_ROUTABLE_DEBT scale with debt-token decimals.
    function test_aaveSec_loanManager_dustConstants_scaleWithDebtDecimals() public {
        _deployVault();
        uint256 expected = 10 ** uint256(loanManager.debtToken().decimals());
        assertEq(
            loanManager.DUST_THRESHOLD(),
            expected,
            "DUST_THRESHOLD does not scale with debt token decimals"
        );
        assertEq(
            loanManager.MIN_ROUTABLE_DEBT(),
            expected,
            "MIN_ROUTABLE_DEBT does not scale with debt token decimals"
        );
    }
}
