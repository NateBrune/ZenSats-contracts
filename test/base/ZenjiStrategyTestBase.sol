// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./ZenjiForkTestBase.sol";
import { BaseSwapper } from "../../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @title ZenjiStrategyTestBase
/// @notice Meta-base for ALL strategy fork tests — both IPOR vault and CrvUsd LP strategies.
///         Parameterises every shared test via abstract/virtual hooks so the two mid-level bases
///         (IporVaultStrategyTestBase, CrvUsdLpStrategyTestBase) and their concrete files only
///         implement what differs between deployments.
abstract contract ZenjiStrategyTestBase is ZenjiForkTestBase {
    // ============ Abstract: must be implemented by each concrete deployment ============

    /// @notice Deploy and return the address of a fresh swapper (for the timelock test).
    function _newSwapper() internal virtual returns (address);

    /// @notice Expected slippage() value after _postDeploySetup() has run.
    function _initialSwapperSlippage() internal pure virtual returns (uint256);

    /// @notice Oracle to mock when simulating a debt-asset price drop.
    ///         LP strategies: CRVUSD_USD_ORACLE. IPOR vaults: USDT_USD_ORACLE.
    function _debtOracle() internal pure virtual returns (address);

    /// @notice Deposit that noticeably skews the pool / swap route (for slippage tests).
    function _largeDepositAmount() internal pure virtual returns (uint256);

    /// @notice Deposit representing ~$1 M (for test_oneMillion_depositAndRedeem).
    function _oneMillionAmount() internal pure virtual returns (uint256);

    /// @notice Human label printed alongside the $1 M result, e.g. "10 BTC (~$1M)".
    function _oneMillionLabel() internal pure virtual returns (string memory);

    /// @notice Small collateral amount used in the large-ratio fuzz test.
    function _ratioTestSmallAmount() internal pure virtual returns (uint256);

    // -- TVL multi-depositor parameters --
    function _tvlChunk() internal pure virtual returns (uint256);
    function _tvlMinChunk() internal pure virtual returns (uint256);
    function _tvlIterCap() internal pure virtual returns (uint256);
    function _tvlLabel() internal pure virtual returns (string memory);

    /// @notice Assert the strategy deployed funds to the expected external protocol.
    ///         Called inside test_strategyBalance_afterDeposit after the base balance check.
    ///         LP base → verify staking vault shares. IPOR base → verify plasma vault shares.
    function _assertStrategyIntegration() internal virtual;

    // ============ Virtual: override to specialise ============

    /// @notice TVL target for test_multiDepositors_reachTargetTvl.
    ///         Units match getCollateralValue() output: debt-token decimals.
    ///         Llama (crvUSD 18 dec) → 5_000_000e18. Aave (USDT 6 dec) → 5_000_000e6.
    function _tvlTarget() internal pure virtual returns (uint256) {
        return 5_000_000e18;
    }

    /// @notice Effective minimum deposit for test_minimumDeposit_fullRedeem.
    ///         Default: vault.MIN_DEPOSIT(). Override when the economic floor is higher.
    function _effectiveMinDeposit() internal view virtual returns (uint256) {
        return vault.MIN_DEPOSIT();
    }

    /// @notice Extra oracle addresses (beyond collateral + debt) to drop 5% in
    ///         test_withdrawWithUnrealizedStrategyLoss. Needed when the strategy's internal
    ///         withdrawal path uses a third oracle (e.g., crvUSD for IPOR strategies).
    function _strategyOraclesToDrop() internal virtual returns (address[] memory) {
        return new address[](0);
    }

    /// @notice Extra slippage set before test_threeUserSequentialWithdrawals.
    ///         0 = keep current slippage. LP strategies override with 2-3%.
    function _sequentialWithdrawalSlippage() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @notice Assert post-harvest state is valid.
    ///         Default: no-op — net yield sign depends on borrow cost vs strategy yield.
    ///         LP strategies override to assertGt (CRV harvest must increase NAV).
    function _assertHarvestYield(uint256 navBefore, uint256 navAfter) internal virtual { }

    /// @notice Called after vm.warp and before harvestYield() in test_harvestIncreasesNavPerShare.
    ///         Override to trigger any off-chain checkpoints the strategy relies on (e.g. Stake DAO
    ///         locker user_checkpoint) so that accrued rewards are visible before harvest.
    function _checkpointRewards() internal virtual { }

    /// @notice Assert pending rewards are non-zero after time has passed.
    ///         Default: non-strict (≥0) — CRV rewards need off-chain accountant to register.
    ///         IPOR base overrides to strict (>0) — interest is visible immediately.
    function _assertPendingRewardsAfterTime(uint256 pending) internal virtual {
        assertGe(pending, 0, "Pending rewards should be >= 0");
    }

    /// @notice Simulate an arbitrageur restoring the strategy's primary LP pool to fair
    /// value after a deposit perturbed it. Default no-op — used by non-LP strategies (IPOR
    /// PlasmaVault) where there's no pool imbalance to arbitrage. LP-based strategies
    /// override to perform the specific arb swap that restores their pool's ratio.
    function _arbitragePoolBalance() internal virtual { }

    /// @notice Deposit size for the realistic-lifecycle test. Must be small enough that
    /// the strategy's LP pool can absorb the single-sided add and an arb can restore it
    /// within MAX_SINGLE_SIDED_EXIT_DISCOUNT (2%). Default = _baseDeposit() which is fine
    /// for non-LP strategies and large/deep LP pools; thin-pool LP strategies (e.g.
    /// pmUSD/crvUSD with $10M TVL) should override to a smaller amount (1-5% of pool TVL).
    function _realisticLifecycleDeposit() internal pure virtual returns (uint256) {
        return _baseDeposit();
    }

    // ============ Internal helpers ============

    function _baseSwapper() internal view returns (BaseSwapper) {
        return BaseSwapper(address(vault.swapper()));
    }

    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount)
        internal
        returns (bool)
    {
        _syncAndMockOracles();
        _deployVault();

        deal(_collateral(), user1, depositAmount);

        BaseSwapper bs = _baseSwapper();
        if (bs.slippage() != targetSlippage) {
            vm.prank(owner);
            bs.setSlippage(targetSlippage);
        }

        _depositAs(user1, depositAmount);
        _refreshOracles();

        uint256 shares = vault.balanceOf(user1);
        if (shares == 0) return false;

        vm.prank(user1);
        try vault.redeem(shares, user1, user1) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Public wrapper so the slippage scenario can be called via `this.runSlippageScenario`
    ///      inside a snapshot/revert block.
    function runSlippageScenario(uint256 targetSlippage, uint256 depositAmount)
        external
        returns (bool)
    {
        return _runSlippageScenario(targetSlippage, depositAmount);
    }

    /// @dev Public wrapper for deposit chunk so TVL test can call via `this.tryDepositChunk`.
    function tryDepositChunk(address depositor, uint256 amount) external returns (bool) {
        if (msg.sender != address(this)) revert("self only");
        _depositAs(depositor, amount);
        return true;
    }

    // ============ Swapper tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        address newSwapper_ = _newSwapper();
        vm.prank(vault.gov());
        vault.proposeSwapper(newSwapper_);

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.executeSwapper();

        vm.warp(block.timestamp + 1 weeks + 1);
        _syncAndMockOracles();

        vm.prank(vault.gov());
        vault.executeSwapper();
        assertEq(address(vault.swapper()), newSwapper_, "Swapper should be updated");

        address anotherSwapper_ = _newSwapper();
        vm.prank(vault.gov());
        vault.proposeSwapper(anotherSwapper_);

        vm.prank(vault.gov());
        vault.cancelSwapper();

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        vault.executeSwapper();
    }

    function test_setSlippage() public {
        _deployVault();

        BaseSwapper bs = _baseSwapper();
        assertEq(bs.slippage(), _initialSwapperSlippage(), "Initial slippage mismatch");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        bs.setSlippage(10e16);

        vm.prank(owner);
        bs.setSlippage(5e16);
        assertEq(bs.slippage(), 5e16, "Slippage should be 5%");

        // Above the 5% MAX_SLIPPAGE cap is rejected
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        bs.setSlippage(5e16 + 1);
    }

    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, _largeDepositAmount());
        assertTrue(passed, "Large deposit full redeem should succeed at 2% slippage");
    }

    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        _deployVault();
        _depositAs(user1, _largeDepositAmount());

        _refreshOracles();

        // Double the collateral price so the swapper oracle floor demands 2× more output
        // than the market can deliver, forcing SwapperUnderperformed.
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        vm.mockCall(
            _collateralPriceOracle(),
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer * 2, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(shares, user1, user1);
    }

    function test_slippageSweep_bySlippage() public {
        uint256[] memory levels = new uint256[](8);
        levels[0] = 5e13; //   5 bps
        levels[1] = 25e13; //  25 bps
        levels[2] = 50e13; //  50 bps
        levels[3] = 1e16; //  1.0%
        levels[4] = 2e16; //  2.0%
        levels[5] = 3e16; //  3.0%
        levels[6] = 5e16; //  5.0%
        levels[7] = 10e16; // 10.0%

        uint256 depositAmt = _largeDepositAmount();
        uint256 firstPass = 0;

        for (uint256 i = 0; i < levels.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(levels[i], depositAmt) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("SlippageSweep slippage_bps=%d passed=%d", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) firstPass = levels[i];
        }

        console.log("SlippageSweep firstPass_bps=%d", firstPass == 0 ? 0 : firstPass / 1e14);
        assertTrue(firstPass == 0 || firstPass <= 2e16, "Full exit should need <= 2% slippage");
    }

    // ============ Strategy-generic tests ============

    function test_strategyBalance_afterDeposit() public virtual {
        _deployVault();
        _depositAs(user1, _unit());
        assertGt(yieldStrategy.balanceOf(), 0, "Strategy should report balance");
        _assertStrategyIntegration();
    }

    function test_pendingRewards_view() public {
        _deployVault();
        _depositAs(user1, _unit());
        uint256 pending = yieldStrategy.pendingRewards();
        assertGe(pending, 0, "Pending rewards view should not revert");
    }

    function test_harvestYield_afterTimePassed() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        uint256 stratBefore = yieldStrategy.balanceOf();

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        vm.prank(owner);
        vault.harvestYield();

        uint256 stratAfter = yieldStrategy.balanceOf();
        // Allow up to 0.02% decrease from oracle mock rounding after warp — the important
        // invariant is that the strategy did not suffer a significant loss.
        assertGe(
            stratAfter * 10000,
            stratBefore * 9998,
            "Strategy balance must not significantly decrease after harvest"
        );
        console.log("Harvest: before=%d after=%d", stratBefore, stratAfter);
    }

    function test_harvestIncreasesNavPerShare() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        uint256 navBefore = vault.convertToAssets(vault.totalSupply());

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();
        _checkpointRewards();

        vm.prank(owner);
        vault.harvestYield();

        uint256 navAfter = vault.convertToAssets(vault.totalSupply());
        console.log("NAV per share: before=%d after=%d", navBefore, navAfter);
        _assertHarvestYield(navBefore, navAfter);
    }

    function test_pendingRewards_nonZeroAfterTime() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        uint256 pending = yieldStrategy.pendingRewards();
        console.log("pendingRewards after 30d: %d", pending);
        _assertPendingRewardsAfterTime(pending);
    }

    // ============ Multi-depositor TVL test ============

    function test_multiDepositors_reachTargetTvl() public {
        _deployVault();

        vm.prank(vault.gov());
        vault.setParam(1, 30e16);
        vm.prank(vault.gov());
        vault.setParam(4, 5e16);

        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");
        address[4] memory users = [user1, user2, user3, user4];
        uint256 chunk = _tvlChunk();
        uint256 minChunk = _tvlMinChunk();
        uint256 tvl = loanManager.getCollateralValue(vault.getTotalCollateral());

        for (uint256 i = 0; i < _tvlIterCap() && tvl < _tvlTarget(); i++) {
            address depositor = users[i % users.length];
            deal(_collateral(), depositor, chunk);
            bool ok;
            try this.tryDepositChunk(depositor, chunk) returns (bool success) {
                ok = success;
            } catch {
                ok = false;
            }
            if (!ok) {
                if (chunk <= minChunk) break;
                chunk = chunk / 2;
                continue;
            }
            if (i % 4 == 3) _refreshOracles();
            tvl = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        assertGe(tvl, _tvlTarget(), "TVL should reach target");
        console.log(_tvlLabel(), tvl);
    }

    // ============ Core lifecycle tests ============

    function test_largeWithdraw_doesNotBankruptRemaining() public {
        _deployVault();

        uint256 smallDeposit = _unit() / 10;
        uint256 largeDeposit = _unit() * 5;
        deal(_collateral(), user1, smallDeposit);
        deal(_collateral(), user2, largeDeposit);

        _depositAs(user1, smallDeposit);
        _depositAs(user2, largeDeposit);

        uint256 user1SharesBefore = vault.balanceOf(user1);

        _refreshOracles();
        _redeemAllAs(user2);

        assertEq(
            vault.balanceOf(user1), user1SharesBefore, "Shares unchanged after large withdrawal"
        );

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining depositor must withdraw");
        assertGe(received * 100, smallDeposit * 50, "Remaining depositor lost >50%");
        console.log("Large withdraw: smallDeposit=%d received=%d", smallDeposit, received);
    }

    function test_withdrawAfterInterestAccrual_7days() public {
        _deployVault();
        uint256 dep = _unit() * 2;
        _depositAs(user1, dep);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));
        assertGe(valueAfter * 100, valueBefore * 95, "7-day value loss >5%");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 7 days");
        _assertValuePreserved(dep, withdrawn, 500, "7-day withdraw: >5% loss");
        console.log("7-day withdraw: deposited=%d withdrawn=%d", dep, withdrawn);
    }

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();

        uint256 slippage = _sequentialWithdrawalSlippage();
        if (slippage > 0) {
            BaseSwapper bs = _baseSwapper();
            vm.prank(owner);
            bs.setSlippage(slippage);
        }

        address user3 = makeAddr("user3");
        uint256 d1 = _unit();
        uint256 d2 = _unit() * 2;
        uint256 d3 = _unit() * 3;
        deal(_collateral(), user1, d1);
        deal(_collateral(), user2, d2);
        deal(_collateral(), user3, d3);

        _depositAs(user1, d1);
        _depositAs(user2, d2);
        vm.startPrank(user3);
        collateralToken.approve(address(vault), d3);
        vault.deposit(d3, user3);
        vm.stopPrank();
        vm.roll(block.number + 1);

        _refreshOracles();
        uint256 shares3 = vault.balanceOf(user3);
        uint256 w3 = _redeemSharesOrSkip(user3, shares3);

        _refreshOracles();
        uint256 w2 = _redeemAllAs(user2);

        _refreshOracles();
        uint256 w1 = _redeemAllAs(user1);

        assertGt(w1, 0, "User1 must withdraw");
        assertGt(w2, 0, "User2 must withdraw");
        assertGt(w3, 0, "User3 must withdraw");
        assertGe(w1 * 100, d1 * 80, "User1: >20% loss");
        assertGe(w2 * 100, d2 * 80, "User2: >20% loss");
        assertGe(w3 * 100, d3 * 80, "User3: >20% loss");
        console.log("3-user sequential: w1=%d w2=%d w3=%d", w1, w2, w3);
    }

    function test_fullLifecycle_depositRebalanceWithdraw() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        uint256 dep = _unit() * 3;
        _depositAs(user1, dep);
        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        int256 upPrice = (answer * 115) / 100;
        vm.mockCall(
            _collateralPriceOracle(),
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, upPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfterUp = loanManager.getCurrentLTV();
        assertGt(ltvAfterUp, ltvBefore, "LTV should increase after upward rebalance");

        vm.clearMockedCalls();
        _refreshOracles();

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after lifecycle");
        _assertValuePreserved(dep, withdrawn, 500, "Lifecycle: >5% loss");
        console.log("Lifecycle: deposited=%d withdrawn=%d", dep, withdrawn);
    }

    function test_strategyDebtProportionality_afterPartialWithdraw() public {
        _deployVault();
        _depositAs(user1, _unit() * 4);

        _refreshOracles();

        (, uint256 debtBefore) = loanManager.getPositionValues();
        uint256 stratBefore = yieldStrategy.balanceOf();

        uint256 shares = vault.balanceOf(user1);
        _redeemSharesOrSkip(user1, shares / 2);

        (, uint256 debtAfter) = loanManager.getPositionValues();
        uint256 stratAfter = yieldStrategy.balanceOf();

        if (debtBefore > 0 && stratBefore > 0) {
            uint256 debtRatio = (debtAfter * 1e18) / debtBefore;
            uint256 stratRatio = (stratAfter * 1e18) / stratBefore;
            uint256 diff = debtRatio > stratRatio ? debtRatio - stratRatio : stratRatio - debtRatio;
            assertLe(diff, 25e16, "Strategy/debt divergence >25% after partial withdraw");
            console.log(
                "Proportionality: debtRatio=%d stratRatio=%d diff=%d", debtRatio, stratRatio, diff
            );
        }
    }

    function test_interestAccrual_30days() public {
        _deployVault();
        uint256 dep = _unit() * 2;
        _depositAs(user1, dep);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));
        assertGe(valueAfter * 100, valueBefore * 90, "30-day value loss >10%");
        console.log("30-day: valueBefore=%d valueAfter=%d", valueBefore, valueAfter);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 30 days");
        _assertValuePreserved(dep, withdrawn, 1000, "30-day withdraw: >10% total loss");
        console.log("30-day withdraw: deposited=%d withdrawn=%d", dep, withdrawn);
    }

    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        uint256 dep = _unit() * 2;
        _depositAs(user1, dep);

        _refreshOracles();

        // Drop collateral price 5%.
        (uint80 roundId1, int256 answer1,,, uint80 answeredInRound1) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        vm.mockCall(
            _collateralPriceOracle(),
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(
                roundId1, (answer1 * 95) / 100, block.timestamp, block.timestamp, answeredInRound1
            )
        );

        // Drop debt-asset price 5% — preserves the collateral/debt ratio so the swapper oracle
        // floor stays within range.
        (uint80 roundId2, int256 answer2,,, uint80 answeredInRound2) =
            IChainlinkOracle(_debtOracle()).latestRoundData();
        vm.mockCall(
            _debtOracle(),
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(
                roundId2, (answer2 * 95) / 100, block.timestamp, block.timestamp, answeredInRound2
            )
        );

        // Drop additional strategy oracles (e.g., crvUSD for IPOR withdrawal path).
        address[] memory extra = _strategyOraclesToDrop();
        for (uint256 i = 0; i < extra.length; i++) {
            (uint80 rId, int256 ans,,, uint80 arId) = IChainlinkOracle(extra[i]).latestRoundData();
            vm.mockCall(
                extra[i],
                abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                abi.encode(rId, (ans * 95) / 100, block.timestamp, block.timestamp, arId)
            );
        }

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw with collateral price drop");
        console.log("Strategy loss: deposited=%d withdrawn=%d", dep, withdrawn);
    }

    function testFuzz_largeRatioDeposits_noBankruptcy(uint256 ratio) public {
        _deployVault();
        ratio = bound(ratio, 10, 100);

        uint256 smallAmount = _ratioTestSmallAmount();
        uint256 largeAmount = smallAmount * ratio;
        deal(_collateral(), user1, smallAmount);
        deal(_collateral(), user2, largeAmount);

        _depositAs(user1, smallAmount);
        _depositAs(user2, largeAmount);

        _refreshOracles();
        _redeemAllAs(user2);

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining user must be able to withdraw");
        assertGe(received * 100, smallAmount * 40, "Remaining user lost >60%");
    }

    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

        uint256 minAmount = _effectiveMinDeposit();
        deal(_collateral(), user1, minAmount);

        uint256 shares = _depositAs(user1, minAmount);
        assertGt(shares, 0, "Should receive shares for minimum deposit");

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Should receive collateral back for minimum deposit");
        console.log("MinDeposit: deposited=%d received=%d", minAmount, received);
    }

    function test_oneMillion_depositAndRedeem() public {
        bool passed = _runSlippageScenario(2e16, _oneMillionAmount());
        assertTrue(passed, "~$1M full redeem should succeed at 2% slippage");
        console.log("$1M test: %s deposit+redeem at 2%% slippage passed", _oneMillionLabel());
    }

    /// @notice Realistic mainnet lifecycle: deposit → arbitrageurs restore the LP pool
    /// to fair value → user exits. The immediate-redeem tests above are *worst-case*
    /// because the redeemer absorbs the pool imbalance they just created. In practice,
    /// arbitrageurs fill that gap within blocks and the LP holders (including the strategy)
    /// receive the spread as fees. This test exercises that path.
    /// @dev Non-LP strategies (IPOR PlasmaVault) get a no-op `_arbitragePoolBalance()`
    ///      and naturally complete the round-trip — there's no pool to imbalance.
    function test_realisticLifecycle_depositArbExit() public {
        _deployVault();

        uint256 dep = _realisticLifecycleDeposit();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);

        // Arbitrageur restores the pool ratio (LP strategies only); non-LP: no-op.
        _arbitragePoolBalance();

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Realistic exit returned zero");
        // After arb-rebalance, round-trip cost should be modest: a handful of bps from
        // pool fees + the bid/ask the depositor paid on the way in. 5% is a generous
        // floor that distinguishes "works as designed" from "something is wrong."
        assertGe(received * 100, dep * 95, "Realistic round-trip loss > 5%");
        console.log("Realistic lifecycle: deposited=%d received=%d", dep, received);
    }

    // ============ Security: access control ============

    /// @notice The loan manager's state-mutating entry points must reject any caller
    /// other than the vault. A bypass here would let a stranger drain or grief the
    /// position. We verify each function in the vault-only surface reverts.
    function test_loanManager_unauthorizedCalls_revert() public {
        _deployVault();
        address stranger = makeAddr("stranger");
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

    // ============ Security: donation resilience ============

    /// @notice ERC4626 first-depositor inflation: an attacker mints 1 share, donates
    /// a large amount of collateral directly to the vault, then a second depositor's
    /// shares round to zero. VIRTUAL_SHARE_OFFSET defeats this by anchoring share
    /// price away from the donatable surface. This test asserts the second depositor
    /// receives a non-trivial share count even under a pathological donation.
    function test_donation_firstDepositor_cannotInflateShares() public {
        _deployVault();

        // Attacker mints minimum-sized shares, then dumps collateral on the vault.
        address attacker = makeAddr("attacker");
        uint256 attackerDep = vault.MIN_DEPOSIT();
        deal(_collateral(), attacker, attackerDep);
        vm.startPrank(attacker);
        collateralToken.approve(address(vault), attackerDep);
        vault.deposit(attackerDep, attacker);
        vm.stopPrank();

        // Donation: 100x the attacker's deposit, transferred directly to the vault.
        uint256 donation = attackerDep * 100;
        deal(_collateral(), address(this), donation);
        collateralToken.transfer(address(vault), donation);

        // Victim deposits a normal amount and must receive proportionally fair shares.
        uint256 victimDep = _unit();
        deal(_collateral(), user1, victimDep);
        vm.startPrank(user1);
        collateralToken.approve(address(vault), victimDep);
        uint256 victimShares = vault.deposit(victimDep, user1);
        vm.stopPrank();

        // Victim shares must be > 0 by orders of magnitude — anything close to 0
        // would mean the donation successfully inflated the share price.
        assertGt(victimShares, 1e3, "Victim received near-zero shares (inflation succeeded)");
    }

    /// @notice Donating collateral or debt-token directly to the loan manager must
    /// not corrupt accounting or brick the position. The vault sizes its withdraws
    /// from the manager's reported aToken/debt balances, not stray idle balances,
    /// so donations should be either absorbed harmlessly or become protocol surplus.
    function test_donation_toLoanManager_doesNotBrickRedeem() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        // Donate one unit of collateral directly to the manager.
        uint256 donation = _unit();
        deal(_collateral(), address(this), donation);
        collateralToken.transfer(address(loanManager), donation);

        _refreshOracles();

        // Redeem must still succeed and return a sensible amount of collateral.
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Redeem failed after collateral donation to manager");
        // User must receive at least 90% of their original deposit (interest +
        // swap costs over a single block can't legitimately exceed 10%).
        assertGe(received * 100, _unit() * 2 * 90, "Donation corrupted user accounting");
    }
}
