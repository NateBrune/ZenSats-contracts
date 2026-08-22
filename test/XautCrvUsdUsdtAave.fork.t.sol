// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { AaveSecurityTestMixin } from "./base/AaveSecurityTestMixin.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiXautAaveUsdtStakeDao } from "../src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import {
    UniversalRouterV3SingleHopSwapper
} from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UsdtCrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapTwoLP } from "../src/interfaces/ICurveStableSwapTwoLP.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title XautCrvUsdUsdtAave
/// @notice Fork tests for XAUT collateral -> Aave V3 (eMode 43) -> borrow USDT -> Curve
///         crvUSD/USDT LP staked in Stake DAO.
/// @dev XAUT has 6 decimals. Aave eMode category 43 ("XAUt USDC USDT GHO") is activated, but the
///      vault is conservatively configured at 60% LTV (AaveLoanManager maxLtvBps = 6000).
///
///      This configuration's distinguishing risk vs. the pmUSD/crvUSD sibling
///      (XautPmUsdCrvUsdAave): the swap leg (USDT<->crvUSD) and the LP leg (crvUSD single-sided
///      add/remove) both use the SAME Curve pool (crvUSD/USDT, 0x390f...97BF4). A deposit pays
///      the swap fee AND the LP add's implicit swap fee on that one pool; a withdrawal pays the
///      LP remove's implicit swap fee AND the swap-back fee on the same pool again — i.e. the
///      pool is hit four times per round trip instead of twice. See
///      test_sameLpPool_roundTrip_lossWithinBound below.
contract XautCrvUsdUsdtAave is AaveSecurityTestMixin {
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_XAUT = 0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    uint8 constant AAVE_EMODE_XAUT = 43; // "XAUt USDC USDT GHO"

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant XAUT_USDT_V3_FEE = 500; // 0.05%

    // The USDT/crvUSD pool is used as BOTH the swap leg AND the LP pool for this config.
    // Legacy 2-coin StableSwap: coins(0)=USDT, coins(1)=crvUSD.
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;
    address constant STAKE_DAO_REWARD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    // NOTE: XAU/USD oracle has a 24h heartbeat — oracles are mocked in tests
    address constant XAU_USD_ORACLE = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniversalRouterV3SingleHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    UsdtCrvUsdLpStakeDaoStrategy public strategy;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return XAUT;
    }

    /// @notice 1 XAUT = 1e6 (6 decimals, ~$3000+/oz)
    function _unit() internal pure override returns (uint256) {
        return 1e6;
    }

    /// @notice 0.01 XAUT ~ $30-45 — matches VIRTUAL_SHARE_OFFSET/MIN_DEPOSIT economics
    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e4;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](4);
        oracles[0] = XAU_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return XAU_USD_ORACLE;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    function _collateralStalenessWarp() internal pure override returns (uint256) {
        return 90001; // XAU/USD Chainlink heartbeat is 24h; staleness window is 90000s
    }

    function _maxTargetLtv() internal pure override returns (uint256) {
        return 60e16; // XAUT loan manager maxLtvBps = 6000 (60%)
    }

    /// @notice The crvUSD/USDT pool is hit 4x per round trip (swap + LP-add on deposit,
    ///         LP-remove + swap on withdraw) instead of the usual 2x — keep fuzz sizes modest
    ///         so the single-block round trip stays within a realistic slippage budget.
    function _fuzzMax() internal pure override returns (uint256) {
        return _unit() * 200; // 200 XAUT
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return _unit() * 100; // 2 users x 100 XAUT = 200 XAUT combined
    }

    function _strategyLabel() internal pure override returns (string memory) {
        return "XAUT/USDT (crvUSD/USDT Curve pool, dual-use swap+LP)";
    }

    // ============ Aave USDT liquidity guard ============

    // aUSDT contract holds the underlying USDT available for borrowing. When Aave USDT hits
    // 100% utilization, DefaultReserveInterestRateStrategyV2 overflows (panic 0x11) on any new
    // borrow. Skip the entire test suite in that state rather than reporting false failures.
    address constant AAVE_A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    function setUp() public override {
        super.setUp();
        // 200 XAUT (fuzz max) at ~$4500/oz x 60% LTV ~= $540k USDT borrow; require 1M headroom.
        if (IERC20(USDT).balanceOf(AAVE_A_USDT) < 1_000_000e6) vm.skip(true);
    }

    // ============ Vault deployment ============

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        // Deploy order: crvSwapper(+0), swapper(+1), strategy(+2), loanManager(+3), vault(+4)
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000 // XAU/USD heartbeat is 24h
        );

        strategy = new UsdtCrvUsdLpStakeDaoStrategy(
            USDT,
            expectedVaultAddress,
            owner,
            USDT_CRVUSD_POOL, // swap leg
            USDT_CRVUSD_POOL, // LP pool (same pool)
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            USDT_CRVUSD_GAUGE,
            USDT_INDEX,
            CRVUSD_INDEX,
            CRVUSD_INDEX, // lpCrvUsdIndex — crvUSD is also at index 1 in the LP pool (same pool)
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE,
            "USDT -> crvUSD/USDT LP Strategy"
        );

        loanManager = new AaveLoanManager(
            XAUT,
            USDT,
            AAVE_A_XAUT,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            6000,
            7500,
            expectedVaultAddress,
            AAVE_EMODE_XAUT,
            90000 // XAU/USD heartbeat is 24h
        );

        ZenjiXautAaveUsdtStakeDao vault_ = new ZenjiXautAaveUsdtStakeDao(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(vault_) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault_));

        vault = vault_;
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        vm.startPrank(owner);
        swapper.setSlippage(1e16);
        // XAUT loan manager maxLtvBps = 6000 (60%), but base Zenji defaults to 65%.
        vault.setParam(1, 60e16);
        vm.stopPrank();
        _syncAndMockOracles();
    }

    // ============ 1. Wiring / config ============

    function test_eModeCategory_isSet() public {
        _deployVault();
        uint256 category = IAavePool(AAVE_POOL).getUserEMode(address(loanManager));
        assertEq(category, AAVE_EMODE_XAUT, "eMode category should be 43 (XAUt USDC USDT GHO)");
    }

    function test_vaultConfig_wiring() public {
        _deployVault();

        assertEq(vault.targetLtv(), 60e16, "targetLtv should be 60% post-deploy setup");
        assertEq(
            AaveLoanManager(address(loanManager)).maxCollateralOracleStaleness(),
            90000,
            "Collateral oracle staleness should be 90000s (24h heartbeat + buffer)"
        );
        assertEq(
            strategy.name(), "USDT -> crvUSD/USDT LP Strategy", "Strategy name should match deploy"
        );
        assertEq(
            address(strategy.lpPool()), USDT_CRVUSD_POOL, "Strategy lpPool should be the crvUSD/USDT pool"
        );
        assertEq(vault.name(), "Zen XAUT (USDT/crvUSD StakeDao)", "Vault name mismatch");
        assertEq(vault.symbol(), "zenXAUT-USDTcrvUSDStake", "Vault symbol mismatch");
        assertEq(vault.MAX_TARGET_LTV(), 60e16, "MAX_TARGET_LTV should be 60%");
    }

    function test_poolCoinIndex() public {
        _deployVault();
        address coin0 = ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapTwoLP(USDT_CRVUSD_POOL).coins(1);
        assertEq(coin0, USDT, "coin0 should be USDT");
        assertEq(coin1, CRVUSD, "coin1 should be crvUSD");
    }

    // ============ 2. Full lifecycle ============

    function test_fullLifecycle_depositRebalanceWithdraw() public {
        _deployVault();
        vm.prank(vault.gov());
        vault.setParam(1, 55e16); // decrease from 60% -> immediate

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
        uint256 ltvAfter = loanManager.getCurrentLTV();
        assertGt(ltvAfter, ltvBefore, "LTV should increase after upward rebalance");

        vm.clearMockedCalls();
        _refreshOracles();

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after lifecycle");
        _assertValuePreserved(dep, withdrawn, 500, "Lifecycle: >5% loss");
        console.log("Lifecycle: deposited=%d withdrawn=%d", dep, withdrawn);
    }

    // ============ 3. Large deposit / full redeem slippage ============

    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount)
        internal
        returns (bool)
    {
        _syncAndMockOracles();
        _deployVault();

        deal(XAUT, user1, depositAmount);

        if (swapper.slippage() != targetSlippage) {
            vm.prank(owner);
            swapper.setSlippage(targetSlippage);
        }

        _depositAs(user1, depositAmount);

        uint256 shares = vault.balanceOf(user1);
        if (shares == 0) return false;

        vm.prank(user1);
        try vault.redeem(shares, user1, user1) {
            return true;
        } catch {
            return false;
        }
    }

    function runSlippageScenario(uint256 targetSlippage, uint256 depositAmount)
        external
        returns (bool)
    {
        return _runSlippageScenario(targetSlippage, depositAmount);
    }

    /// @notice A 50 XAUT position (~$225K+) can fully exit at the 2% production default.
    /// Kept modest vs. the pmUSD sibling's 100 XAUT because this pool is hit 4x per round trip.
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, 50e6); // 50 XAUT
        assertTrue(passed, "50 XAUT full redeem should succeed at 2% slippage");
    }

    /// @notice Slippage below the pool's swap fee should cause the redeem to revert — the
    ///         dual-use pool means the deposit/withdraw path always pays at least one exchange
    ///         fee even before considering the LP add/remove implicit fee.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        bool passed = _runSlippageScenario(1e13, 50e6); // 0.1 bps
        assertFalse(passed, "50 XAUT full redeem should revert when slippage < pool fee");
    }

    /// @notice Binary-searches the largest single-depositor position that can deposit AND fully
    ///         redeem within 1% slippage — the repo-standard capacity methodology (mirrors
    ///         CrvUsdLpStrategyTestBase.test_capacityReport and the XAUT/pmUSD sibling).
    /// @dev INFORMATIONAL. Mainnet pool liquidity moves, so the number is a snapshot of the fork
    ///      block, not a constant. Use it to set the vault deposit cap WITH a safety margin —
    ///      never set the cap at the measured value. Run with -vv to read the report.
    function test_capacityReport() public {
        uint256 slippage = 1e16; // 1%

        uint256 lo = 0;
        uint256 hi = 0;
        uint256[10] memory probe =
            [uint256(1e6), 2e6, 5e6, 10e6, 20e6, 50e6, 100e6, 200e6, 350e6, 500e6];

        for (uint256 i = 0; i < probe.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe[i]) returns (bool ok) {
                passed = ok;
            } catch { }
            vm.revertTo(snap);
            console.log("  %d XAUT: %s", probe[i] / 1e6, passed ? "pass" : "FAIL");
            if (passed) { lo = probe[i]; }
            else if (hi == 0) { hi = probe[i]; break; }
        }

        require(lo > 0, "Not even 1 XAUT passes at 1% - vault broken at this block");
        if (hi == 0) {
            console.log("XAUT/crvUSD-USDT capacity: > 500 XAUT (probe exhausted)");
            return;
        }

        uint256 step = 1e6; // 1 XAUT resolution
        while (hi - lo > step) {
            uint256 mid = lo + ((hi - lo) / 2 / step) * step;
            uint256 snap = vm.snapshot();
            bool ok;
            try this.runSlippageScenario(slippage, mid) returns (bool r) {
                ok = r;
            } catch { }
            vm.revertTo(snap);
            if (ok) lo = mid;
            else hi = mid;
        }

        (, int256 rawPrice,,,) = IChainlinkOracle(XAU_USD_ORACLE).latestRoundData();
        uint256 capUsd = (lo * uint256(rawPrice)) / (1e6 * 1e8);

        console.log("=== XAUT / crvUSD-USDT capacity report ===");
        console.log("Safe cap:   %d XAUT  (~$%d)", lo / 1e6, capUsd);
        console.log("First fail: %d XAUT", hi / 1e6);

        assertGt(lo, 0, "Must find a passing size");
    }

    // ============ 4. Multi-depositor / sequential withdrawal fairness ============

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();

        address user3 = makeAddr("user3");
        uint256 d1 = _unit();
        uint256 d2 = _unit() * 2;
        uint256 d3 = _unit() * 3;
        deal(XAUT, user1, d1);
        deal(XAUT, user2, d2);
        deal(XAUT, user3, d3);

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

    // ============ 5. Harvest ============

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
        // Allow a small tolerance for oracle-mock rounding after warp — the invariant is that
        // the strategy did not suffer a significant loss from harvesting.
        assertGe(
            stratAfter * 10000,
            stratBefore * 9998,
            "Strategy balance must not significantly decrease after harvest"
        );
        console.log("Harvest: before=%d after=%d", stratBefore, stratAfter);
    }

    // ============ 6. Interest accrual over time ============

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

    // ============ 7. Same-pool swap+LP round-trip loss bound ============

    /// @notice This configuration's defining risk: the crvUSD/USDT Curve pool is used as BOTH
    ///         the debt<->yield-asset swap leg AND the LP pool the strategy single-sides into.
    ///         A normal LP-strategy deployment hits its swap pool twice per round trip (once on
    ///         the way in, once on the way out) and its LP pool twice (add, then remove) — but
    ///         those are usually two *different* pools, so the two fee-legs are independent and
    ///         can partially offset via pool-specific arbitrage. Here all four legs share one
    ///         pool: deposit pays [USDT->crvUSD swap fee] + [crvUSD single-sided add implicit
    ///         swap fee], and withdrawal pays [crvUSD single-sided remove implicit swap fee] +
    ///         [crvUSD->USDT swap fee]. On a legacy Curve StableSwap pool with a ~4bps
    ///         (0.04%) exchange fee, four fee-legs on the same block (no time for the pool to
    ///         mean-revert between legs) bound the expected mechanical loss at roughly
    ///         4 x 4bps = 16bps. We assert a 50bps ceiling — ~3x the theoretical fee cost, enough
    ///         for pool skew/rounding while still catching a design regression that would let
    ///         the dual-use pool bleed value on every round trip.
    function test_sameLpPool_roundTrip_lossWithinBound() public {
        _deployVault();

        uint256 dep = 10e6; // 10 XAUT — modest size, deposit doesn't itself skew the pool much
        deal(XAUT, user1, dep);

        _depositAs(user1, dep);
        _refreshOracles();

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 xautOut = vault.redeem(shares, user1, user1);

        assertGt(xautOut, 0, "Same-pool round trip must return non-zero collateral");

        uint256 lossBps = dep > xautOut ? ((dep - xautOut) * 10000) / dep : 0;
        console.log("Same-pool round trip: deposited=%d received=%d lossBps=%d", dep, xautOut, lossBps);

        assertLe(lossBps, 50, "Same-pool swap+LP round trip lost more than 50 bps");
    }

    // ============ Swapper-specific tests (matches XautPmUsdCrvUsdAave patterns) ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        UniversalRouterV3SingleHopSwapper newSwapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000
        );

        vm.prank(vault.gov());
        vault.proposeSwapper(address(newSwapper));

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.executeSwapper();

        vm.warp(block.timestamp + 1 weeks + 1);
        _syncAndMockOracles();

        vm.prank(vault.gov());
        vault.executeSwapper();
        assertEq(address(vault.swapper()), address(newSwapper), "Swapper should be updated");

        UniversalRouterV3SingleHopSwapper anotherSwapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000
        );
        vm.prank(vault.gov());
        vault.proposeSwapper(address(anotherSwapper));

        vm.prank(vault.gov());
        vault.cancelSwapper();

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        vault.executeSwapper();
    }

    function test_setSlippage() public {
        _deployVault();

        assertEq(swapper.slippage(), 1e16, "Slippage should be 1% after deploy setup");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(10e16);

        vm.prank(owner);
        swapper.setSlippage(5e16);
        assertEq(swapper.slippage(), 5e16, "Slippage should be 5%");

        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.setSlippage(5e16 + 1);
    }

    // ============ Strategy/debt coverage rebalance (Plan B, gold vault) ============

    /// @notice Ports test_coverageUp_clearsRatioCondition (WbtcCrvUsdUsdtLlama) to the XAUT/Aave
    ///         "gold" vault. This vault uses a DIFFERENT loan manager (AaveLoanManager, not
    ///         LlamaLoanManager) and a DIFFERENT swapper (UniversalRouterV3SingleHopSwapper, not
    ///         UniswapMixedCurveSwapper) — the Plan B fix in ZenjiCoreLib.rebalanceCoverageUp must
    ///         be proven venue-agnostic directly here, not inferred from the WBTC/Llama result.
    /// @dev Same technique as the WBTC test: drain Stake DAO reward-vault shares out of the
    ///      strategy to induce a strategy-balance loss without touching collateral/debt, so
    ///      rebalance() takes the ratioTooLow arm (not an LTV arm).
    function test_coverageUp_clearsRatioCondition() public {
        _deployVault();
        uint256 depositAmount = _unit() * 5; // 5 XAUT (~$4490/oz => ~$22.4k)
        _depositAs(user1, depositAmount);
        _refreshOracles();

        IERC20 sdShares = IERC20(address(strategy.stakingVault()));
        uint256 shares = sdShares.balanceOf(address(strategy));
        assertGt(shares, 0, "strategy must hold staked shares");

        vm.prank(address(strategy));
        sdShares.transfer(makeAddr("lossSinkXaut"), (shares * 4) / 100); // -4% => ratio ~96%

        _refreshOracles();
        uint256 ratio0 = vault.strategyToDebtRatio();
        console.log("XAUT start ratio(bps)=%d", ratio0 / 1e14);
        assertTrue(vault.strategyDebtRebalanceNeeded(), "setup must put ratio out of band");

        uint256 prevRatio = ratio0;
        for (uint256 i = 0; i < 5; i++) {
            _refreshOracles();
            try vault.rebalance() { }
            catch (bytes memory err) {
                console.log("XAUT pass %d: rebalance reverted", i + 1);
                _skipOnEnvironmentalRevert(err);
                break;
            }
            uint256 r = vault.strategyToDebtRatio();
            console.log(
                "XAUT pass %d: ratio(bps)=%d strat=%d", i + 1, r / 1e14, strategy.balanceOf()
            );
            if (!vault.strategyDebtRebalanceNeeded()) {
                console.log("XAUT cleared after %d pass(es)", i + 1);
                break;
            }
            assertLe(prevRatio, r + 1, "coverage-up must not push the ratio further from parity");
            prevRatio = r;
        }

        assertFalse(
            vault.strategyDebtRebalanceNeeded(),
            "coverage rebalance must clear strategyDebtRebalanceNeeded() on the gold vault"
        );
    }
}
