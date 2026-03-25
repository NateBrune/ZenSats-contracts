// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Simple ERC20 with mint ============

contract MockERC20_H3 is ERC20 {
    uint8 private _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============ Controllable mock yield strategy ============
// simulateYield() externally bumps strategy balance to simulate yield accrual

contract ControlledMockStrategy is IYieldStrategy {
    IERC20 public immutable _asset;
    address private _vault;
    uint256 private _balance;
    uint256 private _costBasis;

    constructor(address asset_, address vault_) {
        _asset = IERC20(asset_);
        _vault = vault_;
    }

    // Allow external test control to simulate yield
    function simulateYield(uint256 extraAmount) external {
        MockERC20_H3(address(_asset)).mint(address(this), extraAmount);
        _balance += extraAmount;
    }

    modifier onlyVault() {
        require(msg.sender == _vault, "Unauthorized");
        _;
    }

    function deposit(uint256 amount) external onlyVault returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), amount);
        _balance += amount;
        _costBasis += amount;
        return amount;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 toSend = amount > _balance ? _balance : amount;
        _balance -= toSend;
        _costBasis = _costBasis > toSend ? _costBasis - toSend : 0;
        _asset.transfer(_vault, toSend);
        return toSend;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 toSend = _balance;
        _balance = 0;
        _costBasis = 0;
        if (toSend > 0) _asset.transfer(_vault, toSend);
        return toSend;
    }

    function harvest() external pure returns (uint256) { return 0; }
    function emergencyWithdraw() external onlyVault returns (uint256) {
        uint256 toSend = _balance;
        _balance = 0;
        _costBasis = 0;
        if (toSend > 0) _asset.transfer(_vault, toSend);
        return toSend;
    }
    function asset() external view returns (address) { return address(_asset); }
    function underlyingAsset() external view returns (address) { return address(_asset); }
    function balanceOf() external view returns (uint256) { return _balance; }
    function costBasis() external view returns (uint256) { return _costBasis; }
    function unrealizedProfit() external view returns (uint256) {
        return _balance > _costBasis ? _balance - _costBasis : 0;
    }
    function pendingRewards() external pure returns (uint256) { return 0; }
    function transferOwnerFromVault(address) external pure { }
    function setSlippage(uint256) external pure { }

    function updateCachedVirtualPrice() external { }
    function name() external pure returns (string memory) { return "ControlledMock"; }
    function vault() external view returns (address) { return _vault; }
}

// ============ Mock loan manager that implements full ILoanManager ============
// Returns 1:1 debt/collateral value conversions

contract MockLoanManager_H3 is ILoanManager {
    address private immutable _coll;
    address private immutable _debt;
    address private _vault;

    constructor(address coll_, address debt_, address vault_) {
        _coll = coll_;
        _debt = debt_;
        _vault = vault_;
    }

    function collateralAsset() external view returns (address) { return _coll; }
    function debtAsset() external view returns (address) { return _debt; }

    // 1:1 ratio for both directions in this simplified mock
    function getDebtValue(uint256 debtAmount) external pure returns (uint256) { return debtAmount; }
    function getCollateralValue(uint256 collateralAmount) external pure returns (uint256) { return collateralAmount; }
    function getNetCollateralValue() external pure returns (uint256) { return 0; }
    function getPositionValues() external pure returns (uint256, uint256) { return (0, 0); }
    function loanExists() external pure returns (bool) { return false; }
    function getCurrentLTV() external pure returns (uint256) { return 0; }
    function getCurrentCollateral() external pure returns (uint256) { return 0; }
    function getCurrentDebt() external pure returns (uint256) { return 0; }
    function getHealth() external pure returns (int256) { return 0; }
    function getCollateralBalance() external pure returns (uint256) { return 0; }
    function getDebtBalance() external pure returns (uint256) { return 0; }
    function calculateBorrowAmount(uint256, uint256) external pure returns (uint256) { return 0; }
    function healthCalculator(int256, int256) external pure returns (int256) { return 0; }
    function minCollateral(uint256, uint256) external pure returns (uint256) { return 0; }
    function maxLtvBps() external pure returns (uint256) { return type(uint256).max; }
    function checkOracleFreshness() external view {} // view, not pure (matches interface)
    function initializeVault(address v) external { _vault = v; }

    function createLoan(uint256, uint256, uint256) external {}
    function addCollateral(uint256) external {}
    function borrowMore(uint256, uint256) external {}
    function repayDebt(uint256) external {}
    function removeCollateral(uint256) external {}
    function unwindPosition(uint256) external {}
    function transferCollateral(address, uint256) external {}
    function transferDebt(address, uint256) external {}
}

