// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { IporYieldStrategy } from "../src/strategies/IporYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock IPOR", "mIPOR") { }
}

contract IporYieldStrategyTest is Test {
    MockERC20 crvUSD;
    MockYieldVault iporVault;
    IporYieldStrategy strategy;

    address vault = makeAddr("vault");
    address user = makeAddr("user");

    function setUp() public {
        crvUSD = new MockERC20("Curve USD", "crvUSD", 18);
        iporVault = new MockYieldVault(address(crvUSD));

        strategy = new IporYieldStrategy(address(crvUSD), vault, address(iporVault));

        crvUSD.mint(vault, 1_000_000e18);
        vm.prank(vault);
        crvUSD.approve(address(strategy), type(uint256).max);
    }

    function test_deposit_and_balanceOf() public {
        vm.prank(vault);
        uint256 deposited = strategy.deposit(1000e18);

        assertEq(deposited, 1000e18);
        assertGt(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 1000e18);
    }

    function test_withdraw_reducesCostBasis() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.withdraw(500e18);

        assertGt(received, 0);
        assertLt(strategy.costBasis(), 1000e18);
    }

    function test_withdrawAll_resetsCostBasis() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.withdrawAll();

        assertGt(received, 0);
        assertEq(strategy.costBasis(), 0);
        assertEq(strategy.balanceOf(), 0);
    }

    function test_emergencyWithdraw_withdrawsAll() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();

        assertGt(received, 0);
        assertEq(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 0);
    }

    function test_harvest_noRewards() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 rewards = strategy.harvest();

        assertEq(rewards, 0);
    }

    function test_viewFunctions() public view {
        assertEq(strategy.underlyingAsset(), address(crvUSD));
        assertEq(strategy.pendingRewards(), 0);
        assertEq(strategy.name(), "IPOR PlasmaVault Strategy");
    }

    function test_pauseStrategy_blocksDeposit() public {
        vm.prank(vault);
        uint256 received = strategy.pauseStrategy();
        assertEq(received, 0);
        assertTrue(strategy.paused());

        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.StrategyPaused.selector);
        strategy.deposit(1e18);
    }

    function test_pauseStrategy_unwindsOnPause() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.pauseStrategy();

        assertTrue(strategy.paused());
        assertGt(received, 0);
        assertEq(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 0);
    }

    function test_pauseStrategy_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.pauseStrategy();
    }

    // ============ Branch Coverage: BaseYieldStrategy ============

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.ZeroAmount.selector);
        strategy.deposit(0);
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.ZeroAmount.selector);
        strategy.withdraw(0);
    }

    function test_deposit_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.deposit(1000e18);
    }

    function test_withdraw_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdraw(1000e18);
    }

    function test_withdrawAll_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdrawAll();
    }

    function test_harvest_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.harvest();
    }

    function test_emergencyWithdraw_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.emergencyWithdraw();
    }

    function test_harvest_revertsWhenPaused() public {
        // Pause first
        vm.prank(vault);
        strategy.pauseStrategy();
        assertTrue(strategy.paused());

        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.StrategyPaused.selector);
        strategy.harvest();
    }

    function test_pauseStrategy_unpauseToggle() public {
        // Pause
        vm.prank(vault);
        strategy.pauseStrategy();
        assertTrue(strategy.paused(), "Should be paused");

        // Unpause
        vm.prank(vault);
        uint256 received = strategy.pauseStrategy();
        assertFalse(strategy.paused(), "Should be unpaused");
        assertEq(received, 0, "Unpause should return 0");
    }

    function test_withdraw_moreThanBalance_caps() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        uint256 balance = strategy.balanceOf();

        // Withdraw more than balance — should cap to balance
        vm.prank(vault);
        uint256 received = strategy.withdraw(balance + 1000e18);

        assertGt(received, 0, "Should receive some crvUSD");
        assertEq(strategy.balanceOf(), 0, "Balance should be 0 after withdrawing all");
    }

    function test_withdraw_zeroBalance_returns0() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        // Withdraw all first
        vm.prank(vault);
        strategy.withdrawAll();

        // Now withdraw from empty — should return 0 (not revert)
        vm.prank(vault);
        uint256 received = strategy.withdraw(100e18);
        assertEq(received, 0, "Should return 0 from empty strategy");
    }

    function test_withdrawAll_empty_returns0() public {
        vm.prank(vault);
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0, "WithdrawAll on empty should return 0");
    }

    function test_emergencyWithdraw_empty_returns0() public {
        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();
        assertEq(received, 0, "EmergencyWithdraw on empty should return 0");
    }

    function test_asset_returnsCrvUSD() public view {
        assertEq(strategy.asset(), address(crvUSD), "Asset should be crvUSD");
    }

    function test_costBasis_tracking() public {
        vm.prank(vault);
        strategy.deposit(1000e18);
        assertEq(strategy.costBasis(), 1000e18, "Cost basis should be 1000e18");

        vm.prank(vault);
        strategy.deposit(500e18);
        assertEq(strategy.costBasis(), 1500e18, "Cost basis should be 1500e18");
    }

    function test_unrealizedProfit_belowCostBasis() public {
        vm.prank(vault);
        strategy.deposit(1000e18);
        // unrealizedProfit when value == costBasis should be 0
        assertEq(strategy.unrealizedProfit(), 0, "No profit when at cost basis");
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new IporYieldStrategy(address(0), vault, address(iporVault));

        // vault == address(0) is valid (deferred init), so no revert expected
        IporYieldStrategy deferredStrategy = new IporYieldStrategy(address(crvUSD), address(0), address(iporVault));
        assertEq(deferredStrategy.vault(), address(0));

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new IporYieldStrategy(address(crvUSD), vault, address(0));
    }
}
