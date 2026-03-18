// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Shared Mocks ============

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title LoanManagerTestBase
/// @notice Abstract base for loan manager unit tests.
///         Provides ~25 shared tests covering access control, zero amounts,
///         transfers, view functions, constructor validation, initializeVault,
///         swapper timelock, healthCalculator, and loanExists.
abstract contract LoanManagerTestBase is Test {
    ILoanManager public manager;
    MockERC20 public collateral;
    MockERC20 public debt;

    address vault = address(this);
    address nonVault = makeAddr("nonVault");

    // ============ Abstract functions ============

    /// @notice Deploy mocks and manager, setting `manager`, `collateral`, `debt`
    function _deployManager() internal virtual;

    /// @notice Deploy a deferred manager (vault == address(0))
    function _deployDeferredManager() internal virtual returns (ILoanManager);

    /// @notice Make the primary collateral oracle stale
    function _makeOracleStale() internal virtual;

    /// @notice Make the primary collateral oracle return invalid (zero/negative) price
    function _makeOracleInvalidPrice() internal virtual;

    /// @notice Make the primary oracle's answeredInRound < roundId
    function _makeOracleStaleAnsweredInRound() internal virtual;

    /// @notice Default collateral amount for createLoan
    function _defaultCollateral() internal view virtual returns (uint256);

    /// @notice Default debt amount for createLoan
    function _defaultDebt() internal view virtual returns (uint256);

    /// @notice Default bands for createLoan (0 for Aave)
    function _defaultBands() internal pure virtual returns (uint256);

    /// @notice Create a new MockSwapper-equivalent and return its address
    function _newMockSwapper() internal virtual returns (address);

    /// @notice Whether proposeSwapper/executeSwapper/cancelSwapper are available
    function _supportsSwapperTimelock() internal pure virtual returns (bool) {
        return true;
    }

    // ============ setUp ============

    function setUp() public virtual {
        _deployManager();
    }

    // ============ Helpers ============

    function _createDefaultLoan() internal {
        collateral.mint(address(manager), _defaultCollateral());
        manager.createLoan(_defaultCollateral(), _defaultDebt(), _defaultBands());
    }

    // ============ Access Control ============

    function test_createLoan_revertsFromNonVault() public {
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.createLoan(_defaultCollateral(), _defaultDebt(), _defaultBands());
    }

    // ============ Zero Amount Reverts ============

    function test_addCollateral_zero_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.addCollateral(0);
    }

    function test_repayDebt_zero_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.repayDebt(0);
    }

    function test_borrowMore_zero_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.borrowMore(0, 0);
    }

    function test_removeCollateral_zero_reverts() public {
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        manager.removeCollateral(0);
    }

    // ============ Transfers ============

    function test_transferDebt_revertsOnZeroAddress() public {
        debt.mint(address(manager), 1e18);
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.transferDebt(address(0), 1e18);
    }

    function test_transferCollateral_revertsOnZeroAddress() public {
        collateral.mint(address(manager), _defaultCollateral());
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        manager.transferCollateral(address(0), _defaultCollateral());
    }

    function test_transferCollateral_and_transferDebt_success() public {
        collateral.mint(address(manager), _defaultCollateral());
        debt.mint(address(manager), _defaultDebt());

        manager.transferCollateral(vault, _defaultCollateral());
        manager.transferDebt(vault, _defaultDebt());

        assertEq(collateral.balanceOf(vault), _defaultCollateral(), "collateral transferred");
        assertEq(debt.balanceOf(vault), _defaultDebt(), "debt transferred");
    }

    function test_getCollateralBalance_and_getDebtBalance() public {
        collateral.mint(address(manager), _defaultCollateral());
        debt.mint(address(manager), _defaultDebt());

        assertEq(manager.getCollateralBalance(), _defaultCollateral(), "collateral balance");
        assertEq(manager.getDebtBalance(), _defaultDebt(), "debt balance");
    }

    // ============ Oracle Freshness ============

    function test_checkOracleFreshness_revertsOnStale() public {
        _makeOracleStale();
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.checkOracleFreshness();
    }

    function test_checkOracleFreshness_revertsOnInvalidPrice() public {
        _makeOracleInvalidPrice();
        vm.expectRevert(ILoanManager.InvalidPrice.selector);
        manager.checkOracleFreshness();
    }

    function test_checkOracleFreshness_revertsOnAnsweredInRound() public {
        _makeOracleStaleAnsweredInRound();
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.checkOracleFreshness();
    }

    // ============ View Functions (No Loan) ============

    function test_getCurrentLTV_noLoan() public view {
        assertEq(manager.getCurrentLTV(), 0, "No loan should return 0 LTV");
    }

    function test_getHealth_noLoan() public view {
        assertEq(manager.getHealth(), type(int256).max, "No loan should return max health");
    }

    function test_getNetCollateralValue_noLoan() public view {
        assertEq(manager.getNetCollateralValue(), 0, "No collateral value");
    }

    function test_loanExists_false() public view {
        assertFalse(manager.loanExists(), "No loan should exist");
    }

    function test_getCollateralValue_zero() public view {
        assertEq(manager.getCollateralValue(0), 0, "Zero should return 0 value");
    }

    function test_getDebtValue_zero() public view {
        assertEq(manager.getDebtValue(0), 0, "Zero should return 0 value");
    }

    function test_getCollateralValue_nonZero() public view {
        uint256 val = manager.getCollateralValue(_defaultCollateral());
        assertGt(val, 0, "Should return non-zero for non-zero input");
    }

    function test_getDebtValue_nonZero() public view {
        uint256 val = manager.getDebtValue(_defaultDebt());
        assertGt(val, 0, "Should return non-zero for non-zero input");
    }

    function test_calculateBorrowAmount() public view {
        uint256 amount = manager.calculateBorrowAmount(_defaultCollateral(), 7e17);
        assertGt(amount, 0, "Should calculate non-zero borrow");
    }

    // ============ View Functions (With Loan) ============

    function test_loanExists_true() public {
        _createDefaultLoan();
        assertTrue(manager.loanExists(), "Loan should exist");
    }

    function test_getCurrentLTV_and_health_withLoan() public {
        _createDefaultLoan();
        uint256 ltv = manager.getCurrentLTV();
        assertGt(ltv, 0, "LTV should be > 0");
        int256 health = manager.getHealth();
        assertGt(health, 0, "Health should be positive");
    }

    function test_getNetCollateralValue_withDebt() public {
        _createDefaultLoan();
        uint256 net = manager.getNetCollateralValue();
        assertGt(net, 0, "Net value should be positive");
    }

    function test_getPositionValues_withLoan() public {
        _createDefaultLoan();
        (uint256 collVal, uint256 debtVal) = manager.getPositionValues();
        assertGt(collVal, 0, "Collateral value > 0");
        assertGt(debtVal, 0, "Debt value > 0");
    }

    // ============ Swapper Timelock ============

    function test_proposeSwapper_and_execute() public {
        if (!_supportsSwapperTimelock()) return;
        address newSwapper = _newMockSwapper();
        _proposeSwapper(newSwapper);
        vm.warp(block.timestamp + 1 weeks + 1);
        _executeSwapper();
    }

    function test_cancelSwapper() public {
        if (!_supportsSwapperTimelock()) return;
        address newSwapper = _newMockSwapper();
        _proposeSwapper(newSwapper);
        _cancelSwapper();
        vm.expectRevert();
        _executeSwapper();
    }

    function test_proposeSwapper_zeroAddress_reverts() public {
        if (!_supportsSwapperTimelock()) return;
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        _proposeSwapper(address(0));
    }

    // ============ initializeVault ============

    function test_initializeVault_success() public {
        ILoanManager deferred = _deployDeferredManager();
        _initializeVault(address(deferred), vault);
        assertEq(_getVault(address(deferred)), vault, "Vault should be set");
    }

    function test_initializeVault_alreadySet_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        _initializeVault(address(manager), vault);
    }

    function test_initializeVault_zeroAddress_reverts() public {
        ILoanManager deferred = _deployDeferredManager();
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        _initializeVault(address(deferred), address(0));
    }

    function test_initializeVault_wrongSender_reverts() public {
        ILoanManager deferred = _deployDeferredManager();
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        _initializeVault(address(deferred), vault);
    }

    // ============ unwindPosition ============

    function test_unwindPosition_noPosition_noRevert() public {
        manager.unwindPosition(_defaultCollateral());
    }

    function test_unwindPosition_revertsFromNonVault() public {
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.unwindPosition(_defaultCollateral());
    }

    // ============ Internal helpers for swapper timelock ============
    // These use low-level calls because proposeSwapper/executeSwapper/cancelSwapper
    // are not on ILoanManager interface

    function _proposeSwapper(address newSwapper) internal {
        (bool ok,) =
            address(manager).call(abi.encodeWithSignature("proposeSwapper(address)", newSwapper));
        if (!ok) {
            // Re-call to propagate revert reason
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _executeSwapper() internal {
        (bool ok,) = address(manager).call(abi.encodeWithSignature("executeSwapper()"));
        if (!ok) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _cancelSwapper() internal {
        (bool ok,) = address(manager).call(abi.encodeWithSignature("cancelSwapper()"));
        if (!ok) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _initializeVault(address target, address _vault) internal {
        (bool ok,) = target.call(abi.encodeWithSignature("initializeVault(address)", _vault));
        if (!ok) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _getVault(address target) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("vault()"));
        require(ok, "vault() call failed");
        return abi.decode(data, (address));
    }
}