// ============ Minimal mock swapper ============

contract MockSwapper_H3 is ISwapper {
    function swapDebtForCollateral(uint256) external pure returns (uint256) { return 0; }
    function swapCollateralForDebt(uint256) external pure returns (uint256) { return 0; }
    function quoteCollateralForDebt(uint256 amt) external pure returns (uint256) { return amt; }
}

// ============ Concrete Zenji subclass ============

contract ZenjiTestable_H3 is Zenji {
    constructor(
        address coll,
        address debt,
        address lm,
        address strategy,
        address swapper,
        address owner_,
        address helper
    ) Zenji(coll, debt, lm, strategy, swapper, owner_, helper) {}

    function VIRTUAL_SHARE_OFFSET() public pure override returns (uint256) {
        return 1e5;
    }
}

// ============ H-3 Verification Test ============

/// @title H-3 Verification: Stale accumulatedFees in totalAssets() / ERC4626 view functions
/// @notice Proves that totalAssets() overstates NAV when accumulatedFees has not been
///         updated since the last strategy yield event.
///
/// Root cause: ZenjiViewHelper.getTotalCollateralValue() reads v.accumulatedFees() (storage)
///   directly without calling _accrueYieldFees() first.
///   => strategyBalance - accFees is overstated when fees are stale-low.
contract VerifyH3_StaleAccumulatedFees is Test {
    ZenjiTestable_H3 vault;
    ZenjiViewHelper viewHelper;
    ControlledMockStrategy strategy;
    MockLoanManager_H3 loanManager;
    MockERC20_H3 collateral;
    MockERC20_H3 debtToken;
    MockSwapper_H3 swapper;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");

    uint256 constant ONE_UNIT = 1e8; // 1 WBTC (8 decimals)

    function setUp() public {
        vm.warp(1_710_000_000);

        // Deploy tokens
        collateral = new MockERC20_H3("Wrapped BTC", "WBTC", 8);
        debtToken = new MockERC20_H3("Tether USD", "USDT", 6);

        // Deploy view helper and swapper
        viewHelper = new ZenjiViewHelper();
        swapper = new MockSwapper_H3();

        // Predict vault address so strategy and loan manager can reference it
        uint256 nonce = vm.getNonce(address(this));
        // nonce+0 = loanManager, nonce+1 = strategy, nonce+2 = vault
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);

        loanManager = new MockLoanManager_H3(address(collateral), address(debtToken), predictedVault);
        strategy = new ControlledMockStrategy(address(debtToken), predictedVault);

        vault = new ZenjiTestable_H3(
            address(collateral),
            address(debtToken),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        require(address(vault) == predictedVault, "Vault address prediction failed");

        // Set feeRate to 10% (1e17)
        vm.prank(owner);
        vault.setParam(0, 1e17);

        // Fund depositor
        collateral.mint(depositor, 100 * ONE_UNIT);
        vm.prank(depositor);
        collateral.approve(address(vault), type(uint256).max);
    }

    /// @notice Main bug proof:
    ///         totalAssets() reads stale accumulatedFees from storage, overstating NAV
    ///         when the strategy has accrued yield since the last _accrueYieldFees() call.
    function test_H3_StaleFeesMakesTotalAssetsOverstate() public {
        // === SETUP: deposit collateral, enter non-idle mode to engage ZenjiViewHelper ===

        // Vault starts non-idle. Deposit collateral.
        // Note: in non-idle mode, deposit() calls _deployCapital() which calls
        // loanManager.calculateBorrowAmount() returning 0 -- so no actual loan is created.
        // The deposited collateral stays in the vault.
        uint256 depositAmount = 10 * ONE_UNIT;
        vm.prank(depositor);
        vault.deposit(depositAmount, depositor);

        assertEq(vault.accumulatedFees(), 0, "Initial fees should be 0");
        assertEq(vault.lastStrategyBalance(), 0, "Initial lastStrategyBalance should be 0");

        // === PHASE 1: Simulate an initial capital deployment to the strategy ===
        // We inject 5000e6 USDT into the strategy (simulates deployed capital)
        // and call accrueYieldFees() to checkpoint.
        uint256 initialStrategyBalance = 5_000e6; // 5000 USDT
        strategy.simulateYield(initialStrategyBalance);

        // Checkpoint: accumulatedFees = 10% of 5000e6 = 500e6
        vault.accrueYieldFees();

        uint256 feesAfterFirstCheckpoint = vault.accumulatedFees();
        assertEq(feesAfterFirstCheckpoint, 500e6, "10% fee on 5000 USDT initial balance");
        assertEq(vault.lastStrategyBalance(), initialStrategyBalance, "lastStrategyBalance updated");

        // === PHASE 2: Strategy yields 1000 USDT MORE -- no accrual triggered yet ===
        uint256 yieldAmount = 1_000e6; // 1000 USDT new yield
        strategy.simulateYield(yieldAmount);

        // State now:
        //   strategy.balanceOf()  = 6000e6
        //   lastStrategyBalance   = 5000e6  (stale)
        //   accumulatedFees       = 500e6   (stale -- does not include 10% of new 1000e6)
        //   un-accrued fees due   = 100e6

        assertEq(strategy.balanceOf(), 6_000e6, "Strategy balance after yield");
        assertEq(vault.accumulatedFees(), feesAfterFirstCheckpoint, "Fees still stale");
        assertEq(vault.lastStrategyBalance(), initialStrategyBalance, "LSB still stale");

        // === PHASE 3: Read ERC4626 view functions WITHOUT calling accrueYieldFees() ===
        // At this point totalAssets() will call getTotalCollateral()
        // which calls viewHelper.getTotalCollateralValue():
        //   strategyBalance - accFees = 6000e6 - 500e6 = 5500e6
        //   getDebtValue(5500e6) = 5500e6 (1:1 in our mock)
        // But the CORRECT value should be:
        //   strategyBalance - freshFees = 6000e6 - 600e6 = 5400e6

        uint256 totalAssets_stale = vault.totalAssets();
        uint256 convertToShares_stale = vault.convertToShares(ONE_UNIT);
        uint256 previewDeposit_stale = vault.previewDeposit(ONE_UNIT);

        console.log("=== H-3 Stale Fees Test: Before accrual ===");
        console.log("strategy.balanceOf()       :", strategy.balanceOf());
        console.log("accumulatedFees (stale)    :", vault.accumulatedFees());
        console.log("lastStrategyBalance (stale):", vault.lastStrategyBalance());
        console.log("totalAssets (stale)        :", totalAssets_stale);
        console.log("convertToShares (stale)    :", convertToShares_stale);
        console.log("previewDeposit (stale)     :", previewDeposit_stale);

        // === PHASE 4: Accrue fees and read again ===
        vault.accrueYieldFees();

        uint256 freshFees = vault.accumulatedFees();
        // Expected: 500e6 + 10% * 1000e6 = 600e6
        assertEq(freshFees, 600e6, "Fresh fees after accrual: 10% on 1000 USDT yield");

        uint256 totalAssets_fresh = vault.totalAssets();
        uint256 convertToShares_fresh = vault.convertToShares(ONE_UNIT);
        uint256 previewDeposit_fresh = vault.previewDeposit(ONE_UNIT);

        console.log("=== H-3 Stale Fees Test: After accrual ===");
        console.log("accumulatedFees (fresh)    :", vault.accumulatedFees());
        console.log("totalAssets (fresh)        :", totalAssets_fresh);
        console.log("convertToShares (fresh)    :", convertToShares_fresh);
        console.log("previewDeposit (fresh)     :", previewDeposit_fresh);

        // === PHASE 5: ASSERT BUG ===

        // Un-accrued fees = 100e6 USDT
        // In our mock, getDebtValue() returns 1:1 so the strategy contribution to
        // totalAssets is directly in debt token units. The collateral denominator
        // absorbs these debt units additively.
        // Key assertion: stale totalAssets > fresh totalAssets
        // (stale subtracts fewer fees from the strategy balance, inflating NAV)

        uint256 navError = totalAssets_stale > totalAssets_fresh
            ? totalAssets_stale - totalAssets_fresh
            : 0;

        console.log("=== BUG PROOF ===");
        console.log("NAV overstatement (stale - fresh totalAssets):", navError);
        console.log("Un-accrued fee amount:", freshFees - feesAfterFirstCheckpoint);

        assertTrue(
            totalAssets_stale > totalAssets_fresh,
            "BUG: totalAssets() overstates NAV when accumulatedFees is stale"
        );

        // With fewer-subtracted fees: stale NAV is higher => convertToShares returns FEWER shares
        // (the depositor gets less for the same deposit when NAV is inflated)
        assertTrue(
            convertToShares_stale <= convertToShares_fresh,
            "BUG: convertToShares() undervalues depositor shares when fees are stale"
        );

        // NAV error should equal the un-accrued fee amount converted through getDebtValue
        // In our 1:1 mock that is exactly 100e6 USDT reflected in the totalAssets delta.
        // Note: totalAssets is in collateral units (WBTC, 8 dec) while strategy contribution
        // passes through getDebtValue(). In our 1:1 mock these magnitudes will differ by
        // the decimal difference (6 dec USDT vs 8 dec WBTC) but the direction is unambiguous.
        assertGt(navError, 0, "NAV overstatement must be positive");
    }

    /// @notice Control test: verify that state-mutating functions DO accrue fees first.
    ///         Deposit calls _accrueYieldFees() before calculating share price.
    function test_H3_StateChangingFunctionsAreProtected() public {
        // Setup: checkpoint an initial strategy balance
        strategy.simulateYield(5_000e6);
        vault.accrueYieldFees(); // checkpoint

        // Add more yield (stale now)
        strategy.simulateYield(1_000e6);

        uint256 feesBefore = vault.accumulatedFees();
        uint256 lsbBefore = vault.lastStrategyBalance();

        // Deposit -- internally calls _accrueYieldFees() before share calculation
        uint256 depositAmt = 5 * ONE_UNIT;
        collateral.mint(depositor, depositAmt);
        vm.prank(depositor);
        vault.deposit(depositAmt, depositor);

        uint256 feesAfter = vault.accumulatedFees();
        uint256 lsbAfter = vault.lastStrategyBalance();

        console.log("=== H-3 Control: Deposit triggers fee accrual ===");
        console.log("Fees before deposit:", feesBefore);
        console.log("Fees after deposit: ", feesAfter);
        console.log("LSB before deposit: ", lsbBefore);
        console.log("LSB after deposit:  ", lsbAfter);

        // Deposit MUST have accrued fees (fees increased from 500e6 to 600e6)
        assertGt(feesAfter, feesBefore, "Deposit should trigger fee accrual");
        assertEq(feesAfter, 600e6, "Fees after deposit: 10% on total 6000 USDT");
        assertEq(lsbAfter, 6_000e6, "lastStrategyBalance updated after deposit");
    }

    /// @notice BOUNDARY: Verify maximum staleness scenario.
    ///         Large yield accrual with no checkpoint produces proportionally larger error.
    function test_H3_LargeYieldStalenessProducesLargerError() public {
        // Initial deposit
        vm.prank(depositor);
        vault.deposit(5 * ONE_UNIT, depositor);

        // Simulate a large initial balance and checkpoint it
        strategy.simulateYield(100_000e6); // 100k USDT
        vault.accrueYieldFees();
        uint256 feesAtCheckpoint = vault.accumulatedFees(); // 10k USDT

        // Now a large yield (50k USDT) with NO checkpoint
        strategy.simulateYield(50_000e6);

        uint256 totalAssets_stale = vault.totalAssets();

        vault.accrueYieldFees();
        uint256 totalAssets_fresh = vault.totalAssets();

        uint256 largeNavError = totalAssets_stale > totalAssets_fresh
            ? totalAssets_stale - totalAssets_fresh
            : 0;

        console.log("=== H-3 Boundary: Large yield staleness ===");
        console.log("totalAssets (stale):", totalAssets_stale);
        console.log("totalAssets (fresh):", totalAssets_fresh);
        console.log("NAV overstatement  :", largeNavError);
        console.log("Fees at checkpoint :", feesAtCheckpoint);
        console.log("Fresh fees         :", vault.accumulatedFees());

        // Large yield creates proportionally larger NAV error
        assertTrue(totalAssets_stale > totalAssets_fresh, "Large yield: stale NAV still overstates");
        assertGt(largeNavError, 0, "Large yield: NAV overstatement is non-zero");
    }
}
