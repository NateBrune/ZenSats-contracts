// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { LlamaSecurityTestMixin } from "./base/LlamaSecurityTestMixin.sol";
import { ZenjiWbtcLlamaStakeDao } from "../src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { PmUsdCrvUsdStakeDaoStrategy } from "../src/strategies/lp/PmUsdCrvUsdStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title WbtcCrvUsdPmUsdLlama
/// @notice Fork tests for WBTC + crvUSD + pmUSD/crvUSD (Stake DAO) strategy on LlamaLend
///         Swap route: WBTC -> WETH via Uniswap V3 (0.05%) -> crvUSD via Curve TriCRV
contract WbtcCrvUsdPmUsdLlama is LlamaSecurityTestMixin {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;

    // Curve TwoCrypto WBTC/crvUSD pool — passed to LlamaLoanManager as collateralDebtPool
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;

    // Uniswap V3 WBTC/WETH pool (0.05% fee) + Curve TriCRV (WETH <-> crvUSD)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500; // 0.05%
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniswapMixedCurveSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    PmUsdCrvUsdStakeDaoStrategy public strategy;
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
        // 2 WBTC per user (4 WBTC combined) stays well within Uniswap V3 pool depth at 1% slippage.
        // 5 WBTC per user can hit V3TooLittleReceived at certain pool conditions.
        return 2e8;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    function _sequentialWithdrawalSlippage() internal pure returns (uint256) { return 3e16; }

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

    function setUp() public override {
        super.setUp();
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

        strategy = new PmUsdCrvUsdStakeDaoStrategy(
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

        ZenjiWbtcLlamaStakeDao vault_ = new ZenjiWbtcLlamaStakeDao(
            address(llamaManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(vault_) == expectedVaultAddress, "Vault address mismatch");

        llamaManager.initializeVault(address(vault_));
        strategy.initializeVault(address(vault_));

        vm.prank(owner);
        swapper.setVault(address(vault_));

        // Cast LlamaLoanManager to AaveLoanManager for the base-class field.
        // Both implement ILoanManager so all shared selectors (loanExists, getCurrentLTV, ...)
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

    /// @notice When the BTC oracle price is 2x the real price, LlamaLoanManager's 95%
    ///         post-swap output check (SwapperUnderperformed) blocks redemption because
    ///         the oracle-derived expectation cannot be met by the actual swap output.
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        _deployVault();
        _depositAs(user1, 10e8);

        _refreshOracles();

        // Mock BTC oracle at 2x -- oracle expects 2x WBTC out; real swap output stays at real price
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

        uint256 firstPass = 0;
        uint256 depositAmt = 10e8; // 10 WBTC

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
        assertTrue(firstPass > 0 && firstPass <= 2e16, "Full redeem should succeed within 2% slippage on UniV3+TriCRV");
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
    function _tvlChunk() internal pure returns (uint256) { return 5e8; }
    function _tvlMinChunk() internal pure returns (uint256) { return 1e7; }
    function _tvlIterCap() internal pure returns (uint256) { return 160; }
    function _requireTvlSetup() internal {}
    function _tvlLabel() internal pure returns (string memory) { return "WBTC multi-user TVL(crvUSD 18d)="; }

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
        // Two-hop route (WBTC→WETH→crvUSD via Uniswap V3 + Curve TriCrypto) accumulates ~1.17% in
        // fees + oracle/market spread. The residual crvUSD profit swap (LP returns more than borrowed)
        // uses the oracle floor — 5% covers Chainlink/V3 price divergence across mainnet blocks.
        vm.prank(owner);
        swapper.setSlippage(5e16);

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

        // Drop crvUSD price 5% -- preserves BTC/crvUSD ratio so the swapper floor stays in range
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

    /// @notice Deposit 10 BTC (~$1M at $100k/BTC) and fully redeem.
    function test_oneMillion_depositAndRedeem() public {
        // 10 BTC ≈ $1M at $100k/BTC
        uint256 depositAmount = 10e8; // 10 BTC in satoshis
        bool passed = _runSlippageScenario(2e16, depositAmount);
        assertTrue(passed, "10 BTC (~$1M) full redeem should succeed at 2% slippage");
        console.log("$1M test: 10 BTC deposit+redeem at 2%% slippage passed");
    }

    // ============ Dust / Minimum Deposit Tests ============

    /// @notice Verifies that a ~1e5 sat dust deposit can be fully redeemed.
    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        // This is equivalent to ~$100 USD at $100k/BTC
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

        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);

        console.log("Dust redemption succeeded.");
    }

    /// @notice Trace every number through the full deposit->redeem path for a tiny (~$10) deposit.
    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        // Exact minimum deposit: 1e4 sat at 1e8 precision = 0.0001 WBTC ~ $10
        uint256 dustAmount = 1e4;
        deal(WBTC, user1, dustAmount);

        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (sat):           ", dustAmount);
        console.log("sharesMinted:               ", sharesMinted);
        console.log("LlamaLend collateral (sat): ", posCollateral);
        console.log("LlamaLend debt (crvUSD e18):", posDebt);
        console.log("Strategy bal (crvUSD e18):  ", stratBal);
        console.log("Vault idle WBTC (sat):      ", IERC20(WBTC).balanceOf(address(vault)));
        console.log("Vault idle crvUSD (e18):    ", IERC20(CRVUSD).balanceOf(address(vault)));

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        uint256 collateralNeeded = vault.previewRedeem(sharesMinted);
        console.log("=== Projected unwind ===");
        console.log("collateralNeeded (sat):", collateralNeeded);
        if (posCollateral > 0) {
            uint256 debtToRepay = posDebt * collateralNeeded / posCollateral;
            console.log("debtToRepay (crvUSD e18): ", debtToRepay);
            console.log("debtNeeded 105%% (e18):    ", debtToRepay * 105 / 100);
        }
        console.log("maxSlippage (bps):     ", vault.maxSlippage() / 1e14);
        console.log("swapper slippage (bps):", swapper.slippage() / 1e14);

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
                } else if (selector == bytes4(keccak256("ExchangeFailed()"))) {
                    console.log("=> ExchangeFailed: Curve output below oracle floor");
                } else {
                    console.log("=> Unknown selector (check loanManager / strategy / LP errors)");
                }
            }
        }
    }

    /// @notice Show realistic minimum deposit that avoids dust redemption failures.
    ///         Economic minimum for WBTC is ~1e6 sat (0.01 BTC, ~$1000) to cover swap fees.
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
                assertGt(collateralReceived, 0, "Realistic deposit should redeem non-zero collateral");
                console.log("User redeemed shares for sat");
                console.log(i);
                console.log(shares);
                console.log(collateralReceived);
            }
        }
    }

    /// @notice Document the vault's economic minimum for WBTC (LlamaLend/Curve path).
    function test_documentEconomicMinimum() public pure {
        uint256 contractMinimum = 1e4;
        uint256 virtualOffset = 1e5;
        uint256 economicMinimum = 1e5; // 0.001 WBTC = 1e5 sat

        console.log("Contract MIN_DEPOSIT:  %d sat", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d sat", virtualOffset);
        console.log("Economic minimum:      %d sat", economicMinimum);
        console.log("Why dust fails on mainnet (WBTC LlamaLend/Curve path):");
        console.log("1. Deposit of tiny sat passes MIN_DEPOSIT check");
        console.log("2. Very few shares created due to low VIRTUAL_SHARE_OFFSET");
        console.log("3. Redeem triggers proportional flash-loan unwind");
        console.log("4. Curve WBTC->crvUSD output below oracle floor at tiny sizes");
        console.log("5. Oracle floor (1%% tolerance) > tiny Curve output at micro sizes");
        console.log("6. Vault reverts: ExchangeFailed or SwapperUnderperformed");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 1e4;
        deal(WBTC, user1, depositAmount);
        vm.prank(user1); IERC20(WBTC).approve(address(vault), depositAmount);
        vm.prank(user1); vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_sat=%d debt_crvusd18=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    /// @notice Sweeps swapper slippage levels (1%-20%) to identify the minimum tolerance
    ///         needed to redeem a 1e4 sat deposit and prints the exact revert selector.
    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 1e4; // exact minimum deposit: 10000 sat = 0.0001 WBTC

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;  //  1%%
        slippageLevels[1] = 2e16;  //  2%%
        slippageLevels[2] = 3e16;  //  3%%
        slippageLevels[3] = 5e16;  //  5%%
        slippageLevels[4] = 10e16; // 10%%
        slippageLevels[5] = 20e16; // 20%%

        uint256 firstSuccess = 0;

        console.log("=== WBTC Slippage Sweep for 1e4 sat deposit (LlamaLend/Curve) ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();

            _deployVault();

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
                } else if (selector == bytes4(keccak256("HealthTooLow()"))) {
                    console.log("  => HealthTooLow (LlamaLend health < min)");
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

        console.log("WBTC LlamaLend firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14);
    }

    // ============ TVL Ceiling Tests ============

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


    /// @notice Determines the current single-depositor TVL cap at 1% swapper slippage.
    ///         Coarse sweep locates the cliff, binary search narrows to 1-WBTC resolution,
    ///         then measures the actual round-trip bps cost and USD value at the cap.
    ///         Replaces the former slippage sweep, liquidity sweep, ceiling, and cap tests.
    function test_capacityReport() public {
        uint256 slippage = 1e16; // 1%

        // ── Stage 1: coarse sweep to locate the cliff bracket ───────────────────────
        uint256[14] memory probe = [
            uint256(1e8), 5e8, 10e8, 25e8, 50e8, 75e8,
            100e8, 125e8, 150e8, 175e8, 200e8, 250e8, 300e8, 500e8
        ];
        uint256 lo = 0;
        uint256 hi = 0;
        console.log("=== WBTC capacity sweep at 1%% slippage ===");
        for (uint256 i = 0; i < probe.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe[i]) returns (bool ok) { passed = ok; } catch {}
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
            deal(WBTC, user1, safeCap);
            vm.prank(owner); swapper.setSlippage(slippage);
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

    /// @notice Sweep deposit size at a fixed 1% slippage to find the largest size that exits.
    ///         Complements test_slippageSweep_bySlippage (which fixes size, varies slippage).
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
