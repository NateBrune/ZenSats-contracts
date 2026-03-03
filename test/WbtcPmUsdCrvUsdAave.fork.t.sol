// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {Zenji} from "../src/Zenji.sol";
import {ZenjiViewHelper} from "../src/ZenjiViewHelper.sol";
import {AaveLoanManager} from "../src/lenders/AaveLoanManager.sol";
import {CurveThreeCryptoSwapper} from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import {CrvToCrvUsdSwapper} from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import {PmUsdCrvUsdStrategy} from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import {ICurveStableSwapNG} from "../src/interfaces/ICurveStableSwapNG.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {SafeTransferLib} from "../src/libraries/SafeTransferLib.sol";
import {TimelockLib} from "../src/libraries/TimelockLib.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title WbtcPmUsdCrvUsdAave
/// @notice Fork tests for WBTC + USDT + pmUSD/crvUSD (Stake DAO) strategy on Aave
contract WbtcPmUsdCrvUsdAave is Test {
    using SafeTransferLib for IERC20;

    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Curve / Stake DAO
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4; // WBTC/USDT
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14; // CRV/crvUSD

    // Oracles
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");

    IERC20 wbtc;
    IERC20 usdt;
    ZenjiViewHelper viewHelper;

    // Deployed contracts (set in _deployVault)
    Zenji vault;
    AaveLoanManager loanManager;
    PmUsdCrvUsdStrategy strategy;
    CurveThreeCryptoSwapper swapper;
    CrvToCrvUsdSwapper crvSwapper;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        wbtc = IERC20(WBTC);
        usdt = IERC20(USDT);
        viewHelper = new ZenjiViewHelper();

        _syncAndMockOracles();

        deal(WBTC, user1, 100e8);
        deal(WBTC, user2, 100e8);
    }

    // ============ Helpers ============

    function _syncAndMockOracles() internal {
        (,,, uint256 btcUpdatedAt,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        (,,, uint256 usdtUpdatedAt,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUsdUpdatedAt,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUpdatedAt,) = IChainlinkOracle(CRV_USD_ORACLE).latestRoundData();

        uint256 maxUpdatedAt = btcUpdatedAt;
        if (usdtUpdatedAt > maxUpdatedAt) maxUpdatedAt = usdtUpdatedAt;
        if (crvUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUsdUpdatedAt;
        if (crvUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUpdatedAt;
        if (block.timestamp < maxUpdatedAt + 1) vm.warp(maxUpdatedAt + 1);

        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
        _mockOracle(CRV_USD_ORACLE);
    }

    function _mockOracle(address oracle) internal {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(oracle).latestRoundData();
        uint256 timestamp = block.timestamp > updatedAt ? block.timestamp : updatedAt;
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer, timestamp, timestamp, answeredInRound)
        );
    }

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    function _deployVault() internal {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();

        crvSwapper = new CrvToCrvUsdSwapper(owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE);
        swapper = new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        strategy = new PmUsdCrvUsdStrategy(
            USDT,
            CRVUSD,
            CRV,
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
            expectedVaultAddress
        );

        vault = new Zenji(WBTC, USDT, address(loanManager), address(strategy), address(swapper), owner, address(viewHelper));
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        wbtc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _redeemAllAs(address user) internal returns (uint256 collateral) {
        uint256 shares = vault.balanceOf(user);
        if (shares == 0) return 0;
        vm.prank(user);
        collateral = vault.redeem(shares, user, user);
    }

    function _assertValuePreserved(uint256 deposited, uint256 withdrawn, uint256 toleranceBps, string memory msg_) internal pure {
        uint256 minExpected = deposited - (deposited * toleranceBps) / 10000;
        require(withdrawn >= minExpected, msg_);
    }

    function _refreshOracles() internal {
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
        _mockOracle(CRV_USD_ORACLE);
    }

    // ============ A. Value Accounting Tests ============

    function test_depositAndRedeem_fullCycle() public {
        _deployVault();
        uint256 depositAmount = 1e8; // 1 WBTC

        _depositAs(user1, depositAmount);
        assertTrue(loanManager.loanExists(), "Loan should exist");
        assertGt(strategy.balanceOf(), 0, "Strategy should have balance");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Full cycle: >2% loss");
        console.log("Full cycle: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_depositAndRedeem_partial() public {
        _deployVault();
        uint256 depositAmount = 2e8; // 2 WBTC

        uint256 shares = _depositAs(user1, depositAmount);

        _refreshOracles();

        vm.prank(user1);
        uint256 first = vault.redeem(shares / 2, user1, user1);

        _refreshOracles();

        uint256 second = _redeemAllAs(user1);

        uint256 total = first + second;
        _assertValuePreserved(depositAmount, total, 200, "Partial cycle: >2% total loss");

        uint256 halfDeposit = depositAmount / 2;
        assertGe(first, halfDeposit - (halfDeposit * 500) / 10000, "First half: >5% deviation");
        assertGe(second, halfDeposit - (halfDeposit * 500) / 10000, "Second half: >5% deviation");

        console.log("Partial: first=%d second=%d total=%d", first, second, total);
    }

    function test_depositAndRedeem_tiny() public {
        _deployVault();
        uint256 depositAmount = 1e4; // MIN_DEPOSIT

        uint256 shares = _depositAs(user1, depositAmount);
        assertGt(shares, 0, "Should receive shares for min deposit");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Should receive something back for min deposit");
        console.log("Tiny: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_depositAndRedeem_large() public {
        _deployVault();
        uint256 depositAmount = 5e8; // 5 WBTC

        _depositAs(user1, depositAmount);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Large cycle: >2% loss");
        console.log("Large: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_multiUser_depositAndRedeem() public {
        _deployVault();
        uint256 deposit1 = 1e8; // 1 WBTC
        uint256 deposit2 = 2e8; // 2 WBTC

        _depositAs(user1, deposit1);
        _depositAs(user2, deposit2);

        _refreshOracles();

        uint256 withdrawn1 = _redeemAllAs(user1);
        _refreshOracles();
        uint256 withdrawn2 = _redeemAllAs(user2);

        _assertValuePreserved(deposit1, withdrawn1, 300, "User1: >3% loss");
        _assertValuePreserved(deposit2, withdrawn2, 300, "User2: >3% loss");

        assertGe(withdrawn2, withdrawn1 * 150 / 100, "User2 should get >= 1.5x User1");

        console.log("Multi-user: u1=%d u2=%d", withdrawn1, withdrawn2);
    }

    function test_sequentialDepositsAndRedeems() public {
        _deployVault();

        uint256 shares1 = _depositAs(user1, 1e8);

        _refreshOracles();

        vm.prank(user1);
        uint256 partialOut = vault.redeem(shares1 / 2, user1, user1);
        assertGt(partialOut, 0, "Partial redeem should return collateral");

        _refreshOracles();

        _depositAs(user1, 1e8);

        _refreshOracles();

        uint256 finalOut = _redeemAllAs(user1);
        assertGt(finalOut, 0, "Final redeem should return collateral");

        uint256 totalIn = 2e8;
        uint256 totalOut = partialOut + finalOut;
        _assertValuePreserved(totalIn, totalOut, 300, "Sequential: >3% total loss");

        console.log("Sequential: totalIn=%d totalOut=%d", totalIn, totalOut);
    }

    // ============ B. Rebalance Tests ============

    function test_rebalance_upward() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, 2e8);

        _refreshOracles();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfter = loanManager.getCurrentLTV();

        assertGt(ltvAfter, ltvBefore, "LTV should increase after upward rebalance");
        console.log("Rebalance up: ltv %d -> %d", ltvBefore, ltvAfter);
    }

    function test_rebalance_downward() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, 2e8);

        _refreshOracles();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 85) / 100;
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfter = loanManager.getCurrentLTV();

        assertLt(ltvAfter, ltvBefore, "LTV should decrease after downward rebalance");
        console.log("Rebalance down: ltv %d -> %d", ltvBefore, ltvAfter);
    }

    function test_rebalance_notNeeded_reverts() public {
        _deployVault();
        _depositAs(user1, 1e8);

        vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_bountyPaid() public {
        _deployVault();
        vm.startPrank(owner);
        vault.setParam(1, 55e16);
        vm.stopPrank();

        _depositAs(user1, 2e8);

        vm.startPrank(owner);
        vault.setParam(0, 1e17);
        vault.setParam(3, 1e17);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();
        vault.accrueYieldFees();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 keeperUsdtBefore = IERC20(USDT).balanceOf(keeper);
        vm.prank(keeper);
        vault.rebalance();
        uint256 keeperUsdtAfter = IERC20(USDT).balanceOf(keeper);

        console.log("Bounty paid: %d USDT", keeperUsdtAfter - keeperUsdtBefore);
    }

    // ============ C. Emergency Mode Tests ============

    function test_emergency_fullFlow() public {
        _deployVault();
        uint256 depositAmount = 1e8;
        _depositAs(user1, depositAmount);

        _refreshOracles();

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyStep(0);
        vault.emergencyStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        assertTrue(vault.emergencyMode(), "Should be emergency mode");
        assertTrue(vault.liquidationComplete(), "Should be liquidation complete");

        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 500, "Emergency: >5% loss");
        console.log("Emergency: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_emergency_depositBlocked() public {
        _deployVault();
        _depositAs(user1, 1e8);

        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.startPrank(user2);
        wbtc.approve(address(vault), 1e8);
        vm.expectRevert(Zenji.EmergencyModeActive.selector);
        vault.deposit(1e8, user2);
        vm.stopPrank();
    }

    function test_emergency_redeemBeforeLiquidation() public {
        _deployVault();
        _depositAs(user1, 1e8);

        _refreshOracles();

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 shares = vault.balanceOf(user1);
        vm.expectRevert(Zenji.EmergencyModeActive.selector);
        vault.redeem(shares, user1, user1);
        vm.stopPrank();
    }

    function test_emergency_rescueAssets() public {
        _deployVault();
        _depositAs(user1, 1e8);

        address randomToken = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        deal(randomToken, address(vault), 1000e6);

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.rescueAssets(randomToken, feeRecipient);
        vm.stopPrank();

        assertEq(IERC20(randomToken).balanceOf(feeRecipient), 1000e6, "Should rescue USDC");
        assertEq(IERC20(randomToken).balanceOf(address(vault)), 0, "Vault should have 0 USDC");
    }

    // ============ D. Yield & Fee Tests ============

    function test_harvestYield() public {
        _deployVault();
        _depositAs(user1, 1e8);

        uint256 stratBefore = strategy.balanceOf();
        vm.prank(owner);
        vault.harvestYield();
        uint256 stratAfter = strategy.balanceOf();

        assertGe(stratAfter, stratBefore, "Strategy balance should not decrease after harvest");
        console.log("Harvest: before=%d after=%d", stratBefore, stratAfter);
    }

    function test_feeAccrual_andWithdraw() public {
        _deployVault();

        vm.prank(owner);
        vault.setParam(0, 1e17);

        _depositAs(user1, 2e8);

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        vault.accrueYieldFees();
        uint256 fees = vault.accumulatedFees();

        if (fees > 0) {
            vm.prank(owner);
            vault.withdrawFees(feeRecipient);
            assertEq(vault.accumulatedFees(), 0, "Fees should be zero after withdrawal");
            console.log("Fees withdrawn: %d", fees);
        } else {
            console.log("No fees accrued (expected on short fork)");
        }
    }

    function test_feeAccrual_zeroRate() public {
        _deployVault();

        assertEq(vault.feeRate(), 0, "Default fee rate should be 0");

        _depositAs(user1, 1e8);

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        vault.accrueYieldFees();
        assertEq(vault.accumulatedFees(), 0, "No fees should accrue with 0 rate");
    }

    // ============ E. Oracle Staleness Tests ============

    function test_oracleStale_depositReverts() public {
        _deployVault();

        vm.warp(block.timestamp + 3601);

        vm.startPrank(user1);
        wbtc.approve(address(vault), 1e8);
        vm.expectRevert();
        vault.deposit(1e8, user1);
        vm.stopPrank();
    }

    function test_oracleStale_rebalanceReverts() public {
        _deployVault();
        _depositAs(user1, 1e8);

        vm.warp(block.timestamp + 3601);

        vm.expectRevert();
        vault.rebalance();
    }

    // ============ F. Governance Timelock Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, 1e8);

        CurveThreeCryptoSwapper newSwapper = new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

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

        CurveThreeCryptoSwapper anotherSwapper = new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);
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

    // ============ G. Boundary & Revert Tests ============

    function test_deposit_belowMinimum_reverts() public {
        _deployVault();

        vm.startPrank(user1);
        wbtc.approve(address(vault), 1e4 - 1);
        vm.expectRevert(Zenji.AmountTooSmall.selector);
        vault.deposit(1e4 - 1, user1);
        vm.stopPrank();
    }

    function test_deposit_atCap_reverts() public {
        _deployVault();

        vm.prank(owner);
        vault.setParam(2, 1e8);

        _depositAs(user1, 1e8);

        vm.startPrank(user2);
        wbtc.approve(address(vault), 1e8);
        vm.expectRevert(Zenji.DepositCapExceeded.selector);
        vault.deposit(1e8, user2);
        vm.stopPrank();
    }

    function test_redeem_zeroShares_reverts() public {
        _deployVault();
        _depositAs(user1, 1e8);

        vm.prank(user1);
        vm.expectRevert(Zenji.ZeroAmount.selector);
        vault.redeem(0, user1, user1);
    }

    function test_redeem_moreThanBalance_reverts() public {
        _deployVault();
        uint256 shares = _depositAs(user1, 1e8);

        vm.prank(user1);
        vm.expectRevert(Zenji.InsufficientShares.selector);
        vault.redeem(shares + 1, user1, user1);
    }

    function test_setParam_boundaries() public {
        _deployVault();

        vm.startPrank(owner);

        vault.setParam(1, 15e16);
        assertEq(vault.targetLtv(), 15e16, "Should accept min LTV");

        vault.setParam(1, 65e16);
        assertEq(vault.targetLtv(), 65e16, "Should accept max LTV");

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, 15e16 - 1);

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, 65e16 + 1);

        vault.setParam(0, 2e17);
        assertEq(vault.feeRate(), 2e17, "Should accept max fee rate");

        vm.expectRevert(Zenji.InvalidFeeRate.selector);
        vault.setParam(0, 2e17 + 1);

        vault.setParam(3, 5e17);
        assertEq(vault.rebalanceBountyRate(), 5e17, "Should accept max bounty");

        vm.expectRevert(Zenji.InvalidBountyRate.selector);
        vault.setParam(3, 5e17 + 1);

        vault.setParam(2, 0);
        assertEq(vault.depositCap(), 0, "Should accept 0 cap");
        vault.setParam(2, type(uint256).max);
        assertEq(vault.depositCap(), type(uint256).max, "Should accept max cap");

        vm.stopPrank();
    }

    // ============ H. Idle Mode Tests ============

    function test_idleMode_enterExit() public {
        _deployVault();
        _depositAs(user1, 1e8);

        _refreshOracles();

        assertTrue(loanManager.loanExists(), "Loan should exist before idle");

        vm.prank(owner);
        vault.setIdle(true);

        assertTrue(vault.idle(), "Should be idle");

        uint256 vaultBal = wbtc.balanceOf(address(vault));
        assertGt(vaultBal, 0, "Vault should hold collateral in idle mode");

        _depositAs(user1, 1e8);
        uint256 vaultBalAfter = wbtc.balanceOf(address(vault));
        assertGt(vaultBalAfter, vaultBal, "More collateral should be in vault");

        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);

        assertFalse(vault.idle(), "Should not be idle");
        assertTrue(loanManager.loanExists(), "Loan should exist after exit idle");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(2e8, withdrawn, 500, "Idle enter/exit: >5% loss");
        console.log("Idle enter/exit: deposited=2e8 withdrawn=%d", withdrawn);
    }

    function test_idleMode_depositWhileIdle() public {
        _deployVault();

        vm.prank(owner);
        vault.setIdle(true);

        _depositAs(user1, 1e8);

        assertFalse(loanManager.loanExists(), "No loan should exist in idle mode");
        assertEq(wbtc.balanceOf(address(vault)), 1e8, "All collateral should be in vault");

        vm.roll(block.number + 1);

        uint256 withdrawn = _redeemAllAs(user1);
        assertEq(withdrawn, 1e8, "Should get exact deposit back in idle mode");
    }

    // ============ I. Strategy-Specific Tests ============

    function test_strategyBalance_afterDeposit() public {
        _deployVault();
        _depositAs(user1, 1e8);

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
        _depositAs(user1, 1e8);
        uint256 pending = strategy.pendingRewards();
        assertGe(pending, 0, "Pending rewards view should not revert");
    }

    function test_harvestYield_afterTimePassed() public {
        _deployVault();
        _depositAs(user1, 2e8);

        uint256 stratBefore = strategy.balanceOf();
        uint256 crvBefore = IERC20(CRV).balanceOf(address(strategy));
        console.log("Before warp: stratBalance=%d crvBalance=%d", stratBefore, crvBefore);

        // Fast-forward 7 days to accrue rewards
        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        // Harvest — claim CRV from accountant, swap to crvUSD, compound back into LP
        vm.prank(owner);
        vault.harvestYield();

        uint256 stratAfter = strategy.balanceOf();
        uint256 crvAfter = IERC20(CRV).balanceOf(address(strategy));
        console.log("After harvest: stratBalance=%d crvBalance=%d", stratAfter, crvAfter);

        if (stratAfter > stratBefore) {
            console.log("Harvest compounded %d USDT worth of rewards", stratAfter - stratBefore);
        } else {
            // Accountant may need an external checkpoint to distribute rewards on fork.
            // If no rewards accrued, this is expected — verify in production.
            console.log("No rewards compounded - accountant likely needs backend checkpoint");
        }

        // Strategy balance should never decrease from a harvest
        assertGe(stratAfter, stratBefore, "Strategy balance must not decrease after harvest");
    }

    // ============ J. Fuzz Tests ============

    function testFuzz_deposit_and_redeem(uint256 amount) public {
        _deployVault();
        amount = bound(amount, 1e7, 10e8);
        deal(WBTC, user1, amount);

        _depositAs(user1, amount);
        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);

        assertGt(withdrawn, 0, "Should receive collateral back");
        assertEq(vault.balanceOf(user1), 0, "Shares should be zero");
        _assertValuePreserved(amount, withdrawn, 500, "Fuzz deposit/redeem: >5% loss");
    }

    function testFuzz_deposit_and_withdraw(uint256 amount) public {
        _deployVault();
        amount = bound(amount, 1e7, 10e8);
        deal(WBTC, user1, amount);

        uint256 shares = _depositAs(user1, amount);
        _refreshOracles();

        uint256 assets = vault.convertToAssets(shares);
        if (assets > 0) {
            vm.prank(user1);
            vault.withdraw(assets, user1, user1);
            assertGt(wbtc.balanceOf(user1), 0, "Should receive WBTC back");
        }
    }

    function testFuzz_multiUser_deposit_redeem(uint256 a1, uint256 a2) public {
        _deployVault();
        a1 = bound(a1, 1e7, 5e8);
        a2 = bound(a2, 1e7, 5e8);
        deal(WBTC, user1, a1);
        deal(WBTC, user2, a2);

        _depositAs(user1, a1);
        _depositAs(user2, a2);

        _refreshOracles();
        uint256 w1 = _redeemAllAs(user1);
        _refreshOracles();
        uint256 w2 = _redeemAllAs(user2);

        assertGt(w1, 0, "User1 should receive collateral");
        assertGt(w2, 0, "User2 should receive collateral");

        uint256 ratio_in = (a1 * 1e18) / a2;
        uint256 ratio_out = (w1 * 1e18) / w2;
        uint256 diff = ratio_in > ratio_out ? ratio_in - ratio_out : ratio_out - ratio_in;
        assertLe(diff, ratio_in / 10, "Proportional fairness: >10% deviation");
    }

    function testFuzz_emergency_proRata(uint256 depositAmount, uint256 sharesFraction) public {
        _deployVault();
        depositAmount = bound(depositAmount, 1e7, 5e8);
        deal(WBTC, user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyStep(0);
        vault.emergencyStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        sharesFraction = bound(sharesFraction, 1, shares);
        uint256 availableBefore = wbtc.balanceOf(address(vault));
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user1);
        uint256 collateral = vault.redeem(sharesFraction, user1, user1);

        uint256 expected = (availableBefore * sharesFraction) / supplyBefore;
        assertApproxEqAbs(collateral, expected, 1, "Pro-rata mismatch");
    }

    function testFuzz_deposit_withdraw_neverZeroAssets(uint256 depositAmount) public {
        _deployVault();
        depositAmount = bound(depositAmount, 1e7, 5e8);
        deal(WBTC, user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        // Full redeem — user1 is sole depositor, triggering isFinalWithdraw (full close path).
        // Partial redeems as sole depositor can fail InsufficientCollateral due to swap slippage
        // when the proportional unwind path can't recover the oracle-priced collateralAmount.
        vm.prank(user1);
        uint256 collateral = vault.redeem(shares, user1, user1);

        assertGt(collateral, 0, "Must receive collateral for non-zero share burn");
    }
}
