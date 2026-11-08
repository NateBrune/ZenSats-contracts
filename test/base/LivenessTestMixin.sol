// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./ZenjiForkTestBase.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";

/// @title LivenessTestMixin
/// @notice Halting-condition suite. Every test here deliberately tries to WEDGE the vault, then
///         asserts the properties that must survive any wedge:
///
///           1. `rebalance()` may revert -- that is an accepted, documented outcome (M-02) -- but a
///              reverting `rebalance()` must NEVER mutate state. No collateral half-spent, no LTV
///              dragged, nothing for the next tick to inherit.
///           2. A wedged `rebalance()` must never block `deposit()`.
///           3. A wedged `rebalance()` must never block `withdraw()` / `redeem()`. Depositors can
///              always leave.
///           4. `setIdle(true)` / `setIdle(false)` must ALWAYS be available as the escape hatch, and
///              must clear the wedge. Every accepted-risk writeup in this repo terminates in
///              "a strategist runs setIdle/unIdle" -- so that path failing turns an accepted
///              liveness blip into a stuck vault.
///           5. `rebalance()` must never report SUCCESS while leaving a band out of range. A silent
///              out-of-band success is what hands the next tick to a blocking arm.
///
/// @dev    Wedges are induced with MARKET conditions (strategy loss, strategy gain, collateral
///         price moves), not with rotated-in malicious swappers. A malicious swapper is a
///         governance action that governance can undo; a 60% strategy loss with LTV drifting
///         through the band is what actually shows up in production, and it is the case where the
///         escape hatch has to work.
///
///         Inherited by every live vault suite so all three configurations (WBTC/LlamaLend,
///         wstETH/LlamaLend, XAUT/Aave) are covered by the same invariants.
abstract contract LivenessTestMixin is ZenjiForkTestBase {
    struct PositionSnapshot {
        uint256 strategyBalance;
        uint256 debt;
        uint256 collateral;
        uint256 totalSupply;
    }

    /// @notice Deposit size for liveness scenarios.
    /// @dev    Deliberately the SMALL size, not `_baseDeposit()`. These tests ask "is this path
    ///         blocked?", which is independent of trade size -- but sizing them at `_baseDeposit()`
    ///         made the unwind legs bump into real pool depth, so `_skipOnEnvironmentalRevert`
    ///         fired and the wedge under test was never actually exercised. A skipped liveness test
    ///         is worse than no test: it reads green. Size-vs-depth is covered separately by
    ///         `test_capacityReport` and the round-trip suites.
    function _livenessDeposit() internal pure virtual returns (uint256) {
        return _tinyDeposit() * 10;
    }

    // ============ Scenario generators ============

    /// @notice The strategy's Stake DAO reward-vault share token, or address(0) if this strategy
    ///         does not expose one (in which case share-based loss/gain scenarios are skipped).
    function _strategyShares() internal view returns (IERC20) {
        (bool ok, bytes memory d) =
            address(yieldStrategy).staticcall(abi.encodeWithSignature("stakingVault()"));
        if (!ok || d.length < 32) return IERC20(address(0));
        return IERC20(abi.decode(d, (address)));
    }

    /// @notice Burn `pct`% of the strategy's position, driving coverage DOWN (arm 3 territory).
    function _induceStrategyLoss(uint256 pct) internal returns (bool applied) {
        IERC20 shares = _strategyShares();
        if (address(shares) == address(0)) return false;
        uint256 bal = shares.balanceOf(address(yieldStrategy));
        if (bal == 0) return false;
        vm.prank(address(yieldStrategy));
        shares.transfer(makeAddr("livenessLossSink"), (bal * pct) / 100);
        return true;
    }

    /// @notice Drive coverage ABOVE the upper band (arm 4 territory). Overridden per suite: the
    ///         Stake DAO reward-vault share token has no plain balance slot, so `deal()` cannot
    ///         mint it (stdStorage finds no storage use). Suites that already own a working
    ///         generator (`_induceGainUntilRatio`) forward to it; suites that do not return false
    ///         and the surplus scenario is skipped rather than faked.
    function _induceLivenessSurplus() internal virtual returns (bool applied) {
        return false;
    }

    /// @notice Re-mock the COLLATERAL oracle at `bps`/10000 of its live price, fresh-timestamped.
    ///         Raising the collateral price lowers LTV (toward/through `lowerBand`, arm 1
    ///         territory); lowering it raises LTV (arm 2 territory).
    /// @dev    Must be applied AFTER the last `_refreshOracles()`, which re-mocks at real prices,
    ///         and MUST be undone with `_restoreOraclePrices()` before exercising any path that
    ///         swaps. A shifted oracle with an unmoved market is an oracle/market DIVERGENCE: every
    ///         swapper floors its output against the oracle, so all of them correctly refuse. That
    ///         is a real halting condition, but an environmental one (a depeg), and it is not the
    ///         dispatch wedge these tests are trying to isolate -- leaving it in place would mask
    ///         the thing under test behind `SwapperUnderperformed` / `V3TooLittleReceived`.
    ///         `_oracleList()[0]` is the collateral oracle by convention in every suite.
    function _shiftCollateralPrice(uint256 bps) internal {
        address oracle = _oracleList()[0];
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(oracle).latestRoundData();
        uint256 ts = block.timestamp > updatedAt ? block.timestamp : updatedAt;
        int256 shifted = (answer * int256(bps)) / int256(uint256(10000));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, shifted, ts, ts, answeredInRound)
        );
    }

    /// @notice Undo `_shiftCollateralPrice`, putting every oracle back on the real market price.
    /// @dev    `vm.clearMockedCalls()` FIRST is load-bearing. `_refreshOracles()` re-mocks each
    ///         oracle with whatever `latestRoundData()` currently returns -- and while the shift
    ///         mock is installed, that IS the fabricated price, so refreshing alone re-pins the lie
    ///         permanently. Clearing drops back to real chain data, then the refresh re-applies only
    ///         the fresh-timestamp mocks the suite needs.
    function _restoreOraclePrices() internal {
        vm.clearMockedCalls();
        _refreshOracles();
    }

    // ============ Assertions ============

    function _snapshotPosition() internal view returns (PositionSnapshot memory) {
        return PositionSnapshot({
            strategyBalance: yieldStrategy.balanceOf(),
            debt: loanManager.getCurrentDebt(),
            collateral: loanManager.getCurrentCollateral(),
            totalSupply: vault.totalSupply()
        });
    }

    function _assertUnchanged(PositionSnapshot memory before, string memory ctx) internal view {
        assertEq(yieldStrategy.balanceOf(), before.strategyBalance, string.concat(ctx, ": strategy balance moved on a reverted call"));
        assertEq(loanManager.getCurrentDebt(), before.debt, string.concat(ctx, ": debt moved on a reverted call"));
        assertEq(loanManager.getCurrentCollateral(), before.collateral, string.concat(ctx, ": collateral moved on a reverted call"));
        assertEq(vault.totalSupply(), before.totalSupply, string.concat(ctx, ": share supply moved on a reverted call"));
    }

    /// @notice Call `rebalance()` and enforce invariants 1 and 5: it either succeeds without
    ///         silently leaving the coverage band open, or it reverts having changed nothing.
    ///
    /// @dev    Invariant 5 is ARM-AWARE, and it has to be. `rebalance()` dispatches exactly ONE arm
    ///         per call, LTV first (`Zenji.rebalance` dispatch table). When an LTV arm runs, coverage
    ///         is allowed to end up out of band -- arm 2 in particular "withdraws from the strategy
    ///         and repays symmetrically, which pushes coverage AWAY from parity whenever coverage
    ///         < 1", per its own NatSpec, which is why arms 3 and 4 exist as separate triggers.
    ///         So the guarantee only binds when dispatch actually reached a COVERAGE arm, i.e. LTV
    ///         was already in band going in.
    ///
    ///         This asymmetry is worth stating plainly because it is the engine of the deadlock
    ///         class these tests exist for: an LTV arm can legitimately return success having left
    ///         coverage short, and the NEXT tick then re-dispatches on LTV first again.
    /// @return succeeded whether the call went through
    function _rebalanceRespectingInvariants(string memory ctx) internal returns (bool succeeded) {
        PositionSnapshot memory before = _snapshotPosition();

        uint256 ltvBefore = loanManager.getCurrentLTV();
        bool ltvWasOutOfBand = ltvBefore < vault.targetLtv() - vault.DEADBAND_SPREAD()
            || ltvBefore > vault.targetLtv() + vault.DEADBAND_SPREAD();

        try vault.rebalance() {
            uint256 ratio = vault.strategyToDebtRatio();
            if (!ltvWasOutOfBand && ratio != type(uint256).max) {
                // Dispatch fell through to a coverage arm: it must have restored the band.
                uint256 minRatio = vault.PRECISION() - vault.DEADBAND_SPREAD();
                uint256 maxRatio = vault.PRECISION() + vault.DEADBAND_SPREAD();
                assertTrue(
                    ratio >= minRatio && ratio <= maxRatio,
                    string.concat(ctx, ": a coverage arm reported success with coverage still out of band")
                );
            }
            return true;
        } catch (bytes memory err) {
            // Invariant 1: a reverted rebalance is fine, a half-applied one is not.
            _assertUnchanged(before, ctx);
            err; // any revert reason is acceptable here
            return false;
        }
    }

    /// @notice Invariant 4: the escape hatch must always be available and must clear the wedge.
    function _escapeViaIdle() internal {
        vm.prank(owner);
        try vault.setIdle(true) {
            // full unwind succeeded
        } catch (bytes memory err) {
            _skipOnEnvironmentalRevert(err);
            revert("setIdle(true) is BLOCKED -- the documented escape hatch does not work");
        }
        assertTrue(vault.idle(), "setIdle(true) did not take effect -- escape hatch is broken");
        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);
        assertFalse(vault.idle(), "setIdle(false) did not take effect -- escape hatch is broken");
    }

    /// @notice Invariant 3: depositors can always leave. Environmental (market-depth) reverts are
    ///         a skip, not a failure -- see `_isEnvironmentalRevert`.
    function _assertCanStillExit(address user, string memory ctx) internal {
        uint256 shares = vault.balanceOf(user);
        if (shares == 0) return;
        _refreshOracles();
        vm.prank(user);
        try vault.redeem(shares, user, user) returns (uint256 got) {
            assertGt(got, 0, string.concat(ctx, ": redeem returned zero collateral"));
            console.log("%s: exit OK, received=%d", ctx, got);
        } catch (bytes memory err) {
            _skipOnEnvironmentalRevert(err);
            revert(string.concat(ctx, ": redeem is BLOCKED -- depositors cannot exit"));
        }
    }

    /// @notice Invariant 2: a wedged rebalance must not block new deposits.
    function _assertCanStillDeposit(string memory ctx) internal {
        uint256 amount = _livenessDeposit();
        deal(_collateral(), user2, amount);
        _refreshOracles();
        vm.startPrank(user2);
        collateralToken.approve(address(vault), amount);
        try vault.deposit(amount, user2) returns (uint256 shares) {
            assertGt(shares, 0, string.concat(ctx, ": deposit minted zero shares"));
        } catch (bytes memory err) {
            vm.stopPrank();
            _skipOnEnvironmentalRevert(err);
            revert(string.concat(ctx, ": deposit is BLOCKED"));
        }
        vm.stopPrank();
    }

    // ============ Tests ============

    /// @notice A deep strategy loss (arm 3 territory, past the point where the venue will permit a
    ///         corrective removal) must not block exits or deposits, and the idle escape must clear
    ///         it. This is the M-02 / M-NEW-1 wedge in its most severe form.
    function test_liveness_deepLoss_exitDepositAndEscapeAllSurvive() public {
        _deployVault();
        _depositAs(user1, _livenessDeposit());
        _refreshOracles();
        if (!_induceStrategyLoss(60)) {
            console.log("strategy exposes no share token -- scenario N/A");
            return;
        }
        _refreshOracles();

        bool ok = _rebalanceRespectingInvariants("deepLoss");
        console.log("deepLoss: rebalance succeeded=%s", ok ? "yes" : "no (clean revert)");

        _assertCanStillDeposit("deepLoss");
        _escapeViaIdle();

        // After the escape, rebalance must be usable again: either it works or it is not needed.
        _refreshOracles();
        try vault.rebalance() {
            console.log("deepLoss: rebalance works again after idle escape");
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            assertEq(
                sel,
                Zenji_RebalanceNotNeeded_selector(),
                "after the idle escape, rebalance() must either succeed or be unnecessary"
            );
            console.log("deepLoss: RebalanceNotNeeded after idle escape (position is back in band)");
        }
        _assertCanStillExit(user1, "deepLoss");
    }

    /// @notice The dispatch-order hazard, directly. Coverage is driven below band AND the collateral
    ///         price is moved so LTV lands out of band too -- so `rebalance()` picks an LTV arm while
    ///         coverage is still short, which is the exact configuration where arm 1's
    ///         `enforceCoverageAfterIncrease` guard refuses. Whatever it does, the vault must not be
    ///         stuck: deposits, exits and the idle escape all keep working.
    function test_liveness_coverageAndLtvBothOutOfBand_neverStuck() public {
        _deployVault();
        _depositAs(user1, _livenessDeposit());
        _refreshOracles();
        if (!_induceStrategyLoss(20)) {
            console.log("strategy exposes no share token -- scenario N/A");
            return;
        }
        _refreshOracles();

        // Raise the collateral price 12%: LTV = debt / collateralValue falls through `lowerBand`,
        // so the LTV arm wins dispatch while coverage is still below its own band.
        _shiftCollateralPrice(11200);
        uint256 ltv = loanManager.getCurrentLTV();
        uint256 lower = vault.targetLtv() - vault.DEADBAND_SPREAD();
        console.log("bothBands: ltv(bps)=%d lowerBand(bps)=%d ratio(bps)=%d", ltv / 1e14, lower / 1e14, vault.strategyToDebtRatio() / 1e14);

        bool ok = _rebalanceRespectingInvariants("bothBands");
        console.log("bothBands: rebalance succeeded=%s", ok ? "yes" : "no (clean revert)");

        // Put the oracle back on the real price before touching any swapping path -- see
        // `_shiftCollateralPrice`. The dispatch wedge is what is under test, not a depeg.
        _restoreOraclePrices();

        // The wedge must not have cost anyone their exit or blocked new capital.
        _assertCanStillDeposit("bothBands");
        _escapeViaIdle();
        _assertCanStillExit(user1, "bothBands");
    }

    /// @notice Repeated ticks across a drifting position must never wedge PERMANENTLY and must never
    ///         silently drift out of band. Runs a sequence of losses and price moves, calling
    ///         `rebalance()` after each, enforcing the invariants on every single tick.
    function test_liveness_repeatedRebalanceSequence_neverCorrupts() public {
        _deployVault();
        _depositAs(user1, _livenessDeposit());
        _refreshOracles();

        uint256[5] memory lossPcts = [uint256(5), 8, 3, 12, 6];
        uint256[5] memory priceBps = [uint256(10300), 9800, 10500, 9600, 10100];
        uint256 succeeded = 0;

        for (uint256 i = 0; i < lossPcts.length; i++) {
            if (!_induceStrategyLoss(lossPcts[i])) {
                console.log("strategy exposes no share token -- scenario N/A");
                return;
            }
            _refreshOracles();
            _shiftCollateralPrice(priceBps[i]);
            if (_rebalanceRespectingInvariants("sequence")) succeeded++;
            console.log("tick %d: ratio(bps)=%d ltv(bps)=%d", i, vault.strategyToDebtRatio() / 1e14, loanManager.getCurrentLTV() / 1e14);
            _restoreOraclePrices();
        }
        console.log("sequence: %d of 5 ticks rebalanced", succeeded);

        // Whatever the sequence did, the vault is still usable.
        _escapeViaIdle();
        _assertCanStillExit(user1, "sequence");
    }

    /// @notice Arm 4 territory: a strategy SURPLUS beyond the upper band. Arm 4 gained three
    ///         unconditional revert paths in the skim rewrite (audit M-02 on that arm) and can brick
    ///         a permissionless `rebalance()` where the old arm never reverted -- so the same
    ///         no-corruption / still-exitable guarantees are asserted here.
    function test_liveness_largeSurplus_arm4NeverCorrupts() public {
        _deployVault();
        _depositAs(user1, _livenessDeposit());
        _refreshOracles();
        if (!_induceLivenessSurplus()) {
            console.log("no surplus generator for this suite -- scenario N/A");
            return;
        }
        _refreshOracles();
        console.log("surplus: ratio(bps)=%d", vault.strategyToDebtRatio() / 1e14);

        bool ok = _rebalanceRespectingInvariants("surplus");
        console.log("surplus: rebalance succeeded=%s", ok ? "yes" : "no (clean revert)");

        _assertCanStillDeposit("surplus");
        _escapeViaIdle();
        _assertCanStillExit(user1, "surplus");
    }

    /// @notice The escape hatch must work from a cold wedge with no prior successful rebalance --
    ///         i.e. `setIdle` must not itself depend on the position being in band.
    function test_liveness_idleEscape_worksFromDeepWedge() public {
        _deployVault();
        _depositAs(user1, _livenessDeposit());
        _refreshOracles();
        if (!_induceStrategyLoss(45)) {
            console.log("strategy exposes no share token -- scenario N/A");
            return;
        }
        _refreshOracles();
        _shiftCollateralPrice(9400); // push LTV up at the same time
        console.log("coldWedge: ltv(bps)=%d ratio(bps)=%d", loanManager.getCurrentLTV() / 1e14, vault.strategyToDebtRatio() / 1e14);
        _restoreOraclePrices();

        // Do NOT attempt a rebalance first: this asserts the escape works cold.
        _escapeViaIdle();
        _refreshOracles();
        _assertCanStillExit(user1, "coldWedge");
    }

    // ============ Helpers ============

    /// @dev `Zenji.RebalanceNotNeeded` selector, resolved without importing the whole contract type
    ///      into the mixin's inheritance surface.
    function Zenji_RebalanceNotNeeded_selector() internal pure returns (bytes4) {
        return bytes4(keccak256("RebalanceNotNeeded()"));
    }
}
