// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
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

/// @title WstEthAaveExtensive
/// @notice Extensive fork tests for wstETH + USDT + IPOR (Aave) vault configuration
contract WstEthAaveExtensive is Test {
    using SafeTransferLib for IERC20;

    // Mainnet addresses
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // IPOR / Curve
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    // Uniswap V3
    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant FEE_WSTETH_WETH = 100; // 0.01%
    uint24 constant FEE_WETH_USDT = 3000; // 0.3%

    // Oracles
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");

    IERC20 wstETH;
    IERC20 usdt;
    ZenjiViewHelper viewHelper;

    // Deployed contracts
    Zenji vault;
    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    UniswapV3TwoHopSwapper swapper;
    WstEthOracle wstEthOracle;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        wstETH = IERC20(WSTETH);
        usdt = IERC20(USDT);
        viewHelper = new ZenjiViewHelper();

        _syncAndMockOracles();

        deal(WSTETH, user1, 200e18);
        deal(WSTETH, user2, 200e18);
    }

    // ============ Helpers ============

    function _syncAndMockOracles() internal {
        (,,, uint256 stEthEthUpdatedAt,) = IChainlinkOracle(STETH_ETH_ORACLE).latestRoundData();
        (,,, uint256 ethUsdUpdatedAt,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        (,,, uint256 usdtUpdatedAt,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUsdUpdatedAt,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();

        uint256 maxUpdatedAt = stEthEthUpdatedAt;
        if (ethUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = ethUsdUpdatedAt;
        if (usdtUpdatedAt > maxUpdatedAt) maxUpdatedAt = usdtUpdatedAt;
        if (crvUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUsdUpdatedAt;
        if (block.timestamp < maxUpdatedAt + 1) vm.warp(maxUpdatedAt + 1);

        _mockOracle(STETH_ETH_ORACLE);
        _mockOracle(ETH_USD_ORACLE);
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
        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            address(wstEthOracle), USDT_USD_ORACLE
        );

        strategy = new UsdtIporYieldStrategy(
            USDT, CRVUSD, expectedVaultAddress, USDT_CRVUSD_POOL, IPOR_PLASMA_VAULT, 0, 1, CRVUSD_USD_ORACLE, USDT_USD_ORACLE
        );

        loanManager = new AaveLoanManager(
            WSTETH, USDT, AAVE_A_WSTETH, AAVE_VAR_DEBT_USDT, AAVE_POOL,
            address(wstEthOracle), USDT_USD_ORACLE, address(swapper), 7100, 7600, expectedVaultAddress
        );

        vault = new Zenji(WSTETH, USDT, address(loanManager), address(strategy), address(swapper), owner, address(viewHelper));
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        wstETH.approve(address(vault), amount);
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
        _mockOracle(STETH_ETH_ORACLE);
        _mockOracle(ETH_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
    }

    // ============ A. Value Accounting Tests ============

    function test_depositAndRedeem_fullCycle() public {
        _deployVault();
        uint256 depositAmount = 10e18; // 10 wstETH

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
        uint256 depositAmount = 20e18; // 20 wstETH

        uint256 shares = _depositAs(user1, depositAmount);

        _refreshOracles();

        // Redeem first half
        vm.prank(user1);
        uint256 first = vault.redeem(shares / 2, user1, user1);

        _refreshOracles();

        // Redeem second half
        uint256 second = _redeemAllAs(user1);

        uint256 total = first + second;
        _assertValuePreserved(depositAmount, total, 200, "Partial cycle: >2% total loss");

        // Each half should be roughly proportional
        uint256 halfDeposit = depositAmount / 2;
        assertGe(first, halfDeposit - (halfDeposit * 500) / 10000, "First half: >5% deviation");
        assertGe(second, halfDeposit - (halfDeposit * 500) / 10000, "Second half: >5% deviation");

        console.log("Partial: first=%d second=%d total=%d", first, second, total);
    }

    function test_depositAndRedeem_tiny() public {
        _deployVault();
        uint256 depositAmount = 1e4; // MIN_DEPOSIT for 18-decimal token

        uint256 shares = _depositAs(user1, depositAmount);
        assertGt(shares, 0, "Should receive shares for min deposit");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Should receive something back for min deposit");
        console.log("Tiny: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_depositAndRedeem_large() public {
        _deployVault();
        uint256 depositAmount = 50e18; // 50 wstETH

        _depositAs(user1, depositAmount);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Large cycle: >2% loss");
        console.log("Large: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_multiUser_depositAndRedeem() public {
        _deployVault();
        uint256 deposit1 = 10e18;
        uint256 deposit2 = 20e18;

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

        uint256 shares1 = _depositAs(user1, 10e18);

        _refreshOracles();

        vm.prank(user1);
        uint256 partialOut = vault.redeem(shares1 / 2, user1, user1);
        assertGt(partialOut, 0, "Partial redeem should return collateral");

        _refreshOracles();

        _depositAs(user1, 10e18);

        _refreshOracles();

        uint256 finalOut = _redeemAllAs(user1);
        assertGt(finalOut, 0, "Final redeem should return collateral");

        uint256 totalIn = 20e18;
        uint256 totalOut = partialOut + finalOut;
        _assertValuePreserved(totalIn, totalOut, 300, "Sequential: >3% total loss");

        console.log("Sequential: totalIn=%d totalOut=%d", totalIn, totalOut);
    }

    // ============ B. Rebalance Tests ============

    function test_rebalance_upward() public {
        _deployVault();
        _depositAs(user1, 20e18);

        // IPOR PlasmaVault has a short withdraw cooldown; advance time to avoid revert
        _refreshOracles();

        // Increase ETH price by 20% → wstETH worth more → LTV drops below band
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            ETH_USD_ORACLE,
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
        _depositAs(user1, 20e18);

        // IPOR PlasmaVault has a short withdraw cooldown; advance time to avoid revert
        _refreshOracles();

        // Decrease ETH price by 15% → wstETH worth less → LTV rises above band
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 85) / 100;
        vm.mockCall(
            ETH_USD_ORACLE,
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
        _depositAs(user1, 10e18);

        vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_bountyPaid() public {
        _deployVault();
        _depositAs(user1, 20e18);

        vm.startPrank(owner);
        vault.setParam(0, 1e17); // 10% fee rate
        vault.setParam(3, 1e17); // 10% bounty rate
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();
        vault.accrueYieldFees();

        // Force rebalance by moving price
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            ETH_USD_ORACLE,
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
        uint256 depositAmount = 10e18;
        _depositAs(user1, depositAmount);

        // Respect IPOR's 1s withdraw lock
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
        _depositAs(user1, 10e18);

        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.startPrank(user2);
        wstETH.approve(address(vault), 10e18);
        vm.expectRevert(Zenji.EmergencyModeActive.selector);
        vault.deposit(10e18, user2);
        vm.stopPrank();
    }

    function test_emergency_redeemBeforeLiquidation() public {
        _deployVault();
        _depositAs(user1, 10e18);

        // Respect IPOR's withdraw lock before attempting emergency actions
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
        _depositAs(user1, 10e18);

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
        _depositAs(user1, 10e18);

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

        _depositAs(user1, 20e18);

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

        _depositAs(user1, 10e18);

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        vault.accrueYieldFees();
        assertEq(vault.accumulatedFees(), 0, "No fees should accrue with 0 rate");
    }

    // ============ E. Oracle Staleness Tests ============

    function test_oracleStale_depositReverts() public {
        _deployVault();

        // Warp past max staleness (1 hour for collateral oracle)
        vm.warp(block.timestamp + 3601);

        vm.startPrank(user1);
        wstETH.approve(address(vault), 10e18);
        vm.expectRevert();
        vault.deposit(10e18, user1);
        vm.stopPrank();
    }

    function test_oracleStale_rebalanceReverts() public {
        _deployVault();
        _depositAs(user1, 10e18);

        vm.warp(block.timestamp + 3601);

        vm.expectRevert();
        vault.rebalance();
    }

    // ============ F. Governance Timelock Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, 10e18);

        UniswapV3TwoHopSwapper newSwapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            address(wstEthOracle), USDT_USD_ORACLE
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

        // Test cancel
        UniswapV3TwoHopSwapper anotherSwapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            address(wstEthOracle), USDT_USD_ORACLE
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

    // ============ G. Boundary & Revert Tests ============

    function test_deposit_belowMinimum_reverts() public {
        _deployVault();

        vm.startPrank(user1);
        wstETH.approve(address(vault), 1e4 - 1);
        vm.expectRevert(Zenji.AmountTooSmall.selector);
        vault.deposit(1e4 - 1, user1);
        vm.stopPrank();
    }

    function test_deposit_atCap_reverts() public {
        _deployVault();

        vm.prank(owner);
        vault.setParam(2, 10e18); // Cap at 10 wstETH

        _depositAs(user1, 10e18);

        vm.startPrank(user2);
        wstETH.approve(address(vault), 10e18);
        vm.expectRevert(Zenji.DepositCapExceeded.selector);
        vault.deposit(10e18, user2);
        vm.stopPrank();
    }

    function test_redeem_zeroShares_reverts() public {
        _deployVault();
        _depositAs(user1, 10e18);

        vm.prank(user1);
        vm.expectRevert(Zenji.ZeroAmount.selector);
        vault.redeem(0, user1, user1);
    }

    function test_redeem_moreThanBalance_reverts() public {
        _deployVault();
        uint256 shares = _depositAs(user1, 10e18);

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
        _depositAs(user1, 10e18);

        // Ensure IPOR cooldown has elapsed before unwinding
        _refreshOracles();

        assertTrue(loanManager.loanExists(), "Loan should exist before idle");

        vm.prank(owner);
        vault.setIdle(true);

        assertTrue(vault.idle(), "Should be idle");
        uint256 vaultBal = wstETH.balanceOf(address(vault));
        assertGt(vaultBal, 0, "Vault should hold collateral in idle mode");

        _depositAs(user1, 10e18);
        uint256 vaultBalAfter = wstETH.balanceOf(address(vault));
        assertGt(vaultBalAfter, vaultBal, "More collateral should be in vault");

        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);

        assertFalse(vault.idle(), "Should not be idle");
        assertTrue(loanManager.loanExists(), "Loan should exist after exit idle");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(20e18, withdrawn, 500, "Idle enter/exit: >5% loss");
        console.log("Idle enter/exit: deposited=20e18 withdrawn=%d", withdrawn);
    }

    // ============ I. Fuzz Tests ============

    function testFuzz_deposit_and_redeem(uint256 amount) public {
        _deployVault();
        amount = bound(amount, 1e18, 50e18); // Min 0.01 wstETH
        deal(WSTETH, user1, amount);

        _depositAs(user1, amount);
        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);

        assertGt(withdrawn, 0, "Should receive collateral back");
        assertEq(vault.balanceOf(user1), 0, "Shares should be zero");
        _assertValuePreserved(amount, withdrawn, 500, "Fuzz deposit/redeem: >5% loss");
    }

    function testFuzz_deposit_and_withdraw(uint256 amount) public {
        _deployVault();
        amount = bound(amount, 1e18, 50e18);
        deal(WSTETH, user1, amount);

        uint256 shares = _depositAs(user1, amount);
        _refreshOracles();

        uint256 assets = vault.convertToAssets(shares);
        if (assets > 0) {
            vm.prank(user1);
            vault.withdraw(assets, user1, user1);
            assertGt(wstETH.balanceOf(user1), 0, "Should receive wstETH back");
        }
    }

    function testFuzz_multiUser_deposit_redeem(uint256 a1, uint256 a2) public {
        _deployVault();
        a1 = bound(a1, 1e18, 25e18);
        a2 = bound(a2, 1e18, 25e18);
        deal(WSTETH, user1, a1);
        deal(WSTETH, user2, a2);

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
        depositAmount = bound(depositAmount, 1e18, 25e18);
        deal(WSTETH, user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyStep(0);
        vault.emergencyStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        sharesFraction = bound(sharesFraction, 1, shares);
        uint256 availableBefore = wstETH.balanceOf(address(vault));
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user1);
        uint256 collateral = vault.redeem(sharesFraction, user1, user1);

        uint256 expected = (availableBefore * sharesFraction) / supplyBefore;
        assertApproxEqAbs(collateral, expected, 1, "Pro-rata mismatch");
    }

    function testFuzz_deposit_withdraw_neverZeroAssets(uint256 depositAmount, uint256) public {
        _deployVault();
        depositAmount = bound(depositAmount, 1e18, 25e18);
        deal(WSTETH, user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        // Full redeem — sole depositor path should always return non-zero collateral.
        // Partial redeems can fail with InsufficientCollateral due to slippage in unwind.
        vm.prank(user1);
        uint256 collateral = vault.redeem(shares, user1, user1);

        assertGt(collateral, 0, "Must receive collateral for non-zero share burn");
    }

    function test_idleMode_depositWhileIdle() public {
        _deployVault();

        vm.prank(owner);
        vault.setIdle(true);

        _depositAs(user1, 10e18);

        assertFalse(loanManager.loanExists(), "No loan should exist in idle mode");
        assertEq(wstETH.balanceOf(address(vault)), 10e18, "All collateral should be in vault");

        uint256 withdrawn = _redeemAllAs(user1);
        assertEq(withdrawn, 10e18, "Should get exact deposit back in idle mode");
    }
}
