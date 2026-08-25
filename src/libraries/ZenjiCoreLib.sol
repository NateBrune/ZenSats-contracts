// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../interfaces/ILoanManager.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import { SafeTransferLib } from "./SafeTransferLib.sol";

/// @title ZenjiCoreLib
/// @notice External library for Zenji admin and emergency operations
/// @dev Functions are `external` so they deploy separately and reduce Zenji bytecode.
///      Called via DELEGATECALL, so `address(this)` is the vault and token transfers work correctly.
/// @notice Minimal accessor for the venue-specific health floor. AaveLoanManager and
///         LlamaLoanManager both already declare `int256 public constant MIN_HEALTH`, which
///         Solidity auto-implements as an external view getter with this exact selector -- this
///         lets rebalanceCoverageUp read it without adding MIN_HEALTH() to ILoanManager (which
///         would force every ILoanManager mock in the test suite to implement it).
interface IMinHealth {
    function MIN_HEALTH() external view returns (int256);
}

/// @notice Minimal accessor for a swapper's self-reported slippage tolerance. Mirrors the
///         file-scope `ISwapperSlippageConfig` in Zenji.sol (same selector, `slippage()`), kept
///         as a local minimal interface rather than imported to avoid a circular import between
///         Zenji.sol and this library -- same rationale as `IMinHealth` above.
interface ISwapperSlippage {
    function slippage() external view returns (uint256);
}

