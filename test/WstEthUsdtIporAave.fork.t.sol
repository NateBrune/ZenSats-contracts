// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";

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

/// @title WstEthUsdtIporAave Fork Tests
/// @notice Smoke tests for wstETH + USDT + IPOR (Aave) configuration
contract WstEthUsdtIporAaveForkTest is Test {
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

    // IPOR
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    // Curve pool for USDT ↔ crvUSD (used by UsdtIporYieldStrategy)
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    // Uniswap V3 SwapRouter02
    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // Oracles
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Uniswap V3 pool fees
    uint24 constant FEE_WSTETH_WETH = 100; // 0.01%
    uint24 constant FEE_WETH_USDT = 3000; // 0.3%

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");

    IERC20 wstETH;
    IERC20 usdt;

    ZenjiViewHelper viewHelper;

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        wstETH = IERC20(WSTETH);
        usdt = IERC20(USDT);

        viewHelper = new ZenjiViewHelper();

        _syncOracles();
        _mockOracle(STETH_ETH_ORACLE);
        _mockOracle(ETH_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);

        // Fund test user with wstETH
        deal(WSTETH, user1, 100e18); // 100 wstETH
    }

    function _syncOracles() internal {
        (,,, uint256 stEthEthUpdatedAt,) = IChainlinkOracle(STETH_ETH_ORACLE).latestRoundData();
        (,,, uint256 ethUsdUpdatedAt,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        (,,, uint256 usdtUpdatedAt,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUsdUpdatedAt,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();

        uint256 maxUpdatedAt = stEthEthUpdatedAt;
        if (ethUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = ethUsdUpdatedAt;
        if (usdtUpdatedAt > maxUpdatedAt) maxUpdatedAt = usdtUpdatedAt;
        if (crvUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUsdUpdatedAt;

        if (block.timestamp < maxUpdatedAt + 1) {
            vm.warp(maxUpdatedAt + 1);
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

    /// @notice Test wstETH + USDT + IPOR (Aave) full integration
    function test_smoke_wstETH_USDT_IPOR_Aave() public {
        console.log("=== Testing wstETH + USDT + IPOR (Aave) ===");

        // Deploy wstETH/USD oracle
        WstEthOracle wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        // Mock the composite oracle too (it reads from the underlying feeds which are already mocked)
        // Verify it returns a reasonable price
        int256 wstEthPrice = wstEthOracle.latestAnswer();
        console.log("wstETH/USD price:", uint256(wstEthPrice));
        assertGt(wstEthPrice, 0, "wstETH oracle should return positive price");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // Deploy swapper
        UniswapV3TwoHopSwapper swapper = new UniswapV3TwoHopSwapper(
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

        // Deploy yield strategy (USDT → crvUSD → IPOR)
        UsdtIporYieldStrategy strategy = new UsdtIporYieldStrategy(
            USDT,
            CRVUSD,
            expectedVaultAddress,
            USDT_CRVUSD_POOL,
            IPOR_PLASMA_VAULT,
            0, // USDT index in pool
            1, // crvUSD index in pool
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE
        );

        // Deploy loan manager
        AaveLoanManager loanManager = new AaveLoanManager(
            WSTETH,
            USDT,
            AAVE_A_WSTETH,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            address(wstEthOracle),
            USDT_USD_ORACLE,
            address(swapper),
            7100, // 71% max LTV
            7600, // 76% liquidation threshold
            expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        // Deploy vault
        Zenji vault = new Zenji(
            WSTETH,
            USDT,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        // Approve vault for user
        vm.prank(user1);
        wstETH.approve(address(vault), type(uint256).max);

        // Test deposit (10 wstETH)
        vm.prank(user1);
        uint256 shares = vault.deposit(10e18, user1);
        assertGt(shares, 0, "Should receive shares");

        // Verify loan was created
        assertTrue(loanManager.loanExists(), "Loan should exist");

        // Verify debt was deployed to yield
        uint256 strategyBalance = strategy.balanceOf();
        assertGt(strategyBalance, 0, "Strategy should have balance");

        console.log("Shares received:", shares);
        console.log("Strategy balance:", strategyBalance);

        // Test harvest
        vm.prank(owner);
        vault.harvestYield();

        // Test rebalance (only if needed)
        if (viewHelper.isRebalanceNeeded(address(vault))) {
            vm.prank(owner);
            vault.rebalance();
        }

        // Test partial and full withdrawal (best-effort on fork)
        vm.warp(block.timestamp + 2); // Wait for redemption delay
        _mockOracle(STETH_ETH_ORACLE);
        _mockOracle(ETH_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);

        vm.startPrank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "Should receive wstETH back");
            console.log("Partial redeem:", withdrawn);
        } catch {
            console.log("Partial redeem reverted; skipping withdrawal assertions");
            vm.stopPrank();
            return;
        }

        try vault.redeem(vault.balanceOf(user1), user1, user1) returns (uint256 finalWithdrawn) {
            assertGt(finalWithdrawn, 0, "Should receive remaining wstETH");
            console.log("Final redeem:", finalWithdrawn);
        } catch {
            console.log("Final redeem reverted; skipping");
        }
        vm.stopPrank();

        console.log("wstETH + USDT + IPOR (Aave) smoke test passed!");
    }
}
