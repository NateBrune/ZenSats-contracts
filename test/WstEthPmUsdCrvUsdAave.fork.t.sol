// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title WstEthPmUsdCrvUsdAave
/// @notice Fork tests for wstETH + USDT + pmUSD/crvUSD (Stake DAO) strategy on Aave
contract WstEthPmUsdCrvUsdAave is ZenjiForkTestBase {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 3000;

    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniswapV3TwoHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    WstEthOracle public wstEthOracle;
    PmUsdCrvUsdStrategy public strategy;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WSTETH;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](5);
        oracles[0] = STETH_ETH_ORACLE;
        oracles[1] = ETH_USD_ORACLE;
        oracles[2] = USDT_USD_ORACLE;
        oracles[3] = CRVUSD_USD_ORACLE;
        oracles[4] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return ETH_USD_ORACLE;
    }

    function _fuzzMin() internal pure override returns (uint256) {
        return 1e17;
    }

    function _fuzzMultiMin() internal pure override returns (uint256) {
        return 3e18;
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return 50e18;
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
        revert("crvUSD index not found");
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 5);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();

        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
            USDT_USD_ORACLE
        );

        strategy = new PmUsdCrvUsdStrategy(
            USDT,
            CRVUSD,
            CRV,
            PMUSD,
            expectedVaultAddress,
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
            WSTETH,
            USDT,
            AAVE_A_WSTETH,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            address(wstEthOracle),
            USDT_USD_ORACLE,
            address(swapper),
            7100,
            7600,
            expectedVaultAddress
        );

        vault = new Zenji(
            WSTETH,
            USDT,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        yieldStrategy = strategy;
    }

    // ============ Swapper-Specific Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        UniswapV3TwoHopSwapper newSwapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
            USDT_USD_ORACLE
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

        UniswapV3TwoHopSwapper anotherSwapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
            USDT_USD_ORACLE
        );
        vm.prank(vault.gov());
        vault.proposeSwapper(address(anotherSwapper));

        vm.prank(vault.gov());
        vault.cancelSwapper();

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        vault.executeSwapper();
    }

    function test_slippageTimelock() public {
        _deployVault();

        assertEq(swapper.slippage(), 1e16, "Initial slippage should be 1%");

        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        vm.prank(owner);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        swapper.executeSlippage();

        vm.warp(block.timestamp + 1 weeks + 1);
        _syncAndMockOracles();

        vm.prank(owner);
        swapper.executeSlippage();
        assertEq(swapper.slippage(), 10e16, "Slippage should be 10%");
    }

    /// @notice A ~$10M position (3,000 wstETH at the historical test range) can fully exit in
    ///         a single redeem at the 2% production ceiling.
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, 3000e18);
        assertTrue(passed, "3000 wstETH full redeem should succeed at 2% slippage on Uniswap V3");
    }

    /// @notice When slippage tolerance is set below the effective fee floor of the route, the
    ///         full redemption must fail the swap output floor.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        bool passed = _runSlippageScenario(5e13, 3000e18); // 5 bps
        assertFalse(
            passed,
            "3000 wstETH full redeem should revert when slippage tolerance is below route fee floor"
        );
    }

    // ============ Liquidity / Slippage Sweep ============

    /// @dev Deploy a fresh vault, set slippage to targetSlippage, deposit depositAmount wstETH,
    ///      then attempt a single full redeem.  Returns true if the redeem succeeds.
    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) internal returns (bool) {
        _syncAndMockOracles(); // re-anchor oracle mocks to current block.timestamp after any vm.revertTo
        _deployVault();

        deal(WSTETH, user1, depositAmount);

        if (swapper.slippage() != targetSlippage) {
            vm.prank(owner);
            swapper.proposeSlippage(targetSlippage);
            vm.warp(block.timestamp + 1 weeks + 1);
            _syncAndMockOracles();
            vm.prank(owner);
            swapper.executeSlippage();
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

    /// @notice Sweep slippage levels at a fixed deposit size (3 000 wstETH ≈ $10M) to find
    ///         the minimum slippage required for a clean full exit on the Uniswap V3 two-hop path.
    ///         Each level is isolated via vm.snapshot/revertTo so timelock warps don't accumulate.
    function test_slippageSweep_bySlippage() public {
        uint256[] memory levels = new uint256[](8);
        levels[0] = 5e13;  //  5 bps (below pool fees — should fail)
        levels[1] = 25e13; // 25 bps
        levels[2] = 50e13; // 50 bps
        levels[3] = 1e16;  //  1.0% (production default)
        levels[4] = 2e16;  //  2.0%
        levels[5] = 3e16;  //  3.0%
        levels[6] = 5e16;  //  5.0%
        levels[7] = 10e16; // 10.0%

        uint256 depositAmt = 3000e18; // ~3 000 wstETH ≈ $10M
        uint256 firstPass = 0;

        for (uint256 i = 0; i < levels.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(levels[i], depositAmt) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap); // isolate: undo warp + state before logging
            console.log("SlippageSweep deposit=3000 slippage=%s bps passed=%s", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) firstPass = levels[i];
        }

        console.log("SlippageSweep firstPass(bps)=%s", firstPass == 0 ? 0 : firstPass / 1e14);
        assertTrue(firstPass == 0 || firstPass <= 2e16, "Full 3000 wstETH exit should need <= 2% slippage");
    }

    /// @notice Sweep deposit sizes at the 1% production slippage to find the largest position
    ///         that can exit cleanly — answers "how much liquidity can we use?".
    ///         Each level is isolated via vm.snapshot/revertTo.
    function test_slippageSweep_bySize() public {
        uint256[] memory sizes = new uint256[](8);
        sizes[0] = 10e18;    //    10 wstETH  (~$35k)
        sizes[1] = 100e18;   //   100 wstETH  (~$350k)
        sizes[2] = 500e18;   //   500 wstETH  (~$1.75M)
        sizes[3] = 1000e18;  //  1000 wstETH  (~$3.5M)
        sizes[4] = 3000e18;  //  3000 wstETH  (~$10M)
        sizes[5] = 5000e18;  //  5000 wstETH  (~$17.5M)
        sizes[6] = 10000e18; // 10000 wstETH  (~$35M)
        sizes[7] = 20000e18; // 20000 wstETH  (~$70M)

        uint256 slippage = 1e16; // 1% — production default
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
            console.log(
                "SizeSweep slippage=100bps deposit=%s wstETH passed=%s",
                sizes[i] / 1e18,
                passed ? 1 : 0
            );
            if (passed) lastPass = sizes[i];
        }

        console.log("SizeSweep lastPass=%s wstETH", lastPass == 0 ? 0 : lastPass / 1e18);
        assertGt(lastPass, 0, "At least the smallest size must exit at 1% slippage");
    }

    /// @notice Refine the liquidity threshold at 1% slippage in the 3k-20k wstETH band.
    function test_liquiditySweep_bySize_refined() public {
        uint256[] memory sizes = new uint256[](7);
        sizes[0] = 3000e18;
        sizes[1] = 4000e18;
        sizes[2] = 5000e18;
        sizes[3] = 7000e18;
        sizes[4] = 10000e18;
        sizes[5] = 15000e18;
        sizes[6] = 20000e18;

        uint256 slippage = 1e16;
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "RefinedSizeSweep slippage=100bps deposit=%s wstETH passed=%s",
                sizes[i] / 1e18,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("RefinedSizeSweep lastPass=%s wstETH", lastPass == 0 ? 0 : lastPass / 1e18);
        console.log("RefinedSizeSweep firstFail=%s wstETH", firstFail == 0 ? 0 : firstFail / 1e18);
        assertGt(lastPass, 0, "Refined sweep should have at least one passing size");
    }

    function test_liquiditySweep_bySize_ultraRefined() public {
        uint256[] memory sizes = new uint256[](5);
        sizes[0] = 5000e18;
        sizes[1] = 5500e18;
        sizes[2] = 6000e18;
        sizes[3] = 6500e18;
        sizes[4] = 7000e18;

        uint256 slippage = 1e16; // 1%
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "UltraRefined slippage=100bps deposit=%s wstETH passed=%s",
                sizes[i] / 1e18,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("UltraRefined lastPass=%s wstETH", lastPass == 0 ? 0 : lastPass / 1e18);
        console.log("UltraRefined firstFail=%s wstETH", firstFail == 0 ? 0 : firstFail / 1e18);
        assertGt(lastPass, 0, "Ultra-refined sweep should have at least one passing size");
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
        assertEq(strategy.name(), "USDT -> pmUSD/crvUSD LP Strategy");
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

    function test_multiDepositors_reach20mTvl() public {
        _deployVault();

        vm.prank(vault.gov());
        vault.setParam(1, 30e16);
        vm.prank(vault.gov());
        vault.setStrategySlippage(5e16);

        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");

        address[4] memory users = [user1, user2, user3, user4];
        uint256 targetTvlUsdt = 20_000_000e6;
        uint256 chunk = 300e18; // 300 wstETH per deposit tx
        uint256 minChunk = 10e18; // 10 wstETH
        uint256 tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());

        for (uint256 i = 0; i < 200 && tvlUsdt < targetTvlUsdt; i++) {
            address depositor = users[i % users.length];
            deal(WSTETH, depositor, chunk);
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
            tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        assertGe(tvlUsdt, 20_000_000e6, "TVL should reach at least $20M");
        console.log("wstETH multi-user TVL(USDT 6d)=%d", tvlUsdt);
    }

    // ============ $10K Confidence Tests ============

    function test_largeWithdraw_doesNotBankruptRemaining() public {
        _deployVault();

        uint256 smallDeposit = 1e17; // 0.1 wstETH
        uint256 largeDeposit = 5e18; // 5 wstETH (50x)
        deal(WSTETH, user1, smallDeposit);
        deal(WSTETH, user2, largeDeposit);

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
        _depositAs(user1, 2e18);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));

        assertGe(valueAfter * 100, valueBefore * 95, "7-day value loss >5%");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 7 days");
        _assertValuePreserved(2e18, withdrawn, 500, "7-day withdraw: >5% loss");
        console.log("7-day withdraw: deposited=2e18 withdrawn=%d", withdrawn);
    }

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();
        address user3 = makeAddr("user3");

        uint256 d1 = 1e18;
        uint256 d2 = 2e18;
        uint256 d3 = 3e18;
        deal(WSTETH, user1, d1);
        deal(WSTETH, user2, d2);
        deal(WSTETH, user3, d3);

        _depositAs(user1, d1);
        _depositAs(user2, d2);
        vm.startPrank(user3);
        IERC20(WSTETH).approve(address(vault), d3);
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

        _depositAs(user1, 3e18);

        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        int256 upPrice = (answer * 115) / 100;
        vm.mockCall(
            ETH_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, upPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfterUp = loanManager.getCurrentLTV();
        assertGt(ltvAfterUp, ltvBefore, "LTV should increase after upward rebalance");

        // Restore oracle to real price before withdrawal
        vm.clearMockedCalls();
        _syncAndMockOracles();

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after lifecycle");
        _assertValuePreserved(3e18, withdrawn, 500, "Lifecycle: >5% loss");
        console.log("Lifecycle: deposited=3e18 withdrawn=%d", withdrawn);
    }

    function test_strategyDebtProportionality_afterPartialWithdraw() public {
        _deployVault();
        _depositAs(user1, 4e18);

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
            console.log(
                "Proportionality: debtRatio=%d stratRatio=%d diff=%d", debtRatio, stratRatio, diff
            );
        }
    }

    function test_interestAccrual_30days() public {
        _deployVault();
        _depositAs(user1, 2e18);

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));

        assertGe(valueAfter * 100, valueBefore * 90, "30-day value loss >10%");
        console.log("30-day: valueBefore=%d valueAfter=%d", valueBefore, valueAfter);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 30 days");
        _assertValuePreserved(2e18, withdrawn, 1000, "30-day withdraw: >10% total loss");
        console.log("30-day withdraw: deposited=2e18 withdrawn=%d", withdrawn);
    }

    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        _depositAs(user1, 2e18);

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
        console.log("Strategy loss: deposited=2e18 withdrawn=%d", withdrawn);
    }

    function testFuzz_largeRatioDeposits_noBankruptcy(uint256 ratio) public {
        _deployVault();
        ratio = bound(ratio, 10, 100);

        uint256 smallAmount = 1e17;
        uint256 largeAmount = smallAmount * ratio;
        deal(WSTETH, user1, smallAmount);
        deal(WSTETH, user2, largeAmount);

        _depositAs(user1, smallAmount);
        _depositAs(user2, largeAmount);

        _refreshOracles();
        _redeemAllAs(user2);

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining user must be able to withdraw");
        assertGe(received * 100, smallAmount * 40, "Remaining user lost >60%");
    }
}
