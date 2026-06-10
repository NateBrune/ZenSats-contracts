// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title M-05: Emergency-mode guard missing from rebalance()
///
/// HYPOTHESIS (MEDIUM):
///   Zenji.harvestYield() guards against emergency mode:
///       function harvestYield() external nonReentrant {
///           if (emergencyMode) revert EmergencyModeActive();   // <-- guard
///           ...
///       }
///   Zenji.rebalance() does NOT:
///       function rebalance() external nonReentrant {
///           if (!loanManager.loanExists()) revert RebalanceNotNeeded();
///           ...                                                   // <-- NO emergencyMode guard
///           _adjustLtv(targetLtv, true, true);                   // can INCREASE debt
///       }
///   rebalance() is permissionless and pays a keeper bounty (rebalanceBountyRate, default 20%
///   of fees since last rebalance). During an active emergency a bounty-incentivized keeper can
///   call rebalance() and, if LTV is below the lower deadband, drive _adjustLtv(targetLtv,
///   true, true) which calls loanManager.borrowMore(...) — INCREASING debt and re-deploying it
///   to yield while the protocol is supposed to be winding down.
///
/// This is a fork-free unit test with a controllable MockLoanManager (LTV forced below the
/// lower deadband) and a mock yield strategy. We assert:
///   (1) harvestYield() reverts EmergencyModeActive during emergency,
///   (2) rebalance() does NOT revert EmergencyModeActive during emergency (it proceeds), and
///   (3) rebalance() reaches the debt-INCREASE path: loanManager.borrowMore() is invoked.

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../../src/Zenji.sol";
import { ZenjiViewHelper } from "../../src/ZenjiViewHelper.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../../src/interfaces/ISwapper.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice A yield strategy mock that holds debt asset and reports it as balanceOf().
contract MockStrategy is IYieldStrategy {
    IERC20 public debt;
    address public override vault;
    address public initializer;
    uint256 internal _bal; // reported balance in debt terms
    uint256 internal _basis;

    constructor(address _debt) {
        debt = IERC20(_debt);
        initializer = msg.sender;
    }

    function initializeVault(address v) external {
        require(msg.sender == initializer, "init");
        vault = v;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "onlyVault");
        _;
    }

    function deposit(uint256 amt) external onlyVault returns (uint256) {
        debt.transferFrom(msg.sender, address(this), amt);
        _bal += amt;
        _basis += amt;
        return amt;
    }

    function withdraw(uint256 amt) external onlyVault returns (uint256) {
        uint256 w = amt > _bal ? _bal : amt;
        _bal -= w;
        _basis = _basis > w ? _basis - w : 0;
        debt.transfer(vault, w);
        return w;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 w = _bal;
        _bal = 0;
        _basis = 0;
        if (w > 0) debt.transfer(vault, w);
        return w;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
        uint256 w = _bal;
        _bal = 0;
        _basis = 0;
        if (w > 0) debt.transfer(vault, w);
        return w;
    }

    function asset() external view returns (address) {
        return address(debt);
    }

    function underlyingAsset() external view returns (address) {
        return address(debt);
    }

    function balanceOf() external view returns (uint256) {
        return _bal;
    }

    function costBasis() external view returns (uint256) {
        return _basis;
    }

    function unrealizedProfit() external view returns (uint256) {
        return _bal > _basis ? _bal - _basis : 0;
    }

    function pendingRewards() external pure returns (uint256) {
        return 0;
    }

    function name() external pure returns (string memory) {
        return "MockStrategy";
    }

    function transferOwnerFromVault(address) external { }

    function setSlippage(uint256) external { }

    function updateCachedVirtualPrice() external { }
}

