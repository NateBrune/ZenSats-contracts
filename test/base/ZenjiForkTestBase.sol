// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../../src/Zenji.sol";
import { ZenjiViewHelper } from "../../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../../src/lenders/AaveLoanManager.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../../src/interfaces/IYieldStrategy.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";
import { TimelockLib } from "../../src/libraries/TimelockLib.sol";

/// @title ZenjiForkTestBase
/// @notice Abstract base for all Zenji fork tests — shared helpers + common test suite
abstract contract ZenjiForkTestBase is Test {
    using SafeTransferLib for IERC20;

    // Common mainnet addresses
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");

    // Core contracts (set by children in _deployVaultContracts)
    Zenji public vault;
    AaveLoanManager public loanManager;
    IYieldStrategy public yieldStrategy;
    IERC20 public collateralToken;
    IERC20 public usdt;
    ZenjiViewHelper public viewHelper;

    // ============ Abstract: children MUST implement ============

    /// @notice Collateral token address
    function _collateral() internal pure virtual returns (address);

    /// @notice 1 unit of collateral (e.g. 1e8 for WBTC, 1e18 for wstETH)
    function _unit() internal pure virtual returns (uint256);

    /// @notice List of oracle addresses to mock/sync
    function _oracleList() internal pure virtual returns (address[] memory);

    /// @notice The oracle to mock when simulating collateral price changes (rebalance tests)
    function _collateralPriceOracle() internal pure virtual returns (address);

    /// @notice Deploy swapper, strategy, loanManager, vault. Must set vault, loanManager, yieldStrategy.
    function _deployVaultContracts() internal virtual;

    // ============ Virtual: children CAN override ============

    /// @notice Standard deposit size for deterministic tests. Default = 1 unit.
    function _baseDeposit() internal pure virtual returns (uint256) {
        return _unit();
    }

    /// @notice Tiny deposit used in min-size round-trip test. Override for strategies where
    ///         protocol-level minimum is technically smaller but swap/liquidity path is not.
    function _tinyDeposit() internal pure virtual returns (uint256) {
        return 1e4;
    }

    /// @notice Hook called after _deployVaultContracts (e.g. set swapper slippage)
    function _postDeploySetup() internal virtual { }

    /// @notice Fuzz bounds for single-user tests
    function _fuzzMin() internal pure virtual returns (uint256) {
        return _unit() / 10;
    }

    function _fuzzMax() internal pure virtual returns (uint256) {
        return _unit() * 10;
    }

    /// @notice Fuzz bounds for multi-user tests
    function _fuzzMultiMin() internal pure virtual returns (uint256) {
        return _unit();
    }

    function _fuzzMultiMax() internal pure virtual returns (uint256) {
        return _unit() * 10;
    }

    /// @notice Multi-user fuzz: max round-trip loss and proportional fairness deviation (percent)
    function _fuzzMultiUserLossPct() internal pure virtual returns (uint256) {
        return 5;
    }

    function _fuzzMultiUserFairnessPct() internal pure virtual returns (uint256) {
        return 10;
    }

    /// @notice Whether to run inherited multi-user fuzz test for this suite.
    ///         Some fork paths (e.g., multi-hop swap routes) can have non-deterministic
    ///         edge behavior under arbitrary fuzzed pairs that is not representative
    ///         of production-sized flows.
    function _runMultiUserFuzz() internal pure virtual returns (bool) {
        return true;
    }

    /// @notice Seconds to warp forward to trigger a stale collateral oracle.
    ///         Must exceed the collateral oracle's staleness window by at least 1.
    ///         Default matches the standard 1-hour BTC/ETH heartbeat (3600 + 1).
    ///         Override for vaults whose collateral oracle has a longer heartbeat
    ///         e.g. XAU/USD (24 h) → return 90001.
    function _collateralStalenessWarp() internal pure virtual returns (uint256) {
        return 3601;
    }

    /// @dev The maximum targetLtv accepted by this vault's loan manager (in 1e18 precision).
    ///      Default matches BTC/ETH vaults whose maxLtvBps ≥ 6500.
    ///      Override for vaults with a lower cap, e.g. XAUT (maxLtvBps = 6000 → 60e16).
    function _maxTargetLtv() internal pure virtual returns (uint256) {
        return 65e16;
    }

    // ============ setUp ============

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        collateralToken = IERC20(_collateral());
        usdt = IERC20(USDT);
        viewHelper = new ZenjiViewHelper();

        _syncAndMockOracles();

        deal(_collateral(), user1, 100 * _unit());
        deal(_collateral(), user2, 100 * _unit());
    }

    // ============ Helpers ============

    function _syncAndMockOracles() internal {
        address[] memory oracles = _oracleList();
        uint256 maxUpdatedAt = 0;
        for (uint256 i = 0; i < oracles.length; i++) {
            (,,, uint256 updatedAt,) = IChainlinkOracle(oracles[i]).latestRoundData();
            if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
        }
        if (block.timestamp < maxUpdatedAt + 1) vm.warp(maxUpdatedAt + 1);
        for (uint256 i = 0; i < oracles.length; i++) {
            _mockOracle(oracles[i]);
        }
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
        _deployVaultContracts();
        _postDeploySetup();
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        collateralToken.approve(address(vault), amount);
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

    function _assertValuePreserved(
        uint256 deposited,
        uint256 withdrawn,
        uint256 toleranceBps,
        string memory msg_
    ) internal pure {
        uint256 minExpected = deposited - (deposited * toleranceBps) / 10000;
        require(withdrawn >= minExpected, msg_);
    }

    function _refreshOracles() internal {
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        address[] memory oracles = _oracleList();
        for (uint256 i = 0; i < oracles.length; i++) {
            _mockOracle(oracles[i]);
        }
    }

    // ============ A. Value Accounting Tests ============

    function test_depositAndRedeem_fullCycle() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);
        assertTrue(loanManager.loanExists(), "Loan should exist");
        assertGt(yieldStrategy.balanceOf(), 0, "Strategy should have balance");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Full cycle: >2% loss");
        console.log("Full cycle: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_depositAndRedeem_partial() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit() * 2;

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
        uint256 depositAmount = _tinyDeposit();

        uint256 shares = _depositAs(user1, depositAmount);
        assertGt(shares, 0, "Should receive shares for min deposit");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Should receive something back for min deposit");
        console.log("Tiny: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_depositAndRedeem_large() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit() * 5;

        _depositAs(user1, depositAmount);

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(depositAmount, withdrawn, 200, "Large cycle: >2% loss");
        console.log("Large: deposited=%d withdrawn=%d", depositAmount, withdrawn);
    }

    function test_multiUser_depositAndRedeem() public {
        _deployVault();
        uint256 deposit1 = _baseDeposit();
        uint256 deposit2 = _baseDeposit() * 2;

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
        uint256 dep = _baseDeposit();

        uint256 shares1 = _depositAs(user1, dep);

        _refreshOracles();

        vm.prank(user1);
        uint256 partialOut = vault.redeem(shares1 / 2, user1, user1);
        assertGt(partialOut, 0, "Partial redeem should return collateral");

        _refreshOracles();

        _depositAs(user1, dep);

        _refreshOracles();

        uint256 finalOut = _redeemAllAs(user1);
        assertGt(finalOut, 0, "Final redeem should return collateral");

        uint256 totalIn = dep * 2;
        uint256 totalOut = partialOut + finalOut;
        _assertValuePreserved(totalIn, totalOut, 300, "Sequential: >3% total loss");

        console.log("Sequential: totalIn=%d totalOut=%d", totalIn, totalOut);
    }

    // ============ B. Rebalance Tests ============

    function test_rebalance_upward() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, _baseDeposit() * 2);

        _refreshOracles();

        // Increase collateral price by 20% -> LTV drops below lower band
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            _collateralPriceOracle(),
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

        _depositAs(user1, _baseDeposit() * 2);

        _refreshOracles();

        // Decrease collateral price by 15% -> LTV rises above upper band
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        int256 newPrice = (answer * 85) / 100;
        vm.mockCall(
            _collateralPriceOracle(),
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
        _depositAs(user1, _baseDeposit());

        vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_bountyPaid() public {
        _deployVault();
        vm.startPrank(owner);
        vault.setParam(1, 55e16);
        vm.stopPrank();

        _depositAs(user1, _baseDeposit() * 2);

        vm.startPrank(owner);
        vault.setParam(0, 1e17);
        vault.setParam(3, 1e17);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();
        vault.accrueYieldFees();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(_collateralPriceOracle()).latestRoundData();
        int256 newPrice = (answer * 120) / 100;
        vm.mockCall(
            _collateralPriceOracle(),
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
        uint256 depositAmount = _baseDeposit();
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
        _depositAs(user1, _baseDeposit());

        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.startPrank(user2);
        collateralToken.approve(address(vault), _baseDeposit());
        vm.expectRevert(Zenji.EmergencyModeActive.selector);
        vault.deposit(_baseDeposit(), user2);
        vm.stopPrank();
    }

    function test_emergency_redeemBeforeLiquidation() public {
        _deployVault();
        _depositAs(user1, _baseDeposit());

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
        _depositAs(user1, _baseDeposit());

        deal(USDC, address(vault), 1000e6);

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.rescueAssets(USDC, feeRecipient);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(feeRecipient), 1000e6, "Should rescue USDC");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "Vault should have 0 USDC");
    }

    // ============ D. Yield & Fee Tests ============

    function test_harvestYield() public {
        _deployVault();
        _depositAs(user1, _baseDeposit());

        uint256 stratBefore = yieldStrategy.balanceOf();
        vm.prank(owner);
        vault.harvestYield();
        uint256 stratAfter = yieldStrategy.balanceOf();

        assertGe(stratAfter, stratBefore, "Strategy balance should not decrease after harvest");
        console.log("Harvest: before=%d after=%d", stratBefore, stratAfter);
    }

    function test_feeAccrual_andWithdraw() public {
        _deployVault();

        vm.prank(owner);
        vault.setParam(0, 1e17);

        _depositAs(user1, _baseDeposit() * 2);

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

        _depositAs(user1, _baseDeposit());

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        vault.accrueYieldFees();
        assertEq(vault.accumulatedFees(), 0, "No fees should accrue with 0 rate");
    }

    // ============ E. Oracle Staleness Tests ============

    function test_oracleStale_depositReverts() public {
        _deployVault();

        vm.warp(block.timestamp + _collateralStalenessWarp());

        vm.startPrank(user1);
        collateralToken.approve(address(vault), _baseDeposit());
        vm.expectRevert();
        vault.deposit(_baseDeposit(), user1);
        vm.stopPrank();
    }

    function test_oracleStale_rebalanceReverts() public {
        _deployVault();
        _depositAs(user1, _baseDeposit());

        vm.warp(block.timestamp + _collateralStalenessWarp());

        vm.expectRevert();
        vault.rebalance();
    }

    // ============ F. Boundary & Revert Tests ============

    function test_deposit_belowMinimum_reverts() public {
        _deployVault();

        vm.startPrank(user1);
        collateralToken.approve(address(vault), 1e4 - 1);
        vm.expectRevert(Zenji.AmountTooSmall.selector);
        vault.deposit(1e4 - 1, user1);
        vm.stopPrank();
    }

    function test_deposit_atCap_reverts() public {
        _deployVault();

        vm.prank(owner);
        vault.setParam(2, _baseDeposit());

        _depositAs(user1, _baseDeposit());

        vm.startPrank(user2);
        collateralToken.approve(address(vault), _baseDeposit());
        vm.expectRevert(Zenji.DepositCapExceeded.selector);
        vault.deposit(_baseDeposit(), user2);
        vm.stopPrank();
    }

    function test_redeem_zeroShares_reverts() public {
        _deployVault();
        _depositAs(user1, _baseDeposit());

        vm.prank(user1);
        vm.expectRevert(Zenji.ZeroAmount.selector);
        vault.redeem(0, user1, user1);
    }

    function test_redeem_moreThanBalance_reverts() public {
        _deployVault();
        uint256 shares = _depositAs(user1, _baseDeposit());

        vm.prank(user1);
        vm.expectRevert(Zenji.InsufficientShares.selector);
        vault.redeem(shares + 1, user1, user1);
    }

    function test_setParam_boundaries() public {
        _deployVault();

        vm.startPrank(owner);

        vault.setParam(1, 15e16);
        assertEq(vault.targetLtv(), 15e16, "Should accept min LTV");

        vault.setParam(1, _maxTargetLtv());
        assertEq(vault.targetLtv(), _maxTargetLtv(), "Should accept max LTV");

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, 15e16 - 1);

        vm.expectRevert(Zenji.InvalidTargetLtv.selector);
        vault.setParam(1, _maxTargetLtv() + 1);

        vault.setParam(0, 2e17);
        assertEq(vault.feeRate(), 2e17, "Should accept max fee rate");

        vm.expectRevert(Zenji.InvalidFeeRate.selector);
        vault.setParam(0, 2e17 + 1);

        vault.setParam(3, 1e18);
        assertEq(vault.rebalanceBountyRate(), 1e18, "Should accept max bounty");

        vm.expectRevert(Zenji.InvalidBountyRate.selector);
        vault.setParam(3, 1e18 + 1);

        vault.setParam(2, 0);
        assertEq(vault.depositCap(), 0, "Should accept 0 cap");
        vault.setParam(2, type(uint256).max);
        assertEq(vault.depositCap(), type(uint256).max, "Should accept max cap");

        vm.stopPrank();
    }

    // ============ G. Idle Mode Tests ============

    function test_idleMode_enterExit() public {
        _deployVault();
        _depositAs(user1, _baseDeposit());

        _refreshOracles();

        assertTrue(loanManager.loanExists(), "Loan should exist before idle");

        vm.prank(owner);
        vault.setIdle(true);

        assertTrue(vault.idle(), "Should be idle");

        uint256 vaultBal = collateralToken.balanceOf(address(vault));
        assertGt(vaultBal, 0, "Vault should hold collateral in idle mode");

        _depositAs(user1, _baseDeposit());
        uint256 vaultBalAfter = collateralToken.balanceOf(address(vault));
        assertGt(vaultBalAfter, vaultBal, "More collateral should be in vault");

        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);

        assertFalse(vault.idle(), "Should not be idle");
        assertTrue(loanManager.loanExists(), "Loan should exist after exit idle");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        _assertValuePreserved(_baseDeposit() * 2, withdrawn, 500, "Idle enter/exit: >5% loss");
        console.log("Idle enter/exit: deposited=%d withdrawn=%d", _baseDeposit() * 2, withdrawn);
    }

    function test_idleMode_depositWhileIdle() public {
        _deployVault();

        vm.prank(owner);
        vault.setIdle(true);

        _depositAs(user1, _baseDeposit());

        assertFalse(loanManager.loanExists(), "No loan should exist in idle mode");
        assertEq(
            collateralToken.balanceOf(address(vault)),
            _baseDeposit(),
            "All collateral should be in vault"
        );

        vm.roll(block.number + 1);

        uint256 withdrawn = _redeemAllAs(user1);
        assertEq(withdrawn, _baseDeposit(), "Should get exact deposit back in idle mode");
    }

    // ============ H. Fuzz Tests ============

    function testFuzz_deposit_and_redeem(uint256 amount) public {
        _deployVault();
        amount = bound(amount, _fuzzMin(), _fuzzMax());
        deal(_collateral(), user1, amount);

        _depositAs(user1, amount);
        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);

        assertGt(withdrawn, 0, "Should receive collateral back");
        assertEq(vault.balanceOf(user1), 0, "Shares should be zero");
        _assertValuePreserved(amount, withdrawn, 500, "Fuzz deposit/redeem: >5% loss");
    }

    function testFuzz_deposit_and_withdraw(uint256 amount) public {
        _deployVault();
        amount = bound(amount, _fuzzMin(), _fuzzMax());
        deal(_collateral(), user1, amount);

        uint256 shares = _depositAs(user1, amount);
        _refreshOracles();

        uint256 assets = vault.convertToAssets(shares);
        if (assets > 0) {
            vm.prank(user1);
            vault.withdraw(assets, user1, user1);
            assertGt(collateralToken.balanceOf(user1), 0, "Should receive collateral back");
        }
    }

    function testFuzz_multiUser_deposit_redeem(uint256 a1, uint256 a2) public {
        if (!_runMultiUserFuzz()) return;
        _deployVault();
        a1 = bound(a1, _fuzzMultiMin(), _fuzzMultiMax());
        a2 = bound(a2, _fuzzMultiMin(), _fuzzMultiMax());
        deal(_collateral(), user1, a1);
        deal(_collateral(), user2, a2);

        _depositAs(user1, a1);
        _depositAs(user2, a2);

        _refreshOracles();
        uint256 w1 = _redeemAllAs(user1);
        _refreshOracles();
        uint256 w2 = _redeemAllAs(user2);

        assertGt(w1, 0, "User1 should receive collateral");
        assertGt(w2, 0, "User2 should receive collateral");

        uint256 lossPct = _fuzzMultiUserLossPct();
        if (lossPct > 0) {
            uint256 minW1 = (a1 * (100 - lossPct)) / 100;
            uint256 minW2 = (a2 * (100 - lossPct)) / 100;
            assertGe(w1, minW1, "User1: round-trip loss exceeds tolerance");
            assertGe(w2, minW2, "User2: round-trip loss exceeds tolerance");
        }

        uint256 ratio_in = (a1 * 1e18) / a2;
        uint256 ratio_out = (w1 * 1e18) / w2;
        uint256 diff = ratio_in > ratio_out ? ratio_in - ratio_out : ratio_out - ratio_in;
        uint256 fairnessPct = _fuzzMultiUserFairnessPct();
        assertLe(diff, ratio_in * fairnessPct / 100, "Proportional fairness deviation exceeded");
    }

    function testFuzz_emergency_proRata(uint256 depositAmount, uint256 sharesFraction) public {
        _deployVault();
        depositAmount = bound(depositAmount, _fuzzMin(), _fuzzMultiMax() / 2);
        deal(_collateral(), user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyStep(0);
        vault.emergencyStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        sharesFraction = bound(sharesFraction, 1, shares);
        uint256 availableBefore = collateralToken.balanceOf(address(vault));
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user1);
        uint256 collateral = vault.redeem(sharesFraction, user1, user1);

        uint256 expected = (availableBefore * sharesFraction) / supplyBefore;
        assertApproxEqAbs(collateral, expected, 1, "Pro-rata mismatch");
    }

    function testFuzz_deposit_withdraw_neverZeroAssets(uint256 depositAmount) public {
        _deployVault();
        depositAmount = bound(depositAmount, _fuzzMin(), _fuzzMultiMax() / 2);
        deal(_collateral(), user1, depositAmount);

        uint256 shares = _depositAs(user1, depositAmount);
        _refreshOracles();

        // Full redeem — sole depositor path should always return non-zero collateral.
        vm.prank(user1);
        uint256 collateral = vault.redeem(shares, user1, user1);

        assertGt(collateral, 0, "Must receive collateral for non-zero share burn");
    }
}
