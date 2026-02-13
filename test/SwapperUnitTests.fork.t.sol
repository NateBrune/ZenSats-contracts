// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { CurveTwoCryptoSwapper } from "../src/CurveTwoCryptoSwapper.sol";
import { CurveThreeCryptoSwapper } from "../src/CurveThreeCryptoSwapper.sol";
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
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        // Test initial state
        assertEq(swapper.gov(), owner, "Initial gov should be owner");
        assertEq(swapper.slippage(), 5e16, "Initial slippage should be 5%");

        // Test unauthorized access
        vm.prank(nonGov);
        vm.expectRevert(CurveTwoCryptoSwapper.Unauthorized.selector);
        swapper.proposeSlippage(10e16);

        // Test slippage proposal
        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        // Test executing too early
        vm.prank(owner);
        vm.expectRevert(); // Should revert due to timelock
        swapper.executeSlippage();

        // Wait for timelock and execute
        vm.warp(block.timestamp + 2 days + 1);
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
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        // Test zero slippage
        vm.prank(owner);
        vm.expectRevert(CurveTwoCryptoSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(0);

        // Test excessive slippage
        vm.prank(owner);
        vm.expectRevert(CurveTwoCryptoSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(1e18 + 1); // > 100%
    }

    /// @notice Test CurveTwoCryptoSwapper slippage cancellation
    function test_curveTwoCryptoSwapper_slippage_cancellation() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        // Propose slippage
        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        // Cancel it
        vm.prank(owner);
        swapper.cancelSlippage();

        // Wait for original timelock and try to execute - should fail
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(owner);
        vm.expectRevert(); // No pending slippage to execute
        swapper.executeSlippage();
    }

    /// @notice Test CurveThreeCryptoSwapper governance functions
    function test_curveThreeCryptoSwapper_governance() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0);

        // Test initial state
        assertEq(swapper.gov(), owner, "Initial gov should be owner");
        assertEq(swapper.slippage(), 5e16, "Initial slippage should be 5%");

        // Test unauthorized access
        vm.prank(nonGov);
        vm.expectRevert(CurveThreeCryptoSwapper.Unauthorized.selector);
        swapper.proposeSlippage(10e16);

        // Test slippage proposal and execution
        vm.prank(owner);
        swapper.proposeSlippage(8e16); // 8%

        vm.warp(block.timestamp + 2 days + 1);
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
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0);

        // Test zero slippage
        vm.prank(owner);
        vm.expectRevert(CurveThreeCryptoSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(0);

        // Test excessive slippage
        vm.prank(owner);
        vm.expectRevert(CurveThreeCryptoSwapper.InvalidSlippage.selector);
        swapper.proposeSlippage(1e18 + 1); // > 100%
    }

    /// @notice Test CurveThreeCryptoSwapper slippage cancellation
    function test_curveThreeCryptoSwapper_slippage_cancellation() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0);

        // Propose slippage
        vm.prank(owner);
        swapper.proposeSlippage(12e16); // 12%

        // Cancel it
        vm.prank(owner);
        swapper.cancelSlippage();

        // Wait and try to execute - should fail
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(owner);
        vm.expectRevert(); // No pending slippage to execute
        swapper.executeSlippage();
    }

    /// @notice Test CurveTwoCryptoSwapper quote edge cases
    function test_curveTwoCryptoSwapper_quote_edge_cases() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        // Test zero amount
        uint256 quote = swapper.quoteCollateralForDebt(0);
        assertEq(quote, 0, "Zero amount should return zero quote");
    }

    /// @notice Test CurveThreeCryptoSwapper quote edge cases
    function test_curveThreeCryptoSwapper_quote_edge_cases() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0);

        // Test zero amount
        uint256 quote = swapper.quoteCollateralForDebt(0);
        assertEq(quote, 0, "Zero amount should return zero quote");
    }

    /// @notice Test CurveTwoCryptoSwapper swap edge cases
    function test_curveTwoCryptoSwapper_swap_edge_cases() public {
        CurveTwoCryptoSwapper swapper =
            new CurveTwoCryptoSwapper(owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0);

        // Test zero swap
        uint256 received = swapper.swapCollateralForDebt(0);
        assertEq(received, 0, "Zero swap should return zero");

        received = swapper.swapDebtForCollateral(0);
        assertEq(received, 0, "Zero swap should return zero");
    }

    /// @notice Test CurveThreeCryptoSwapper swap edge cases
    function test_curveThreeCryptoSwapper_swap_edge_cases() public {
        CurveThreeCryptoSwapper swapper =
            new CurveThreeCryptoSwapper(owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0);

        // Test zero swap
        uint256 received = swapper.swapCollateralForDebt(0);
        assertEq(received, 0, "Zero swap should return zero");

        received = swapper.swapDebtForCollateral(0);
        assertEq(received, 0, "Zero swap should return zero");
    }
}
