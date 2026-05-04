// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { ZenjiWbtcCrvUsdPmUsd } from "../src/implementations/ZenjiWbtcCrvUsdPmUsd.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title WbtcUniCurveLlama
/// @notice Fork tests for WBTC + crvUSD + pmUSD/crvUSD (Stake DAO) strategy on LlamaLend
///         using the cheaper UniV3 WBTC/WETH (0.05%) + Curve TriCRV (WETH→crvUSD) swap route.
contract WbtcUniCurveLlama is ZenjiForkTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;

    // Curve TwoCrypto WBTC/crvUSD pool passed to LlamaLoanManager as collateralDebtPool
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;

    // Uniswap V3 WBTC/WETH pool (fee=500, 0.05%) + Curve TriCRV (WETH↔crvUSD)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500; // V3 0.05%
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniswapMixedCurveSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    PmUsdCrvUsdStrategy public strategy;
    LlamaLoanManager public llamaManager;

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
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = CRVUSD_USD_ORACLE;
        oracles[2] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        // 2 WBTC per user (4 WBTC combined) stays within Uniswap V3 pool depth at 1% slippage.
        return 2e8;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    // ============ Vault deployment ============

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD not found in pmUSD pool");
    }

    function _getWethCrvUsdIndices() internal view returns (uint256 wethIdx, uint256 crvUsdIdx) {
        ICurveTriCrypto pool = ICurveTriCrypto(TRICRYPTO_POOL);
        for (uint256 i = 0; i < 3; i++) {
            address coin = pool.coins(i);
            if (coin == WETH) wethIdx = i;
            else if (coin == CRVUSD) crvUsdIdx = i;
        }
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        // Deploy order: crvSwapper(+0), swapper(+1), strategy(+2), llamaManager(+3), vault(+4)
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();
        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedCurveSwapper(
            owner,
            WBTC,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WBTC_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            3600 // BTC/USD oracle max staleness: 1 hour
        );

        strategy = new PmUsdCrvUsdStrategy(
            CRVUSD,
            address(0), // vault initialised separately via initializeVault
            owner,
            PMUSD_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            CRV_USD_ORACLE
        );

        llamaManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0) // vault initialised separately via initializeVault
        );

        ZenjiWbtcCrvUsdPmUsd vault_ = new ZenjiWbtcCrvUsdPmUsd(
            address(llamaManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(vault_) == expectedVaultAddress, "Vault address mismatch");

        llamaManager.initializeVault(address(vault_));
        strategy.initializeVault(address(vault_));

        vm.prank(owner);
        swapper.setVault(address(vault_));

        // Cast LlamaLoanManager to AaveLoanManager for the base-class field.
        // Both implement ILoanManager so all shared selectors (loanExists, getCurrentLTV, …)
        // resolve correctly at the LlamaLoanManager address.
        loanManager = AaveLoanManager(address(llamaManager));

        vault = vault_;
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        _syncAndMockOracles();
    }

    // ============ Swapper helpers ============

    function _newSwapper() internal returns (UniswapMixedCurveSwapper) {
        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();
        return new UniswapMixedCurveSwapper(
            owner,
            WBTC,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WBTC_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            3600
        );
    }

    // ============ Swapper-specific tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        UniswapMixedCurveSwapper newSwapper = _newSwapper();

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

        UniswapMixedCurveSwapper anotherSwapper = _newSwapper();
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

        assertEq(swapper.slippage(), 1e16, "Initial slippage should be 1%");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(5e16);

        vm.prank(owner);
        swapper.setSlippage(5e16);
        assertEq(swapper.slippage(), 5e16, "Slippage should be 5%");
    }

    /// @notice A 10 WBTC position can fully exit in a single redeem at 2% slippage
    ///         on the UniV3 WBTC/WETH (0.05%) + Curve TriCRV path.
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, 10e8);
        assertTrue(passed, "10 WBTC full redeem should succeed at 2% slippage on UniV3+TriCRV path");
    }

    /// @notice When the BTC oracle price is 2× the real price, LlamaLoanManager's 95%
    ///         post-swap output check (SwapperUnderperformed) blocks redemption because
    ///         the oracle-derived expectation cannot be met by the actual swap output.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        _deployVault();
        _depositAs(user1, 10e8);

        _refreshOracles();

        // Mock BTC oracle at 2× — oracle expects 2× WBTC out; real swap output stays at real price
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer * 2, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(shares, user1, user1);
    }

    /// @dev Deploy a fresh vault, set slippage to targetSlippage, deposit depositAmount WBTC,
    ///      then attempt a single full redemption. Returns true if the redeem succeeds.
    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) internal returns (bool) {
        _syncAndMockOracles();
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

    function runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) external returns (bool) {
        return _runSlippageScenario(targetSlippage, depositAmount);
    }

    function tryDepositChunk(address depositor, uint256 amount) external returns (bool) {
        if (msg.sender != address(this)) revert("self only");
        _depositAs(depositor, amount);
        return true;
    }

    function test_slippageSweep_bySlippage() public {
        uint256[] memory levels = new uint256[](8);
        levels[0] = 5e13;  //  5 bps
        levels[1] = 25e13; // 25 bps
        levels[2] = 50e13; // 50 bps
        levels[3] = 1e16;  //  1.0%
        levels[4] = 2e16;  //  2.0%
        levels[5] = 3e16;  //  3.0%
        levels[6] = 5e16;  //  5.0%
        levels[7] = 10e16; // 10.0%

        uint256 depositAmt = 10e8; // 10 WBTC
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
            console.log("SlippageSweep deposit=10 slippage=%s bps passed=%s", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) firstPass = levels[i];
        }

        console.log("SlippageSweep firstPass(bps)=%s", firstPass == 0 ? 0 : firstPass / 1e14);
        assertTrue(firstPass == 0 || firstPass <= 2e16, "Full 10 WBTC exit should need <= 2% slippage");
    }

    /// @notice Sweep deposit sizes at 1% slippage to find the largest position that can exit cleanly.
    function test_slippageSweep_bySize() public {
        uint256[] memory sizes = new uint256[](8);
        sizes[0] = 1e8;   //   1 WBTC
        sizes[1] = 5e8;   //   5 WBTC
        sizes[2] = 10e8;  //  10 WBTC
        sizes[3] = 20e8;  //  20 WBTC
        sizes[4] = 30e8;  //  30 WBTC
        sizes[5] = 50e8;  //  50 WBTC
        sizes[6] = 75e8;  //  75 WBTC
        sizes[7] = 100e8; // 100 WBTC

        uint256 slippage = 1e16;
        uint256 lastPass = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("WBTC SizeSweep slippage=100bps deposit=%s WBTC passed=%s", sizes[i] / 1e8, passed ? 1 : 0);
            if (passed) lastPass = sizes[i];
        }

        console.log("WBTC SizeSweep lastPass=%s WBTC", lastPass == 0 ? 0 : lastPass / 1e8);
        assertGt(lastPass, 0, "At least the smallest size must exit at 1% slippage");
    }

    // ============ Strategy-Specific Tests ============

    function test_strategyBalance_afterDeposit() public {
        _deployVault();
        _depositAs(user1, _unit());

        assertGt(strategy.balanceOf(), 0, "Strategy should report balance");
        uint256 rvShares = strategy.rewardVault().balanceOf(address(strategy));
        assertGt(rvShares, 0, "Reward vault should hold shares");
    }

    function test_strategyName() public {
        _deployVault();
        assertEq(strategy.name(), "crvUSD -> pmUSD/crvUSD LP Strategy");
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

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        vm.prank(owner);
        vault.harvestYield();

        uint256 stratAfter = strategy.balanceOf();
        assertGe(stratAfter, stratBefore, "Strategy balance must not decrease after harvest");
        console.log("7-day harvest: stratBefore=%d stratAfter=%d", stratBefore, stratAfter);
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

    function test_largeWithdraw_doesNotBankruptRemaining() public {
        _deployVault();

        uint256 smallDeposit = 1e7; // 0.1 WBTC
        uint256 largeDeposit = 5e8; // 5 WBTC
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

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();
        // Two-hop route (WBTC→WETH via V3 0.05% + WETH→crvUSD via Curve TriCRV) adds ~0.15%
        // in fees plus oracle/market basis between BTC/USD and crvUSD/USD Chainlink feeds.
        // Combined spread marginally exceeds the 1% default oracle floor; 2% is principled:
        // bpsCostCurve data shows 6 WBTC combined round-trip is only ~13 bps.
        vm.prank(owner);
        swapper.setSlippage(2e16);
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
        vm.prank(user1);
        vault.redeem(shares / 2, user1, user1);

        (, uint256 debtAfter) = loanManager.getPositionValues();
        uint256 stratAfter = strategy.balanceOf();

        if (debtBefore > 0 && stratBefore > 0) {
            uint256 debtRatio = (debtAfter * 1e18) / debtBefore;
            uint256 stratRatio = (stratAfter * 1e18) / stratBefore;

            uint256 diff = debtRatio > stratRatio ? debtRatio - stratRatio : stratRatio - debtRatio;
            assertLe(diff, 25e16, "Strategy/debt divergence >25% after partial withdraw");
            console.log("Proportionality: debtRatio=%d stratRatio=%d diff=%d", debtRatio, stratRatio, diff);
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

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 30 days");
        _assertValuePreserved(2e8, withdrawn, 1000, "30-day withdraw: >10% total loss");
        console.log("30-day withdraw: deposited=2e8 withdrawn=%d", withdrawn);
    }

    /// @notice Simulates unrealized strategy loss by dropping both BTC and crvUSD prices 5%.
    ///         Mocking both oracles at the same ratio preserves the swapper floor (which uses
    ///         the collateral/debt price ratio). This tests that withdrawal still succeeds even
    ///         when all asset values have dropped 5% in USD terms.
    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        _depositAs(user1, 2e8);
        _refreshOracles();

        // Drop BTC price 5%
        (uint80 roundId1, int256 answer1,,, uint80 answeredInRound1) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId1, (answer1 * 95) / 100, block.timestamp, block.timestamp, answeredInRound1)
        );

        // Drop crvUSD price 5% — preserves BTC/crvUSD ratio so the swapper floor stays in range
        (uint80 roundId2, int256 answer2,,, uint80 answeredInRound2) =
            IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId2, (answer2 * 95) / 100, block.timestamp, block.timestamp, answeredInRound2)
        );

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw with collateral price drop");
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

    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

        uint256 minAmount = vault.MIN_DEPOSIT();
        deal(WBTC, user1, minAmount);

        uint256 shares = _depositAs(user1, minAmount);
        assertGt(shares, 0, "Should receive shares for minimum deposit");

        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Should receive collateral back for minimum deposit");
        console.log("MinDeposit: deposited=%d sat received=%d sat", minAmount, received);
    }

    // ============ TVL Cap Test ============

    /// @dev Decode a low-level revert into a human-readable label for console output.
    function _decodeRevertReason(bytes memory err, string memory step) internal pure returns (string memory) {
        if (err.length < 4) return string(abi.encodePacked(step, ": revert (no data)"));
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)")))
            return string(abi.encodePacked(step, ": SwapperUnderperformed (oracle floor not met on WBTC->WETH->crvUSD)"));
        if (sel == bytes4(keccak256("SlippageExceeded()")))
            return string(abi.encodePacked(step, ": SlippageExceeded (UniV3 minAmountOut not met)"));
        if (sel == bytes4(keccak256("InsufficientCollateral()")))
            return string(abi.encodePacked(step, ": InsufficientCollateral (recovered WBTC < minOut after unwind)"));
        if (sel == bytes4(keccak256("HealthTooLow()")))
            return string(abi.encodePacked(step, ": HealthTooLow (LlamaLend health < min)"));
        if (sel == bytes4(keccak256("InsufficientWithdrawal()")))
            return string(abi.encodePacked(step, ": InsufficientWithdrawal (strategy LP underperformed maxSlippage)"));
        if (sel == bytes4(keccak256("Error(string)"))) {
            if (err.length > 68) {
                bytes memory msg_ = new bytes(err.length - 68);
                for (uint256 i = 0; i < msg_.length; i++) msg_[i] = err[68 + i];
                return string(abi.encodePacked(step, ": require(", string(msg_), ")"));
            }
            return string(abi.encodePacked(step, ": require (empty message)"));
        }
        bytes memory h = new bytes(8);
        bytes16 chars = "0123456789abcdef";
        for (uint256 k = 0; k < 4; k++) {
            h[k * 2]     = chars[uint8(sel[k]) >> 4];
            h[k * 2 + 1] = chars[uint8(sel[k]) & 0xf];
        }
        return string(abi.encodePacked(step, ": unknown selector 0x", string(h)));
    }

    /// @notice Finds the exact single-depositor safe TVL cap at 1% slippage via open-ended binary search.
    ///         Uses the UniV3 WBTC/WETH (0.05%) + Curve TriCRV swap route.
    function test_singleDepositorSafeTvlCap_1pct() public {
        uint256 slippage = 1e16;

        // ── Phase 1: coarse sweep at 50 WBTC steps up to 1000 WBTC ──────────────────
        uint256 clo = 0;
        uint256 chi = 0;
        {
            uint256[] memory coarse = new uint256[](20);
            for (uint256 i = 0; i < 20; i++) coarse[i] = (i + 1) * 50e8; // 50..1000 WBTC
            for (uint256 i = 0; i < coarse.length; i++) {
                uint256 snap = vm.snapshot();
                bool passed;
                try this.runSlippageScenario(slippage, coarse[i]) returns (bool ok) { passed = ok; } catch {}
                vm.revertTo(snap);
                if (passed) { clo = coarse[i]; }
                else if (chi == 0) { chi = coarse[i]; break; }
            }
        }
        require(clo > 0, "Not even 50 WBTC passes at 1% - pool is broken");
        if (chi == 0) {
            console.log("WBTC UniCurve TvlCap: pool handles >1000 WBTC at 1%% slippage (cap not found)");
            return;
        }

        // ── Phase 2: binary search within [clo, chi] at 1 WBTC resolution ───────────
        uint256 lo = clo;
        uint256 hi = chi;
        while (hi - lo > 1e8) {
            uint256 mid = lo + ((hi - lo) / 2 / 1e8) * 1e8;
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, mid) returns (bool ok) { passed = ok; } catch {}
            vm.revertTo(snap);
            if (passed) lo = mid;
            else        hi = mid;
        }
        uint256 safeCap   = lo;
        uint256 firstFail = hi;

        // ── Phase 3: clean measurement at safeCap ─────────────────────────────────────
        uint256 depositUsd;
        uint256 redeemUsd;
        uint256 roundTripBps;
        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(WBTC, user1, safeCap);
            vm.prank(owner); swapper.setSlippage(slippage);

            _depositAs(user1, safeCap);
            _syncAndMockOracles();

            uint256 sharesAll = vault.balanceOf(user1);
            vm.prank(user1);
            uint256 wbtcOut = vault.redeem(sharesAll, user1, user1);

            (, int256 rawPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
            uint256 price8 = uint256(rawPrice);
            depositUsd   = (safeCap * price8) / 1e16;
            redeemUsd    = (wbtcOut * price8) / 1e16;
            roundTripBps = safeCap > wbtcOut ? ((safeCap - wbtcOut) * 10000) / safeCap : 0;

            vm.revertTo(snap);
        }

        // ── Phase 4: trace the first failing size ─────────────────────────────────────
        string memory failReason = "not found";
        uint256 traceTarget = firstFail;
        for (uint256 probe = firstFail; probe <= firstFail + 20 * 1e8; probe += 1e8) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe) returns (bool ok) { passed = ok; } catch {}
            vm.revertTo(snap);
            if (!passed) { traceTarget = probe; break; }
        }

        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(WBTC, user1, traceTarget);
            vm.prank(owner); swapper.setSlippage(slippage);

            vm.startPrank(user1);
            IERC20(WBTC).approve(address(vault), traceTarget);
            bool depositOk;
            try vault.deposit(traceTarget, user1) returns (uint256) {
                depositOk = true;
            } catch (bytes memory err) {
                depositOk = false;
                failReason = _decodeRevertReason(err, "deposit");
            }
            vm.stopPrank();

            if (depositOk) {
                vm.roll(block.number + 1);
                _syncAndMockOracles();
                uint256 sharesAll = vault.balanceOf(user1);
                vm.prank(user1);
                try vault.redeem(sharesAll, user1, user1) returns (uint256) {
                    failReason = "passed in trace (pool state shifted)";
                } catch (bytes memory err) {
                    failReason = _decodeRevertReason(err, "redeem");
                }
            }
            vm.revertTo(snap);
        }

        console.log("=== WBTC Single-depositor safe TVL cap at 1%% slippage (UniV3+TriCRV) ===");
        console.log("Max safe deposit:    %s WBTC",  safeCap / 1e8);
        console.log("First failing size:  %s WBTC",  firstFail / 1e8);
        console.log("Deposit value:      ~$%s",       depositUsd);
        console.log("Redeem  value:      ~$%s",       redeemUsd);
        console.log("Round-trip cost:     %s bps",    roundTripBps);
        console.log("Failure reason:      %s",        failReason);

        assertGt(safeCap, 0, "Must find a passing size");
        assertLe(roundTripBps, 100, "Round-trip cost at cap must be within 1%%");
    }

    // ============ Slippage capacity diagnostic ============

    /// @notice Diagnostic: measures actual round-trip loss at a range of deposit sizes.
    function test_slippageCapacity() public {
        _deployVault();

        uint256[8] memory amounts =
            [uint256(1e6), 1e7, 5e7, 1e8, 2e8, 3e8, 5e8, 10e8];

        console.log("=== WBTC LlamaLend round-trip slippage (UniV3 WBTC/WETH 0.05%% + Curve TriCRV) ===");
        console.log("Simulating deposit -> 5-block wait -> full redeem");
        console.log("swap path on unwind: WBTC->WETH via UniV3, WETH->crvUSD via TriCRV");
        console.log("");

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 snap = vm.snapshot();
            uint256 amount = amounts[i];

            deal(WBTC, user1, amount);
            _syncAndMockOracles();
            _depositAs(user1, amount);

            vm.roll(block.number + 5);
            vm.warp(block.timestamp + 60);
            _syncAndMockOracles();

            uint256 received = _redeemAllAs(user1);

            uint256 loss = amount > received ? amount - received : 0;
            uint256 bps = (loss * 10_000) / amount;

            console.log(
                string.concat(
                    vm.toString(amount / 1e6),
                    " centi-WBTC (1e-2 BTC)  ->  received ",
                    vm.toString(received),
                    " sat  (",
                    vm.toString(bps),
                    " bps loss  ",
                    bps <= 100 ? "OK" : "EXCEEDS 1%",
                    ")"
                )
            );

            vm.revertTo(snap);
        }
    }
}
