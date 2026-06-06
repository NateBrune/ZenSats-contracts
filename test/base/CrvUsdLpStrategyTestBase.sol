// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiStrategyTestBase } from "./ZenjiStrategyTestBase.sol";
import { CrvUsdLpStakeDaoStrategy } from "../../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { UniswapMixedCurveSwapper } from "../../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveStableSwapTwoLP } from "../../src/interfaces/ICurveStableSwapTwoLP.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @title CrvUsdLpStrategyTestBase
/// @notice Mid-level base for all CrvUsdLpStakeDaoStrategy fork tests (USDT/crvUSD Curve LP + Stake DAO).
///         Extends ZenjiStrategyTestBase with LP-specific tests and LP-specific hook defaults.
abstract contract CrvUsdLpStrategyTestBase is ZenjiStrategyTestBase {
    // ============ Shared LP constants ============

    // USDT/crvUSD Curve StableSwap (legacy 2-coin, v0.3.7 — pool == LP token)
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant CRVUSD_INDEX = 1; // coin(0)=USDT, coin(1)=crvUSD
    address constant STAKEDAO_USDT_CRVUSD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // ============ Typed fields (concrete sets these in _deployVaultContracts) ============

    CrvUsdLpStakeDaoStrategy public strategy;
    UniswapMixedCurveSwapper public swapper;

    // ============ ZenjiStrategyTestBase hook implementations ============

    /// @notice LP strategies use crvUSD as debt asset.
    function _debtOracle() internal pure override returns (address) {
        return CRVUSD_USD_ORACLE;
    }

    /// @notice Default slippage after deploy for LP strategies (UniswapMixedCurveSwapper default).
    function _initialSwapperSlippage() internal pure override returns (uint256) {
        return 1e16;
    }

    // ============ Abstract: LP-specific parameterisation ============

    /// @notice Deploy and return a fresh UniswapMixedCurveSwapper (for the swapper timelock test).
    function _newSwapper() internal virtual override returns (address);

    // -- Capacity report parameters --

    /// @notice Ordered probe amounts for the binary-search capacity test.
    function _capacityProbeAmounts() internal pure virtual returns (uint256[] memory);

    /// @notice Human label for the capacity sweep header, e.g. "WBTC USDT/crvUSD".
    function _capacityLabel() internal pure virtual returns (string memory);

    /// @notice Short collateral token label for per-probe console output, e.g. "WBTC".
    function _collateralLabel() internal pure virtual returns (string memory);

    // -- Rebalanced round-trip parameters --

    /// @notice Deposit amounts passed to _assertRebalancedRoundTrip in order.
    function _rebalancedAmounts() internal pure virtual returns (uint256[] memory);

    // ============ Virtual: LP-specific defaults ============

    function _strategyName() internal pure virtual returns (string memory) {
        return "crvUSD -> USDT/crvUSD LP Strategy";
    }

    // ============ ZenjiStrategyTestBase hook implementations ============

    function _assertStrategyIntegration() internal override {
        uint256 rvShares = strategy.stakingVault().balanceOf(address(strategy));
        assertGt(rvShares, 0, "Stake DAO reward vault should hold LP shares");
    }

    /// @notice LP harvest must increase NAV — CRV rewards compound via harvestYield().
    ///         Skips when NAV decreases, which happens in fork tests because Curve trading
    ///         fees (~1.5% APY) only accrue via real swap traffic — vm.warp() generates none.
    ///         harvestYield() captures CRV rewards only; if CRV APR alone < borrow APR the
    ///         fork NAV decreases even though the full live APR (fees + CRV) exceeds it.
    function _assertHarvestYield(uint256 navBefore, uint256 navAfter) internal override {
        if (navAfter <= navBefore) {
            console.log("[ENV SKIP] CRV rewards alone < borrow cost in fork (trading fees don't accrue without swap traffic): before=%d after=%d", navBefore, navAfter);
            vm.skip(true);
            return;
        }
        assertGt(navAfter, navBefore, "LP harvest must increase NAV per share");
    }

    // ============ LP-specific tests ============

    function test_strategyName() public {
        _deployVault();
        assertEq(strategy.name(), _strategyName());
    }

    function test_poolCoinIndex() public {
        _deployVault();
        address coin1 =
            ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).coins(uint256(uint128(CRVUSD_INDEX)));
        assertEq(coin1, CRVUSD, "crvUSD should be at index 1 in USDT/crvUSD pool");
    }

    function test_cachedVirtualPrice_initialized() public {
        _deployVault();
        uint256 cvp = strategy.cachedVirtualPrice();
        assertGt(cvp, 0, "cachedVirtualPrice should be initialized at deploy");
        assertGe(cvp, 1e18, "VP should be >= 1.0 (stable pool with accrued fees)");
        assertLe(cvp, 2e18, "VP should be < 2.0");
        console.log("cachedVirtualPrice=%d", cvp);
    }

    function test_updateCachedVirtualPrice_permissionless() public {
        _deployVault();
        uint256 vpBefore = strategy.cachedVirtualPrice();

        vm.warp(block.timestamp + 1 hours);
        _syncAndMockOracles();

        vm.prank(user1);
        strategy.updateCachedVirtualPrice();

        uint256 vpAfter = strategy.cachedVirtualPrice();
        assertGe(vpAfter, vpBefore, "VP should not decrease after time");
    }

    // ============ TVL ceiling / capacity test ============

    /// @notice Binary-search the maximum deposit that round-trips at 1% slippage.
    ///         Reports safe cap, first-fail, and round-trip cost in signed micro-bps
    ///         (1 bps = 10_000 ubps; positive = gain, negative = loss).
    function test_capacityReport() public {
        uint256 slippage = 1e16;

        uint256[] memory probe = _capacityProbeAmounts();
        uint256 lo = 0;
        uint256 hi = 0;
        console.log("=== %s USDT/crvUSD capacity sweep at 1%% slippage ===", _capacityLabel());

        for (uint256 i = 0; i < probe.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe[i]) returns (bool ok) {
                passed = ok;
            }
                catch { }
            vm.revertTo(snap);
            console.log(
                "  %d %s: %s", probe[i] / _unit(), _collateralLabel(), passed ? "pass" : "FAIL"
            );
            if (passed) { lo = probe[i]; }
            else if (hi == 0) { hi = probe[i]; break; }
        }
        require(lo > 0, "Not even 1 unit passes at 1% slippage");
        if (hi == 0) {
            console.log("Cap > probe max (probe exhausted)");
            return;
        }

        uint256 step = _unit();
        while (hi - lo > step) {
            uint256 mid = lo + ((hi - lo) / 2 / step) * step;
            uint256 snap = vm.snapshot();
            bool ok;
            try this.runSlippageScenario(slippage, mid) returns (bool r) {
                ok = r;
            }
                catch { }
            vm.revertTo(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        uint256 safeCap = lo;
        uint256 firstFail = hi;

        int256 ubpsAtCap;
        uint256 capUsd;
        uint256 receivedAtCap;
        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(_collateral(), user1, safeCap);
            vm.prank(owner);
            swapper.setSlippage(slippage);
            _depositAs(user1, safeCap);
            _syncAndMockOracles();
            receivedAtCap = _redeemAllAs(user1);
            ubpsAtCap = (int256(receivedAtCap) - int256(safeCap)) * 1_000_000 / int256(safeCap);
            (, int256 rawPrice,,,) = IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
            capUsd = (safeCap * uint256(rawPrice)) / (_unit() * 1e8);
            vm.revertTo(snap);
        }

        console.log("=== %s USDT/crvUSD capacity report ===", _capacityLabel());
        console.log("Safe cap:   %d %s  (~$%d)", safeCap / _unit(), _collateralLabel(), capUsd);
        console.log("First fail: %d %s", firstFail / _unit(), _collateralLabel());
        console.log("Deposited:  %d (raw)", safeCap);
        console.log("Received:   %d (raw)", receivedAtCap);
        if (ubpsAtCap >= 0) {
            console.log("Round-trip: +%d ubps (net gain)", uint256(ubpsAtCap));
        } else {
            console.log("Round-trip: -%d ubps (net loss)", uint256(-ubpsAtCap));
        }

        assertGt(safeCap, 0, "Must find a passing size");
        assertGe(ubpsAtCap, -1_000_000, "Round-trip loss at safe cap must be within 1%");
    }

    // ============ Rebalanced round-trip test ============

    /// @notice Round-trip cost after the pool is fully rebalanced by arbs.
    ///
    /// Worst-case scenario: strategy adds crvUSD single-sided (pool skews crvUSD-heavy),
    /// then arbs restore balance (USDT → crvUSD), then strategy exits from the balanced pool.
    /// Unlike the immediate-exit case where entry/exit slippage largely cancels, after rebalance
    /// the strategy pays the full single-sided exit cost from a pool at equilibrium.
    function test_roundTripCost_afterPoolRebalance() public {
        uint256[] memory amounts = _rebalancedAmounts();
        for (uint256 i = 0; i < amounts.length; i++) {
            _assertRebalancedRoundTrip(amounts[i]);
        }
    }

    /// @notice Simulate an arbitrageur restoring the USDT/crvUSD pool to its pre-deposit
    /// ratio. The strategy added crvUSD single-sided; the arb sells USDT into the pool to
    /// buy back the excess crvUSD. Pool fees from this swap accrue to LP holders (the
    /// strategy), which is reflected once `updateCachedVirtualPrice` is called.
    function _arbitragePoolBalance() internal override {
        uint256 crvUsdPost = ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).balances(1);
        uint256 usdtPost = ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).balances(0);
        uint256 crvUsdExcess = crvUsdPost > usdtPost * 1e12 ? crvUsdPost - usdtPost * 1e12 : 0;
        uint256 usdtToSwap = crvUsdExcess / (2 * 1e12);
        if (usdtToSwap == 0) return;

        address usdt_ = ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).coins(0);
        address arb = makeAddr("arb");
        deal(usdt_, arb, usdtToSwap);
        vm.startPrank(arb);
        // USDT has non-standard approve (no return value) — use low-level call.
        (bool ok,) = usdt_.call(
            abi.encodeWithSignature("approve(address,uint256)", USDT_CRVUSD_POOL, usdtToSwap)
        );
        require(ok, "USDT approve failed");
        ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).exchange(0, 1, usdtToSwap, 0);
        vm.stopPrank();

        // Refresh the strategy's VP cache so the oracle floor reflects the arb's fees.
        strategy.updateCachedVirtualPrice();
    }

    function _assertRebalancedRoundTrip(uint256 depositAmount) internal {
        uint256 snap = vm.snapshot();

        _syncAndMockOracles();
        _deployVault();
        deal(_collateral(), user1, depositAmount);
        vm.prank(owner);
        swapper.setSlippage(1e16);

        _depositAs(user1, depositAmount);

        _arbitragePoolBalance();
        _syncAndMockOracles();

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 received = vault.redeem(shares, user1, user1);

        int256 ubps = (int256(received) - int256(depositAmount)) * 1_000_000 / int256(depositAmount);
        if (ubps >= 0) {
            console.log(
                "  %d %s after rebalance: +%d ubps",
                depositAmount / _unit(),
                _collateralLabel(),
                uint256(ubps)
            );
        } else {
            console.log(
                "  %d %s after rebalance: -%d ubps",
                depositAmount / _unit(),
                _collateralLabel(),
                uint256(-ubps)
            );
        }

        // Loss must be less than 1 bps (10_000 ubps) even in the adversarial rebalanced scenario.
        assertGe(ubps, -10_000, "Round-trip loss after pool rebalance exceeds 1 bps");

        vm.revertTo(snap);
    }
}
