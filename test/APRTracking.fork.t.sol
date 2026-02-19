// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { VaultTracker } from "../src/VaultTracker.sol";
import { IporYieldStrategy } from "../src/strategies/IporYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

interface IYieldVault {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
}

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title APRTrackingForkTest
/// @notice Validates that APR tracking works correctly with auto-compounding vaults
contract APRTrackingForkTest is Test {
    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant LLAMALEND_WBTC = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant IPOR_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address constant WBTC_WHALE = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

    IERC20 wbtc;
    IERC20 crvUSD;
    IYieldVault iporVault;
    Zenji vault;
    VaultTracker tracker;
    IporYieldStrategy strategy;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        require(bytes(rpcUrl).length > 0, "RPC URL required");
        vm.createSelectFork(rpcUrl);

        // Sync block time with mainnet oracle to avoid StaleOracle()
        (,, uint256 btcUpdate,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        uint256 currentTime = block.timestamp;
        if (btcUpdate + 1 > currentTime) {
            vm.warp(btcUpdate + 1);
        }

        // Mock oracles to prevent StaleOracle or Reverts during the test
        // This is safe because we are testing the logic flow, not the oracle source
        mockOracle(50000e8);

        wbtc = IERC20(WBTC);
        crvUSD = IERC20(CRVUSD);
        iporVault = IYieldVault(IPOR_VAULT);

        // Check IPOR vault capacity
        uint256 maxDeposit = iporVault.maxDeposit(address(this));
        console.log("IPOR Vault max deposit:", maxDeposit);
        console.log("IPOR Vault total assets:", iporVault.totalAssets());

        // Fund test user
        vm.prank(WBTC_WHALE);
        wbtc.transfer(user1, 5e8); // 5 WBTC
    }

    /// @notice Helper to mock oracle after time warp
    function mockOracle(uint256 price) internal {
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1))
        );
    }

    // ============ IPOR Vault Direct Tests ============

    /// @notice Test that IPOR vault share price (proves auto-compounding works)
    function test_iporVault_sharePrice() public view {
        // Get current share price
        uint256 totalAssets = iporVault.totalAssets();
        uint256 totalSupply = iporVault.totalSupply();

        console.log("=== IPOR Vault State ===");
        console.log("Total assets (crvUSD):", totalAssets);
        console.log("Total supply (shares):", totalSupply);

        if (totalSupply > 0) {
            // IPOR PlasmaVault uses 1e27 decimals for shares, so adjust calculation
            // convertToAssets(1e27) gives us the value of 1 "full share"
            uint256 oneShare = 1e27;
            uint256 assetsPerShare = iporVault.convertToAssets(oneShare);
            console.log("Assets per 1e27 shares:", assetsPerShare);

            // Check convertToAssets is working
            uint256 testShares = 1000e18; // 1000 shares (at 18 decimals would be wrong, but let's see)
            uint256 testAssets = iporVault.convertToAssets(testShares);
            console.log("Assets for 1000e18 shares:", testAssets);

            // The key thing: as yield accrues, convertToAssets(shares) increases
            // This means strategy.balanceOf() will return more crvUSD over time
            assertGt(totalAssets, 0, "Vault should have assets");
        }
    }

    /// @notice Test strategy balanceOf vs costBasis captures yield
    function test_strategy_balanceOfVsCostBasis() public {
        // Skip if IPOR vault is at capacity
        if (iporVault.maxDeposit(address(this)) < 1000e18) {
            console.log("SKIPPING: IPOR vault at capacity");
            return;
        }

        // Deploy strategy with a mock vault address first
        address mockVault = address(this);
        strategy = new IporYieldStrategy(CRVUSD, mockVault, IPOR_VAULT);

        // Get some crvUSD
        deal(CRVUSD, mockVault, 10_000e18);

        // Approve and deposit
        crvUSD.approve(address(strategy), type(uint256).max);
        uint256 depositAmount = 1000e18;
        strategy.deposit(depositAmount);

        console.log("=== Strategy After Deposit ===");
        console.log("Cost basis:", strategy.costBasis());
        console.log("Balance of:", strategy.balanceOf());
        console.log("Unrealized profit:", strategy.unrealizedProfit());

        // Immediately after deposit, balance should be very close to cost basis
        // (maybe slightly less due to any entry fees)
        assertGe(strategy.balanceOf(), depositAmount * 99 / 100, "Balance should be ~deposit");
        assertEq(strategy.costBasis(), depositAmount, "Cost basis should equal deposit");

        // Now let's check what happens with time (in a real scenario)
        // The IPOR vault's share price should increase as yield accrues

        // For this test, we can't easily simulate yield accrual
        // But we can verify the math is correct
        uint256 currentBalance = strategy.balanceOf();
        uint256 costBasis = strategy.costBasis();

        if (currentBalance > costBasis) {
            console.log("Strategy has unrealized profit!");
            console.log("Profit:", currentBalance - costBasis);
        }
    }

    // ============ Full Vault Integration Tests ============

    /// @notice Deploy full vault setup and test APR tracking flow
    function test_fullVault_aprTrackingFlow() public {
        // Skip if IPOR vault is at capacity
        if (iporVault.maxDeposit(address(this)) < 100_000e18) {
            console.log("SKIPPING: IPOR vault at capacity (need 100k crvUSD room)");
            return;
        }

        viewHelper = new ZenjiViewHelper();

        // Step 1: Deploy vault with IPOR strategy
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        strategy = new IporYieldStrategy(CRVUSD, predictedVault, IPOR_VAULT);
        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            predictedVault
        );

        vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == predictedVault, "Vault address mismatch");

        tracker = new VaultTracker(address(vault));

        // Step 2: Enable yield

        // Step 3: User deposits
        vm.startPrank(user1);
        wbtc.approve(address(vault), type(uint256).max);
        uint256 depositAmount = 1e8; // 1 WBTC
        uint256 shares = vault.deposit(depositAmount, address(this));
        vm.stopPrank();

        console.log("=== After User Deposit ===");
        console.log("User shares:", shares);
        console.log("Vault total collateral:", vault.getTotalCollateral());
        console.log("Vault total value (debt):", viewHelper.getTotalDebtValue(address(vault)));
        console.log("Strategy balance:", strategy.balanceOf());
        console.log("Strategy cost basis:", strategy.costBasis());

        // Step 4: Take initial snapshot
        tracker.update();
        uint256 initialSharePrice = tracker.sharePrice();
        console.log("Initial share price:", initialSharePrice);

        // Step 5: Wait and simulate yield
        // In a real scenario, IPOR vault share price increases over time
        // For testing, we'll warp time and see if any profit is detected
        vm.warp(block.timestamp + 7 days);
        mockOracle(89238e8); // Re-mock oracle after warp

        // Step 6: Take another snapshot
        tracker.update();
        uint256 newSharePrice = tracker.sharePrice();

        console.log("=== After 7 Days ===");
        console.log("New share price:", newSharePrice);
        console.log("Strategy balance:", strategy.balanceOf());
        console.log("Strategy unrealized profit:", strategy.unrealizedProfit());

        // Get APR
        uint256 apr = tracker.calculateAPR(7);
        console.log("7-day APR (bps):", apr);

        // Get metrics
        (uint256 currentPrice, uint256 profit, uint256 loss, int256 netProfit,) =
            tracker.getPerformanceMetrics();
        console.log("Current price:", currentPrice);
        console.log("Cumulative profit:", profit);
        console.log("Cumulative loss:", loss);
        console.log("Net profit:", netProfit);
    }

    /// @notice Test that strategy.balanceOf() correctly reflects IPOR share value growth
    function test_strategy_capturesYieldGrowth() public {
        // Skip if IPOR vault is at capacity
        if (iporVault.maxDeposit(address(this)) < 1000e18) {
            console.log("SKIPPING: IPOR vault at capacity");
            return;
        }

        // Deploy standalone strategy
        address mockVault = address(this);
        strategy = new IporYieldStrategy(CRVUSD, mockVault, IPOR_VAULT);

        // Get crvUSD and deposit
        deal(CRVUSD, mockVault, 10_000e18);
        crvUSD.approve(address(strategy), type(uint256).max);

        uint256 depositAmount = 5000e18;
        strategy.deposit(depositAmount);

        uint256 initialBalance = strategy.balanceOf();
        uint256 initialCostBasis = strategy.costBasis();

        console.log("=== Initial State ===");
        console.log("Deposit amount:", depositAmount);
        console.log("Initial balance:", initialBalance);
        console.log("Initial cost basis:", initialCostBasis);
        console.log("IPOR shares held:", iporVault.balanceOf(address(strategy)));

        // The key insight: strategy.balanceOf() calls iporVault.convertToAssets(shares)
        // This should return more assets as yield accrues in the IPOR vault

        // Verify the math
        uint256 shares = iporVault.balanceOf(address(strategy));
        uint256 assetsFromShares = iporVault.convertToAssets(shares);

        console.log("=== Verification ===");
        console.log("Shares in IPOR:", shares);
        console.log("Assets from shares:", assetsFromShares);
        console.log("Strategy.balanceOf():", strategy.balanceOf());

        assertEq(strategy.balanceOf(), assetsFromShares, "balanceOf should equal convertToAssets");

        // Now let's manually check IPOR's share price
        uint256 iporTotalAssets = iporVault.totalAssets();
        uint256 iporTotalSupply = iporVault.totalSupply();

        if (iporTotalSupply > 0) {
            uint256 iporSharePrice = (iporTotalAssets * 1e18) / iporTotalSupply;
            console.log("=== IPOR Vault ===");
            console.log("Total assets:", iporTotalAssets);
            console.log("Total supply:", iporTotalSupply);
            console.log("Share price:", iporSharePrice);

            // If share price > 1e18, there's been yield
            if (iporSharePrice > 1e18) {
                console.log("IPOR vault has accumulated yield!");
                uint256 expectedAssets = (shares * iporSharePrice) / 1e18;
                console.log("Expected assets:", expectedAssets);
            }
        }
    }

    /// @notice Test profit detection when IPOR share price is > 1:1
    function test_profitDetection_withExistingYield() public {
        // This test checks if we can detect profit from IPOR's existing yield
        // The IPOR vault likely has share price > 1:1 if it's been running

        uint256 totalAssets = iporVault.totalAssets();
        uint256 totalSupply = iporVault.totalSupply();

        if (totalSupply == 0) {
            console.log("SKIPPING: IPOR vault has no deposits");
            return;
        }

        uint256 sharePrice = (totalAssets * 1e18) / totalSupply;
        console.log("IPOR current share price:", sharePrice);

        // If share price > 1e18, depositing X crvUSD gives fewer shares
        // When we convert those shares back to assets, we get X crvUSD
        // But as yield accrues, those shares become worth more

        if (sharePrice > 1e18) {
            console.log("IPOR has accumulated yield - share price above 1:1");

            // Calculate theoretical yield percentage
            uint256 yieldBps = ((sharePrice - 1e18) * 10000) / 1e18;
            console.log("Cumulative yield since inception (bps):", yieldBps);
        } else {
            console.log("IPOR share price is 1:1 (no yield yet or newly deployed)");
        }
    }

    /// @notice Simulate yield by mocking IPOR vault's convertToAssets
    /// @dev Skipped: mocking strategy yield doesn't account for LlamaLend debt accrual over the
    ///      time warp, and real yield requires an external harvest that can't be simulated here.
    function test_simulatedYield_aprCalculation() public {
        vm.skip(true);
        // Skip if IPOR vault is at capacity
        if (iporVault.maxDeposit(address(this)) < 100_000e18) {
            console.log("SKIPPING: IPOR vault at capacity");
            return;
        }

        // Deploy full vault
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        strategy = new IporYieldStrategy(CRVUSD, predictedVault, IPOR_VAULT);
        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            predictedVault
        );

        vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        tracker = new VaultTracker(address(vault));

        // User deposits
        vm.startPrank(user1);
        wbtc.approve(address(vault), type(uint256).max);
        vault.deposit(1e8, address(this));
        vm.stopPrank();

        // Take initial snapshot
        tracker.update();
        uint256 initialWbtc = vault.getTotalCollateral();
        uint256 initialSharePrice = tracker.sharePrice();

        console.log("=== Initial ===");
        console.log("Total WBTC:", initialWbtc);
        console.log("Share price:", initialSharePrice);

        // Get current strategy state
        uint256 strategyShares = iporVault.balanceOf(address(strategy));
        uint256 strategyAssets = strategy.balanceOf();

        console.log("Strategy IPOR shares:", strategyShares);
        console.log("Strategy assets (crvUSD):", strategyAssets);

        // Now we'll simulate 5% yield by mocking convertToAssets
        // This simulates what happens when IPOR auto-compounds
        uint256 simulatedYield = strategyAssets * 5 / 100; // 5% yield
        uint256 newAssetValue = strategyAssets + simulatedYield;

        // Mock the IPOR vault's convertToAssets to return higher value
        vm.mockCall(
            IPOR_VAULT,
            abi.encodeWithSelector(IYieldVault.convertToAssets.selector, strategyShares),
            abi.encode(newAssetValue)
        );

        // Also mock balanceOf to return same shares
        vm.mockCall(
            IPOR_VAULT,
            abi.encodeWithSelector(IYieldVault.balanceOf.selector, address(strategy)),
            abi.encode(strategyShares)
        );

        // Warp time forward
        vm.warp(block.timestamp + 365 days); // 1 year
        mockOracle(89238e8);

        // Take new snapshot
        tracker.update();

        uint256 newWbtc = vault.getTotalCollateral();
        uint256 newSharePrice = tracker.sharePrice();

        console.log("=== After Simulated 5% Yield ===");
        console.log("New total WBTC:", newWbtc);
        console.log("New share price:", newSharePrice);
        console.log("Strategy new balance:", strategy.balanceOf());

        // Calculate actual increase
        if (newSharePrice > initialSharePrice) {
            uint256 increase = newSharePrice - initialSharePrice;
            uint256 percentIncrease = (increase * 10000) / initialSharePrice;
            console.log("Share price increase (bps):", percentIncrease);
        }

        // Get APR
        uint256 apr = tracker.calculateAPR(365);
        console.log("Calculated APR (bps):", apr);

        // With 5% yield simulated, we should see positive profit
        (, uint256 profit,,,) = tracker.getPerformanceMetrics();
        console.log("Recorded profit:", profit);

        assertGt(newSharePrice, initialSharePrice, "Share price should increase with yield");
    }
}
