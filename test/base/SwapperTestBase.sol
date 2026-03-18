// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { BaseSwapper } from "../../src/swappers/base/BaseSwapper.sol";
import { ISwapper } from "../../src/interfaces/ISwapper.sol";

/// @title SwapperTestBase
/// @notice Abstract base for swapper unit tests. Provides shared governance,
///         slippage validation, cancellation, and zero-amount edge case tests.
abstract contract SwapperTestBase is Test {
    address owner = makeAddr("owner");
    address nonGov = makeAddr("nonGov");

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        }
        _deploySwapper();
    }

    /// @notice Deploy the swapper under test. Must set _swapper() and optionally _iswapper().
    function _deploySwapper() internal virtual;

    /// @notice The BaseSwapper instance under test
    function _swapper() internal view virtual returns (BaseSwapper);

    /// @notice Whether this swapper implements ISwapper (false for reward swappers like CrvToCrvUsd)
    function _implementsISwapper() internal pure virtual returns (bool) {
        return true;
    }

    /// @notice The ISwapper instance (only valid if _implementsISwapper() is true)
    function _iswapper() internal view virtual returns (ISwapper) {
        return ISwapper(address(_swapper()));
    }

    // ============ Governance Tests ============

    function test_governance() public {
        BaseSwapper s = _swapper();

        assertEq(s.gov(), owner, "Initial gov should be owner");
        assertEq(s.slippage(), 1e16, "Initial slippage should be 1%");

        // Unauthorized access
        vm.prank(nonGov);
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        s.proposeSlippage(10e16);

        // Propose and execute slippage
        vm.prank(owner);
        s.proposeSlippage(10e16);

        vm.prank(owner);
        vm.expectRevert();
        s.executeSlippage();

        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        s.executeSlippage();
        assertEq(s.slippage(), 10e16, "Slippage should be updated");

        // Governance transfer
        address newGov = makeAddr("newGov");
        vm.prank(owner);
        s.transferGovernance(newGov);

        vm.prank(newGov);
        s.acceptGovernance();
        assertEq(s.gov(), newGov, "Governance should be transferred");
    }

    function test_slippage_validation() public {
        BaseSwapper s = _swapper();

        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        s.proposeSlippage(0);

        vm.prank(owner);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        s.proposeSlippage(1e18 + 1);
    }

    function test_slippage_cancellation() public {
        BaseSwapper s = _swapper();

        vm.prank(owner);
        s.proposeSlippage(10e16);

        vm.prank(owner);
        s.cancelSlippage();

        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        vm.expectRevert();
        s.executeSlippage();
    }

    // ============ ISwapper Zero-Amount Tests ============

    function test_zero_quote() public {
        if (!_implementsISwapper()) return;
        assertEq(_iswapper().quoteCollateralForDebt(0), 0, "Zero quote should return zero");
    }

    function test_zero_swapCollateralForDebt() public {
        if (!_implementsISwapper()) return;
        assertEq(_iswapper().swapCollateralForDebt(0), 0, "Zero swap should return zero");
    }

    function test_zero_swapDebtForCollateral() public {
        if (!_implementsISwapper()) return;
        assertEq(_iswapper().swapDebtForCollateral(0), 0, "Zero swap should return zero");
    }
}
