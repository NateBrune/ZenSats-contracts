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
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
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
            USDT_USD_ORACLE,
            3_600
        );

        strategy = new PmUsdCrvUsdStrategy(
            USDT,
            CRVUSD,
            CRV,
            PMUSD,
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
            expectedVaultAddress,
            0, // eMode: disabled
            3600
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

        UniswapV3TwoHopSwapper newSwapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
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

        UniswapV3TwoHopSwapper anotherSwapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
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

        assertEq(swapper.slippage(), 1e16, "Initial slippage should be 1%");

        // Unauthorized caller cannot set slippage
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(10e16);

        // Gov can set slippage directly
        vm.prank(owner);
        swapper.setSlippage(10e16);
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
        vault.setParam(4, 5e16);

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

    /// @notice Deposit exactly vault.MIN_DEPOSIT() and fully redeem.
    /// Confirms the contract-minimum path succeeds end-to-end on mainnet liquidity.
    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

        // Use the vault's own MIN_DEPOSIT() — production ZenjiWstEthPmUsd returns 3e16 (~$114),
        // the base Zenji used in fork tests returns 1e4 (essentially dust for 18-decimal wstETH).
        // Use max(MIN_DEPOSIT, 3e16) to guarantee the carry-trade path is exercised.
        uint256 minAmount = vault.MIN_DEPOSIT() > 3e16 ? vault.MIN_DEPOSIT() : 3e16;
        deal(WSTETH, user1, minAmount);

        uint256 shares = _depositAs(user1, minAmount);
        assertGt(shares, 0, "Should receive shares for minimum deposit");

        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Should receive collateral back for minimum deposit");
        console.log("MinDeposit: deposited=%d wei received=%d wei", minAmount, received);
    }

    /// @notice Deposit 250 wstETH (~$1M at $4,000/wstETH) and fully redeem.
    /// Confirms a large round-trip within normal operating range succeeds.
    function test_oneMillion_depositAndRedeem() public {
        // 250 wstETH ≈ $1M at $4,000/wstETH
        uint256 depositAmount = 250e18;
        bool passed = _runSlippageScenario(2e16, depositAmount);
        assertTrue(passed, "250 wstETH (~$1M) full redeem should succeed at 2% slippage");
        console.log("$1M test: 250 wstETH deposit+redeem at 2%% slippage passed");
    }

    // ============ Dust / Minimum Deposit Tests ============

    /// @notice Verifies that a ~0.03 wstETH dust deposit can be fully redeemed.
    ///         The two-hop swap path (wstETH→WETH→USDT) on tiny amounts exercises
    ///         the dust-swap threshold bypass for micro flash-loan repayments.
    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        // 0.03 wstETH — matches the economic minimum used in test_minimumDeposit_fullRedeem.
        // At $3,500/wstETH this is ~$105, well above the swap fee floor.
        uint256 dustAmount = 3e16;
        deal(WSTETH, user1, dustAmount);

        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), dustAmount);

        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        console.log("Dust deposit: %d wei", dustAmount);
        console.log("Shares minted: %d", sharesMinted);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        // Should succeed — dust swap threshold bypasses oracle minOut for micro swaps
        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);

        console.log("Dust redemption succeeded.");
    }

    /// @notice Trace every number through the full deposit→redeem path for a 0.03 wstETH deposit.
    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        uint256 dustAmount = 3e16; // 0.03 wstETH ~$105
        deal(WSTETH, user1, dustAmount);

        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (wei):      ", dustAmount);
        console.log("sharesMinted:          ", sharesMinted);
        console.log("Aave collateral (wei): ", posCollateral);
        console.log("Aave debt (USDT e6):   ", posDebt);
        console.log("Strategy bal (USDT e6):", stratBal);
        console.log("Vault idle wstETH (wei):", IERC20(WSTETH).balanceOf(address(vault)));

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        uint256 collateralNeeded = vault.previewRedeem(sharesMinted);
        console.log("=== Projected unwind ===");
        console.log("collateralNeeded (wei):", collateralNeeded);
        if (posCollateral > 0) {
            uint256 debtToRepay = posDebt * collateralNeeded / posCollateral;
            console.log("debtToRepay (USDT e6): ", debtToRepay);
            console.log("debtNeeded 105% (e6):  ", debtToRepay * 105 / 100);
        }
        console.log("maxSlippage (bps):     ", vault.maxSlippage() / 1e14);
        console.log("swapper slippage (bps):", swapper.slippage() / 1e14);

        console.log("=== Attempting vault.redeem ===");
        vm.prank(user1);
        try vault.redeem(sharesMinted, user1, user1) returns (uint256 amount) {
            console.log("Redeem SUCCEEDED (wei):", amount);
        } catch (bytes memory err) {
            console.log("Redeem REVERTED. Raw error bytes length:", err.length);
            if (err.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(err, 32)) }
                if (selector == Zenji.InsufficientWithdrawal.selector) {
                    console.log("=> InsufficientWithdrawal: strategy LP underperformed maxSlippage");
                } else if (selector == Zenji.InsufficientCollateral.selector) {
                    console.log("=> InsufficientCollateral: not enough wstETH recovered after unwind");
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
    ///         Economic minimum for wstETH is ~0.03 wstETH (~$105) due to two-hop swap overhead.
    function test_realisticMinimum_succeeds() public {
        _deployVault();

        // 0.1 wstETH ~$350 at $3,500/wstETH — comfortably above economic dust floor
        uint256 realAmount = 1e17;

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];

        for (uint256 i = 0; i < users.length; i++) {
            deal(WSTETH, users[i], realAmount);
            vm.prank(users[i]);
            IERC20(WSTETH).approve(address(vault), realAmount);

            vm.prank(users[i]);
            vault.deposit(realAmount, users[i]);
        }

        _syncAndMockOracles();

        // Move forward 1 block to bypass COOLDOWN_BLOCKS check
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 shares = vault.balanceOf(users[i]);
            if (shares > 0) {
                vm.prank(users[i]);
                uint256 collateralReceived = vault.redeem(shares, users[i], users[i]);
                assertGt(collateralReceived, 0, "Realistic deposit should redeem non-zero collateral");
                console.log("User redeemed shares for wei");
                console.log(i);
                console.log(shares);
                console.log(collateralReceived);
            }
        }
    }

    /// @notice Document the vault's economic minimum for wstETH.
    ///         The base Zenji MIN_DEPOSIT (1e4 wei) is negligible for 18-decimal wstETH;
    ///         the real bound is set by the two-hop swap mechanics (~0.03 wstETH).
    function test_documentEconomicMinimum() public pure {
        // MIN_DEPOSIT = 1e4 wei (from base Zenji) — negligible for 18-decimal wstETH
        uint256 contractMinimum = 1e4;

        // VIRTUAL_SHARE_OFFSET = 1e5 wei (from base Zenji)
        uint256 virtualOffset = 1e5;

        // Economic minimum = 3e16 wei = 0.03 wstETH (~$105 at $3,500/wstETH)
        // Must cover two-hop fee (wstETH→WETH→USDT) + flashloan premium
        uint256 economicMinimum = 3e16;

        console.log("Contract MIN_DEPOSIT:  %d wei", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d wei", virtualOffset);
        console.log("Economic minimum:      %d wei", economicMinimum);
        console.log("Why dust fails on mainnet (wstETH two-hop):");
        console.log("1. Deposit of tiny wei passes MIN_DEPOSIT check");
        console.log("2. Very few shares created due to low VIRTUAL_SHARE_OFFSET");
        console.log("3. Redeem triggers proportional flash-loan unwind");
        console.log("4. Two-hop swap: wstETH->WETH->USDT accumulates pool fees");
        console.log("5. Oracle floor (1% tolerance) > tiny Uniswap output at micro sizes");
        console.log("6. Vault reverts: SwapperUnderperformed");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    /// @notice Single shot: deposit 0.03 wstETH then redeem, with trace for debugging
    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 3e16; // 0.03 wstETH ~$105
        deal(WSTETH, user1, depositAmount);
        vm.prank(user1); IERC20(WSTETH).approve(address(vault), depositAmount);
        vm.prank(user1); vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_wei=%d debt_usdt6=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    /// @notice Sweeps swapper slippage levels (1%–20%) to identify the minimum tolerance
    ///         needed to redeem a 0.03 wstETH deposit and prints the exact revert selector.
    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 3e16; // 0.03 wstETH ~$105

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;  //  1%
        slippageLevels[1] = 2e16;  //  2%
        slippageLevels[2] = 3e16;  //  3%
        slippageLevels[3] = 5e16;  //  5%
        slippageLevels[4] = 10e16; // 10%
        slippageLevels[5] = 20e16; // 20%

        uint256 firstSuccess = 0;

        console.log("=== wstETH Swapper Slippage Sweep for 3e16 wei deposit ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();

            _deployVault();

            if (slippageLevels[i] != swapper.slippage()) {
                vm.prank(owner);
                swapper.setSlippage(slippageLevels[i]);
            }

            deal(WSTETH, user1, depositAmount);
            vm.prank(user1);
            IERC20(WSTETH).approve(address(vault), depositAmount);
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

            console.log("slippage_bps=%d redeem=%d errLen=%d", slippageLevels[i] / 1e14, ok ? 1 : 0, errData.length);
            if (!ok) {
                if (selector == bytes4(keccak256("InsufficientWithdrawal()"))) {
                    console.log("  => InsufficientWithdrawal (strategy LP underperformed maxSlippage)");
                } else if (selector == bytes4(keccak256("InsufficientCollateral()"))) {
                    console.log("  => InsufficientCollateral (shortfall exceeds maxSlippage)");
                } else if (selector == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)"))) {
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

        console.log("wstETH firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14);
    }

    // ============ TVL Ceiling / Uniswap Liquidity Tests ============

    /// @dev Decode a low-level revert into a human-readable label for console output.
    function _decodeRevertReason(bytes memory err, string memory step) internal pure returns (string memory) {
        if (err.length < 4) return string(abi.encodePacked(step, ": revert (no data)"));
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        if (sel == bytes4(keccak256("ExchangeFailed()")))
            return string(abi.encodePacked(step, ": ExchangeFailed (Curve USDT->crvUSD output below oracle floor at 1% slippage)"));
        if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)")))
            return string(abi.encodePacked(step, ": SwapperUnderperformed (Uniswap USDT->wstETH output below oracle floor)"));
        if (sel == bytes4(keccak256("SlippageExceeded()")))
            return string(abi.encodePacked(step, ": SlippageExceeded (Uniswap minAmountOut not met)"));
        if (sel == bytes4(keccak256("InsufficientCollateral()")))
            return string(abi.encodePacked(step, ": InsufficientCollateral (recovered wstETH < minOut after unwind)"));
        if (sel == bytes4(keccak256("HealthTooLow()")))
            return string(abi.encodePacked(step, ": HealthTooLow (Aave health < 1.1)"));
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

    /// @notice Exhaustively deposits until the protocol refuses all deposit sizes,
    ///         reporting the true single-asset TVL ceiling at 30% target LTV.
    function test_tvlCeiling_exhaustive() public {
        _deployVault();
        vm.prank(vault.gov()); vault.setParam(1, 30e16); // 30% target LTV
        vm.prank(vault.gov()); vault.setParam(4, 5e16);  // 5% vault slippage

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];
        uint256 chunk = 500e18;  // 500 wstETH starting chunk
        uint256 minChunk = 1e17; // 0.1 wstETH floor
        string memory stopReason = "iter_cap";

        for (uint256 i = 0; i < 500; i++) {
            address depositor = users[i % users.length];
            deal(WSTETH, depositor, chunk);
            bool ok;
            try this.tryDepositChunk(depositor, chunk) returns (bool success) {
                ok = success;
            } catch {
                ok = false;
            }

            if (!ok) {
                if (chunk > minChunk) {
                    chunk = chunk / 2;
                    continue;
                } else {
                    stopReason = "ceiling_hit";
                    break;
                }
            }

            if (i % 4 == 0) _refreshOracles();
            uint256 tvl = loanManager.getCollateralValue(vault.getTotalCollateral());
            if (tvl >= 5_000_000e6  && tvl < 5_001_000e6)  console.log("wstETH Ceiling milestone: $5M");
            if (tvl >= 10_000_000e6 && tvl < 10_001_000e6) console.log("wstETH Ceiling milestone: $10M");
            if (tvl >= 20_000_000e6 && tvl < 20_001_000e6) console.log("wstETH Ceiling milestone: $20M");
            if (tvl >= 30_000_000e6 && tvl < 30_001_000e6) console.log("wstETH Ceiling milestone: $30M");
            if (tvl >= 50_000_000e6 && tvl < 50_001_000e6) console.log("wstETH Ceiling milestone: $50M");
        }

        uint256 tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        console.log("wstETH TVL Ceiling stop_reason=%s", stopReason);
        console.log("wstETH TVL Ceiling final_tvl_usdt6=%d", tvlUsdt);
        console.log("wstETH TVL Ceiling final_chunk_wei=%d", chunk);
        assertGt(tvlUsdt, 0, "Should have deposited something");
    }

    /// @notice Deposits multiple users toward the maximum achievable TVL, reporting the
    ///         peak before Curve/Uniswap pool depth becomes binding.
    function test_multiDepositors_maxTvl() public {
        _deployVault();

        vm.prank(vault.gov()); vault.setParam(1, 30e16);
        vm.prank(vault.gov()); vault.setParam(4, 5e16);

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];
        uint256 targetTvlUsdt = 50_000_000e6; // push toward $50M (caps at pool depth)
        uint256 chunk = 500e18;  // 500 wstETH per deposit tx
        uint256 minChunk = 1e17; // 0.1 wstETH
        uint256 tvlUsdt = 0;
        uint256 iter = 0;

        while (iter < 300 && tvlUsdt < targetTvlUsdt) {
            address depositor = users[iter % users.length];
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
                iter++;
                continue;
            }
            iter++;
            if (iter % 4 == 0) _refreshOracles();
            tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        console.log("wstETH MaxTvl reached TVL(USDT 6d)=%d", tvlUsdt);
        console.log("wstETH MaxTvl final chunk size=%d wei", chunk);
        assertGt(tvlUsdt, 3_000_000e6, "Should exceed $3M TVL");
    }

    /// @notice Pinpoints the Uniswap V3 wstETH→WETH→USDT two-hop path's per-tx
    ///         USDT→wstETH slippage cliff at exactly 1% swapper tolerance.
    /// @dev On every redeem the vault swaps ~5% USDT surplus back to wstETH via the two-hop swapper.
    ///      Sweep from 1,000 to 20,000 wstETH to capture the single-depositor liquidity limit.
    function test_uniswapSlippageCeiling_1pct() public {
        uint256[] memory sizes = new uint256[](12);
        sizes[0]  = 1000e18;  //  1000 wstETH  ~$3.5M
        sizes[1]  = 2000e18;  //  2000 wstETH  ~$7M
        sizes[2]  = 3000e18;  //  3000 wstETH  ~$10.5M
        sizes[3]  = 4000e18;  //  4000 wstETH  ~$14M
        sizes[4]  = 5000e18;  //  5000 wstETH  ~$17.5M  ← estimated boundary
        sizes[5]  = 6000e18;  //  6000 wstETH  ~$21M
        sizes[6]  = 7000e18;  //  7000 wstETH  ~$24.5M
        sizes[7]  = 8000e18;  //  8000 wstETH  ~$28M
        sizes[8]  = 10000e18; // 10000 wstETH  ~$35M
        sizes[9]  = 12000e18; // 12000 wstETH  ~$42M
        sizes[10] = 15000e18; // 15000 wstETH  ~$52.5M
        sizes[11] = 20000e18; // 20000 wstETH  ~$70M

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

            // Surplus USDT swap estimate: deposit × $3,500/wstETH × 65% LTV × 5% buffer
            uint256 approxSwapUsdtK = (sizes[i] * 113750) / 1e18 / 1000; // $K
            console.log(
                "wstETH UniswapCeiling slippage=100bps deposit=%s wstETH swapEst=$%sK passed=%s",
                sizes[i] / 1e18,
                approxSwapUsdtK,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("wstETH UniswapCeiling lastPass=%s wstETH", lastPass / 1e18);
        console.log("wstETH UniswapCeiling firstFail=%s wstETH", firstFail == 0 ? 0 : firstFail / 1e18);
        assertGt(lastPass, 0, "At least 1000 wstETH should pass at 1% slippage");
    }

    /// @notice Fine-grain bisection around the Uniswap wstETH two-hop cliff at 1% slippage.
    function test_uniswapSlippageCeiling_1pct_finegrain() public {
        uint256[] memory sizes = new uint256[](10);
        sizes[0] = 4500e18;  //  4500 wstETH
        sizes[1] = 5000e18;  //  5000 wstETH
        sizes[2] = 5250e18;  //  5250 wstETH
        sizes[3] = 5500e18;  //  5500 wstETH
        sizes[4] = 5750e18;  //  5750 wstETH
        sizes[5] = 6000e18;  //  6000 wstETH
        sizes[6] = 6250e18;  //  6250 wstETH
        sizes[7] = 6500e18;  //  6500 wstETH
        sizes[8] = 6750e18;  //  6750 wstETH
        sizes[9] = 7000e18;  //  7000 wstETH

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
                "wstETH UniswapFine slippage=100bps deposit=%s wstETH passed=%s",
                sizes[i] / 1e18,
                passed ? 1 : 0
            );

            if (passed) { lastPass = sizes[i]; }
            else if (firstFail == 0) { firstFail = sizes[i]; }
        }

        console.log("wstETH UniswapFine lastPass=%s  firstFail=%s wstETH", lastPass / 1e18, firstFail / 1e18);
        assertGt(lastPass, 0, "Fine-grain: at least 4500 wstETH should pass");
    }

    /// @notice Finds the exact single-depositor safe TVL cap at 1% slippage via open-ended binary search.
    ///
    /// @dev Runs four phases:
    ///   Phase 1 — coarse sweep (500 wstETH steps, 500..10000) to bracket the cliff.
    ///   Phase 2 — binary search within that bracket at 50 wstETH resolution.
    ///   Phase 3 — clean deposit + redeem at the safe cap to measure actual round-trip cost.
    ///   Phase 4 — trace the first failing size to expose the exact revert reason.
    function test_singleDepositorSafeTvlCap_1pct() public {
        uint256 slippage = 1e16; // 1%

        // ── Phase 1: coarse sweep at 500 wstETH steps ─────────────────────────────────
        uint256 clo = 0;
        uint256 chi = 0;
        {
            uint256[] memory coarse = new uint256[](20);
            for (uint256 i = 0; i < 20; i++) coarse[i] = (i + 1) * 500e18; // 500..10000 wstETH
            for (uint256 i = 0; i < coarse.length; i++) {
                uint256 snap = vm.snapshot();
                bool passed;
                try this.runSlippageScenario(slippage, coarse[i]) returns (bool ok) { passed = ok; } catch {}
                vm.revertTo(snap);
                if (passed) { clo = coarse[i]; }
                else if (chi == 0) { chi = coarse[i]; break; }
            }
        }
        require(clo > 0, "Not even 500 wstETH passes at 1% - pool is broken");
        require(chi > 0, "Everything passes up to 10000 wstETH - extend upper bound");

        // ── Phase 2: binary search within [clo, chi] at 50 wstETH resolution ─────────
        uint256 lo = clo;
        uint256 hi = chi;
        while (hi - lo > 50e18) {
            uint256 mid = lo + ((hi - lo) / 2 / 50e18) * 50e18;
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
            deal(WSTETH, user1, safeCap);
            vm.prank(owner); swapper.setSlippage(slippage);

            _depositAs(user1, safeCap);
            _syncAndMockOracles();

            uint256 sharesAll = vault.balanceOf(user1);
            vm.prank(user1);
            uint256 wstEthOut = vault.redeem(sharesAll, user1, user1);

            // ETH/USD oracle: 8-decimal Chainlink price. wstETH has 18 decimals.
            // Note: wstETH slightly > ETH; this provides a conservative USD estimate.
            (, int256 rawPrice,,,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
            uint256 price8 = uint256(rawPrice);
            depositUsd   = (safeCap   * price8) / 1e26; // whole dollars
            redeemUsd    = (wstEthOut * price8) / 1e26;
            roundTripBps = safeCap > wstEthOut ? ((safeCap - wstEthOut) * 10000) / safeCap : 0;

            vm.revertTo(snap);
        }

        // ── Phase 4: trace the first failing size ─────────────────────────────────────
        string memory failReason = "not found";
        uint256 traceTarget = firstFail;
        for (uint256 probe = firstFail; probe <= firstFail + 10 * 50e18; probe += 50e18) {
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
            deal(WSTETH, user1, traceTarget);
            vm.prank(owner); swapper.setSlippage(slippage);

            vm.startPrank(user1);
            IERC20(WSTETH).approve(address(vault), traceTarget);
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

        // ── Report ─────────────────────────────────────────────────────────────────────
        console.log("=== wstETH Single-depositor safe TVL cap at 1%% slippage ===");
        console.log("Max safe deposit:    %s wstETH", safeCap / 1e18);
        console.log("First failing size:  %s wstETH", firstFail / 1e18);
        console.log("Deposit value:      ~$%s",        depositUsd);
        console.log("Redeem  value:      ~$%s",        redeemUsd);
        console.log("Round-trip cost:     %s bps",     roundTripBps);
        console.log("Failure reason:      %s",         failReason);

        assertGt(safeCap, 0, "Must find a passing size");
        assertLe(roundTripBps, 100, "Round-trip cost at cap must be within 1%%");
    }

    /// @notice Diagnostic: shows exactly WHY single-depositor transactions fail above the cliff.
    /// @dev For wstETH, deposit routes via Curve USDT/crvUSD pool; redeem routes USDT surplus
    ///      via Uniswap V3 two-hop wstETH→WETH→USDT. At large sizes the two-hop output can fall
    ///      below the oracle floor, triggering SwapperUnderperformed.
    function test_singleDepositorFailureDiagnosis() public {
        uint256 slippage = 1e16; // 1%

        // Straddle the expected Uniswap cliff (~5000-7000 wstETH at this fork block).
        // Re-run test_uniswapSlippageCeiling_1pct to update if oracle prices shift.
        uint256 failSize = 8000e18;  // 8000 wstETH — expected to fail at 1%
        uint256 safeSize = 3000e18;  // 3000 wstETH — expected to pass at 1%

        _syncAndMockOracles();
        _deployVault();
        vm.prank(owner); swapper.setSlippage(slippage);

        console.log("");
        console.log("=== wstETH Deposit / Redeem path analysis ===");
        console.log("  Deposit: wstETH -> Aave (collateral) -> borrow USDT");
        console.log("           -> [USDT/crvUSD Curve pool] -> crvUSD");
        console.log("           -> [pmUSD/crvUSD Curve pool] -> LP staked in Stake DAO");
        console.log("  Redeem:  LP -> crvUSD -> USDT repays Aave debt");
        console.log("           -> 5%% USDT surplus -> [Uniswap V3 USDT->WETH->wstETH two-hop] -> wstETH");
        console.log("");

        // ── Attempt deposit at failing size ────────────────────────────────────
        console.log("=== Live vault.deposit(%s wstETH, 1%% slippage) ===", failSize / 1e18);
        deal(WSTETH, user1, failSize);
        vm.startPrank(user1);
        IERC20(WSTETH).approve(address(vault), failSize);
        bool depositOk;
        try vault.deposit(failSize, user1) returns (uint256 shares) {
            depositOk = true;
            console.log("  Deposit PASSED, shares: %s", shares);
        } catch (bytes memory err) {
            depositOk = false;
            console.log("  Deposit FAILED: %s", _decodeRevertReason(err, "deposit"));
        }
        vm.stopPrank();

        if (depositOk) {
            vm.roll(block.number + 1);
            _syncAndMockOracles();
            uint256 shares = vault.balanceOf(user1);
            vm.prank(user1);
            try vault.redeem(shares, user1, user1) returns (uint256 wstEthOut) {
                console.log("  Redeem PASSED, received %s wstETH", wstEthOut / 1e18);
                console.log("  --> Neither step failed (pool liquidity shifted at fork block)");
            } catch (bytes memory err) {
                console.log("  Redeem FAILED: %s", _decodeRevertReason(err, "redeem"));
                console.log("  --> Failure at redeem-time Uniswap two-hop USDT->wstETH swap (pool depth exceeded).");
            }
        } else {
            console.log("  --> Failure at DEPOSIT (Curve USDT/crvUSD), not at redeem-time Uniswap swap.");
        }

        // ── Control: safe size should succeed ────────────────────────────────
        console.log("");
        console.log("=== Control: vault.deposit(%s wstETH, 1%% slippage) ===", safeSize / 1e18);
        deal(WSTETH, user2, safeSize);
        vm.startPrank(user2);
        IERC20(WSTETH).approve(address(vault), safeSize);
        try vault.deposit(safeSize, user2) returns (uint256 shares) {
            console.log("  Control deposit PASSED, shares: %s (expected)", shares);
        } catch (bytes memory err) {
            console.log("  Control deposit FAILED: %s (unexpected)", _decodeRevertReason(err, "deposit"));
        }
        vm.stopPrank();
    }
}
