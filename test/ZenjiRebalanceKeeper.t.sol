// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ZenjiRebalanceKeeper} from "../src/keepers/ZenjiRebalanceKeeper.sol";

contract MockKeeperToken is ERC20 {
    constructor() ERC20("Mock Keeper Token", "MKT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ZenjiRebalanceKeeperTest is Test {
    ZenjiRebalanceKeeper internal keeper;
    MockKeeperToken internal token;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant MOCK_VAULT = address(0xBEEF);

    function setUp() external {
        keeper = new ZenjiRebalanceKeeper(MOCK_VAULT, OWNER);
        token = new MockKeeperToken();

        token.mint(address(keeper), 1_000e18);
    }

    function test_ownerCanDrainErc20() external {
        uint256 amount = 250e18;

        vm.prank(OWNER);
        keeper.drainERC20(address(token), RECEIVER, amount);

        assertEq(token.balanceOf(RECEIVER), amount);
        assertEq(token.balanceOf(address(keeper)), 750e18);
    }

    function test_nonOwnerCannotDrainErc20() external {
        vm.prank(OTHER);
        vm.expectRevert(ZenjiRebalanceKeeper.Unauthorized.selector);
        keeper.drainERC20(address(token), RECEIVER, 1e18);
    }

    function test_transferOwnership_newOwnerCanDrain() external {
        vm.prank(OWNER);
        keeper.transferOwnership(OTHER);

        vm.prank(OWNER);
        vm.expectRevert(ZenjiRebalanceKeeper.Unauthorized.selector);
        keeper.drainERC20(address(token), RECEIVER, 1e18);

        vm.prank(OTHER);
        keeper.drainERC20(address(token), RECEIVER, 1e18);

        assertEq(token.balanceOf(RECEIVER), 1e18);
    }
}
