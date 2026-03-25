// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { LoanManagerTestBase, MockERC20 } from "./base/LoanManagerTestBase.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

// ============ Aave-Specific Mocks ============

contract MockAavePool is IAavePool {
    IERC20 public immutable coll;
    IERC20 public immutable debtAsset;
    MockERC20 public immutable aToken;
    MockERC20 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        coll = IERC20(_collateral);
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
        if (burnAmount > balance) burnAmount = balance;
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
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }
    function setUserEMode(uint8) external {}
    function getUserEMode(address) external pure returns (uint256) { return 0; }
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

contract MockSwapper is ISwapper {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable debtToken;
    uint256 public lastCollateralIn;

    constructor(address _collateral, address _debt) {
        collateralToken = MockERC20(_collateral);
        debtToken = MockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount;
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        lastCollateralIn = collateralAmount;
        debtToken.mint(msg.sender, collateralAmount);
        return collateralAmount;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        collateralToken.mint(msg.sender, debtAmount);
        return debtAmount;
    }
}

// ============ Test Contract ============

contract AaveLoanManagerTest is LoanManagerTestBase {
    MockERC20 aToken;
    MockERC20 vDebt;
    MockOracle collateralOracle;
    MockOracle debtOracle;
    MockAavePool pool;
    MockSwapper swapper;
    AaveLoanManager aaveManager;

    function _deployManager() internal override {
        collateral = new MockERC20("COLL", "COLL", 18);
        debt = new MockERC20("DEBT", "DEBT", 18);
        aToken = new MockERC20("aCOLL", "aCOLL", 18);
        vDebt = new MockERC20("vDEBT", "vDEBT", 18);

        pool = new MockAavePool(address(collateral), address(debt), address(aToken), address(vDebt));
        collateralOracle = new MockOracle(8, 1e8);
        debtOracle = new MockOracle(8, 1e8);
        swapper = new MockSwapper(address(collateral), address(debt));

        aaveManager = new AaveLoanManager(
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
            vault,
            0, // eMode: disabled
            3600
        );
        manager = ILoanManager(address(aaveManager));
    }

    function _deployDeferredManager() internal override returns (ILoanManager) {
        AaveLoanManager deferred = new AaveLoanManager(
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
            address(0),
            0, // eMode: disabled
            3600
        );
        return ILoanManager(address(deferred));
    }

    function _makeOracleStale() internal override {
        vm.warp(2 hours + 1);
        collateralOracle.setUpdatedAt(block.timestamp - 2 hours);
    }

    function _makeOracleInvalidPrice() internal override {
        collateralOracle.setPrice(0);
    }

    function _makeOracleStaleAnsweredInRound() internal override {
        collateralOracle.setAnsweredInRound(0);
    }

    function _defaultCollateral() internal pure override returns (uint256) {
        return 100e18;
    }

    function _defaultDebt() internal pure override returns (uint256) {
        return 50e18;
    }

    function _defaultBands() internal pure override returns (uint256) {
        return 0;
    }

    function _newMockSwapper() internal override returns (address) {
        return address(new MockSwapper(address(collateral), address(debt)));
    }

    // ============ Aave-Specific Tests ============

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
        manager.createLoan(100e18, 65e18, 0);
        debt.burnFrom(address(manager), debt.balanceOf(address(manager)));

        manager.unwindPosition(type(uint256).max);

        assertEq(vDebt.balanceOf(address(manager)), 0, "debt cleared");
        assertGt(collateral.balanceOf(vault), 0, "vault receives collateral");
        assertGt(swapper.lastCollateralIn(), 0, "swapper used");
    }

    function test_executeOperation_revertsWhenNotPool() public {
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        aaveManager.executeOperation(address(debt), 1e18, 0, address(aaveManager), "");
    }

    function test_executeOperation_invalidAsset_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        aaveManager.executeOperation(address(collateral), 1e18, 0, address(aaveManager), "");
    }

    function test_executeOperation_invalidInitiator_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        aaveManager.executeOperation(address(debt), 1e18, 0, address(this), "");
    }

    function test_transferCollateral_usesIdleBalance() public {
        collateral.mint(address(manager), 5e18);
        uint256 vaultBefore = collateral.balanceOf(vault);

        manager.transferCollateral(vault, 5e18);

        assertEq(collateral.balanceOf(vault), vaultBefore + 5e18, "idle transferred");
        assertEq(aToken.balanceOf(address(manager)), 0, "no aToken burned");
    }

    function test_transferCollateral_withATokenUsesWithdraw() public {
        collateral.mint(address(manager), 10e18);
        manager.createLoan(10e18, 0, 0);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.transferCollateral(vault, 5e18);
        assertEq(collateral.balanceOf(vault), vaultBefore + 5e18, "withdraw to vault");
    }

    function test_transferCollateral_partialIdle_withdrawsRemainder() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        collateral.mint(address(manager), 3e18);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.transferCollateral(vault, 10e18);
        assertEq(collateral.balanceOf(vault) - vaultBefore, 10e18, "Should receive full amount");
    }

    function test_removeCollateral() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);

        uint256 aTokenBefore = aToken.balanceOf(address(manager));
        manager.removeCollateral(20e18);
        assertEq(aTokenBefore - aToken.balanceOf(address(manager)), 20e18, "aToken decreased");
        assertEq(collateral.balanceOf(address(manager)), 20e18, "collateral withdrawn to manager");
    }

    function test_transferDebt_success() public {
        debt.mint(address(manager), 50e18);
        manager.transferDebt(vault, 50e18);
        assertEq(debt.balanceOf(vault), 50e18, "debt transferred");
        assertEq(debt.balanceOf(address(manager)), 0, "manager balance zero");
    }

    function test_viewFunctions_afterBorrow() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);

        assertEq(manager.getCurrentCollateral(), 100e18);
        assertEq(manager.getCurrentDebt(), 40e18);
        assertTrue(manager.loanExists());

        uint256 ltv = manager.getCurrentLTV();
        assertGt(ltv, 0);
        assertGt(uint256(manager.getHealth()), 0);

        uint256 borrowAmount = manager.calculateBorrowAmount(10e18, 7e17);
        assertGt(borrowAmount, 0);

        uint256 minColl = manager.minCollateral(10e18, 0);
        assertGt(minColl, 0);

        uint256 net = manager.getNetCollateralValue();
        assertGt(net, 0);
    }

    function test_getCurrentLTV_noCollateral_returnsZero() public view {
        assertEq(manager.getCurrentLTV(), 0);
    }

    function test_getCurrentLTV_noDebt_returnsZero() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        assertEq(manager.getCurrentLTV(), 0);
    }

    function test_getHealth_noPosition_returnsMax() public view {
        assertEq(manager.getHealth(), type(int256).max);
    }

    function test_getHealth_noDebt_returnsMax() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        assertEq(manager.getHealth(), type(int256).max);
    }

    function test_borrowMore_collateralOnly() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        collateral.mint(address(manager), 20e18);
        manager.borrowMore(20e18, 0);
        assertEq(aToken.balanceOf(address(manager)), 120e18);
        assertEq(vDebt.balanceOf(address(manager)), 50e18);
    }

    function test_borrowMore_debtOnly() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        manager.borrowMore(0, 10e18);
        assertEq(aToken.balanceOf(address(manager)), 100e18);
        assertEq(vDebt.balanceOf(address(manager)), 60e18);
    }

    function test_unwindPosition_partial_withAvailableDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);
        debt.mint(address(manager), 30e18);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.unwindPosition(40e18);
        assertGt(collateral.balanceOf(vault), vaultBefore, "vault receives collateral");
    }

    function test_unwindPosition_fullClose_withSufficientDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 30e18, 0);
        debt.mint(address(manager), 30e18);

        manager.unwindPosition(type(uint256).max);
        assertEq(vDebt.balanceOf(address(manager)), 0, "all debt repaid");
        assertGt(collateral.balanceOf(vault), 0, "collateral recovered");
    }

    function test_unwindPosition_partial_dustDebt_noFlashloan() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);
        debt.mint(address(manager), 20e18);
        manager.unwindPosition(40e18);
        assertGt(collateral.balanceOf(vault), 0, "Vault receives collateral");
    }

    function test_unwindPosition_fullClose_noDebt_withdrawsAll() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        manager.unwindPosition(type(uint256).max);
        assertGt(collateral.balanceOf(vault), 0, "All collateral to vault");
    }

    function test_createLoan_collateralOnly_noBorrow() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        assertEq(aToken.balanceOf(address(manager)), 100e18);
        assertEq(vDebt.balanceOf(address(manager)), 0);
    }

    function test_getNetCollateralValue_highDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 60e18, 0);
        assertEq(manager.getNetCollateralValue(), 40e18);
    }

    function test_healthCalculator_withDeltas() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);

        int256 healthBase = manager.healthCalculator(0, 0);
        int256 healthMoreColl = manager.healthCalculator(int256(50e18), 0);
        int256 healthMoreDebt = manager.healthCalculator(0, int256(20e18));
        int256 healthLessColl = manager.healthCalculator(-int256(20e18), 0);
        int256 healthLessDebt = manager.healthCalculator(0, -int256(10e18));

        assertGt(healthMoreColl, healthBase, "More collateral = better health");
        assertLt(healthMoreDebt, healthBase, "More debt = worse health");
        assertLt(healthLessColl, healthBase, "Less collateral = worse health");
        assertGt(healthLessDebt, healthBase, "Less debt = better health");
    }

    function test_healthCalculator_zeroDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 10e18, 0);
        int256 health = manager.healthCalculator(0, -int256(10e18));
        assertEq(health, type(int256).max);
    }

    function test_healthCalculator_negativeCollateralDelta() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);
        int256 health = manager.healthCalculator(-int256(50e18), 0);
        assertGt(health, 0);
    }

    function test_healthCalculator_negativeDebtDelta() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);
        int256 health = manager.healthCalculator(0, -int256(20e18));
        assertGt(health, manager.healthCalculator(0, 0));
    }

    function test_createLoan_zeroCollateral_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.createLoan(0, 50e18, 0);
    }

    function test_minCollateral_zeroDebt() public view {
        assertEq(manager.minCollateral(0, 0), 0);
    }

    // ============ Constructor Zero-Address Checks ============

    function test_constructor_zeroCollateral_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(0),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroDebt_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(0),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroAToken_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(0),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroVDebt_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(0),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroPool_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(0),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroCollateralOracle_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(0),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroDebtOracle_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(0),
            address(swapper),
            7500,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroMaxLtv_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            0,
            8000,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_zeroLiquidationThreshold_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            0,
            vault,
            0, // eMode: disabled
            3600
        );
    }

    function test_constructor_deferredVault() public {
        AaveLoanManager deferred = new AaveLoanManager(
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
            address(0),
            0, // eMode: disabled
            3600
        );
        assertEq(deferred.vault(), address(0));
    }
}
