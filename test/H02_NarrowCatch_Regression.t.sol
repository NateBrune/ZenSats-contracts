// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================
// H-02 FIX REGRESSION
// The broad `catch {}` in unwindPosition's partial-repay path previously escalated ANY
// llamaLend.repay() revert into a destructive, flash-loan-dependent full close. It now
// escalates ONLY LlamaLend's dust assertion ("Amount too low"); every other revert
// surfaces as PartialRepayFailed (fail-safe), so a transient controller fault no longer
// socializes exit costs or forces the hardcoded flash lender.
//
// This test drives a PARTIAL unwind whose repay reverts with a NON-dust reason and asserts
// the call now reverts with PartialRepayFailed rather than reaching the flash path.
// ============================================================

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockFreshOracle {
    uint8 public constant decimals = 8;

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1));
    }
}

/// @notice Controller whose partial repay() reverts with a NON-dust reason.
contract MockControllerNonDustRevert {
    uint256 public dbt;

    function setDebt(uint256 d) external {
        dbt = d;
    }

    function loan_exists(address) external pure returns (bool) {
        return true;
    }

    function debt(address) external view returns (uint256) {
        return dbt;
    }

    function user_state(address) external view returns (uint256[4] memory s) {
        s[0] = 100e8; // collateral
        s[1] = 0;
        s[2] = dbt;
        s[3] = 0;
    }

    function repay(uint256) external pure {
        // Simulates a transient controller fault (pause, etc.) — NOT the dust assertion.
        revert("Controller paused");
    }
}

contract H02_NarrowCatch_Regression is Test {
    LlamaLoanManager mgr;
    MockToken collateral;
    MockToken debtToken;
    MockControllerNonDustRevert controller;

    function setUp() public {
        vm.warp(2_000_000);
        collateral = new MockToken("WBTC", "WBTC", 8);
        debtToken = new MockToken("crvUSD", "crvUSD", 18);
        controller = new MockControllerNonDustRevert();
        controller.setDebt(100e18);

        MockFreshOracle oracle = new MockFreshOracle();

        mgr = new LlamaLoanManager(
            address(collateral),
            address(debtToken),
            address(controller),
            makeAddr("pool"),
            address(oracle),
            address(oracle),
            makeAddr("swapper"),
            address(this), // vault = this test, so we can call unwindPosition
            3600
        );

        // Give the manager debt tokens so the partial repay amount is > 0.
        debtToken.mint(address(mgr), 50e18);
    }

    /// @notice A non-dust partial-repay revert must surface, not escalate to a full close.
    function test_H02_nonDustRepayRevert_surfaces_not_escalates() public {
        // collateralNeeded (10e8) < collateral (100e8) => partial unwind, fullyClose stays false.
        // debtToRepay = 100e18 * 10e8 / 100e8 = 10e18; repayNow = min(10e18, 100e18, 50e18) = 10e18
        // 10e18 != currentDebt(100e18) => enters the try/catch partial path. repay() reverts
        // "Controller paused" (non-dust) => must revert PartialRepayFailed (NOT reach flash path).
        vm.expectRevert(LlamaLoanManager.PartialRepayFailed.selector);
        mgr.unwindPosition(10e8);
        console.log("FIXED: non-dust partial-repay revert -> PartialRepayFailed (no flash escalation)");
    }
}
