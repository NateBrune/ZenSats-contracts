// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/AaveLoanManager.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/CbBtcWbtcUsdtSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title CbBtcAaveExtensive
/// @notice Extensive fork tests for cbBTC + USDT + IPOR (Aave) vault configuration
contract CbBtcAaveExtensive is Test {
    using SafeTransferLib for IERC20;

    // Mainnet addresses
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // IPOR / Curve
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;

    // Curve pools
    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX = 1;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;

    // Oracles
    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");

    IERC20 cbbtc;
    IERC20 usdt;
    ZenjiViewHelper viewHelper;

    Zenji vault;
    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    CbBtcWbtcUsdtSwapper swapper;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        cbbtc = IERC20(CBBTC);
        usdt = IERC20(USDT);
        viewHelper = new ZenjiViewHelper();

        _syncAndMockOracles();

        deal(CBBTC, user1, 50e8);
        deal(CBBTC, user2, 50e8);
    }

    // ============ Helpers ============

    function _syncAndMockOracles() internal {
        (,,, uint256 cbUpdate,) = IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        (,,, uint256 usdtUpdate,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUsdUpdate,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();

        uint256 maxUpdatedAt = cbUpdate;
        if (usdtUpdate > maxUpdatedAt) maxUpdatedAt = usdtUpdate;
        if (crvUsdUpdate > maxUpdatedAt) maxUpdatedAt = crvUsdUpdate;
        if (block.timestamp < maxUpdatedAt + 1) vm.warp(maxUpdatedAt + 1);

        _mockOracle(CBBTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
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

    function _deployVault() internal {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX, TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX
        );

        strategy = new UsdtIporYieldStrategy(
            USDT, CRVUSD, expectedVaultAddress, USDT_CRVUSD_POOL, IPOR_PLASMA_VAULT, USDT_INDEX, CRVUSD_INDEX, CRVUSD_USD_ORACLE, USDT_USD_ORACLE
        );

        loanManager = new AaveLoanManager(
            CBBTC, USDT, AAVE_A_CBBTC, AAVE_VAR_DEBT_USDT, AAVE_POOL,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE, address(swapper), 7500, 8000, expectedVaultAddress
        );

        vault = new Zenji(CBBTC, USDT, address(loanManager), address(strategy), address(swapper), owner, address(viewHelper));
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        cbbtc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
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
        _mockOracle(CBBTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
    }

    // ============ A. Value Accounting Tests ============

    function test_depositAndRedeem_fullCycle() public {
        _deployVault();
        uint256 depositAmount = 1e8; // 1 cbBTC

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
        uint256 depositAmount = 2e8; // 2 cbBTC

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
        uint256 depositAmount = 5e8; // 5 cbBTC

        _depositAs(user1, depositAmount);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Large cycle: >2% loss");
        console.log("Large: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_multiUser_depositAndRedeem() public {
        _deployVault();
        uint256 deposit1 = 1e8;
        uint256 deposit2 = 2e8;

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

        uint256 remainingShares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 remainingOut = vault.redeem(remainingShares, user1, user1);
        assertGt(remainingOut, 0, "Remaining redeem should return collateral");

        console.log("Sequential: partial=%d remaining=%d", partialOut, remainingOut);
    }

    // ============ B. Rebalance & Bounty Tests ============

    function test_rebalance_downward() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, 2e8);

        _refreshOracles();

        // Move price up to force downward rebalance
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        int256 higher = (answer * 120) / 100;
        vm.mockCall(
            CBBTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, higher, updatedAt, updatedAt, answeredInRound)
        );

        vm.prank(keeper);
        vault.rebalance();
    }

    function test_rebalance_upward() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, 2e8);

        _refreshOracles();
        // IPOR PlasmaVault enforces a withdraw cooldown; advance time to clear it
        vm.warp(block.timestamp + 1 days);
        _syncAndMockOracles();

        // Move price down to force upward rebalance
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        int256 lower = (answer * 80) / 100;
        vm.mockCall(
            CBBTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, lower, updatedAt, updatedAt, answeredInRound)
        );

        vm.prank(keeper);
        vault.rebalance();
    }

    function test_rebalance_bountyPaid() public {
        _deployVault();
        vm.startPrank(owner);
        vault.setParam(1, 55e16);
        vm.stopPrank();

        _depositAs(user1, 2e8);

        vm.startPrank(owner);
        vault.setParam(0, 1e17); // 10% fee
        vault.setParam(3, 1e17); // 10% bounty
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();
        vault.accrueYieldFees();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            CBBTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, updatedAt, updatedAt, answeredInRound)
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
        cbbtc.approve(address(vault), 1e8);
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

        address randomToken = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
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
        vault.setParam(0, 1e17); // 10% fee rate

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
        cbbtc.approve(address(vault), 1e8);
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

        CbBtcWbtcUsdtSwapper newSwapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX, TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX
        );

        vm.prank(vault.gov());
        vault.proposeSwapper(address(newSwapper));

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.executeSwapper();

        vm.warp(block.timestamp + 2 days + 1);
        _syncAndMockOracles();

        vm.prank(vault.gov());
        vault.executeSwapper();
        assertEq(address(vault.swapper()), address(newSwapper), "Swapper should be updated");

        CbBtcWbtcUsdtSwapper anotherSwapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX, TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX
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

        assertEq(swapper.slippage(), 5e16, "Initial slippage should be 5%");

        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        vm.prank(owner);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        swapper.executeSlippage();

        vm.warp(block.timestamp + 2 days + 1);
        _syncAndMockOracles();

        vm.prank(owner);
        swapper.executeSlippage();
        assertEq(swapper.slippage(), 10e16, "Slippage should be 10%");
    }

    // ============ G. Boundary & Revert Tests ============

    function test_deposit_belowMinimum_reverts() public {
        _deployVault();

        vm.startPrank(user1);
        cbbtc.approve(address(vault), 1e4 - 1);
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
        cbbtc.approve(address(vault), 1e8);
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

        vault.setParam(1, 73e16);
        assertEq(vault.targetLtv(), 73e16, "Should accept max LTV");

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, 15e16 - 1);

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, 73e16 + 1);

        vault.setParam(0, 2e17);
        assertEq(vault.feeRate(), 2e17, "Should accept max fee rate");

        vm.expectRevert(Zenji.InvalidFeeRate.selector);
        vault.setParam(0, 2e17 + 1);

        vault.setParam(3, 2e17);
        assertEq(vault.rebalanceBountyRate(), 2e17, "Should accept max bounty");

        vm.expectRevert(Zenji.InvalidBountyRate.selector);
        vault.setParam(3, 2e17 + 1);

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
        uint256 vaultBal = cbbtc.balanceOf(address(vault));
        assertGt(vaultBal, 0, "Vault should hold collateral in idle mode");

        _depositAs(user1, 1e8);
        uint256 vaultBalAfter = cbbtc.balanceOf(address(vault));
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
        assertEq(cbbtc.balanceOf(address(vault)), 1e8, "All collateral should be in vault");

        uint256 withdrawn = _redeemAllAs(user1);
        assertEq(withdrawn, 1e8, "Should get exact deposit back in idle mode");
    }
}
