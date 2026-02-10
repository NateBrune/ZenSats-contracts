// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { AaveLoanManager } from "../src/AaveLoanManager.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

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

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
        roundId++;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        updatedAt = newUpdatedAt;
    }

    function setAnsweredInRound(uint80 newAnsweredInRound) external {
        answeredInRound = newAnsweredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}

contract MockAavePool is IAavePool {
    IERC20 public immutable collateral;
    IERC20 public immutable debtAsset;
    MockERC20 public immutable aToken;
    MockERC20 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        collateral = IERC20(_collateral);
        debtAsset = IERC20(_debtAsset);
        aToken = MockERC20(_aToken);
        variableDebtToken = MockERC20(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        variableDebtToken.burnFrom(onBehalfOf, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 burnAmount = amount;
        uint256 balance = aToken.balanceOf(msg.sender);
        if (burnAmount > balance) {
            burnAmount = balance;
        }
        aToken.burnFrom(msg.sender, burnAmount);
        IERC20(asset).transfer(to, burnAmount);
        return burnAmount;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        MockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset, amount, 0, receiverAddress, params
        );
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }
}

contract MockSwapper is ISwapper {
    MockERC20 public immutable collateral;
    MockERC20 public immutable debt;
    uint256 public lastCollateralIn;

    constructor(address _collateral, address _debt) {
        collateral = MockERC20(_collateral);
        debt = MockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount;
    }

    function swapCollateralForDebt(uint256 collateralAmount)
        external
        returns (uint256 debtReceived)
    {
        lastCollateralIn = collateralAmount;
        debt.mint(msg.sender, collateralAmount);
        debtReceived = collateralAmount;
    }

    function swapDebtForCollateral(uint256 debtAmount)
        external
        returns (uint256 collateralReceived)
    {
        collateral.mint(msg.sender, debtAmount);
        collateralReceived = debtAmount;
    }
}

contract AaveLoanManagerTest is Test {
    MockERC20 collateral;
    MockERC20 debt;
    MockERC20 aToken;
    MockERC20 vDebt;

    MockOracle collateralOracle;
    MockOracle debtOracle;
    MockAavePool pool;
    MockSwapper swapper;

    AaveLoanManager manager;

    address vault = address(this);
    address nonVault = makeAddr("nonVault");

    function setUp() public {
        collateral = new MockERC20("COLL", "COLL", 18);
        debt = new MockERC20("DEBT", "DEBT", 18);
        aToken = new MockERC20("aCOLL", "aCOLL", 18);
        vDebt = new MockERC20("vDEBT", "vDEBT", 18);

        pool = new MockAavePool(address(collateral), address(debt), address(aToken), address(vDebt));
        collateralOracle = new MockOracle(8, 1e8);
        debtOracle = new MockOracle(8, 1e8);
        swapper = new MockSwapper(address(collateral), address(debt));

        manager = new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault
        );
    }

    function test_createLoan_borrowMore_repayDebt() public {
        collateral.mint(address(manager), 100e18);

        manager.createLoan(100e18, 50e18, 0);
        assertEq(aToken.balanceOf(address(manager)), 100e18, "aToken minted");
        assertEq(vDebt.balanceOf(address(manager)), 50e18, "debt minted");

        collateral.mint(address(manager), 20e18);
        manager.borrowMore(20e18, 10e18);
        assertEq(aToken.balanceOf(address(manager)), 120e18, "collateral added");
        assertEq(vDebt.balanceOf(address(manager)), 60e18, "debt increased");

        manager.repayDebt(10e18);
        assertEq(vDebt.balanceOf(address(manager)), 50e18, "debt repaid");
    }

    function test_unwindPosition_partial_withdrawsCollateralToVault() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.unwindPosition(40e18);
        uint256 vaultAfter = collateral.balanceOf(vault);

        assertGt(vaultAfter, vaultBefore, "vault receives collateral");
        assertLt(vDebt.balanceOf(address(manager)), 50e18, "debt reduced");
    }

    function test_unwindPosition_fullClose_usesFlashloanAndSwapper() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 80e18, 0);

        debt.burnFrom(address(manager), debt.balanceOf(address(manager)));

        manager.unwindPosition(type(uint256).max);

        assertEq(vDebt.balanceOf(address(manager)), 0, "debt cleared");
        assertGt(collateral.balanceOf(vault), 0, "vault receives collateral");
        assertGt(swapper.lastCollateralIn(), 0, "swapper used");
    }

    function test_executeOperation_revertsWhenNotPool() public {
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.executeOperation(address(debt), 1e18, 0, address(manager), "");
    }

    function test_checkOracleFreshness_revertsOnStale() public {
        vm.warp(2 hours + 1);
        collateralOracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.checkOracleFreshness();
    }

    // AaveLoanManager does not have setSwapper method
    // function test_setSwapper_onlyVault() public {
    //     vm.prank(nonVault);
    //     vm.expectRevert(ILoanManager.Unauthorized.selector);
    //     manager.setSwapper(address(0));
    // }

    function test_transferCollateral_usesIdleBalance() public {
        collateral.mint(address(manager), 5e18);
        uint256 vaultBefore = collateral.balanceOf(vault);

        manager.transferCollateral(vault, 5e18);

        assertEq(collateral.balanceOf(vault), vaultBefore + 5e18, "idle transferred");
        assertEq(aToken.balanceOf(address(manager)), 0, "no aToken burned");
    }

    function test_onlyVault_reverts() public {
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.createLoan(1e18, 0, 0);
    }

    function test_zeroAmount_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.addCollateral(0);

        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.repayDebt(0);

        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.borrowMore(0, 0);

        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.removeCollateral(0);
    }

    function test_transferDebt_revertsOnZeroAddress() public {
        debt.mint(address(manager), 1e18);
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.transferDebt(address(0), 1e18);
    }

    function test_transferCollateral_withATokenUsesWithdraw() public {
        collateral.mint(address(manager), 10e18);
        manager.createLoan(10e18, 0, 0);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.transferCollateral(vault, 5e18);
        assertEq(collateral.balanceOf(vault), vaultBefore + 5e18, "withdraw to vault");
    }

    function test_viewFunctions_afterBorrow() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);

        assertEq(manager.getCurrentCollateral(), 100e18, "collateral balance");
        assertEq(manager.getCurrentDebt(), 40e18, "debt balance");
        assertTrue(manager.loanExists(), "loan exists");

        (uint256 collVal, uint256 debtVal) = manager.getPositionValues();
        assertEq(collVal, 100e18, "position collateral");
        assertEq(debtVal, 40e18, "position debt");

        uint256 ltv = manager.getCurrentLTV();
        assertGt(ltv, 0, "ltv > 0");
        assertGt(uint256(manager.getHealth()), 0, "health > 0");

        uint256 borrowAmount = manager.calculateBorrowAmount(10e18, 7e17);
        assertGt(borrowAmount, 0, "borrow amount > 0");

        uint256 minColl = manager.minCollateral(10e18, 0);
        assertGt(minColl, 0, "min collateral > 0");

        uint256 net = manager.getNetCollateralValue();
        assertGt(net, 0, "net collateral > 0");
    }

    function test_executeOperation_invalidAsset_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.executeOperation(address(collateral), 1e18, 0, address(manager), "");
    }

    function test_executeOperation_invalidInitiator_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.executeOperation(address(debt), 1e18, 0, address(this), "");
    }
}
