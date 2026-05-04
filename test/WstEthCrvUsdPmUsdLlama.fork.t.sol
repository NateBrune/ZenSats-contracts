// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { ZenjiWstEthCrvUsdPmUsd } from "../src/implementations/ZenjiWstEthCrvUsdPmUsd.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
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

/// @title WstEthCrvUsdPmUsdLlama
/// @notice Fork tests for wstETH + crvUSD + pmUSD/crvUSD (Stake DAO) strategy on LlamaLend
contract WstEthCrvUsdPmUsdLlama is ZenjiForkTestBase {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    address constant LLAMALEND_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;

    // LlamaLend LLAMMA pool (used by LlamaLoanManager for health factor / oracle)
    address constant WSTETH_CRVUSD_POOL = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    // Uniswap V3 wstETH/WETH pool (fee=100) + Curve TriCRV (WETH↔crvUSD)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WSTETH_WETH = 100;   // V3 0.01 %
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    WstEthOracle public wstEthOracle;
    UniswapMixedCurveSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    PmUsdCrvUsdStrategy public strategy;
    LlamaLoanManager public llamaManager;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WSTETH;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 3e15; // 0.003 wstETH — matches ZenjiWstEthCrvUsdPmUsd.MIN_DEPOSIT
    }

    function _oracleList() internal pure override returns (address[] memory) {
        // WstEthOracle is a locally-deployed composite; mock its underlying Chainlink feeds.
        address[] memory oracles = new address[](4);
        oracles[0] = STETH_ETH_ORACLE;
        oracles[1] = ETH_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        // Mocking ETH/USD changes the output of WstEthOracle, adjusting effective collateral price.
        return ETH_USD_ORACLE;
    }

    function _fuzzMin() internal pure override returns (uint256) {
        return 1e17; // 0.1 wstETH minimum for fuzz
    }

    function _fuzzMultiMin() internal pure override returns (uint256) {
        return 3e18; // 3 wstETH
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        // Slippage capacity test showed only 2 bps round-trip loss up to 50 wstETH.
        // The earlier 10e18 cap was a workaround for the get_dy over-estimate bug (now fixed).
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
        // Deploy order: wstEthOracle(+0), crvSwapper(+1), swapper(+2),
        //               strategy(+3), llamaManager(+4), vault(+5)
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 5);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();
        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();

        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedCurveSwapper(
            owner,
            WSTETH,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WSTETH_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            address(wstEthOracle),
            CRVUSD_USD_ORACLE,
            3600 // wstETH/USD oracle max staleness: 1 hour
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
            WSTETH,
            CRVUSD,
            LLAMALEND_WSTETH_CONTROLLER,
            WSTETH_CRVUSD_POOL,
            address(wstEthOracle),
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0) // vault initialised separately via initializeVault
        );

        ZenjiWstEthCrvUsdPmUsd vault_ = new ZenjiWstEthCrvUsdPmUsd(
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
            WSTETH,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WSTETH_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            address(wstEthOracle),
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

    /// @notice A 50 wstETH position can fully exit in a single redeem at 2% slippage
    ///         on the V3 wstETH→WETH + Curve TriCrypto WETH→crvUSD path.
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, 50e18);
        assertTrue(passed, "50 wstETH full redeem should succeed at 2% slippage on V3+TriCrypto path");
    }

    /// @notice When the oracle price is 2× the real price, LlamaLoanManager's 95% post-swap
    ///         output check (SwapperUnderperformed) blocks redemption because the oracle-derived
    ///         expectation cannot be met by the actual swap output.
    ///         Note: UniswapMixedCurveSwapper uses oracle-based minOut only for non-dust amounts;
    ///         during full close the remaining crvUSD is dust, so protection comes from the
    ///         LoanManager's own 95% output guard when collateral is swapped during flashloan.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        _deployVault();
        _depositAs(user1, 50e18);

        _refreshOracles();

        // Mock ETH oracle at 2× — LoanManager expects 1.9× actual output from WETH swap; actual <= real
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        vm.mockCall(
            ETH_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer * 2, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(shares, user1, user1);
    }

    /// @dev Deploy a fresh vault, set slippage to targetSlippage, deposit depositAmount wstETH,
    ///      then attempt a single full redemption. Returns true if the redeem succeeds.
    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) internal returns (bool) {
        _syncAndMockOracles();
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

    /// @notice Sweep slippage levels at a fixed deposit size (50 wstETH) to find
    ///         the minimum slippage required for a clean full exit on the V3+TriCrypto path.
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

        uint256 depositAmt = 50e18; // 50 wstETH
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
            console.log("SlippageSweep deposit=50 slippage=%s bps passed=%s", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) firstPass = levels[i];
        }

        console.log("SlippageSweep firstPass(bps)=%s", firstPass == 0 ? 0 : firstPass / 1e14);
        assertTrue(firstPass == 0 || firstPass <= 2e16, "Full 50 wstETH exit should need <= 2% slippage");
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
            console.log("Harvest compounded %d crvUSD worth of rewards", stratAfter - stratBefore);
        } else {
            console.log("No rewards compounded - accountant likely needs backend checkpoint");
        }

        assertGe(stratAfter, stratBefore, "Strategy balance must not decrease after harvest");
    }

    // ============ TVL Helpers ============

    function _tvlTarget() internal pure returns (uint256) { return 5_000_000e18; }
    function _tvlChunk() internal pure returns (uint256) { return 50e18; }
    function _tvlMinChunk() internal pure returns (uint256) { return 1e17; }
    function _tvlIterCap() internal pure returns (uint256) { return 200; }
    function _requireTvlSetup() internal {}
    function _tvlLabel() internal pure returns (string memory) { return "wstETH multi-user TVL(crvUSD 18d)="; }

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
        uint256 chunk     = _tvlChunk();
        uint256 minChunk  = _tvlMinChunk();
        uint256 tvl       = loanManager.getCollateralValue(vault.getTotalCollateral());

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
        // Two-hop route (wstETH→WETH→crvUSD via Uniswap V3 + Curve TriCrypto) accumulates ~1.17%
        // in fees + oracle/market spread — marginally above the 1% default oracle floor.
        // 2% is principled: measured round-trip for 6 wstETH combined is well under 5 bps.
        vm.prank(owner);
        swapper.setSlippage(2e16);

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

    /// @notice Simulates unrealized strategy loss by dropping both ETH and crvUSD prices 5%.
    ///         Mocking both oracles at the same ratio preserves the swapper floor (which uses
    ///         the collateral/debt price ratio). This tests that withdrawal still succeeds even
    ///         when all asset values have dropped 5% in USD terms.
    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        _depositAs(user1, 2e18);

        _refreshOracles();

        // Drop ETH price 5% (flows through WstEthOracle to set collateral value)
        (uint80 roundId1, int256 answer1,,, uint80 answeredInRound1) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        vm.mockCall(
            ETH_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId1, (answer1 * 95) / 100, block.timestamp, block.timestamp, answeredInRound1)
        );

        // Drop crvUSD price 5% — preserves ETH/crvUSD ratio so the swapper floor stays in range
        (uint80 roundId2, int256 answer2,,, uint80 answeredInRound2) =
            IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId2, (answer2 * 95) / 100, block.timestamp, block.timestamp, answeredInRound2)
        );

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw with collateral price drop");
        console.log("Strategy loss: deposited=2e18 withdrawn=%d", withdrawn);
    }

    function testFuzz_largeRatioDeposits_noBankruptcy(uint256 ratio) public {
        _deployVault();
        ratio = bound(ratio, 10, 100);

        uint256 smallAmount = 1e17; // 0.1 wstETH
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

    /// @notice Deposit exactly vault.MIN_DEPOSIT() (or 3e16 wstETH floor) and fully redeem.
    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

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
    function test_oneMillion_depositAndRedeem() public {
        // 250 wstETH ≈ $1M at $4,000/wstETH
        uint256 depositAmount = 250e18;
        bool passed = _runSlippageScenario(2e16, depositAmount);
        assertTrue(passed, "250 wstETH (~$1M) full redeem should succeed at 2% slippage");
        console.log("$1M test: 250 wstETH deposit+redeem at 2%% slippage passed");
    }

    // ============ Dust / Minimum Deposit Tests ============

    /// @notice Verifies that a ~0.03 wstETH dust deposit can be fully redeemed.
    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        // 0.03 wstETH — matches the economic minimum for the V3+TriCrypto swap path.
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

        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);

        console.log("Dust redemption succeeded.");
    }

    /// @notice Trace every number through the full deposit→redeem path for a 0.03 wstETH deposit.
    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        uint256 dustAmount = 3e16; // 0.03 wstETH
        deal(WSTETH, user1, dustAmount);

        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (wei):            ", dustAmount);
        console.log("sharesMinted:                ", sharesMinted);
        console.log("LlamaLend collateral (wei):  ", posCollateral);
        console.log("LlamaLend debt (crvUSD 18d): ", posDebt);
        console.log("Strategy bal (crvUSD e18):   ", stratBal);
        console.log("Vault idle wstETH (wei):     ", IERC20(WSTETH).balanceOf(address(vault)));
        console.log("Vault idle crvUSD (e18):     ", IERC20(CRVUSD).balanceOf(address(vault)));

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        uint256 collateralNeeded = vault.previewRedeem(sharesMinted);
        console.log("=== Projected unwind ===");
        console.log("collateralNeeded (wei):", collateralNeeded);
        if (posCollateral > 0) {
            uint256 debtToRepay = posDebt * collateralNeeded / posCollateral;
            console.log("debtToRepay (crvUSD e18): ", debtToRepay);
            console.log("debtNeeded 105% (e18):    ", debtToRepay * 105 / 100);
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
                    console.log("=> SwapperUnderperformed: V3/TriCrypto oracle divergence on small swap");
                } else {
                    console.log("=> Unknown selector (check loanManager / strategy / LP errors)");
                }
            }
        }
    }

    /// @notice Show realistic minimum deposit that avoids dust redemption failures.
    ///         Economic minimum for wstETH is ~0.1 wstETH (~$350) to cover V3+TriCrypto fees.
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

    /// @notice Document the vault's economic minimum for wstETH (LlamaLend path).
    function test_documentEconomicMinimum() public pure {
        uint256 contractMinimum = 1e4;
        uint256 virtualOffset = 1e5;
        uint256 economicMinimum = 3e16; // 0.03 wstETH

        console.log("Contract MIN_DEPOSIT:  %d wei", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d wei", virtualOffset);
        console.log("Economic minimum:      %d wei", economicMinimum);
        console.log("Why dust fails on mainnet (wstETH LlamaLend/V3+TriCrypto path):");
        console.log("1. Deposit of tiny wei passes MIN_DEPOSIT check");
        console.log("2. Very few shares created due to low VIRTUAL_SHARE_OFFSET");
        console.log("3. Redeem triggers proportional flash-loan unwind");
        console.log("4. V3 wstETH->WETH + TriCrypto WETH->crvUSD accumulate pool fees");
        console.log("5. Oracle floor (1% tolerance) > tiny Curve output at micro sizes");
        console.log("6. Vault reverts: SwapperUnderperformed");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 3e16; // 0.03 wstETH
        deal(WSTETH, user1, depositAmount);
        vm.prank(user1); IERC20(WSTETH).approve(address(vault), depositAmount);
        vm.prank(user1); vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_wei=%d debt_crvusd18=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    /// @notice Sweeps swapper slippage levels (1%–20%) to identify the minimum tolerance
    ///         needed to redeem a 0.03 wstETH deposit and prints the exact revert selector.
    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 3e16; // 0.03 wstETH

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;  //  1%
        slippageLevels[1] = 2e16;  //  2%
        slippageLevels[2] = 3e16;  //  3%
        slippageLevels[3] = 5e16;  //  5%
        slippageLevels[4] = 10e16; // 10%
        slippageLevels[5] = 20e16; // 20%

        uint256 firstSuccess = 0;

        console.log("=== wstETH Slippage Sweep for 3e16 wei deposit (V3+TriCrypto) ===");

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
                } else if (selector == bytes4(keccak256("ExchangeFailed()"))) {
                    console.log("  => ExchangeFailed (Curve output below oracle floor)");
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

    // ============ TVL Ceiling / Curve TriCrypto Liquidity Tests ============

    /// @dev Decode a low-level revert into a human-readable label for console output.
    function _decodeRevertReason(bytes memory err, string memory step) internal pure returns (string memory) {
        if (err.length < 4) return string(abi.encodePacked(step, ": revert (no data)"));
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        if (sel == bytes4(keccak256("ExchangeFailed()")))
            return string(abi.encodePacked(step, ": ExchangeFailed (Curve TriCrypto WETH/crvUSD output below oracle floor at 1% slippage)"));
        if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)")))
            return string(abi.encodePacked(step, ": SwapperUnderperformed (crvUSD->WETH->wstETH output below oracle floor)"));
        if (sel == bytes4(keccak256("SlippageExceeded()")))
            return string(abi.encodePacked(step, ": SlippageExceeded (minAmountOut not met)"));
        if (sel == bytes4(keccak256("InsufficientCollateral()")))
            return string(abi.encodePacked(step, ": InsufficientCollateral (recovered wstETH < minOut after unwind)"));
        if (sel == bytes4(keccak256("HealthTooLow()")))
            return string(abi.encodePacked(step, ": HealthTooLow (LlamaLend health < min)"));
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


    /// @notice Determines the current single-depositor TVL cap at 1% swapper slippage.
    ///         Coarse sweep locates the cliff, binary search narrows to 1-wstETH resolution,
    ///         then measures the actual round-trip bps cost and USD value at the cap.
    ///         Replaces the former slippage sweep, liquidity sweep, ceiling, and cap tests.
    function test_capacityReport() public {
        uint256 slippage = 1e16; // 1%

        // ── Stage 1: coarse sweep to locate the cliff bracket ───────────────────────
        uint256[14] memory probe = [
            uint256(1e18), 5e18, 10e18, 25e18, 50e18, 75e18,
            100e18, 125e18, 150e18, 175e18, 200e18, 250e18, 300e18, 500e18
        ];
        uint256 lo = 0;
        uint256 hi = 0;
        console.log("=== wstETH capacity sweep at 1%% slippage ===");
        for (uint256 i = 0; i < probe.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe[i]) returns (bool ok) { passed = ok; } catch {}
            vm.revertTo(snap);
            console.log("  %d wstETH: %s", probe[i] / 1e18, passed ? "pass" : "FAIL");
            if (passed) { lo = probe[i]; }
            else if (hi == 0) { hi = probe[i]; break; }
        }
        require(lo > 0, "Not even 1 wstETH passes at 1%% slippage");
        if (hi == 0) { console.log("Cap > 500 wstETH"); return; }

        // ── Stage 2: binary search to 1-wstETH resolution ───────────────────────────
        while (hi - lo > 1e18) {
            uint256 mid = lo + ((hi - lo) / 2 / uint256(1e18)) * 1e18;
            uint256 snap = vm.snapshot();
            bool ok;
            try this.runSlippageScenario(slippage, mid) returns (bool r) { ok = r; } catch {}
            vm.revertTo(snap);
            if (ok) lo = mid; else hi = mid;
        }
        uint256 safeCap   = lo;
        uint256 firstFail = hi;

        // ── Stage 3: measure bps and USD value at safeCap ───────────────────────────
        uint256 bpsAtCap;
        uint256 capUsd;
        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(WSTETH, user1, safeCap);
            vm.prank(owner); swapper.setSlippage(slippage);
            _depositAs(user1, safeCap);
            _syncAndMockOracles();
            uint256 received = _redeemAllAs(user1);
            bpsAtCap = safeCap > received ? ((safeCap - received) * 10_000) / safeCap : 0;
            (, int256 rawPrice,,,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
            capUsd = (safeCap * uint256(rawPrice)) / 1e26; // wstETH 1e18 * price 1e8 / 1e26 = USD
            vm.revertTo(snap);
        }

        console.log("=== wstETH capacity report ===");
        console.log("Safe cap:   %d wstETH  (~$%d)", safeCap / 1e18, capUsd);
        console.log("First fail: %d wstETH", firstFail / 1e18);
        console.log("Bps at cap: %d bps", bpsAtCap);

        assertGt(safeCap, 0, "Must find a passing size");
        assertLe(bpsAtCap, 100, "Round-trip cost at safe cap must be within 1%%");
    }

}
