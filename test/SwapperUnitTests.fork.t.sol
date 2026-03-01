// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";
import { CurveThreeCryptoSwapper } from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @title SwapperUnitTests
/// @notice Unit tests for swapper contracts to increase coverage
contract SwapperUnitTests is Test {
    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;

    address constant WBTC_WHALE = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    // Oracle addresses
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    address owner = makeAddr("owner");
    address nonGov = makeAddr("nonGov");

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        }
    }

    /// @notice Test CurveTwoCryptoSwapper governance functions
    function test_curveTwoCryptoSwapper_governance() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE);

        // Test initial state
        assertEq(swapper.gov(), owner, "Initial gov should be owner");
        assertEq(swapper.slippage(), 1e16, "Initial slippage should be 1%");

        // Test unauthorized access
        vm.prank(nonGov);
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.proposeSlippage(10e16);

        // Test slippage proposal
        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        // Test executing too early
        vm.prank(owner);
        vm.expectRevert(); // Should revert due to timelock
        swapper.executeSlippage();

        // Wait for timelock and execute
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        swapper.executeSlippage();

        assertEq(swapper.slippage(), 10e16, "Slippage should be updated");

        // Test governance transfer
        address newGov = makeAddr("newGov");
        vm.prank(owner);
        swapper.transferGovernance(newGov);

        vm.prank(newGov);
        swapper.acceptGovernance();

        assertEq(swapper.gov(), newGov, "Governance should be transferred");
    }

    /// @notice Test CurveTwoCryptoSwapper slippage validation
    function test_curveTwoCryptoSwapper_slippage_validation() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE);

        // Test zero slippage
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(0);

        // Test excessive slippage
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(1e18 + 1); // > 100%
    }

    /// @notice Test CurveTwoCryptoSwapper slippage cancellation
    function test_curveTwoCryptoSwapper_slippage_cancellation() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE);

        // Propose slippage
        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        // Cancel it
        vm.prank(owner);
        swapper.cancelSlippage();

        // Wait for original timelock and try to execute - should fail
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        vm.expectRevert(); // No pending slippage to execute
        swapper.executeSlippage();
    }

    /// @notice Test CurveThreeCryptoSwapper governance functions
    function test_curveThreeCryptoSwapper_governance() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        // Test initial state
        assertEq(swapper.gov(), owner, "Initial gov should be owner");
        assertEq(swapper.slippage(), 1e16, "Initial slippage should be 1%");

        // Test unauthorized access
        vm.prank(nonGov);
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.proposeSlippage(10e16);

        // Test slippage proposal and execution
        vm.prank(owner);
        swapper.proposeSlippage(8e16); // 8%

        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        swapper.executeSlippage();

        assertEq(swapper.slippage(), 8e16, "Slippage should be updated");

        // Test governance transfer
        address newGov = makeAddr("newGov");
        vm.prank(owner);
        swapper.transferGovernance(newGov);

        vm.prank(newGov);
        swapper.acceptGovernance();

        assertEq(swapper.gov(), newGov, "Governance should be transferred");
    }

    /// @notice Test CurveThreeCryptoSwapper slippage validation
    function test_curveThreeCryptoSwapper_slippage_validation() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        // Test zero slippage
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(0);

        // Test excessive slippage
        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(1e18 + 1); // > 100%
    }

    /// @notice Test CurveThreeCryptoSwapper slippage cancellation
    function test_curveThreeCryptoSwapper_slippage_cancellation() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        // Propose slippage
        vm.prank(owner);
        swapper.proposeSlippage(12e16); // 12%

        // Cancel it
        vm.prank(owner);
        swapper.cancelSlippage();

        // Wait and try to execute - should fail
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        vm.expectRevert(); // No pending slippage to execute
        swapper.executeSlippage();
    }

    /// @notice Test CurveTwoCryptoSwapper quote edge cases
    function test_curveTwoCryptoSwapper_quote_edge_cases() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE);

        // Test zero amount
        uint256 quote = swapper.quoteCollateralForDebt(0);
        assertEq(quote, 0, "Zero amount should return zero quote");
    }

    /// @notice Test CurveThreeCryptoSwapper quote edge cases
    function test_curveThreeCryptoSwapper_quote_edge_cases() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        // Test zero amount
        uint256 quote = swapper.quoteCollateralForDebt(0);
        assertEq(quote, 0, "Zero amount should return zero quote");
    }

    /// @notice Test CurveTwoCryptoSwapper swap edge cases
    function test_curveTwoCryptoSwapper_swap_edge_cases() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE);

        // Test zero swap
        uint256 received = swapper.swapCollateralForDebt(0);
        assertEq(received, 0, "Zero swap should return zero");

        received = swapper.swapDebtForCollateral(0);
        assertEq(received, 0, "Zero swap should return zero");
    }

    /// @notice Test CurveThreeCryptoSwapper swap edge cases
    function test_curveThreeCryptoSwapper_swap_edge_cases() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE);

        // Test zero swap
        uint256 received = swapper.swapCollateralForDebt(0);
        assertEq(received, 0, "Zero swap should return zero");

        received = swapper.swapDebtForCollateral(0);
        assertEq(received, 0, "Zero swap should return zero");
    }

    // ============ CbBtcWbtcUsdtSwapper Zero-Amount Tests ============

    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX_CB = 1;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;

    function test_cbBtcWbtcUsdtSwapper_zero_quote() public {
        CbBtcWbtcUsdtSwapper swapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX_CB,
            TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.quoteCollateralForDebt(0), 0, "Zero quote should return zero");
    }

    function test_cbBtcWbtcUsdtSwapper_zero_swapCollateralForDebt() public {
        CbBtcWbtcUsdtSwapper swapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX_CB,
            TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.swapCollateralForDebt(0), 0, "Zero swap should return zero");
    }

    function test_cbBtcWbtcUsdtSwapper_zero_swapDebtForCollateral() public {
        CbBtcWbtcUsdtSwapper swapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC, CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX_CB,
            TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.swapDebtForCollateral(0), 0, "Zero swap should return zero");
    }

    // ============ UniswapV3TwoHopSwapper Zero-Amount Tests ============

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WSTETH_USD_ORACLE = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 500;

    function test_uniswapV3TwoHopSwapper_zero_quote() public {
        UniswapV3TwoHopSwapper swapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            WSTETH_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.quoteCollateralForDebt(0), 0, "Zero quote should return zero");
    }

    function test_uniswapV3TwoHopSwapper_zero_swapCollateralForDebt() public {
        UniswapV3TwoHopSwapper swapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            WSTETH_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.swapCollateralForDebt(0), 0, "Zero swap should return zero");
    }

    function test_uniswapV3TwoHopSwapper_zero_swapDebtForCollateral() public {
        UniswapV3TwoHopSwapper swapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            WSTETH_USD_ORACLE, USDT_USD_ORACLE
        );
        assertEq(swapper.swapDebtForCollateral(0), 0, "Zero swap should return zero");
    }

    // ============ CrvToCrvUsdSwapper Zero-Amount Tests ============

    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    function test_crvToCrvUsdSwapper_zero_swap() public {
        CrvToCrvUsdSwapper swapper = new CrvToCrvUsdSwapper(owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE);
        assertEq(swapper.swap(0), 0, "Zero swap should return zero");
    }
}
