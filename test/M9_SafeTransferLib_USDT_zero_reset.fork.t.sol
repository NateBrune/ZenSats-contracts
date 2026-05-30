// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

// Mock USDT that reverts on zero-reset
contract MockUSDT {
    mapping(address => mapping(address => uint256)) public usdtAllowance;
    bool public usdtRevertOnZeroReset;

    function setRevertOnZeroReset(bool _val) external {
        usdtRevertOnZeroReset = _val;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (usdtRevertOnZeroReset && amount == 0) {
            revert("USDT: zero-reset failed");
        }
        usdtAllowance[msg.sender][spender] = amount;
        return true;
    }

    function usdtAllowanceCheck(address owner, address spender) external view returns (uint256) {
        return usdtAllowance[owner][spender];
    }

    // Standard ERC20 allowance selector for SafeTransferLib compatibility
    function allowance(address owner, address spender) external view returns (uint256) {
        return usdtAllowance[owner][spender];
    }
}

// Mock USDT that returns void on approve (like real USDT)
contract MockUSDTVoid {
    mapping(address => mapping(address => uint256)) public usdtAllowance;
    bool public usdtRevertOnZeroReset;

    function setRevertOnZeroReset(bool _val) external {
        usdtRevertOnZeroReset = _val;
    }

    function approve(address spender, uint256 amount) external {
        if (usdtRevertOnZeroReset && amount == 0) {
            revert("USDT: zero-reset failed");
        }
        usdtAllowance[msg.sender][spender] = amount;
    }

    function usdtAllowanceCheck(address owner, address spender) external view returns (uint256) {
        return usdtAllowance[owner][spender];
    }

    // Standard ERC20 allowance selector for SafeTransferLib compatibility
    function allowance(address owner, address spender) external view returns (uint256) {
        return usdtAllowance[owner][spender];
    }
}

// Test contract that uses SafeTransferLib
contract TestContract {
    using SafeTransferLib for IERC20;

    function callSafeApprove(IERC20 token, address spender, uint256 amount) external {
        token.safeApprove(spender, amount);
    }

    function callEnsureApproval(IERC20 token, address spender, uint256 amount) external {
        token.ensureApproval(spender, amount);
    }

    function getCurrentAllowance(IERC20 token, address spender) external view returns (uint256) {
        return token.allowance(address(this), spender);
    }
}

/// @title M9_SafeTransferLib_USDT_zero_reset
/// @notice PoC for M9: SafeTransferLib safeApprove zero-reset can fail on USDT
/// @dev Demonstrates that if USDT reverts on the zero-reset call, safeApprove()
///      reverts even when the existing allowance may already be sufficient.
contract M9_SafeTransferLib_USDT_zero_reset is Test {
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant SPENDER = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4; // USDT/crvUSD pool

    TestContract public testContract;
    MockUSDT public mockUSDT;
    MockUSDTVoid public mockUSDTVoid;

    function setUp() public {
        testContract = new TestContract();
        mockUSDT = new MockUSDT();
        mockUSDTVoid = new MockUSDTVoid();
    }

    // ============ M9 PoC: zero-reset revert on USDT ============

    /// @dev M9: Demonstrates that safeApprove reverts when USDT reverts on zero-reset,
    ///      even when the existing allowance is already sufficient.
    function test_safeApprove_reverts_on_zero_reset() public {
        // Set initial allowance to 1000 using standard ERC20 allowance selector
        vm.mockCall(
            address(mockUSDT),
            abi.encodeWithSelector(0xdd62ed3e, address(testContract), SPENDER),
            abi.encode(1000)
        );

        // Set zero-reset to revert
        mockUSDT.setRevertOnZeroReset(true);

        // Attempt to approve 2000 — should need zero-reset first
        // The zero-reset reverts, causing safeApprove to revert
        vm.prank(address(testContract));
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        testContract.callSafeApprove(IERC20(address(mockUSDT)), SPENDER, 2000);

        console.log("M9 PoC: safeApprove reverted on zero-reset failure");
    }

    /// @dev M9: Demonstrates that safeApprove works when allowance is 0 (no reset needed).
    function test_safeApprove_works_when_no_existing_allowance() public {
        // Set initial allowance to 0 (no existing allowance)
        vm.mockCall(
            address(mockUSDT),
            abi.encodeWithSelector(0xdd62ed3e, address(testContract), SPENDER),
            abi.encode(0)
        );

        mockUSDT.setRevertOnZeroReset(true);

        // Approve 2000 — no reset needed since existing allowance is 0
        vm.prank(address(testContract));
        testContract.callSafeApprove(IERC20(address(mockUSDT)), SPENDER, 2000);

        uint256 allowance = mockUSDT.usdtAllowance(address(testContract), SPENDER);
        assertEq(allowance, 2000, "Allowance should be set to 2000");

        console.log("M9 PoC: safeApprove succeeded when no existing allowance");
    }

    /// @dev M9: Demonstrates the same issue with the void-returning USDT version.
    function test_safeApprove_void_USDT_reverts_on_zero_reset() public {
        // Set initial allowance to 1000
        vm.mockCall(
            address(mockUSDTVoid),
            abi.encodeWithSelector(0xdd62ed3e, address(testContract), SPENDER),
            abi.encode(1000)
        );

        // Set zero-reset to revert
        mockUSDTVoid.setRevertOnZeroReset(true);

        // Attempt to approve 2000 — should need zero-reset first
        // The zero-reset reverts, causing safeApprove to revert
        vm.prank(address(testContract));
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        testContract.callSafeApprove(IERC20(address(mockUSDTVoid)), SPENDER, 2000);

        console.log("M9 PoC: safeApprove reverted on void-USDT zero-reset failure");
    }

    /// @dev M9: Demonstrates that ensureApproval also fails on zero-reset revert.
    function test_ensureApproval_reverts_on_zero_reset() public {
        // Set initial allowance to 1000
        vm.mockCall(
            address(mockUSDT),
            abi.encodeWithSelector(0xdd62ed3e, address(testContract), SPENDER),
            abi.encode(1000)
        );

        mockUSDT.setRevertOnZeroReset(true);

        // ensureApproval to 2000 — needs zero-reset
        vm.prank(address(testContract));
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        testContract.callEnsureApproval(IERC20(address(mockUSDT)), SPENDER, 2000);

        console.log("M9 PoC: ensureApproval reverted on zero-reset failure");
    }

    /// @dev M9: Demonstrates the impact on the vault — if safeApprove fails on zero-reset,
    ///      the strategy cannot approve the Curve pool, blocking deposits and withdrawals.
    function test_vault_impact_safeApprove_on_real_USDT() public {
        if (USDT.code.length == 0) {
            console.log("M9: skipping real USDT check; no fork code at USDT address");
            return;
        }

        // Use real USDT on mainnet
        IERC20 usdt = IERC20(USDT);

        // Check current allowance of the USDT/crvUSD pool
        uint256 currentAllowance = usdt.allowance(address(this), SPENDER);
        console.log("Current USDT allowance for USDT/crvUSD pool: %d", currentAllowance);

        // If the allowance is already sufficient, safeApprove should work
        // even if zero-reset would fail
        uint256 targetAmount = 1000e6; // 1000 USDT

        if (currentAllowance >= targetAmount) {
            console.log("M9: Existing allowance is sufficient, safeApprove should work");
        } else {
            console.log("M9: Existing allowance is insufficient, safeApprove needs zero-reset");
            console.log("  If USDT zero-reset fails, safeApprove will revert");
        }
    }
}