/// @notice A fully controllable loan manager mock. We drive getCurrentLTV()/getPositionValues()
///         to force the rebalance() debt-INCREASE branch, and record whether borrowMore() ran.
contract MockLoanManager is ILoanManager {
    IERC20 public coll;
    IERC20 public dbt;
    address public vault;

    uint256 public ltv; // current LTV (1e18 = 100%)
    uint256 public collateralAmt; // raw collateral units
    uint256 public debtAmt; // raw debt units
    bool public exists = true;

    // Observability
    bool public borrowMoreCalled;
    uint256 public lastBorrowMoreDebt;

    constructor(address _coll, address _dbt, address _vault) {
        coll = IERC20(_coll);
        dbt = IERC20(_dbt);
        vault = _vault;
    }

    function setState(uint256 _ltv, uint256 _coll, uint256 _debt) external {
        ltv = _ltv;
        collateralAmt = _coll;
        debtAmt = _debt;
    }

    // ----- mutating -----
    function createLoan(uint256, uint256) external { }

    function addCollateral(uint256) external { }

    function borrowMore(uint256, uint256 debt) external {
        borrowMoreCalled = true;
        lastBorrowMoreDebt = debt;
        debtAmt += debt;
        // mint the borrowed debt asset to ourselves so the vault can transfer it out
        MockERC20(address(dbt)).mint(address(this), debt);
    }

    function repayDebt(uint256 amount) external {
        debtAmt = amount >= debtAmt ? 0 : debtAmt - amount;
    }

    function removeCollateral(uint256) external { }

    function unwindPosition(uint256) external { }

    function emergencyUnwindPosition() external { }

    // ----- views -----
    function getCurrentLTV() external view returns (uint256) {
        return ltv;
    }

    function getCurrentCollateral() external view returns (uint256) {
        return collateralAmt;
    }

    function getCurrentDebt() external view returns (uint256) {
        return debtAmt;
    }

    function collateralAsset() external view returns (address) {
        return address(coll);
    }

    function debtAsset() external view returns (address) {
        return address(dbt);
    }

    function getHealth() external pure returns (int256) {
        return 2e18;
    }

    function loanExists() external view returns (bool) {
        return exists;
    }

    // 1 collateral unit (8dec) = $60k => value in debt(18dec) terms.
    function getCollateralValue(uint256 amount) external pure returns (uint256) {
        return amount * 60_000e10; // 1e8 collat -> 60_000e18 debt value
    }

    function getDebtValue(uint256 amount) external pure returns (uint256) {
        return amount / 60_000 / 1e10;
    }

    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        pure
        returns (uint256)
    {
        return (collateral * 60_000e10 * targetLtv) / 1e18;
    }

    function healthCalculator(int256, int256) external pure returns (int256) {
        return 2e18;
    }

    function minCollateral(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPositionValues() external view returns (uint256, uint256) {
        return (collateralAmt, debtAmt);
    }

    function getNetCollateralValue() external pure returns (uint256) {
        return 0;
    }

    function checkOracleFreshness() external view { }

    function maxLtvBps() external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferCollateral(address to, uint256 amount) external {
        coll.transfer(to, amount);
    }

    function transferDebt(address to, uint256 amount) external {
        dbt.transfer(to, amount);
    }

    function getCollateralBalance() external view returns (uint256) {
        return coll.balanceOf(address(this));
    }

    function getDebtBalance() external view returns (uint256) {
        return dbt.balanceOf(address(this));
    }
}

contract MockSwapper is ISwapper {
    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) {
        return d;
    }

    function swapCollateralForDebt(uint256 a) external pure returns (uint256) {
        return a;
    }

    function swapDebtForCollateral(uint256 a) external pure returns (uint256) {
        return a;
    }
}

contract M05_EmergencyGuardGapTest is Test {
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MockStrategy strategy;
    MockLoanManager loanManager;
    MockSwapper swapper;
    ZenjiViewHelper viewHelper;
    Zenji vault;

    address owner = makeAddr("owner"); // gov + strategist + guardian
    address keeper = makeAddr("keeper");

    error EmergencyModeActive();

    function setUp() public {
        vm.warp(1_710_000_000);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        viewHelper = new ZenjiViewHelper();

        // Predict vault address (loanManager + strategy + swapper + vault = 4 deploys after this).
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        loanManager = new MockLoanManager(address(wbtc), address(crvUSD), predictedVault);
        strategy = new MockStrategy(address(crvUSD));
        swapper = new MockSwapper();

        vault = new Zenji(
            address(wbtc),
            address(crvUSD),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == predictedVault, "vault addr mismatch");

        strategy.initializeVault(address(vault));

        // Seed a position: 1 WBTC collateral, debt well BELOW target (forces LTV under lower band).
        // targetLtv defaults to MAX_TARGET_LTV() = 65%. DEADBAND_SPREAD makes lowerBand < 65%.
        // Set current LTV to 1% so it is decisively below the lower deadband => increase path.
        loanManager.setState(1e16 /*1% LTV*/, 1e8 /*1 WBTC*/, 600e18 /*small debt*/);
    }

    /// @notice (1) harvestYield() reverts EmergencyModeActive during emergency.
    function test_M05_harvestYield_blockedInEmergency() public {
        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.expectRevert(EmergencyModeActive.selector);
        vault.harvestYield();

        console.log("[M05] harvestYield() correctly reverts EmergencyModeActive in emergency");
    }

    /// @notice (2) FIX VERIFICATION: rebalance() now reverts EmergencyModeActive in emergency.
    function test_M05_rebalance_notBlockedInEmergency_increasesDebt() public {
        // Enter emergency mode (guardian).
        vm.prank(owner);
        vault.enterEmergencyMode();
        assertTrue(vault.emergencyMode(), "emergency active");

        assertFalse(loanManager.borrowMoreCalled(), "precondition: no borrowMore yet");

        // FIX: rebalance() now reverts EmergencyModeActive when called during emergency.
        vm.prank(keeper);
        vm.expectRevert(EmergencyModeActive.selector);
        vault.rebalance();

        // Position unchanged — debt increase path never reached.
        assertFalse(loanManager.borrowMoreCalled(), "FIX: borrowMore() NOT called during emergency");

        console.log("[M05 FIX VERIFIED] rebalance() correctly reverts EmergencyModeActive in emergency");
    }

    /// @notice CONTRAST: prove the EmergencyModeActive revert in (1) is specifically the emergency
    ///         guard — rebalance() with the SAME state and NO emergency proceeds identically.
    function test_M05_rebalance_normalMode_baseline() public {
        // No emergency. rebalance() should also proceed and increase debt (same code path),
        // proving the only difference for harvestYield() vs rebalance() is the missing guard.
        vm.prank(keeper);
        vault.rebalance();
        assertTrue(loanManager.borrowMoreCalled(), "baseline: borrowMore called in normal mode");
        console.log("[M05 BASELINE] rebalance() increases debt identically in normal mode");
    }
}