library ZenjiCoreLib {
    using SafeTransferLib for IERC20;

    /// @notice Minimum acceptable collateral->debt swap output vs the oracle quote (bps).
    /// @dev MUST match LlamaLoanManager/AaveLoanManager.MIN_SWAP_OUT_BPS. The swappers deliberately
    ///      do NOT carry their own end-to-end floor (UniswapMixedCurveSwapper leaves the V3 hop at
    ///      amountOutMin = 0 for non-wstETH collateral and floors the Curve hop with a same-tx
    ///      get_dy), and document the loan manager's check as the hard floor. Any call site that
    ///      invokes ISwapper.swapCollateralForDebt directly MUST re-apply this bound.
    uint256 internal constant MIN_SWAP_OUT_BPS = 9500;

    /// @notice Safety margin (percent, /100) applied on top of the venue's own MIN_HEALTH when
    ///         gating the feasibility probe in rebalanceCoverageUp. LlamaLend's remove_collateral
    ///         can revert on its own band bound BEFORE our MIN_HEALTH check fires, so a projection
    ///         that only just clears MIN_HEALTH is not proof the venue will accept it; the margin
    ///         also absorbs oracle drift between the projection and execution.
    uint256 internal constant HEALTH_FLOOR_MARGIN_PCT = 105; // MIN_HEALTH * 105 / 100

    error InvalidAddress();
    error InsufficientWithdrawal();
    error InsufficientDeposit();
    error StrategyDebtCoverageTooLow(uint256 actual, uint256 minimum);
    error CoverageDidNotImprove();
    error SwapperUnderperformed(uint256 expected, uint256 actual);
    error DeficitExceedsCollateral(uint256 needed, uint256 available);
    /// @notice Closing the coverage deficit needs a collateral removal the lending venue will not
    ///         accept at current health. `collateralRequired` is the removal that was refused.
    ///         ACTIONABLE: the vault cannot self-heal from here -- an operator should run
    ///         setIdle(true)/setIdle(false), which drives debt to 0 (coverage becomes
    ///         type(uint256).max, excluded from both deadbands) and re-levers at parity for ~1 bp.
    ///         Distinguishable from SwapperUnderperformed (transient, retry) and the venue's own
    ///         HealthTooLow (opaque).
    error CoverageDeficitTooLarge(uint256 deficit, uint256 collateralRequired);

    event EmergencyYieldRedeemed(uint256 debtAssetReceived);
    event EmergencyLoanUnwound(uint256 collateralRecovered, uint256 debtRecovered);
    event LiquidationComplete(uint256 collateralRecovered, uint256 flashloanAmount);
    event EmergencyCollateralTransferred(uint256 amount);
    event EmergencyDebtTransferred(uint256 amount);
    event AssetsRescued(address indexed token, address indexed recipient, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event RebalanceBountyPaid(address indexed keeper, uint256 amount);
    event StrategyDeposit(address indexed strategy, uint256 debtAmount, uint256 depositedAmount);
    /// @notice Arm-4 skim posted `posted` of `available` collateral to the lender. `posted <
    ///         available` means the venue refused the full amount (supply cap / band bound) and the
    ///         remainder is idle at the vault. Silent partial posting would otherwise be
    ///         indistinguishable from a clean run (audit L-03).
    event CoverageSkimPosted(uint256 available, uint256 posted);

    /// @notice Execute emergency step: 0=withdrawYield, 1=unwindLoan, 2=completeLiquidation
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return setLiquidationComplete Whether to set liquidationComplete = true
    /// @return yieldWithdrawn True when step 0 completed: no strategy, or the strategy's exit
    ///         call succeeded (a 0 return from an already-empty strategy counts as success)
    function executeEmergencyStep(
        uint8 step,
        IYieldStrategy yieldStrategy,
        ILoanManager loanManager,
        IERC20 collateralAsset,
        IERC20 debtAsset,
        ISwapper swapper,
        uint256 lastStrategyBalance,
        uint256 accumulatedFees
    )
        external
        returns (
            uint256 newLastStrategyBalance,
            uint256 newAccumulatedFees,
            bool setLiquidationComplete,
            bool yieldWithdrawn
        )
    {
        newLastStrategyBalance = lastStrategyBalance;
        newAccumulatedFees = accumulatedFees;

        if (step == 0) {
            uint256 withdrawn = 0;
            bool exitSucceeded = false;
            if (address(yieldStrategy) != address(0)) {
                try yieldStrategy.withdrawAll() returns (uint256 r) {
                    withdrawn = r;
                    exitSucceeded = true;
                } catch {
                    try yieldStrategy.emergencyWithdraw() returns (uint256 r) {
                        withdrawn = r;
                        exitSucceeded = true;
                    } catch { }
                }
            }
            // Step 0 is complete when there is no strategy, or when the strategy's exit path ran
            // to completion. Success with withdrawn == 0 means the strategy was already empty
            // (withdrawAll on an empty strategy is a clean no-op) — that must mark the step done,
            // or an idle/already-drained vault would be forced through the 3-day skip path. Only
            // when BOTH calls revert (e.g. stale oracle) is the bit left clear, so the guardian
            // must retry after the oracle recovers or explicitly use the vetoable skip.
            yieldWithdrawn = address(yieldStrategy) == address(0) || exitSucceeded;
            newLastStrategyBalance = 0;
            newAccumulatedFees = 0;
            emit EmergencyYieldRedeemed(withdrawn);
        } else if (step == 1) {
            if (!loanManager.loanExists()) {
                _recoverLoanManagerFunds(loanManager);
                _swapRemainingDebtToCollateral(loanManager, debtAsset, swapper);
                emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
                return (newLastStrategyBalance, newAccumulatedFees, false, false);
            }
            // Send all held debt asset to the loan manager up-front; emergencyUnwindPosition
            // repays min(debt, balance) internally and only needs the (oracle-priced) flashloan
            // path for a shortfall. Routing the repay through the unwind instead of repayDebt()
            // keeps the covered-debt exit oracle-free — a stale Chainlink feed must not block
            // the emergency escape (M-03). Excess debt asset is recovered right after.
            uint256 availableDebt = debtAsset.balanceOf(address(this));
            if (availableDebt > 0) {
                debtAsset.safeTransfer(address(loanManager), availableDebt);
            }
            loanManager.emergencyUnwindPosition();
            _recoverLoanManagerFunds(loanManager);
            _swapRemainingDebtToCollateral(loanManager, debtAsset, swapper);
            emit EmergencyLoanUnwound(collateralAsset.balanceOf(address(this)), 0);
        } else {
            setLiquidationComplete = true;
            emit LiquidationComplete(collateralAsset.balanceOf(address(this)), 0);
        }
    }

    /// @notice Emergency rescue: 0=transferCollateral, 1=transferDebt, 2=redeemYield
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    function executeEmergencyRescue(
        uint8 action,
        IERC20 collateralAsset,
        IERC20 debtAsset,
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        ISwapper swapper,
        uint256 accumulatedFees,
        uint256 lastStrategyBalance
    ) external returns (uint256 newAccumulatedFees, uint256 newLastStrategyBalance) {
        newAccumulatedFees = accumulatedFees;
        newLastStrategyBalance = lastStrategyBalance;
        if (action == 0) {
            uint256 amount = collateralAsset.balanceOf(address(loanManager));
            loanManager.transferCollateral(address(this), amount);
            emit EmergencyCollateralTransferred(amount);
        } else if (action == 1) {
            uint256 amount = debtAsset.balanceOf(address(loanManager));
            loanManager.transferDebt(address(this), amount);
            emit EmergencyDebtTransferred(amount);
        } else {
            uint256 withdrawn = yieldStrategy.emergencyWithdraw();
            newAccumulatedFees = 0;
            newLastStrategyBalance = 0;
            _swapRemainingDebtToCollateral(loanManager, debtAsset, swapper);
            emit EmergencyYieldRedeemed(withdrawn);
        }
    }

    /// @notice Rescue stuck tokens (not collateral/debt) from the vault
    function executeRescueAssets(
        address token,
        address recipient,
        IERC20 collateralAsset,
        IERC20 debtAsset
    ) external {
        if (recipient == address(0)) revert InvalidAddress();
        if (token == address(collateralAsset) || token == address(debtAsset)) {
            revert InvalidAddress();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
        emit AssetsRescued(token, recipient, balance);
    }

    /// @notice Withdraw accumulated fees from yield strategy
    /// @return newAccumulatedFees Updated accumulatedFees value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    function processWithdrawFees(
        address recipient,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 accumulatedFees
    ) external returns (uint256 newAccumulatedFees, uint256 newLastStrategyBalance) {
        uint256 fees = accumulatedFees;
        if (fees == 0) return (0, yieldStrategy.balanceOf());

        newAccumulatedFees = 0;

        uint256 strategyBalance = yieldStrategy.balanceOf();
        uint256 debtBefore = debtAsset.balanceOf(address(this));
        if (strategyBalance > 0 && fees > 0) {
            uint256 toWithdraw = fees > strategyBalance ? strategyBalance : fees;
            if (toWithdraw > 0) {
                uint256 received = yieldStrategy.withdraw(toWithdraw);
                debtBefore += received;
            }
        }
        newLastStrategyBalance = yieldStrategy.balanceOf();

        uint256 toTransfer = fees > debtBefore ? debtBefore : fees;
        if (toTransfer > 0) {
            debtAsset.safeTransfer(recipient, toTransfer);
        }

        emit FeesWithdrawn(recipient, toTransfer);
    }

    /// @notice Process rebalance keeper bounty payment
    /// @dev Keeper gets bountyRate% of fees accrued since last rebalance. Admin fees stay in strategy.
    /// @return newFeesAtLastRebalance Updated feesAtLastRebalance value
    /// @return newLastStrategyBalance Updated lastStrategyBalance value
    /// @return bountyPaid Actual bounty amount withdrawn and paid to keeper (must be deducted from accumulatedFees)
    function processRebalanceBounty(
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 accumulatedFees,
        uint256 feesAtLastRebalance,
        uint256 rebalanceBountyRate,
        uint256 precision,
        address keeper
    )
        external
        returns (uint256 newFeesAtLastRebalance, uint256 newLastStrategyBalance, uint256 bountyPaid)
    {
        newFeesAtLastRebalance = feesAtLastRebalance;

        if (rebalanceBountyRate > 0 && accumulatedFees > feesAtLastRebalance) {
            uint256 feesSinceLastRebalance = accumulatedFees - feesAtLastRebalance;
            uint256 bounty = (feesSinceLastRebalance * rebalanceBountyRate) / precision;

            if (bounty > 0) {
                uint256 strategyBalance = yieldStrategy.balanceOf();
                uint256 toWithdraw = bounty > strategyBalance ? strategyBalance : bounty;
                if (toWithdraw > 0) {
                    uint256 withdrawn = yieldStrategy.withdraw(toWithdraw);
                    bountyPaid = withdrawn > bounty ? bounty : withdrawn;
                    if (bountyPaid > 0) {
                        debtAsset.safeTransfer(keeper, bountyPaid);
                        emit RebalanceBountyPaid(keeper, bountyPaid);
                    }
                }
            }

            newFeesAtLastRebalance = accumulatedFees;
        }

        newLastStrategyBalance = yieldStrategy.balanceOf();
    }

    /// @notice Increase strategy/debt coverage when strategy assets fall below debt (S < D).
    /// @dev Plan B: collateral-funded repay. NOTE: _accrueYieldFees is intentionally skipped —
    ///      rebalance() already called it.
    ///
    ///      WHY THIS MUST FUND FROM COLLATERAL (do not "fix" this by funding from the strategy
    ///      again): `D - S` is CONSERVED under any operation that moves the strategy and the debt
    ///      by the same amount — withdraw `w` from strategy + repay `w` of debt leaves S-w, D-w,
    ///      delta(D-S) = 0; borrow `b` + deposit `b` into strategy leaves S+b, D+b, delta(D-S) = 0.
    ///      A strategy-funded repay (the old implementation) therefore leaves the deficit
    ///      identical before and after — only the ratio S/D degrades, since S shrinks while D-S is
    ///      unchanged. Closing the deficit needs value from OUTSIDE the S/D pair. Harvest yield is
    ///      not available on demand, so the only source is collateral (equity). This function
    ///      removes collateral, swaps it to the debt asset, and repays — never touching the
    ///      strategy — which is the one operation that actually shrinks `D - S`.
    ///
    ///      Steps: size collateral for the FULL deficit via quoteCollateralForDebt (which ALREADY
    ///      grosses up by the swapper's own slippage -- do not buffer again; reverts
    ///      DeficitExceedsCollateral if the desired amount exceeds total collateral) -> cap the
    ///      removal to what current health allows via a binary-searched safe-removal cap (below;
    ///      M-02 partial-progress fix) -> if the safe cap can't close a meaningful fraction of the
    ///      deficit, revert CoverageDeficitTooLarge instead of grinding or reverting opaquely ->
    ///      removeCollateral + transferCollateral to pull it to the vault (health is ALSO enforced
    ///      by the venue adapter as a backstop: Aave reverts on MIN_HEALTH, LlamaLend enforces
    ///      internally -- the safe-removal cap should keep us clear of it with margin to spare) ->
    ///      swap collateral -> debt asset via the configured swapper (floored HERE against the
    ///      oracle at MIN_SWAP_OUT_BPS -- the swappers carry no end-to-end floor of their own) ->
    ///      repay, capped at the deficit so coverage cannot overshoot the +spread bound (any
    ///      surplus debt asset is left at the vault, see below) -> postcondition: coverage must
    ///      have STRICTLY increased, or the call reverts.
    ///
    ///      PARTIAL PROGRESS + MULTI-TICK CONVERGENCE (M-02 follow-up): when the full deficit
    ///      cannot be closed in one call without breaching health, this function now closes as
    ///      much as is SAFE (bounded by the health floor below) rather than reverting with no
    ///      progress at all. A partial step repays `r < deficit`; coverage strictly rises (the
    ///      postcondition still enforces this), LTV falls, and the health headroom for the NEXT
    ///      call grows because debt is lower -- so successive keeper ticks take larger bites and
    ///      convergence is monotone and accelerating. The keeper re-evaluates every tick and
    ///      `strategyDebtRebalanceNeeded()` stays true until the band is reached, so no new
    ///      triggering mechanism is required. See COVERAGE_PARTIAL_PROGRESS_PLAN.md S 3.
    ///
    ///      SAFE-REMOVAL CAP: `ILoanManager.healthCalculator(int256 dCollateral, int256 dDebt)` is
    ///      used to project health AFTER removing `c` collateral but BEFORE the repay
    ///      (`dDebt = 0` deliberately -- the venue's own check runs in that exact order, so the
    ///      projection must model that exact intermediate state, not the post-repay state). Health
    ///      is monotonically non-increasing in removed collateral, so the largest safe `c` is found
    ///      by a fixed 8-iteration "largest c such that predicate(c) holds" binary search over
    ///      `[0, cDesired]` -- bounded gas, no unbounded loop, 1/256 precision on cDesired.
    ///      `healthFloor = MIN_HEALTH * HEALTH_FLOOR_MARGIN_PCT / 100` carries a margin above the
    ///      venue's own MIN_HEALTH because LlamaLend's `remove_collateral` can revert on its own
    ///      band bound BEFORE our MIN_HEALTH check ever fires (observed in
    ///      `test_llamaRemoveCollateral_healthTooLow_reverts`) -- a projection that only just
    ///      clears MIN_HEALTH is not proof the venue will accept it. The margin also absorbs oracle
    ///      drift between this projection and execution. `MIN_HEALTH` differs per venue (Aave
    ///      1.1e18, LlamaLend 1e17) and is read from the loan manager rather than hardcoded.
    ///
    ///      ALL-OR-NOTHING: arm 3 removes the full required collateral or reverts. Partial steps
    ///      were implemented, measured, and rejected -- they reintroduced the deadlock this arm
    ///      exists to fix (a partial repay drags LTV past lowerBand, handing priority to arm 1,
    ///      whose coverage guard then refuses) and cost more than the operator escape they were
    ///      meant to replace. See the detailed note at the feasibility probe in the body.
    ///      `CoverageDeficitTooLarge(deficit, collateralRequired)` is the actionable signal M-02
    ///      asked for -- distinguishable from `SwapperUnderperformed` (transient, retry) and
    ///      `HealthTooLow` (opaque, venue-level) -- and tells the operator to run setIdle/unIdle.
    ///
    ///      ACCEPTED RISK (H-01): `deficit` is spot-manipulable. balanceOf() is
    ///      min(vpBased, exitBased); the VP leg is clamped to +/-0.5% but exitBased
    ///      (calc_withdraw_one_coin) is raw spot, and rebalance() has NO same-block cooldown. Any
    ///      caller can manufacture a coverage breach and force a collateral sale. Accepted because
    ///      the collateral swap uses a different venue than the LP pool AND is floored at
    ///      MIN_SWAP_OUT_BPS, the bounty is not farmable, and the skew cost exceeds the gain by
    ///      orders of magnitude. See "Accepted Risk — H-01" in AUDIT_CoverageRebalance_v2.md for
    ///      the full analysis and the four conditions that require it to be revisited. The
    ///      safe-removal cap does not change this analysis: a manufactured deficit now yields a
    ///      bounded partial sale (still floored at MIN_SWAP_OUT_BPS) rather than a revert.
    ///
    ///      Read that last guard precisely: it bounds the RATIO, not value. Arm 3 never touches S,
    ///      so `newCoverage > startCoverage` reduces to `toRepay > 0` and the collateral spent
    ///      never enters the expression. It prevents the old bug class (an operation that looks
    ///      corrective while moving the ratio backwards); it does NOT bound value loss. The value
    ///      bound is the MIN_SWAP_OUT_BPS floor on the swap. This holds unchanged on the partial
    ///      path: a partial step that does not improve coverage still reverts.
    ///
    ///      SURPLUS HANDLING: any debt-asset surplus after the capped repay stays at the vault
    ///      rather than being redeployed into the strategy. Redeploying would interact with the
    ///      `lastStrategyBalance` fee-accrual baseline (out of scope for this fix); the surplus is
    ///      swept up on the next `_swapRemainingDebtToCollateral`-style flow or a subsequent
    ///      deposit/rebalance cycle.
    ///
    ///      DUST FLOOR: if the deficit is at or below one whole unit of the debt asset (same
    ///      dust convention `_swapRemainingDebtToCollateral` already uses, and comparable in
    ///      magnitude to each loan manager's own `DUST_THRESHOLD`, i.e. ~$1 for the stablecoin
    ///      debt assets this vault uses), this function returns without mutating state — the
    ///      deadband absorbs it rather than paying slippage + a keeper bounty for a no-op-sized
    ///      correction.
    ///
    ///      If no swapper is configured, this function returns the current strategy balance
    ///      without reverting (some deployments may not have a swapper set) — the deficit is left
    ///      for the operational idle/unidle mitigation.
    /// @return newLastStrategyBalance Updated strategy balance for vault to store.
    function rebalanceCoverageUp(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        IERC20 collateralAsset,
        ISwapper swapper,
        uint256 accumulatedFees,
        uint256 precision
    ) external returns (uint256 newLastStrategyBalance) {
        uint256 debt = loanManager.getCurrentDebt();
        if (debt == 0) return yieldStrategy.balanceOf();

        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance >= debt) return strategyBalance;

        if (address(swapper) == address(0)) return strategyBalance;

        uint256 deficit = debt - strategyBalance;

        // Dust floor: not worth paying slippage + a keeper bounty to close a sub-$1 deficit.
        // Same convention as _swapRemainingDebtToCollateral's dust check below.
        if (deficit <= 10 ** debtAsset.decimals()) return strategyBalance;

        uint256 startCoverage = (strategyBalance * precision) / debt;

        // 0. Spend idle debt asset FIRST. Repaying from tokens the vault already holds reduces D
        //    without touching S, so it is convergent, NAV-neutral and costs ZERO slippage --
        //    strictly better than selling collateral for the same amount. Sources: surplus left by
        //    a previous arm-3 call (the repay is capped at `deficit`), residual transferDebt from
        //    unwind paths, and donations.
        //
        //    RESERVE accumulatedFees. processWithdrawFees pays fees from
        //    (idle balance + a strategy withdrawal capped at strategyBalance) and zeroes
        //    accumulatedFees BEFORE it knows whether the transfer covered them, so a shortfall is
        //    silently forfeited. Arm 3 runs exactly when the strategy is under-covered, so do not
        //    consume the strategist's claim to buy a slightly smaller collateral sale.
        {
            uint256 idle = debtAsset.balanceOf(address(this));
            uint256 usable = idle > accumulatedFees ? idle - accumulatedFees : 0;
            if (usable > 0) {
                uint256 fromIdle = usable < deficit ? usable : deficit;
                debtAsset.safeTransfer(address(loanManager), fromIdle);
                loanManager.repayDebt(fromIdle);
                deficit -= fromIdle;
            }
        }

        //    Idle balance covered it (or all that is left is dust): D fell, S is untouched, so
        //    coverage strictly improved. Skip the collateral sale entirely and settle up.
        if (deficit <= 10 ** debtAsset.decimals()) {
            uint256 idleOnlyStrategyBalance = yieldStrategy.balanceOf();
            uint256 idleOnlyDebt = loanManager.getCurrentDebt();
            uint256 idleOnlyCoverage = idleOnlyDebt == 0
                ? type(uint256).max
                : (idleOnlyStrategyBalance * precision) / idleOnlyDebt;
            if (idleOnlyCoverage <= startCoverage) revert CoverageDidNotImprove();
            return idleOnlyStrategyBalance;
        }

        // 1. Size the collateral for the REMAINING deficit. quoteCollateralForDebt ALREADY grosses up
        //    by the swapper's own slippage (`collateralOut * P / (P - slippage) + 1`), so do NOT
        //    buffer again here -- doing so over-removes collateral on every call.
        uint256 cDesired = swapper.quoteCollateralForDebt(deficit);
        if (cDesired == 0) return strategyBalance;
        //    Do not silently cap at total collateral: that hands the venue an unsatisfiable
        //    removal and reverts opaquely. Surface it instead -- a deficit this large is an
        //    insolvency signal, not drift, and wants manual handling (setIdle/unIdle).
        uint256 currentCollateral = loanManager.getCurrentCollateral();
        if (cDesired > currentCollateral) {
            revert DeficitExceedsCollateral(cDesired, currentCollateral);
        }

        // 1b. Feasibility probe. Arm 3 removes the FULL cDesired or nothing at all.
        //
        //     PARTIAL PROGRESS WAS TRIED AND REJECTED (measured, not theorised). A safe-removal
        //     binary search that took a bounded partial step REINTRODUCED the very deadlock this
        //     arm exists to fix: on XAUT/Aave a 35% loss took one successful step (coverage
        //     6496 -> 7424 bps) but dragged LTV 60.00% -> 56.78%, past lowerBand (57%). The next
        //     call therefore dispatched to arm 1, whose enforceCoverageAfterIncrease guard refuses
        //     while coverage is still 74%, and rebalance() reverted permanently -- a 30-day warp
        //     moved LTV only to 56.97%, so interest never rescues it. It also cost MORE than the
        //     escape it was meant to replace: ~5 bps for the partial tick, and setIdle/unIdle
        //     (3-13 bps) still required afterwards. The premise it broke is stated in
        //     rebalance()'s NatSpec: arm 3 must reach parity in ONE call, or arm 1 takes priority
        //     with coverage still out of band. Do not reintroduce partial steps without also
        //     addressing dispatch order.
        //
        //     What remains is the useful half: a single projection probe so an infeasible removal
        //     surfaces an ACTIONABLE error naming the operator's next move, instead of an opaque
        //     venue-level HealthTooLow.
        //
        //     VENUE ASYMMETRY (measured): this probe is meaningful on Aave, whose healthCalculator
        //     is a true projection over oracle values. On LlamaLend the projection is
        //     near-insensitive to d_collateral -- removing 1% vs 5% of collateral moved health by
        //     ~1e-11 relative -- so it effectively always passes there and the real bound stays the
        //     venue's own band check plus the MIN_HEALTH guard in removeCollateral. That is exactly
        //     the pre-existing LlamaLend behaviour, which already absorbs a 25% loss in one call.
        //
        //     NOTE: probe with healthCalculator, never healthCalculator(0, 0) as a current-health
        //     proxy. Curve's health_calculator is built for CHANGES and returns -1e18 on a
        //     zero-delta call while health(user, true) reports +0.449e18 on the same position.
        int256 healthFloor =
            (IMinHealth(address(loanManager)).MIN_HEALTH() * int256(HEALTH_FLOOR_MARGIN_PCT)) / 100;
        // Safe cast: cDesired <= currentCollateral, a real token balance many orders of magnitude
        // below type(int256).max.
        if (loanManager.healthCalculator(-int256(cDesired), 0) < healthFloor) {
            revert CoverageDeficitTooLarge(deficit, cDesired);
        }
        uint256 c = cDesired;

        // 2. Free the collateral to the vault. Health is ALSO enforced by the venue adapter as a
        //    backstop (Aave reverts on MIN_HEALTH; LlamaLend enforces internally) -- the
        //    safe-removal cap above should keep us clear of it with margin to spare.
        loanManager.removeCollateral(c);
        loanManager.transferCollateral(address(this), c);

        // 3. Convert collateral -> debt asset.
        //    C-01: this is a DIRECT ISwapper call from the vault, so it bypasses
        //    LlamaLoanManager/AaveLoanManager._swapCollateralForDebt and their SwapperUnderperformed
        //    check. The swappers rely on that check as their hard end-to-end floor, so it is
        //    re-applied here against the oracle-implied value of the collateral we are spending.
        //    This is also the value bound on the whole operation: collateral leaves, debt tokens
        //    arrive, and the gap between them is capped at (100 - MIN_SWAP_OUT_BPS/100)%.
        uint256 expectedDebt = (loanManager.getCollateralValue(c) * MIN_SWAP_OUT_BPS) / 10000;
        collateralAsset.safeTransfer(address(swapper), c);
        uint256 received = swapper.swapCollateralForDebt(c);
        if (received < expectedDebt) revert SwapperUnderperformed(expectedDebt, received);

        // 4. Repay, capped at the deficit so coverage cannot overshoot the +spread bound. Any
        //    surplus stays at the vault — see SURPLUS HANDLING above.
        uint256 toRepay = received < deficit ? received : deficit;
        if (toRepay > 0) {
            debtAsset.safeTransfer(address(loanManager), toRepay);
            loanManager.repayDebt(toRepay);
        }

        // 5. Postcondition: coverage must have strictly improved, or revert. This bounds the
        //    RATIO only -- it prevents the old bug class (an operation that looks corrective while
        //    moving the ratio backwards) but it CANNOT bound value loss: arm 3 never touches S, so
        //    `newCoverage > startCoverage` reduces to `toRepay > 0` and the collateral spent does
        //    not appear in it at all. The value bound is the MIN_SWAP_OUT_BPS floor in step 3 --
        //    do not mistake this check for one.
        uint256 newStrategyBalance = yieldStrategy.balanceOf();
        uint256 newDebt = loanManager.getCurrentDebt();
        uint256 newCoverage =
            newDebt == 0 ? type(uint256).max : (newStrategyBalance * precision) / newDebt;
        if (newCoverage <= startCoverage) revert CoverageDidNotImprove();

        return newStrategyBalance;
    }

    /// @notice Decrease strategy/debt coverage when strategy assets are too far above debt, by
    ///         skimming the surplus out of the strategy and posting it as collateral.
    /// @dev NOTE: _accrueYieldFees is intentionally skipped — rebalance() already called it.
    ///
    ///      WHY THIS MUST SKIM TO COLLATERAL (do not "fix" this by borrowing-and-depositing
    ///      again): the old implementation borrowed `X` debt and deposited it into the SAME
    ///      strategy, raising `S` by exactly what it raised `D`. Post-call coverage is
    ///      `(S+X)/(D+X)`, not the intended `S/(D+X)` -- the recurrence `c' = 2.03 - 1.03/c` has
    ///      fixed points 1.00 and 1.03, so repeated calls converge asymptotically TOWARD the band
    ///      edge and never cross it. Measured on a live fork: WBTC/Llama coverage moved
    ///      105.82% -> 103.28% over 60 consecutive `rebalance()` calls, still out of band; XAUT/Aave
    ///      sawtoothed against arm 2 and never cleared either bound. Correct sizing does not rescue
    ///      the borrow-and-deploy design either: closing the ratio purely by borrowing more implies
    ///      levering 2.33x current debt at 110% coverage and 10.7x at 135%, so the LTV ceiling
    ///      always binds first. A coverage surplus cannot be closed by levering up -- the amount
    ///      that is actually wrong is the surplus itself, so that is what must move. This is the
    ///      exact mirror of the shipped arm-3 fix (rebalanceCoverageUp): arm 3 funds a repay from
    ///      collateral to shrink `D - S`; arm 4 skims strategy surplus into collateral to shrink
    ///      `S - D`. Both move the smallest sufficient amount and target PARITY (1.00), never the
    ///      band edge (1.03) -- at the moment of trigger the surplus above the edge is zero by
    ///      definition, so targeting the edge would skim nothing and re-trigger immediately, the
    ///      same degenerate class as the bug being fixed here.
    ///
    ///      Steps: size the skim as `S - debt` (lands at exactly 1.00 coverage in ONE call) ->
    ///      dust floor (same convention as arm 3) -> withdraw the surplus from the strategy
    ///      (slippage-checked the way adjustLtv's decrease path checks its own withdrawal) -> swap
    ///      debt asset -> collateral asset via the configured swapper (floored HERE against the
    ///      oracle -- see below, this is a DIRECT ISwapper call so it bypasses the loan managers'
    ///      SwapperUnderperformed check) -> post the proceeds as collateral, capped defensively at
    ///      whatever the lending venue will accept (see SUPPLY-CAP HANDLING below) -> postcondition:
    ///      coverage must have STRICTLY decreased, or the call reverts.
    ///
    ///      ORACLE FLOOR (mirrors the C-01 fix on arm 3, and Zenji._swapRemainingDebtToCollateral):
    ///      this is a direct ISwapper call from the vault, so it bypasses
    ///      LlamaLoanManager/AaveLoanManager._swapCollateralForDebt and their SwapperUnderperformed
    ///      check entirely -- the swappers carry no end-to-end floor of their own and document the
    ///      loan manager's check as the hard floor. The floor here is
    ///      `max(swapper.slippage(), maxSlippage * 2)` against `loanManager.getDebtValue(received)`,
    ///      not a naive `maxSlippage`-only floor: `getDebtValue` reads a direct oracle while the
    ///      swapper traverses a (possibly multi-hop) path, so the two prices can legitimately
    ///      diverge by up to ~2x maxSlippage even on a fair swap -- a naive floor would reject good
    ///      swaps. The swapper's self-reported slippage is clamped to 5% (matching
    ///      BaseSwapper.MAX_SLIPPAGE / the clamp in Zenji._swapRemainingDebtToCollateral) so a
    ///      malicious or misconfigured swapper cannot hollow out this floor.
    ///
    ///      POSTCONDITION BOUNDS THE RATIO, NOT VALUE (per arm-3 C-02, same lesson applies here):
    ///      `newCoverage < startCoverage` catches an operation that looks corrective while actually
    ///      moving the ratio the wrong way (or not at all -- e.g. a fully supply-cap-blocked skim,
    ///      see below). It does NOT bound value loss; that bound is the oracle floor above. Do not
    ///      mistake one check for the other.
    ///
    ///      SUPPLY-CAP HANDLING (failure modes #2 and #4 -- Aave supply cap / LlamaLend band
    ///      assertion on addCollateral): `ILoanManager` has no view to project a supply cap or read
    ///      remaining headroom (adding one would force every ILoanManager mock in the test suite to
    ///      implement it, mirroring the reasoning for `IMinHealth` above), so this cannot be sized
    ///      up front the way arm 3 sizes its collateral removal against `healthCalculator`. Instead
    ///      `addCollateral` is attempted defensively: try the full amount; on revert, pull the
    ///      un-supplied tokens back and retry at half, halving down for a bounded number of
    ///      attempts. Whatever fraction succeeds is posted; any remainder is left at the vault as
    ///      idle collateral (same convention as arm 3's SURPLUS HANDLING -- picked up by a
    ///      subsequent deposit/rebalance cycle) rather than reverting the whole call. Reverting
    ///      outright would brick arm 4 exactly when the vault is most profitable (a large,
    ///      cap-constrained surplus), and a *capped-to-zero* skim is not a silent no-op the way the
    ///      replaced implementation's non-convergent design was: the strategy withdrawal in step 1
    ///      already happened regardless of how much collateral posting succeeds, so `S` has already
    ///      fallen and the postcondition still enforces strict improvement. This is safe to leave
    ///      partial (unlike arm 3, where partial progress was tried and reverted on principle -- see
    ///      rebalanceCoverageUp's NatSpec): a capped skim leaves coverage above the band and LTV
    ///      lower, which hands the next tick to arm 1 (LTV-low, levers up). Both arms move coverage
    ///      the same direction when coverage > 1 (arm 4 skim: S down, D same -> coverage down; arm 1
    ///      lever-up: `(S+b)/(D+b)` moves toward 1 from above -> coverage down), so they cooperate
    ///      rather than deadlock -- unlike the low-coverage side, arm 1's
    ///      `enforceCoverageAfterIncrease` guard has no equivalent block on the high side.
    ///
    ///      LTV EFFECT: unlike the replaced implementation (which borrowed, raising LTV), this
    ///      skims strategy value into collateral without touching debt, so LTV FALLS. See the
    ///      updated dispatch table in `rebalance()`'s NatSpec.
    ///
    ///      If no swapper is configured, this function returns the current strategy balance without
    ///      reverting (some deployments may not have a swapper set) -- same convention as arm 3.
    /// @return newLastStrategyBalance Updated strategy balance for vault to store.
    function rebalanceCoverageDown(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        IERC20 collateralAsset,
        ISwapper swapper,
        uint256 maxSlippage,
        uint256 precision
    ) external returns (uint256 newLastStrategyBalance) {
        uint256 debt = loanManager.getCurrentDebt();
        if (debt == 0) return yieldStrategy.balanceOf();

        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance <= debt) return strategyBalance;

        if (address(swapper) == address(0)) return strategyBalance;

        uint256 surplus = strategyBalance - debt;

        // Dust floor: not worth paying slippage + a keeper bounty to skim a sub-$1 surplus.
        // Same convention as rebalanceCoverageUp's deficit dust check.
        if (surplus <= 10 ** debtAsset.decimals()) return strategyBalance;

        uint256 startCoverage = (strategyBalance * precision) / debt;

        // 1. Withdraw EXACTLY the surplus from the strategy -- deliberately unpadded.
        //
        //    Do NOT copy adjustLtv's `* 105 / 100` pad here. That path needs at least `toRepay` in
        //    hand to complete a repay, so it over-requests on purpose. Arm 4 has no such
        //    requirement: it skims, and whatever arrives is what gets swapped.
        //
        //    Padding is actively harmful here (audit M-01). BaseLPStrategy._withdraw redeems shares
        //    proportional to the REQUEST, so a 1.05x request destroys 1.05x the strategy value while
        //    minReceived is measured against the unpadded surplus. That would:
        //      (a) widen the real exit tolerance to 1 - 0.99/1.05 = 5.71%, against a configured 1% --
        //          making this leg the weakest link in the whole value bound;
        //      (b) undershoot parity systematically: post-coverage = 1.05 - 0.05*c, which drops
        //          below 0.97 once c > 1.60 and hands the next tick to ARM 3 -- the expensive arm,
        //          and the one carrying accepted risk H-01; and
        //      (c) waste 5% of every skim on a pointless debt->collateral->borrow round trip.
        //
        //    Unpadded, S falls by exactly `surplus`, so coverage lands on 1.0000 for any starting c.
        uint256 received = yieldStrategy.withdraw(surplus);
        uint256 minReceived = (surplus * (precision - maxSlippage)) / precision;
        if (received < minReceived) revert InsufficientWithdrawal();

        // 2. Convert debt asset -> collateral, ORACLE-FLOORED. C-01 on arm 3 applies identically
        //    here: this is a DIRECT ISwapper call, bypassing the loan managers' own
        //    SwapperUnderperformed check. See ORACLE FLOOR in the function NatSpec for why the
        //    floor is max(swapper.slippage(), maxSlippage*2) rather than a naive maxSlippage floor.
        uint256 oracleExpected = loanManager.getDebtValue(received);
        uint256 swapperSlippage = ISwapperSlippage(address(swapper)).slippage();
        if (swapperSlippage > 5e16) swapperSlippage = 5e16;
        uint256 effectiveSlippage =
            swapperSlippage > maxSlippage * 2 ? swapperSlippage : maxSlippage * 2;
        uint256 floor = (oracleExpected * (precision - effectiveSlippage)) / precision;

        //    Measure the output as a VAULT-SIDE BALANCE DELTA, not the swapper's return value
        //    (audit L-01). Both existing precedents do this -- Zenji._swapRemainingDebtToCollateral
        //    and LlamaLoanManager._swapCollateralForDebt -- because the return value is the
        //    swapper's own claim about a swap it just performed, and the swapper is rotatable by
        //    governance behind a timelock.
        uint256 collateralBefore = collateralAsset.balanceOf(address(this));
        debtAsset.safeTransfer(address(swapper), received);
        swapper.swapDebtForCollateral(received);
        uint256 collateralOut = collateralAsset.balanceOf(address(this)) - collateralBefore;
        if (collateralOut < floor) revert SwapperUnderperformed(floor, collateralOut);

        // 3. Post the proceeds as collateral. Defensive against a supply cap / venue-side band
        //    assertion (failure modes #2, #4): try the full amount, then halve down and retry on
        //    revert, bounded at 6 attempts (>=1/64 granularity of collateralOut). Whatever succeeds
        //    is posted; any remainder is pulled back and left idle at the vault -- see SUPPLY-CAP
        //    HANDLING in the function NatSpec for why partial progress is safe here.
        uint256 candidate = collateralOut;
        uint256 posted;
        for (uint256 i = 0; i < 6 && candidate > 0; i++) {
            collateralAsset.safeTransfer(address(loanManager), candidate);
            try loanManager.addCollateral(candidate) {
                posted = candidate;
                break;
            } catch {
                loanManager.transferCollateral(address(this), candidate);
                candidate = candidate / 2;
            }
        }
        emit CoverageSkimPosted(collateralOut, posted);

        // 4. Postcondition: coverage must have strictly decreased, or revert. Bounds the RATIO
        //    only -- see POSTCONDITION BOUNDS THE RATIO, NOT VALUE in the function NatSpec. This is
        //    the check arm 4 has never had; its absence is what let the borrow-and-deploy bug
        //    survive three audits.
        newLastStrategyBalance = yieldStrategy.balanceOf();
        uint256 newDebt = loanManager.getCurrentDebt();
        uint256 newCoverage =
            newDebt == 0 ? type(uint256).max : (newLastStrategyBalance * precision) / newDebt;
        if (newCoverage >= startCoverage) revert CoverageDidNotImprove();

        return newLastStrategyBalance;
    }

    /// @notice Adjust LTV toward target by borrowing more or repaying debt.
    /// @dev Inlines the strategy deposit/withdraw logic without re-accruing fees because
    ///      `rebalance()` already accrued them before calling into the library.
    function adjustLtv(
        ILoanManager loanManager,
        IYieldStrategy yieldStrategy,
        IERC20 debtAsset,
        uint256 targetLtv,
        uint256 minStrategyToDebtRatioForBorrow,
        uint256 maxSlippage,
        uint256 precision,
        bool increase,
        bool enforceCoverageAfterIncrease
    ) external returns (uint256 newLastStrategyBalance) {
        (uint256 collateral, uint256 currentDebt) = loanManager.getPositionValues();
        uint256 collateralValue = loanManager.getCollateralValue(collateral);
        uint256 targetDebt = (collateralValue * targetLtv) / precision;

        if (increase) {
            if (targetDebt <= currentDebt) return yieldStrategy.balanceOf();

            uint256 additionalBorrow = targetDebt - currentDebt;
            loanManager.borrowMore(0, additionalBorrow);
            uint256 debtBalance = loanManager.getDebtBalance();
            if (debtBalance == 0) return yieldStrategy.balanceOf();

            loanManager.transferDebt(address(this), debtBalance);
            debtAsset.ensureApproval(address(yieldStrategy), debtBalance);

            uint256 balBefore = yieldStrategy.balanceOf();
            yieldStrategy.deposit(debtBalance);
            uint256 balAfter = yieldStrategy.balanceOf();
            uint256 deposited = balAfter > balBefore ? balAfter - balBefore : 0;
            if (deposited < (debtBalance * (precision - maxSlippage)) / precision) {
                revert InsufficientDeposit();
            }
            emit StrategyDeposit(address(yieldStrategy), debtBalance, deposited);

            if (enforceCoverageAfterIncrease) {
                uint256 debt = loanManager.getCurrentDebt();
                if (debt > 0) {
                    uint256 ratio = (balAfter * precision) / debt;
                    if (ratio < minStrategyToDebtRatioForBorrow) {
                        revert StrategyDebtCoverageTooLow(ratio, minStrategyToDebtRatioForBorrow);
                    }
                }
            }

            return balAfter;
        }

        if (targetDebt >= currentDebt) return yieldStrategy.balanceOf();

        uint256 toRepay = currentDebt - targetDebt;
        uint256 strategyBalance = yieldStrategy.balanceOf();
        if (strategyBalance > 0) {
            uint256 toWithdraw = toRepay > strategyBalance ? strategyBalance : toRepay;
            if (toWithdraw > 0) {
                uint256 withdrawRequest = (toWithdraw * 105) / 100;
                if (withdrawRequest > strategyBalance) withdrawRequest = strategyBalance;
                uint256 received = yieldStrategy.withdraw(withdrawRequest);
                uint256 minReceived = (toWithdraw * (precision - maxSlippage)) / precision;
                if (received < minReceived) revert InsufficientWithdrawal();
            }
        }

        newLastStrategyBalance = yieldStrategy.balanceOf();
        uint256 availableDebtBalance = debtAsset.balanceOf(address(this));
        uint256 repayAmount = toRepay < availableDebtBalance ? toRepay : availableDebtBalance;
        if (repayAmount > 0) {
            debtAsset.safeTransfer(address(loanManager), repayAmount);
            loanManager.repayDebt(repayAmount);
        }
    }

    // ============ Internal Helpers ============

    function _recoverLoanManagerFunds(ILoanManager loanManager) private {
        uint256 lmCollateral = loanManager.getCollateralBalance();
        if (lmCollateral > 0) {
            loanManager.transferCollateral(address(this), lmCollateral);
        }
        uint256 lmDebt = loanManager.getDebtBalance();
        if (lmDebt > 0) loanManager.transferDebt(address(this), lmDebt);
    }

    function _swapRemainingDebtToCollateral(
        ILoanManager loanManager,
        IERC20 debtAsset,
        ISwapper swapper
    ) private {
        uint256 debtBal = debtAsset.balanceOf(address(this));
        if (debtBal > 10 ** debtAsset.decimals() && address(swapper) != address(0)) {
            // Best-effort: the swapper's price floor is derived from the same Chainlink feeds
            // the loan manager checks. While stale, the swap would revert and take the whole
            // emergency step down with it — keep the debt asset at the vault instead; re-running
            // the step once the feed heals converts it (M-03).
            try loanManager.checkOracleFreshness() { }
            catch {
                return;
            }
            debtAsset.safeTransfer(address(swapper), debtBal);
            swapper.swapDebtForCollateral(debtBal);
        }
    }
}
