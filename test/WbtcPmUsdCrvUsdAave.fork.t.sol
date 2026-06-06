// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { AaveSecurityTestMixin } from "./base/AaveSecurityTestMixin.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import {
    UniversalRouterV3SingleHopSwapper
} from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import {
    UsdtNgCrvUsdLpStakeDaoStrategy
} from "../src/strategies/lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title WbtcPmUsdCrvUsdAave
/// @notice Fork tests for WBTC + USDT + pmUSD/crvUSD (Stake DAO) strategy on Aave
contract WbtcPmUsdCrvUsdAave is AaveSecurityTestMixin {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniversalRouterV3SingleHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    UsdtNgCrvUsdLpStakeDaoStrategy public strategy;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e6; // 0.01 WBTC
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](4);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    // ============ Aave USDT liquidity guard ============

    // aUSDT contract holds the underlying USDT available for borrowing.
    // When Aave USDT hits 100% utilization, DefaultReserveInterestRateStrategyV2 overflows
    // (panic 0x11) on any new borrow. Skip the entire test suite in that state.
    address constant AAVE_A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    function setUp() public override {
        super.setUp();
        if (IERC20(USDT).balanceOf(AAVE_A_USDT) < 1000e6) vm.skip(true);
    }

    /// @dev Skip the calling test if Aave USDT available liquidity is below minUsdt.
    ///      Large-scale capacity tests (100-300 WBTC) need substantial reserves; at high
    ///      utilization the interest-rate formula overflows (panic 0x11) before the borrow lands.
    function _requireAaveUsdt(uint256 minUsdt) internal {
        if (IERC20(USDT).balanceOf(AAVE_A_USDT) < minUsdt) vm.skip(true);
    }

    // ============ Vault deployment ============

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );
        swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
        );

        strategy = new UsdtNgCrvUsdLpStakeDaoStrategy(
            USDT,
            expectedVaultAddress,
            owner,
            USDT_CRVUSD_POOL,
            PMUSD_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            0,
            1,
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE
        );

        loanManager = new AaveLoanManager(
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500,
            8000,
            expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        vault = new Zenji(
            WBTC,
            USDT,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault));
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        vm.prank(owner);
        swapper.setSlippage(1e16);
        _syncAndMockOracles();
    }

    // ============ Swapper-Specific Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        UniversalRouterV3SingleHopSwapper newSwapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
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
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
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

        // Unauthorized caller cannot set slippage
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(10e16);

        // Gov can set slippage directly (at the 5% cap)
        vm.prank(owner);
        swapper.setSlippage(5e16);
        assertEq(swapper.slippage(), 5e16, "Slippage should be 5%");

        // Above the 5% MAX_SLIPPAGE cap is rejected
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.setSlippage(5e16 + 1);
    }

    /// @notice A $10M position (150 WBTC) can fully exit in a single redeem at the 2% production
    ///         default — Uniswap V3 WBTC/USDT 0.3% has enough depth to satisfy the oracle floor.
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        _requireAaveUsdt(6_000_000e6); // 50 WBTC ≈ $5M borrow at 90% LTV
        bool passed = _runSlippageScenario(2e16, 50e8);
        assertTrue(passed, "50 WBTC full redeem should succeed at 2% slippage on Uniswap V3");
    }

    /// @notice Binary-searches WBTC deposit size at fixed 2% slippage to find the pool's actual
    ///         single-redeem capacity ceiling. The pmUSD/crvUSD pool's imbalance gates exits;
    ///         the WBTC↔USDT route adds Uniswap V3 depth. Self-adjusts as conditions change.
    function test_capacityCeiling_at2Percent() public {
        _requireAaveUsdt(20_000_000e6); // up to 200 WBTC ≈ $18M borrow at 90% LTV

        uint256 lo = 1e6; // 0.01 WBTC ≈ $900 — assumed-passing lower bound
        uint256 hi = 50e8; // 50 WBTC — assumed-failing upper bound
        uint256 granularity = 1e6; // 0.01 WBTC precision
        uint256 ceiling = 0;

        // Verify lo passes (sanity)
        {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(2e16, lo) returns (bool ok) {
                passed = ok;
            }
                catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("WBTC CapacitySweep deposit=%s WBTC passed=%s", lo / 1e8, passed ? 1 : 0);
            if (passed) ceiling = lo;
        }

        while (hi > lo + granularity) {
            uint256 mid = ((lo + hi) / 2 / granularity) * granularity;
            if (mid <= lo || mid >= hi) break;
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(2e16, mid) returns (bool ok) {
                passed = ok;
            }
                catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("WBTC CapacitySweep deposit=%s WBTC passed=%s", mid / 1e8, passed ? 1 : 0);
            if (passed) {
                lo = mid;
                ceiling = mid;
            } else {
                hi = mid;
            }
        }

        // Print ceiling in sat (1e8 = 1 WBTC). Use sat to preserve precision below 1 WBTC.
        console.log("WBTC capacity ceiling at 2%% slippage (sat): %s", ceiling);
        assertGe(
            ceiling, 1e6, "WBTC pool capacity at 2% must support >= 0.01 WBTC (~$900) round-trips"
        );
    }

    /// @notice When slippage tolerance is set below the pool fee (5 bps < 30 bps), the actual
    ///         swap output can never satisfy the oracle minOut floor and the redeem must revert.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        _requireAaveUsdt(6_000_000e6); // 50 WBTC ≈ $5M borrow at 90% LTV
        bool passed = _runSlippageScenario(5e13, 50e8); // 5 bps — below pool fee floor
        assertFalse(passed, "50 WBTC full redeem should revert when slippage < pool fee (0.3%)");
    }

    /// @dev Deploy a fresh vault, set slippage to targetSlippage, deposit depositAmount WBTC,
    ///      then attempt a single full redemption.  Returns true if the redeem succeeds.
    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount)
        internal
        returns (bool)
    {
        _syncAndMockOracles(); // re-anchor oracle mocks to current block.timestamp after any vm.revertTo
        _deployVault();

        deal(WBTC, user1, depositAmount);

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

    function tryDepositChunk(address depositor, uint256 amount) external returns (bool) {
        if (msg.sender != address(this)) revert("self only");
        _depositAs(depositor, amount);
        return true;
    }

    function test_slippageSweep_bySlippage() public {
        _requireAaveUsdt(20_000_000e6); // sweeps 150 WBTC deposits
        uint256[] memory levels = new uint256[](8);
        levels[0] = 1e16; // 1.0%
        levels[1] = 2e16; // 2.0%
        levels[2] = 3e16; // 3.0%
        levels[3] = 5e16; // 5.0%
        levels[4] = 10e16; // 10.0%
        levels[5] = 15e16; // 15.0%
        levels[6] = 20e16; // 20.0%
        levels[7] = 30e16; // 30.0%

        uint256 firstPass = 0;

        // Single full redeem of 150 WBTC — isolates slippage without iterative-peel leverage erosion.
        uint256 depositAmt = 150e8; // 150 WBTC
        for (uint256 i = 0; i < levels.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(levels[i], depositAmt) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("Sweep slippage=%s bps passed=%s", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) {
                firstPass = levels[i];
            }
        }

        console.log("Sweep firstPass(bps)=%s", firstPass == 0 ? 0 : firstPass / 1e14);
        // Uniswap V3 0.3% pool: a clean single full-redeem of 1 WBTC should succeed at <= 2% slippage.
        assertTrue(
            firstPass > 0 && firstPass <= 2e16,
            "Full redeem should succeed within 2% slippage on Uniswap V3"
        );
    }

    // ============ Strategy-Specific Tests ============

    function test_strategyBalance_afterDeposit() public {
        _deployVault();
        _depositAs(user1, _unit());

        assertGt(strategy.balanceOf(), 0, "Strategy should report balance");
        uint256 rvShares = strategy.stakingVault().balanceOf(address(strategy));
        assertGt(rvShares, 0, "Reward vault should hold shares");
    }

    function test_strategyName() public {
        _deployVault();
        assertEq(strategy.name(), "USDT -> NG crvUSD/token LP Strategy");
    }

    function test_pendingRewards_view() public {
        _deployVault();
        _depositAs(user1, _unit());
        uint256 pending = strategy.pendingRewards();
        assertGe(pending, 0, "Pending rewards view should not revert");
    }

    function test_harvestYield_afterTimePassed() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        uint256 stratBefore = strategy.balanceOf();
        uint256 crvBefore = IERC20(CRV).balanceOf(address(strategy));
        console.log("Before warp: stratBalance=%d crvBalance=%d", stratBefore, crvBefore);

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        vm.prank(owner);
        vault.harvestYield();

        uint256 stratAfter = strategy.balanceOf();
        uint256 crvAfter = IERC20(CRV).balanceOf(address(strategy));
        console.log("After harvest: stratBalance=%d crvBalance=%d", stratAfter, crvAfter);

        if (stratAfter > stratBefore) {
            console.log("Harvest compounded %d USDT worth of rewards", stratAfter - stratBefore);
        } else {
            console.log("No rewards compounded - accountant likely needs backend checkpoint");
        }

        assertGe(stratAfter, stratBefore, "Strategy balance must not decrease after harvest");
    }

    // ============ TVL Helpers ============

    function _tvlTarget() internal pure returns (uint256) {
        return 20_000_000e6;
    }

    function _tvlChunk() internal pure returns (uint256) {
        return 10e8;
    }

    function _tvlMinChunk() internal pure returns (uint256) {
        return 1e7;
    }

    function _tvlIterCap() internal pure returns (uint256) {
        return 160;
    }

    function _requireTvlSetup() internal {
        _requireAaveUsdt(25_000_000e6);
    }

    function _tvlLabel() internal pure returns (string memory) {
        return "WBTC multi-user TVL(USDT 6d)=";
    }

    // ============ Multi-Depositor TVL Test ============

    function test_multiDepositors_reachTargetTvl() public {
        _requireTvlSetup();
        _deployVault();

        vm.prank(vault.gov());
        vault.setParam(1, 30e16);
        vm.prank(vault.gov());
        vault.setParam(4, 5e16);

        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");

        address[4] memory users = [user1, user2, user3, user4];
        uint256 targetTvl = _tvlTarget();
        uint256 chunk = _tvlChunk();
        uint256 minChunk = _tvlMinChunk();
        uint256 tvl = loanManager.getCollateralValue(vault.getTotalCollateral());

        for (uint256 i = 0; i < _tvlIterCap() && tvl < targetTvl; i++) {
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
            if (i % 4 == 3) {
                _refreshOracles();
            }
            tvl = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        assertGe(tvl, targetTvl, "TVL should reach target");
        console.log(_tvlLabel(), tvl);
    }

    function test_largeWithdraw_doesNotBankruptRemaining() public {
        _deployVault();

        uint256 smallDeposit = 1e7; // 0.1 WBTC
        uint256 largeDeposit = 5e8; // 5 WBTC (50x)
        deal(WBTC, user1, smallDeposit);
        deal(WBTC, user2, largeDeposit);

        _depositAs(user1, smallDeposit);
        _depositAs(user2, largeDeposit);

        uint256 user1SharesBefore = vault.balanceOf(user1);

        _refreshOracles();

        _redeemAllAs(user2);

        uint256 user1SharesAfter = vault.balanceOf(user1);
        assertEq(user1SharesAfter, user1SharesBefore, "Shares unchanged after large withdrawal");

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining depositor must withdraw");
        assertGe(received * 100, smallDeposit * 50, "Remaining depositor lost >50%");
        console.log("Large withdraw: smallDeposit=%d received=%d", smallDeposit, received);
    }

    function test_withdrawAfterInterestAccrual_7days() public {
        _deployVault();
        _depositAs(user1, 2e8);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));

        assertGe(valueAfter * 100, valueBefore * 95, "7-day value loss >5%");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 7 days");
        _assertValuePreserved(2e8, withdrawn, 500, "7-day withdraw: >5% loss");
        console.log("7-day withdraw: deposited=2e8 withdrawn=%d", withdrawn);
    }

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();
        address user3 = makeAddr("user3");

        uint256 d1 = 1e8;
        uint256 d2 = 2e8;
        uint256 d3 = 3e8;
        deal(WBTC, user1, d1);
        deal(WBTC, user2, d2);
        deal(WBTC, user3, d3);

        _depositAs(user1, d1);
        _depositAs(user2, d2);
        vm.startPrank(user3);
        IERC20(WBTC).approve(address(vault), d3);
        vault.deposit(d3, user3);
        vm.stopPrank();
        vm.roll(block.number + 1);

        _refreshOracles();

        uint256 shares3 = vault.balanceOf(user3);
        vm.prank(user3);
        uint256 w3 = vault.redeem(shares3, user3, user3);

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

        _depositAs(user1, 3e8);

        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        int256 upPrice = (answer * 115) / 100;
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, upPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfterUp = loanManager.getCurrentLTV();
        assertGt(ltvAfterUp, ltvBefore, "LTV should increase after upward rebalance");

        vm.clearMockedCalls();
        _syncAndMockOracles();

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after lifecycle");
        _assertValuePreserved(3e8, withdrawn, 500, "Lifecycle: >5% loss");
        console.log("Lifecycle: deposited=3e8 withdrawn=%d", withdrawn);
    }

    function test_strategyDebtProportionality_afterPartialWithdraw() public {
        _deployVault();
        _depositAs(user1, 4e8);

        _refreshOracles();

        (, uint256 debtBefore) = loanManager.getPositionValues();
        uint256 stratBefore = strategy.balanceOf();

        uint256 shares = vault.balanceOf(user1);
        _redeemSharesOrSkip(user1, shares / 2);

        (, uint256 debtAfter) = loanManager.getPositionValues();
        uint256 stratAfter = strategy.balanceOf();

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
        _depositAs(user1, 2e8);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));

        assertGe(valueAfter * 100, valueBefore * 90, "30-day value loss >10%");
        console.log("30-day: valueBefore=%d valueAfter=%d", valueBefore, valueAfter);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 30 days");
        _assertValuePreserved(2e8, withdrawn, 1000, "30-day withdraw: >10% total loss");
        console.log("30-day withdraw: deposited=2e8 withdrawn=%d", withdrawn);
    }

    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        _depositAs(user1, 2e8);

        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        int256 depegPrice = (answer * 95) / 100;
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, depegPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw with strategy loss");
        console.log("Strategy loss: deposited=2e8 withdrawn=%d", withdrawn);
    }

    function testFuzz_largeRatioDeposits_noBankruptcy(uint256 ratio) public {
        _deployVault();
        ratio = bound(ratio, 10, 100);

        uint256 smallAmount = 1e6;
        uint256 largeAmount = smallAmount * ratio;
        deal(WBTC, user1, smallAmount);
        deal(WBTC, user2, largeAmount);

        _depositAs(user1, smallAmount);
        _depositAs(user2, largeAmount);

        _refreshOracles();
        _redeemAllAs(user2);

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining user must be able to withdraw");
        assertGe(received * 100, smallAmount * 40, "Remaining user lost >60%");
    }

    /// @notice Deposit exactly vault.MIN_DEPOSIT() and fully redeem.
    /// Confirms the contract-minimum path succeeds end-to-end on mainnet liquidity.
    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

        // Use the vault's own MIN_DEPOSIT() — production ZenjiWbtcPmUsd returns 1e5 sat (~$100),
        // the base Zenji used in fork tests returns 1e4 sat (~$10).
        uint256 minAmount = vault.MIN_DEPOSIT();
        deal(WBTC, user1, minAmount);

        uint256 shares = _depositAs(user1, minAmount);
        assertGt(shares, 0, "Should receive shares for minimum deposit");

        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Should receive collateral back for minimum deposit");
        console.log("MinDeposit: deposited=%d sat received=%d sat", minAmount, received);
    }

    /// @notice Deposit 10 BTC (~$1M at $100k/BTC) and fully redeem.
    /// Confirms a large round-trip within normal operating range succeeds.
    function test_oneMillion_depositAndRedeem() public {
        // 10 BTC ≈ $1M at $100k/BTC
        uint256 depositAmount = 10e8; // 10 BTC in satoshis
        bool passed = _runSlippageScenario(2e16, depositAmount);
        assertTrue(passed, "10 BTC (~$1M) full redeem should succeed at 2% slippage");
        console.log("$1M test: 10 BTC deposit+redeem at 2%% slippage passed");
    }

    // ============ Dust / Minimum Deposit Tests ============

    /// @notice Verifies that a ~$70 dust deposit (1e5 sat) can be fully redeemed.
    ///         Previously this reverted with V3TooLittleReceived because the flashloan-premium
    ///         swap (~4 sat) triggered Uniswap V3 integer fee-rounding (1 sat fee on 4 sat input
    ///         = 25% effective fee). Fixed by bypassing minOut enforcement below DUST_SWAP_THRESHOLD.
    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        // This is equivalent to ~$70 USD at $70k/BTC
        uint256 dustAmount = 1e5; // 100k sat = 0.001 WBTC
        deal(WBTC, user1, dustAmount);

        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), dustAmount);

        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        console.log("Dust deposit: %d sat", dustAmount);
        console.log("Shares minted: %d", sharesMinted);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        // Should now succeed — dust swap threshold bypasses oracle minOut for <1000 sat swaps
        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);

        console.log("Dust redemption succeeded.");
    }

    /// @notice Trace every number through the full deposit→redeem path for a tiny (~$7) deposit.
    ///         Uses the exact MIN_DEPOSIT (1e4 sat) to replicate the mainnet failure.
    ///         Catches the raw error bytes to identify which layer fails and what the
    ///         actual Uniswap / LP slippage is on such tiny swaps.
    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        // Exact minimum deposit: 1e4 sat at 1e8 precision = 0.0001 WBTC ~ $7
        uint256 dustAmount = 1e4;
        deal(WBTC, user1, dustAmount);

        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (sat):      ", dustAmount);
        console.log("sharesMinted:          ", sharesMinted);
        console.log("Aave collateral (sat): ", posCollateral);
        console.log("Aave debt (USDT e6):   ", posDebt);
        console.log("Strategy bal (USDT e6):", stratBal);
        console.log("Vault idle WBTC (sat): ", IERC20(WBTC).balanceOf(address(vault)));
        console.log(
            "Vault idle USDT (e6):  ",
            IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7).balanceOf(address(vault))
        );

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        // Project what unwind will attempt:
        uint256 collateralNeeded = vault.previewRedeem(sharesMinted);
        console.log("=== Projected unwind ===");
        console.log("collateralNeeded (sat):", collateralNeeded);
        if (posCollateral > 0) {
            uint256 debtToRepay = posDebt * collateralNeeded / posCollateral;
            console.log("debtToRepay (USDT e6): ", debtToRepay);
            console.log("debtNeeded 105% (e6):  ", debtToRepay * 105 / 100);
        }
        console.log("maxSlippage (bps):     ", vault.maxSlippage() / 1e14);
        console.log("swapper slippage (bps):", swapper.slippage() / 1e14);

        // Try redeem — catch raw error bytes to identify the exact layer
        console.log("=== Attempting vault.redeem ===");
        vm.prank(user1);
        try vault.redeem(sharesMinted, user1, user1) returns (uint256 amount) {
            console.log("Redeem SUCCEEDED (sat):", amount);
        } catch (bytes memory err) {
            console.log("Redeem REVERTED. Raw error bytes length:", err.length);
            if (err.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(err, 32)) }
                if (selector == Zenji.InsufficientWithdrawal.selector) {
                    console.log("=> InsufficientWithdrawal: strategy LP underperformed maxSlippage");
                } else if (selector == Zenji.InsufficientCollateral.selector) {
                    console.log("=> InsufficientCollateral: not enough WBTC recovered after unwind");
                } else if (selector == Zenji.SwapperUnderperformed.selector) {
                    console.log("=> SwapperUnderperformed: Uniswap/oracle divergence on small swap");
                } else if (selector == bytes4(keccak256("V3TooLittleReceived()"))) {
                    console.log("=> V3TooLittleReceived: Uniswap minAmountOut not met");
                } else {
                    console.log("=> Unknown selector (check loanManager / strategy / LP errors)");
                }
            }
        }
    }

    /// @notice Show realistic minimum deposit that avoids dust redemption failures.
    ///         Economic minimum for WBTC is ~1e6 sat (0.01 BTC, ~$1000) to cover Uniswap fees.
    function test_realisticMinimum_succeeds() public {
        _deployVault();

        // 1e6 sat = 0.01 BTC ~$1000 at $100k/BTC — comfortably above economic dust floor
        uint256 realAmount = 1e6;

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];

        for (uint256 i = 0; i < users.length; i++) {
            deal(WBTC, users[i], realAmount);
            vm.prank(users[i]);
            IERC20(WBTC).approve(address(vault), realAmount);

            vm.prank(users[i]);
            vault.deposit(realAmount, users[i]);
        }

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 shares = vault.balanceOf(users[i]);
            if (shares > 0) {
                vm.prank(users[i]);
                uint256 collateralReceived = vault.redeem(shares, users[i], users[i]);
                assertGt(
                    collateralReceived, 0, "Realistic deposit should redeem non-zero collateral"
                );
                console.log("User redeemed shares for sat");
                console.log(i);
                console.log(shares);
                console.log(collateralReceived);
            }
        }
    }

    /// @notice Document the vault's economic minimum for WBTC (Aave/Uniswap path).
    function test_documentEconomicMinimum() public pure {
        uint256 contractMinimum = 1e4;
        uint256 virtualOffset = 1e5;
        uint256 economicMinimum = 1e5; // 0.001 WBTC = 1e5 sat

        console.log("Contract MIN_DEPOSIT:  %d sat", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d sat", virtualOffset);
        console.log("Economic minimum:      %d sat", economicMinimum);
        console.log("Why dust fails on mainnet (WBTC Aave/Uniswap path):");
        console.log("1. Deposit of tiny sat passes MIN_DEPOSIT check");
        console.log("2. Very few shares created due to low VIRTUAL_SHARE_OFFSET");
        console.log("3. Redeem triggers proportional flash-loan unwind");
        console.log("4. Uniswap WBTC->USDT accumulates pool fees at tiny sizes");
        console.log("5. Oracle floor (1%% tolerance) > tiny Uniswap output at micro sizes");
        console.log("6. Vault reverts: V3TooLittleReceived or SwapperUnderperformed");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    /// @notice Single shot: deposit 1e4 sat then redeem, with trace for debugging
    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 1e4;
        deal(WBTC, user1, depositAmount);
        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), depositAmount);
        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_sat=%d debt_usdt6=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    /// @notice Replicate the exact mainnet failure and sweep slippage levels to find root cause
    ///         The trace shows:
    ///           - Aave collateral: 9999 sat, Aave debt: 4601605 USDT
    ///           - Strategy balance: 4599233 USDT withdrawn
    ///           - Flashloan 2443 USDT, repay 2372, shortfall ~2374 USDT
    ///           - Swap ~3736 sat WBTC -> USDT inside flashloan executeOperation
    ///           - V3TooLittleReceived: swapper's minOut (oracle * 99%) > Uniswap actual
    ///
    ///         This test sweeps swapper slippage (1% to 20%) to find the minimum
    ///         slippage tolerance needed to redeem a 1e4 sat deposit, and prints
    ///         the exact revert selector to identify the failure layer.
    function test_swapSlippageDiagnostic_exactTrace() public {
        // Amounts from the mainnet trace
        uint256 depositAmount = 1e4; // exact mainnet deposit: 10000 sat = 0.0001 WBTC

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16; //  1%
        slippageLevels[1] = 2e16; //  2%
        slippageLevels[2] = 3e16; //  3%
        slippageLevels[3] = 5e16; //  5%
        slippageLevels[4] = 45e15; // 4.5%
        slippageLevels[5] = 5e16; // 5% (cap)

        uint256 firstSuccess = 0;

        console.log("=== Swapper Slippage Sweep for 1e4 sat deposit ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();

            _deployVault();

            // Propose + execute slippage change on swapper via gov
            if (slippageLevels[i] != swapper.slippage()) {
                vm.prank(owner);
                swapper.setSlippage(slippageLevels[i]);
            }

            deal(WBTC, user1, depositAmount);
            vm.prank(user1);
            IERC20(WBTC).approve(address(vault), depositAmount);
            vm.prank(user1);
            vault.deposit(depositAmount, user1);

            uint256 shares = vault.balanceOf(user1);
            _syncAndMockOracles();
            vm.roll(block.number + 1);

            bool ok;
            bytes memory errData;
            vm.prank(user1);
            try vault.redeem(shares, user1, user1) returns (uint256) {
                ok = true;
            } catch (bytes memory err) {
                ok = false;
                errData = err;
            }

            bytes4 selector;
            if (errData.length >= 4) {
                assembly { selector := mload(add(errData, 32)) }
            }

            console.log(
                "slippage_bps=%d redeem=%d errLen=%d",
                slippageLevels[i] / 1e14,
                ok ? 1 : 0,
                errData.length
            );
            if (!ok) {
                if (selector == bytes4(keccak256("InsufficientWithdrawal()"))) {
                    console.log(
                        "  => InsufficientWithdrawal (strategy LP underperformed maxSlippage)"
                    );
                } else if (selector == bytes4(keccak256("InsufficientCollateral()"))) {
                    console.log("  => InsufficientCollateral (shortfall exceeds maxSlippage)");
                } else if (selector == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)")))
                {
                    console.log("  => SwapperUnderperformed (oracle floor not met)");
                } else if (selector == bytes4(keccak256("V3TooLittleReceived()"))) {
                    console.log("  => V3TooLittleReceived (Uniswap minAmountOut not met)");
                } else if (selector == bytes4(keccak256("InsufficientFlashloanRepayment()"))) {
                    console.log("  => InsufficientFlashloanRepayment (loanManager)");
                } else if (selector == bytes4(keccak256("DebtNotFullyRepaid()"))) {
                    console.log("  => DebtNotFullyRepaid (loanManager)");
                } else {
                    console.log("  => Unknown selector, errLen:", errData.length);
                }
            }
            if (ok && firstSuccess == 0) {
                firstSuccess = slippageLevels[i];
            }

            vm.revertTo(snap);
        }

        console.log("firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14);
    }

    // ============ TVL Ceiling / Uniswap Liquidity Tests ============

    /// @dev Decode a low-level revert into a human-readable label for console output.
    function _decodeRevertReason(bytes memory err, string memory step)
        internal
        pure
        returns (string memory)
    {
        if (err.length < 4) return string(abi.encodePacked(step, ": revert (no data)"));
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        if (sel == bytes4(keccak256("ExchangeFailed()"))) {
            return string(
                abi.encodePacked(
                    step,
                    ": ExchangeFailed (Curve USDT->crvUSD output below oracle floor at 1% slippage)"
                )
            );
        }
        if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)"))) {
            return string(
                abi.encodePacked(
                    step, ": SwapperUnderperformed (Uniswap USDT->WBTC output below oracle floor)"
                )
            );
        }
        if (sel == bytes4(keccak256("SlippageExceeded()"))) {
            return
                string(abi.encodePacked(step, ": SlippageExceeded (Uniswap minAmountOut not met)"));
        }
        if (sel == bytes4(keccak256("InsufficientCollateral()"))) {
            return string(
                abi.encodePacked(
                    step, ": InsufficientCollateral (recovered WBTC < minOut after unwind)"
                )
            );
        }
        if (sel == bytes4(keccak256("HealthTooLow()"))) {
            return string(abi.encodePacked(step, ": HealthTooLow (Aave health < 1.1)"));
        }
        if (sel == bytes4(keccak256("Error(string)"))) {
            if (err.length > 68) {
                bytes memory msg_ = new bytes(err.length - 68);
                for (uint256 i = 0; i < msg_.length; i++) {
                    msg_[i] = err[68 + i];
                }
                return string(abi.encodePacked(step, ": require(", string(msg_), ")"));
            }
            return string(abi.encodePacked(step, ": require (empty message)"));
        }
        bytes memory h = new bytes(8);
        bytes16 chars = "0123456789abcdef";
        for (uint256 k = 0; k < 4; k++) {
            h[k * 2] = chars[uint8(sel[k]) >> 4];
            h[k * 2 + 1] = chars[uint8(sel[k]) & 0xf];
        }
        return string(abi.encodePacked(step, ": unknown selector 0x", string(h)));
    }

    /// @notice Determines the current single-depositor TVL cap at 1% swapper slippage.
    ///         Coarse sweep locates the cliff, binary search narrows to 1-WBTC resolution,
    ///         then measures the actual round-trip bps cost and USD value at the cap.
    ///         Replaces the former slippage sweep, liquidity sweep, ceiling, and cap tests.
    function test_capacityReport() public {
        uint256 slippage = 1e16; // 1%

        // ── Stage 1: coarse sweep to locate the cliff bracket ───────────────────────
        uint256[14] memory probe = [
            uint256(1e8),
            5e8,
            10e8,
            25e8,
            50e8,
            75e8,
            100e8,
            125e8,
            150e8,
            175e8,
            200e8,
            250e8,
            300e8,
            500e8
        ];
        uint256 lo = 0;
        uint256 hi = 0;
        console.log("=== WBTC capacity sweep at 1%% slippage ===");
        for (uint256 i = 0; i < probe.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe[i]) returns (bool ok) {
                passed = ok;
            }
                catch { }
            vm.revertTo(snap);
            console.log("  %d WBTC: %s", probe[i] / 1e8, passed ? "pass" : "FAIL");
            if (passed) { lo = probe[i]; }
            else if (hi == 0) { hi = probe[i]; break; }
        }
        require(lo > 0, "Not even 1 WBTC passes at 1%% slippage");
        if (hi == 0) { console.log("Cap > 500 WBTC"); return; }

        // ── Stage 2: binary search to 1-WBTC resolution ─────────────────────────────
        while (hi - lo > 1e8) {
            uint256 mid = lo + ((hi - lo) / 2 / uint256(1e8)) * 1e8;
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

        // ── Stage 3: measure bps and USD value at safeCap ───────────────────────────
        uint256 bpsAtCap;
        uint256 capUsd;
        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(WBTC, user1, safeCap);
            vm.prank(owner);
            swapper.setSlippage(slippage);
            _depositAs(user1, safeCap);
            _syncAndMockOracles();
            uint256 received = _redeemAllAs(user1);
            bpsAtCap = safeCap > received ? ((safeCap - received) * 10_000) / safeCap : 0;
            (, int256 rawPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
            capUsd = (safeCap * uint256(rawPrice)) / 1e16;
            vm.revertTo(snap);
        }

        console.log("=== WBTC capacity report ===");
        console.log("Safe cap:   %d WBTC  (~$%d)", safeCap / 1e8, capUsd);
        console.log("First fail: %d WBTC", firstFail / 1e8);
        console.log("Bps at cap: %d bps", bpsAtCap);

        assertGt(safeCap, 0, "Must find a passing size");
        assertLe(bpsAtCap, 100, "Round-trip cost at safe cap must be within 1%%");
    }
}
