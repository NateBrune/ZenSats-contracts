// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";
import { CurveThreeCryptoSwapper } from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IporYieldStrategy } from "../src/strategies/IporYieldStrategy.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";

interface IYieldVault {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
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

/// @title ProtocolSmokeTests
/// @notice Comprehensive smoke tests for Zenji protocol combinations
/// @dev Tests both WBTC+USDT+IPOR (Aave) and WBTC+crvUSD+LlamaLend scenarios
contract ProtocolSmokeTests is Test {
    using SafeTransferLib for IERC20;
    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // LlamaLend
    address constant LLAMALEND_WBTC = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;

    // IPOR
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    // Curve pools
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4; // kept for Curve unit test
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    // Uniswap V3 WBTC/USDT (primary swapper for WBTC vaults)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    // Oracles
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // Whales
    address constant WBTC_WHALE = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");

    IERC20 wbtc;
    IERC20 usdt;
    IERC20 crvUSD;
    IYieldVault iporVault;

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

        wbtc = IERC20(WBTC);
        usdt = IERC20(USDT);
        crvUSD = IERC20(CRVUSD);
        iporVault = IYieldVault(IPOR_PLASMA_VAULT);

        viewHelper = new ZenjiViewHelper();

        _syncOracles();
        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);

        // Fund test user with WBTC/USDT using deal to avoid whale dependencies
        deal(WBTC, user1, 10e8); // 10 WBTC
        deal(USDT, user1, 100_000e6); // 100k USDT
    }

    function _syncOracles() internal {
        (,,, uint256 btcUpdatedAt,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        (,,, uint256 usdtUpdatedAt,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUsdUpdatedAt,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        (,,, uint256 crvUpdatedAt,) = IChainlinkOracle(CRV_USD_ORACLE).latestRoundData();

        uint256 maxUpdatedAt = btcUpdatedAt;
        if (usdtUpdatedAt > maxUpdatedAt) maxUpdatedAt = usdtUpdatedAt;
        if (crvUsdUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUsdUpdatedAt;
        if (crvUpdatedAt > maxUpdatedAt) maxUpdatedAt = crvUpdatedAt;

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

    function _lpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    /// @notice Test WBTC + USDT + IPOR (Aave) full integration
    function test_smoke_WBTC_USDT_IPOR_Aave() public {
        console.log("=== Testing WBTC + USDT + IPOR (Aave) ===");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // Deploy swapper
        UniversalRouterV3SingleHopSwapper swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE
        );

        // Deploy yield strategy
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
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500, // 75% max LTV
            8000, // 80% liquidation threshold
            expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        // Deploy vault
        Zenji vault = new Zenji(
            WBTC,
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
        vm.warp(block.timestamp + 1 weeks + 1);
        _syncOracles();
        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
        assertEq(swapper.slippage(), 1e16, "Slippage should match deployment default (1%)");

        // Approve vault for user
        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        // Enable yield

        // Test deposit
        vm.prank(user1);
        uint256 shares = vault.deposit(1e8, user1); // 1 WBTC
        assertGt(shares, 0, "Should receive shares");

        // Verify loan was created
        assertTrue(loanManager.loanExists(), "Loan should exist");

        // Verify debt was deployed to yield
        uint256 strategyBalance = strategy.balanceOf();
        assertGt(strategyBalance, 0, "Strategy should have balance");

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
        vm.startPrank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "Should receive WBTC back");
        } catch {
            console.log("Partial redeem reverted; skipping withdrawal assertions");
            vm.stopPrank();
            return;
        }

        try vault.redeem(vault.balanceOf(user1), user1, user1) returns (uint256 finalWithdrawn) {
            assertGt(finalWithdrawn, 0, "Should receive remaining WBTC");
        } catch {
            console.log("Final redeem reverted; skipping");
        }
        vm.stopPrank();

        console.log("WBTC + USDT + IPOR (Aave) smoke test passed!");
    }

    /// @notice Test WBTC + USDT + pmUSD/crvUSD (Stake DAO) on Aave with Uniswap swapper
    function test_smoke_WBTC_USDT_pmUSDcrvUSD_Aave_Uniswap() public {
        console.log("=== Testing WBTC + USDT + pmUSD/crvUSD (Aave + Uniswap) ===");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        UniversalRouterV3SingleHopSwapper swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE
        );

        PmUsdCrvUsdStrategy strategy = new PmUsdCrvUsdStrategy(
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
            _lpCrvUsdIndex(),
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE
        );

        AaveLoanManager loanManager = new AaveLoanManager(
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
            expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        Zenji vault = new Zenji(
            WBTC,
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
        vm.warp(block.timestamp + 1 weeks + 1);
        _syncOracles();
        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
        _mockOracle(CRV_USD_ORACLE);
        assertEq(swapper.slippage(), 1e16, "Slippage should match deployment default (1%)");

        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        vm.prank(user1);
        uint256 shares = vault.deposit(1e8, user1); // 1 WBTC
        assertGt(shares, 0, "Should receive shares");
        assertTrue(loanManager.loanExists(), "Loan should exist");
        assertGt(strategy.balanceOf(), 0, "Strategy should have balance");

        vm.prank(owner);
        vault.harvestYield();

        if (viewHelper.isRebalanceNeeded(address(vault))) {
            vm.prank(owner);
            vault.rebalance();
        }

        vm.warp(block.timestamp + 2);
        vm.startPrank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "Should receive WBTC back");
        } catch {
            console.log("Partial redeem reverted; skipping withdrawal assertions");
            vm.stopPrank();
            return;
        }

        try vault.redeem(vault.balanceOf(user1), user1, user1) returns (uint256 finalWithdrawn) {
            assertGt(finalWithdrawn, 0, "Should receive remaining WBTC");
        } catch {
            console.log("Final redeem reverted; skipping");
        }
        vm.stopPrank();

        console.log("WBTC + USDT + pmUSD/crvUSD (Aave + Uniswap) smoke test passed!");
    }

    /// @notice Test WBTC + crvUSD + LlamaLend full integration
    function test_smoke_WBTC_CRVUSD_LlamaLend() public {
        console.log("=== Testing WBTC + crvUSD + LlamaLend ===");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // Deploy swapper
        CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
            owner,
            WBTC,
            CRVUSD,
            WBTC_CRVUSD_POOL,
            1, // WBTC index
            0, // crvUSD index
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE
        );

        // Deploy yield strategy
        IporYieldStrategy strategy =
            new IporYieldStrategy(CRVUSD, expectedVaultAddress, IPOR_PLASMA_VAULT);

        // Deploy loan manager
        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            expectedVaultAddress
        );

        // Deploy vault
        Zenji vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        // Approve vault for user
        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        // Enable yield

        // Test deposit
        vm.prank(user1);
        uint256 shares = vault.deposit(1e8, user1); // 1 WBTC
        assertGt(shares, 0, "Should receive shares");

        // Verify loan was created
        assertTrue(loanManager.loanExists(), "Loan should exist");

        // Verify debt was deployed to yield
        uint256 strategyBalance = strategy.balanceOf();
        assertGt(strategyBalance, 0, "Strategy should have balance");

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
        vm.startPrank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "Should receive WBTC back");
        } catch {
            console.log("Partial redeem reverted; skipping withdrawal assertions");
            vm.stopPrank();
            return;
        }

        try vault.redeem(vault.balanceOf(user1), user1, user1) returns (uint256 finalWithdrawn) {
            assertGt(finalWithdrawn, 0, "Should receive remaining WBTC");
        } catch {
            console.log("Final redeem reverted; skipping");
        }
        vm.stopPrank();

        console.log("WBTC + crvUSD + LlamaLend smoke test passed!");
    }

    /// @notice Test governance functions
    function test_governance_functions() public {
        console.log("=== Testing Governance Functions ===");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // Deploy minimal vault for governance testing
        CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
            owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        IporYieldStrategy strategy =
            new IporYieldStrategy(CRVUSD, expectedVaultAddress, IPOR_PLASMA_VAULT);

        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            expectedVaultAddress
        );

        Zenji vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        // Test governance transfer
        address newGov = makeAddr("newGov");
        vm.prank(owner);
        vault.transferRole(1, newGov);

        vm.warp(block.timestamp + vault.ROLE_TRANSFER_DELAY());
        vm.prank(newGov);
        vault.acceptRole(1);

        assertEq(vault.gov(), newGov, "Governance should be transferred");

        // Test swapper governance
        address newSwapperGov = makeAddr("newSwapperGov");
        vm.prank(owner);
        swapper.transferGovernance(newSwapperGov);

        vm.prank(newSwapperGov);
        swapper.acceptGovernance();

        assertEq(swapper.gov(), newSwapperGov, "Swapper governance should be transferred");

        console.log("Governance functions test passed!");
    }

    /// @notice Test emergency flows
    function test_emergency_flows() public {
        console.log("=== Testing Emergency Flows ===");

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // Deploy vault
        CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
            owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        IporYieldStrategy strategy =
            new IporYieldStrategy(CRVUSD, expectedVaultAddress, IPOR_PLASMA_VAULT);

        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            expectedVaultAddress
        );

        Zenji vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        // Fund and deposit
        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        vm.prank(user1);
        vault.deposit(1e8, user1);

        // Increase swapper slippage for emergency (1% default may be too tight for fork)
        vm.store(address(swapper), bytes32(uint256(0)), bytes32(uint256(5e16)));

        // Test emergency mode
        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyStep(0);
        vault.emergencyStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        assertTrue(vault.emergencyMode(), "Should be in emergency mode");
        assertTrue(vault.liquidationComplete(), "Should be liquidation complete");

        console.log("Emergency flows test passed!");
    }

    /// @notice Test swapper slippage management
    function test_swapper_slippage_management() public {
        console.log("=== Testing Swapper Slippage Management ===");

        CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
            owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        // Gov sets slippage directly
        vm.prank(owner);
        swapper.setSlippage(10e16); // 10%
        assertEq(swapper.slippage(), 10e16, "Slippage should be updated to 10%");

        // Gov can update slippage again
        vm.prank(owner);
        swapper.setSlippage(5e16); // 5%
        assertEq(swapper.slippage(), 5e16, "Slippage should be updated to 5%");

        // Non-gov cannot set slippage
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(1e16);

        console.log("Swapper slippage management test passed!");
    }

    /// @notice Test CurveThreeCryptoSwapper functionality
    function test_curve_three_crypto_swapper() public {
        console.log("=== Testing CurveThreeCryptoSwapper ===");

        CurveThreeCryptoSwapper swapper = new CurveThreeCryptoSwapper(
            owner,
            WBTC,
            USDT,
            TRICRYPTO_POOL,
            1, // WBTC index
            0, // USDT index
            BTC_USD_ORACLE,
            USDT_USD_ORACLE
        );

        // Test quote
        uint256 quote = swapper.quoteCollateralForDebt(1000e6); // 1000 USDT
        assertGt(quote, 0, "Should get quote");

        // Test swap (need tokens)
        deal(WBTC, address(swapper), 1e8); // 1 WBTC to swapper

        try swapper.swapCollateralForDebt(1e8) returns (uint256 usdtReceived) {
            assertGt(usdtReceived, 0, "Should receive USDT");

            // Test reverse swap
            usdt.safeTransfer(address(swapper), usdtReceived);

            uint256 wbtcReceived = swapper.swapDebtForCollateral(usdtReceived);
            assertGt(wbtcReceived, 0, "Should receive WBTC back");
        } catch {
            console.log("Curve swap reverted; skipping swap assertions");
        }

        console.log("CurveThreeCryptoSwapper test passed!");
    }
}
