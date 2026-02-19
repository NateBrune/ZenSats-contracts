// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
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
        manager.createLoan(100e18, 65e18, 0);

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

    // ============ Branch Coverage Tests ============

    function test_removeCollateral() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);

        uint256 aTokenBefore = aToken.balanceOf(address(manager));
        manager.removeCollateral(20e18);
        uint256 aTokenAfter = aToken.balanceOf(address(manager));

        assertEq(aTokenBefore - aTokenAfter, 20e18, "aToken should decrease by 20");
        assertEq(collateral.balanceOf(address(manager)), 20e18, "collateral withdrawn to manager");
    }

    function test_transferDebt_success() public {
        debt.mint(address(manager), 50e18);

        manager.transferDebt(vault, 50e18);
        assertEq(debt.balanceOf(vault), 50e18, "debt transferred to vault");
        assertEq(debt.balanceOf(address(manager)), 0, "manager debt balance zero");
    }

    function test_getNetCollateralValue_withDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 60e18, 0);

        uint256 net = manager.getNetCollateralValue();
        assertEq(net, 40e18, "net should be collateral minus debt value");
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
        assertEq(health, type(int256).max, "Zero debt = max health");
    }

    function test_proposeSwapper_and_execute() public {
        MockSwapper newSwapper = new MockSwapper(address(collateral), address(debt));

        manager.proposeSwapper(address(newSwapper));

        vm.warp(block.timestamp + 2 days + 1);

        manager.executeSwapper();
    }

    function test_cancelSwapper() public {
        MockSwapper newSwapper = new MockSwapper(address(collateral), address(debt));
        manager.proposeSwapper(address(newSwapper));

        manager.cancelSwapper();

        vm.expectRevert();
        manager.executeSwapper();
    }

    function test_minCollateral_zeroDebt() public view {
        uint256 minColl = manager.minCollateral(0, 0);
        assertEq(minColl, 0, "Zero debt = zero min collateral");
    }

    function test_getCollateralBalance_and_getDebtBalance() public {
        collateral.mint(address(manager), 25e18);
        debt.mint(address(manager), 10e18);

        assertEq(manager.getCollateralBalance(), 25e18, "collateral balance");
        assertEq(manager.getDebtBalance(), 10e18, "debt balance");
    }

    function test_proposeSwapper_zeroAddress_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.proposeSwapper(address(0));
    }

    // ============ Additional Branch Coverage ============

    function test_getCurrentLTV_noCollateral_returnsZero() public view {
        // No loan created → collateral == 0 → returns 0
        assertEq(manager.getCurrentLTV(), 0);
    }

    function test_getCurrentLTV_noDebt_returnsZero() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        // debt == 0 → returns 0
        assertEq(manager.getCurrentLTV(), 0);
    }

    function test_getHealth_noPosition_returnsMax() public view {
        // No collateral, no debt → max health
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

        // Add collateral only (debt = 0)
        collateral.mint(address(manager), 20e18);
        manager.borrowMore(20e18, 0);
        assertEq(aToken.balanceOf(address(manager)), 120e18, "collateral added");
        assertEq(vDebt.balanceOf(address(manager)), 50e18, "debt unchanged");
    }

    function test_borrowMore_debtOnly() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        // Borrow more debt only (collateral = 0)
        manager.borrowMore(0, 10e18);
        assertEq(aToken.balanceOf(address(manager)), 100e18, "collateral unchanged");
        assertEq(vDebt.balanceOf(address(manager)), 60e18, "debt increased");
    }

    function test_unwindPosition_partial_withAvailableDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        // Give manager some extra debt for repayment
        debt.mint(address(manager), 30e18);

        uint256 vaultBefore = collateral.balanceOf(vault);
        manager.unwindPosition(40e18);
        uint256 vaultAfter = collateral.balanceOf(vault);

        assertGt(vaultAfter, vaultBefore, "vault receives collateral");
    }

    function test_unwindPosition_fullClose_withSufficientDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 30e18, 0);

        // Give manager enough debt for full repayment (no flashloan needed)
        debt.mint(address(manager), 30e18);

        manager.unwindPosition(type(uint256).max);
        assertEq(vDebt.balanceOf(address(manager)), 0, "all debt repaid");
        assertGt(collateral.balanceOf(vault), 0, "collateral recovered");
    }

    function test_healthCalculator_negativeCollateralDelta() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);

        int256 health = manager.healthCalculator(-int256(50e18), 0);
        assertGt(health, 0, "Still positive health");
    }

    function test_healthCalculator_negativeDebtDelta() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 40e18, 0);

        int256 health = manager.healthCalculator(0, -int256(20e18));
        assertGt(health, manager.healthCalculator(0, 0), "Less debt = better health");
    }

    function test_loanExists_false_whenNoLoan() public view {
        assertFalse(manager.loanExists(), "No loan should exist");
    }

    function test_calculateBorrowAmount() public view {
        uint256 amount = manager.calculateBorrowAmount(100e18, 7500);
        assertGt(amount, 0, "Should calculate non-zero borrow");
    }

    function test_getNetCollateralValue_noLoan() public view {
        assertEq(manager.getNetCollateralValue(), 0, "No collateral value");
    }

    // ============ Round 3: Constructor & initializeVault Branch Coverage ============

    function test_constructor_zeroCollateral_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(0), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroDebt_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(0), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroAToken_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(0), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroVDebt_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(0),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroPool_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(0), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroCollateralOracle_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(0), address(debtOracle),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroDebtOracle_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(0),
            address(swapper), 7500, 8000, vault
        );
    }

    function test_constructor_zeroMaxLtv_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 0, 8000, vault
        );
    }

    function test_constructor_zeroLiquidationThreshold_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 0, vault
        );
    }

    function test_constructor_deferredVault() public {
        AaveLoanManager deferred = new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, address(0)
        );
        assertEq(deferred.vault(), address(0), "Vault should be zero for deferred");
    }

    function test_initializeVault_success() public {
        AaveLoanManager deferred = new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, address(0)
        );
        deferred.initializeVault(vault);
        assertEq(deferred.vault(), vault, "Vault should be set");
    }

    function test_initializeVault_alreadySet_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.initializeVault(vault);
    }

    function test_initializeVault_zeroAddress_reverts() public {
        AaveLoanManager deferred = new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, address(0)
        );
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        deferred.initializeVault(address(0));
    }

    function test_initializeVault_wrongSender_reverts() public {
        AaveLoanManager deferred = new AaveLoanManager(
            address(collateral), address(debt), address(aToken), address(vDebt),
            address(pool), address(collateralOracle), address(debtOracle),
            address(swapper), 7500, 8000, address(0)
        );
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        deferred.initializeVault(vault);
    }

    // ============ Round 3: createLoan with debt==0 ============

    function test_createLoan_collateralOnly_noBorrow() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        assertEq(aToken.balanceOf(address(manager)), 100e18);
        assertEq(vDebt.balanceOf(address(manager)), 0, "No debt created");
    }

    function test_createLoan_zeroCollateral_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.createLoan(0, 50e18, 0);
    }

    // ============ Round 3: unwindPosition edge cases ============

    function test_unwindPosition_noPosition_earlyReturn() public {
        // No aToken, no vDebt -> early return
        manager.unwindPosition(50e18);
        // Should not revert
    }

    function test_unwindPosition_partial_dustDebt_noFlashloan() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 50e18, 0);

        // Give enough debt to repay most, leaving dust
        // debtToRepay = (50e18 * 40e18) / 100e18 = 20e18
        // Give exactly 20e18 - unrepaidDebt = 0 -> isDust -> no flashloan
        debt.mint(address(manager), 20e18);

        manager.unwindPosition(40e18);
        assertGt(collateral.balanceOf(vault), 0, "Vault receives collateral");
    }

    function test_unwindPosition_fullClose_noDebt_withdrawsAll() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);

        // Full close with no debt - should withdraw all collateral
        manager.unwindPosition(type(uint256).max);
        assertGt(collateral.balanceOf(vault), 0, "All collateral to vault");
    }

    // ============ Round 3: transferCollateral partial idle path ============

    function test_transferCollateral_partialIdle_withdrawsRemainder() public {
        // Create a loan, then also give some idle collateral
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 0, 0);
        collateral.mint(address(manager), 3e18); // 3e18 idle

        uint256 vaultBefore = collateral.balanceOf(vault);
        // Request 10e18: 3e18 from idle + 7e18 from aToken withdraw
        manager.transferCollateral(vault, 10e18);
        uint256 vaultAfter = collateral.balanceOf(vault);

        assertEq(vaultAfter - vaultBefore, 10e18, "Should receive full amount");
    }

    function test_transferCollateral_zeroAddress_reverts() public {
        collateral.mint(address(manager), 1e18);
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.transferCollateral(address(0), 1e18);
    }

    // ============ Round 3: getNetCollateralValue debtInCollateral > collateral ============

    function test_getNetCollateralValue_highDebt() public {
        collateral.mint(address(manager), 100e18);
        manager.createLoan(100e18, 60e18, 0);

        // With 1:1 oracles, debtInCollateral = 60e18, collateral = 100e18
        uint256 net = manager.getNetCollateralValue();
        assertEq(net, 40e18, "Net value should be 40");
    }

    // ============ Round 3: getCollateralValue and getDebtValue ============

    function test_getCollateralValue_nonZero() public view {
        uint256 val = manager.getCollateralValue(100e18);
        assertGt(val, 0, "Should return non-zero for non-zero input");
    }

    function test_getDebtValue_nonZero() public view {
        uint256 val = manager.getDebtValue(100e18);
        assertGt(val, 0, "Should return non-zero for non-zero input");
    }
}
