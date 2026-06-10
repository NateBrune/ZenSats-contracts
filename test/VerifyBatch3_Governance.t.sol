// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title VerifyBatch3_Governance
/// @notice PoC tests for HYP-04, HYP-05, HYP-08, HYP-10, HYP-12, HYP-17
///         (governance / facet / fee accounting domain — Batch 3)
///
/// Tests are unit-only (no fork required). Each test is named test_POC_HYPXX.

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ZenjiAdmin } from "../src/ZenjiAdmin.sol";
import { BaseYieldStrategy } from "../src/strategies/BaseYieldStrategy.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================
//  Shared Mocks
// ============================================================

contract MockERC20B3 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockLoanManagerB3 is ILoanManager {
    address public collateralAsset;
    address public debtAsset;

    constructor(address c, address d) { collateralAsset = c; debtAsset = d; }

    function createLoan(uint256, uint256) external override { }
    function addCollateral(uint256) external override { }
    function borrowMore(uint256, uint256) external override { }
    function repayDebt(uint256) external override { }
    function removeCollateral(uint256) external override { }
    function unwindPosition(uint256) external override { }
    function emergencyUnwindPosition() external override { }
    function transferCollateral(address, uint256) external override { }
    function transferDebt(address, uint256) external override { }
    function checkOracleFreshness() external view override { }
    function maxLtvBps() external pure override returns (uint256) { return type(uint256).max; }
    function getCurrentLTV() external pure override returns (uint256) { return 0; }
    function getCurrentCollateral() external pure override returns (uint256) { return 0; }
    function getCurrentDebt() external pure override returns (uint256) { return 0; }
    function getHealth() external pure override returns (int256) { return 1e18; }
    function loanExists() external pure override returns (bool) { return false; }
    function getCollateralValue(uint256 a) external pure override returns (uint256) { return a; }
    function getDebtValue(uint256 a) external pure override returns (uint256) { return a; }
    function calculateBorrowAmount(uint256, uint256) external pure override returns (uint256) { return 0; }
    function healthCalculator(int256, int256) external pure override returns (int256) { return 1e18; }
    function minCollateral(uint256, uint256) external pure override returns (uint256) { return 0; }
    function getPositionValues() external pure override returns (uint256, uint256) { return (0, 0); }
    function getNetCollateralValue() external pure override returns (uint256) { return 0; }
    function getCollateralBalance() external pure override returns (uint256) { return 0; }
    function getDebtBalance() external pure override returns (uint256) { return 0; }
}

/// @dev A yield strategy that can be made to revert on transferOwnerFromVault
///      (simulates a paused/bricked strategy scenario for HYP-04).
contract MockYieldStrategyB3 is IYieldStrategy {
    address public vault;
    address public owner;
    address public immutable _asset;
    MockERC20B3 private _token;
    bool public revertOnOwnerTransfer;
    uint256 public slippageTolerance;

    constructor(address asset_, address vault_, address owner_) {
        _asset = asset_;
        vault = vault_;
        owner = owner_;
        _token = MockERC20B3(asset_);
        slippageTolerance = 1e16;
    }

    function setRevertOnOwnerTransfer(bool v) external { revertOnOwnerTransfer = v; }

    function transferOwner(address newOwner) external {
        if (msg.sender != owner) revert("Unauthorized");
        if (newOwner == address(0)) revert("InvalidAddress");
        // Mirrors BaseYieldStrategy: locked once vault.code.length > 0
        if (vault != address(0) && vault.code.length > 0) revert("Unauthorized");
        owner = newOwner;
    }

    function transferOwnerFromVault(address newOwner) external override {
        if (revertOnOwnerTransfer) revert("strategy: locked");
        owner = newOwner;
    }

    function setSlippage(uint256 s) external override {
        // Mirrors BaseYieldStrategy: only vault or owner can call
        if (msg.sender != vault && msg.sender != owner) revert("Unauthorized");
        // Enforce MIN_SLIPPAGE like BaseYieldStrategy does:
        require(s >= 1e15 && s <= 5e16, "SlippageExceeded");
        slippageTolerance = s;
    }

    function deposit(uint256) external pure override returns (uint256) { return 0; }
    function withdraw(uint256 amt) external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        uint256 out = amt < bal ? amt : bal;
        if (out > 0) _token.transfer(vault, out);
        return out;
    }
    function withdrawAll() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) _token.transfer(vault, bal);
        return bal;
    }
    function harvest() external pure override returns (uint256) { return 0; }
    function emergencyWithdraw() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) _token.transfer(vault, bal);
        return bal;
    }
    function asset() external view override returns (address) { return _asset; }
    function underlyingAsset() external view override returns (address) { return _asset; }
    function balanceOf() external view override returns (uint256) {
        return _token.balanceOf(address(this));
    }
    function costBasis() external pure override returns (uint256) { return 0; }
    function unrealizedProfit() external pure override returns (uint256) { return 0; }
    function pendingRewards() external pure override returns (uint256) { return 0; }
    function name() external pure override returns (string memory) { return "MockB3"; }
    function updateCachedVirtualPrice() external override { }
}

contract MockSwapperB3 is ISwapper {
    MockERC20B3 public immutable col;
    MockERC20B3 public immutable dbt;

    constructor(address c, address d) { col = MockERC20B3(c); dbt = MockERC20B3(d); }

    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) { return d; }
    function swapCollateralForDebt(uint256 a) external returns (uint256) {
        dbt.mint(msg.sender, a);
        return a;
    }
    function swapDebtForCollateral(uint256 a) external returns (uint256) {
        col.mint(msg.sender, a);
        return a;
    }
}

// ============================================================
//  Helper: minimal Chainlink oracle mock (for CrvToCrvUsdSwapper constructor)
// ============================================================

interface IChainlinkMock {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract MockChainlink {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// ============================================================
//  Helper: minimal Curve TriCrypto mock
// ============================================================

contract MockCurveTriCrypto {
    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        return dx; // 1:1 swap for simplicity
    }
    function exchange(uint256, uint256, uint256 dx, uint256, bool) external pure returns (uint256) {
        return dx;
    }
}

// ============================================================
//  Test Suite
// ============================================================

contract VerifyBatch3_Governance is Test {

    // ── Shared setup state ──
    MockERC20B3 collateral;
    MockERC20B3 debt;
    MockLoanManagerB3 lm;
    MockYieldStrategyB3 strategy;
    MockSwapperB3 swapper;
    ZenjiViewHelper viewHelper;
    Zenji vault;

    address gov;
    address guardian;
    address strategist;
    address newGov;
    address oldGov;

    function setUp() public {
        gov = makeAddr("gov");
        guardian = makeAddr("guardian");
        strategist = makeAddr("strategist");
        newGov = makeAddr("newGov");
        oldGov = gov;

        collateral = new MockERC20B3("WBTC", "WBTC", 8);
        debt = new MockERC20B3("USDT", "USDT", 6);

        // Predict vault address so strategy can reference it
        uint256 startNonce = vm.getNonce(address(this));
        // lm=+0, strategy=+1, swapper=+2, viewHelper=+3, vault=+4
        address expectedVault = vm.computeCreateAddress(address(this), startNonce + 4);

        lm = new MockLoanManagerB3(address(collateral), address(debt));
        strategy = new MockYieldStrategyB3(address(debt), expectedVault, gov);
        swapper = new MockSwapperB3(address(collateral), address(debt));
        viewHelper = new ZenjiViewHelper();

        vault = new Zenji(
            address(collateral),
            address(debt),
            address(lm),
            address(strategy),
            address(swapper),
            gov,
            address(viewHelper)
        );
        require(address(vault) == expectedVault, "vault address mismatch");

        // Make gov also the strategist (constructor sets all roles to _owner=gov)
    }

    // ============================================================
    //  HYP-04: Gov/Strategy Owner Permanent Divergence
    // ============================================================

    /// @notice PoC: After acceptRole(1) with a reverting strategy, vault.gov is updated
    ///         but strategy.owner remains the OLD key. The old key can still call
    ///         strategy.setSlippage() directly. New gov cannot force re-sync
    ///         (transferOwner is locked once vault.code.length > 0).
    function test_POC_HYP04_GovStrategyOwnerDivergence() public {
        // PRE-CONDITIONS: verify initial state
        assertEq(vault.gov(), gov, "HYP-04: initial gov wrong");
        assertEq(strategy.owner(), gov, "HYP-04: initial strategy.owner wrong");

        // Make strategy revert on ownership transfer (simulates bricked/paused strategy)
        strategy.setRevertOnOwnerTransfer(true);

        // Step 1: Gov initiates transfer
        vm.prank(gov);
        vault.transferRole(1, newGov);

        // Step 2: Warp past the role-transfer delay
        vm.warp(block.timestamp + vault.GOV_GUARDIAN_TRANSFER_DELAY() + 1);

        // FIXED (M-02): acceptRole now propagates ownership to the strategy WITHOUT try/catch,
        // so if the strategy cannot accept the new owner the entire rotation reverts. There is
        // no silent divergence.
        vm.prank(newGov);
        vm.expectRevert();
        vault.acceptRole(1);

        // Rotation rolled back atomically — both unchanged, no divergence.
        assertEq(vault.gov(), gov, "M-02: vault.gov unchanged after failed propagation");
        assertEq(strategy.owner(), gov, "M-02: strategy.owner unchanged (no divergence)");

        // Once the strategy is transferable, the rotation succeeds and BOTH advance together.
        strategy.setRevertOnOwnerTransfer(false);
        vm.prank(newGov);
        vault.acceptRole(1);
        assertEq(vault.gov(), newGov, "M-02: rotation succeeds when strategy is transferable");
        assertEq(strategy.owner(), newGov, "M-02: strategy.owner propagated atomically");

        console.log("M-02 FIXED: gov rotation is atomic; vault.gov and strategy.owner cannot diverge");
    }

    // ============================================================
    //  HYP-05: CrvToCrvUsdSwapper Slippage Cap Removed
    // ============================================================

    /// @notice PoC: CrvToCrvUsdSwapper.setSlippage() uses `>= PRECISION` guard (not `> MAX_SLIPPAGE`).
    ///         BaseSwapper uses `> MAX_SLIPPAGE` (5e16). This allows 9e17 = 90% slippage via the
    ///         override, while BaseSwapper would revert.
    function test_POC_HYP05_CrvToCrvUsdSwapperSlippageCapRemoved() public {
        // Deploy mocks needed by CrvToCrvUsdSwapper constructor
        MockChainlink crvOracle = new MockChainlink();
        MockChainlink crvUsdOracle = new MockChainlink();
        MockCurveTriCrypto triCrypto = new MockCurveTriCrypto();
        MockERC20B3 crv = new MockERC20B3("CRV", "CRV", 18);
        MockERC20B3 crvUSD = new MockERC20B3("crvUSD", "crvUSD", 18);

        address swapperGov = makeAddr("swapperGov");

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            swapperGov,
            address(crv),
            address(crvUSD),
            address(triCrypto),
            address(crvOracle),
            address(crvUsdOracle)
        );

        // Record initial slippage
        uint256 initialSlippage = crvSwapper.slippage();
        assertEq(initialSlippage, 1e16, "HYP-05: initial slippage should be 1%");

        // BASELINE: confirm BaseSwapper MAX_SLIPPAGE = 5e16
        assertEq(BaseSwapper(address(crvSwapper)).MAX_SLIPPAGE(), 5e16, "HYP-05: MAX_SLIPPAGE should be 5e16");

        // FIXED (M-03): CrvToCrvUsdSwapper now enforces the BaseSwapper MAX_SLIPPAGE (5%) cap.
        // 90% slippage must REVERT (previously accepted via the >= PRECISION guard).
        vm.prank(swapperGov);
        vm.expectRevert(); // InvalidSlippage — 9e17 > MAX_SLIPPAGE (5e16)
        crvSwapper.setSlippage(9e17);

        // Exactly at the 5% cap is allowed.
        vm.prank(swapperGov);
        crvSwapper.setSlippage(5e16);
        assertEq(crvSwapper.slippage(), 5e16, "M-03: slippage settable up to the 5% cap");

        // Just above the cap reverts.
        vm.prank(swapperGov);
        vm.expectRevert(); // InvalidSlippage
        crvSwapper.setSlippage(5e16 + 1);

        console.log("M-03 FIXED: CrvToCrvUsdSwapper enforces 5%% MAX_SLIPPAGE cap");
    }

    // ============================================================
    //  HYP-08: withdrawFees resets feesAtLastRebalance=0 → keeper bounty overcounting
    // ============================================================

    /// @notice Code-trace PoC:
    ///
    ///   withdrawFees() at Zenji.sol:726:
    ///     feesAtLastRebalance = accumulatedFees;
    ///
    ///   But processWithdrawFees returns newAccumulatedFees = 0 (fees fully cleared).
    ///   So feesAtLastRebalance = 0 after withdrawFees.
    ///
    ///   Then if any NEW yield accrues before the next rebalance:
    ///     processRebalanceBounty: feesSinceLastRebalance = accumulatedFees - feesAtLastRebalance
    ///                                                     = X - 0 = X
    ///   So the keeper's bounty is based on the FULL accumulated fees since withdrawFees,
    ///   not just since the last rebalance. This overcounts the bounty denominator.
    ///
    /// The bug: feesAtLastRebalance should remain at the last *rebalance* checkpoint.
    /// After withdrawFees drains accumulatedFees to 0, feesAtLastRebalance should also
    /// become 0 (correct) — BUT the next rebalance then pays bounty on all post-withdraw fees,
    /// as if all those fees accrued in one rebalance period. The correct behavior would be
    /// to track the last rebalance's accumulatedFees independently of the withdraw path.
    ///
    /// Concrete scenario: Rebalance at T=0 (feesAtLastRebalance=100). withdrawFees at T=1
    /// (feesAtLastRebalance reset to 0). New yield accrues: accumulatedFees=50. Rebalance at T=2:
    /// bounty = (50-0) * 20% = 10. But the correct bounty should be (50-0)*20% = 10 which
    /// is the same in this simplified case — the REAL issue surfaces when withdrawFees is called
    /// BEFORE fees since last rebalance are all cleared (partial withdrawal), or when the
    /// feesAtLastRebalance reset causes inflated basis for the next cycle.
    ///
    /// The deeper issue: after withdrawFees, feesAtLastRebalance = 0, which means the NEXT
    /// rebalance bounty uses zero as its basis, so all post-withdraw fees appear as
    /// "since last rebalance" fees even if a rebalance happened recently that already paid out.
    function test_POC_HYP08_WithdrawFeesResetsKeeperBountyBasis() public {
        // Setup: deposit collateral and configure fee rate so fees accrue
        address depositor = makeAddr("depositor");
        collateral.mint(depositor, 100e8);
        vm.startPrank(depositor);
        collateral.approve(address(vault), 100e8);
        vault.deposit(100e8, depositor);
        vm.stopPrank();

        // Set feeRate = 10% — this is an adverse increase, timelocked by PARAM_TIMELOCK_DELAY (1 week)
        vm.prank(gov);
        vault.setParam(0, 1e17); // propose feeRate = 10%
        // Warp past the 1-week delay and execute the param change
        vm.warp(block.timestamp + vault.PARAM_TIMELOCK_DELAY() + 1);
        vm.prank(gov);
        vault.executeParamChange(0);

        // Simulate yield: mint debt tokens to strategy (increases strategy.balanceOf())
        debt.mint(address(strategy), 1000e6);

        // --- Fee accrual: use permissionless accrueYieldFees ---
        vault.accrueYieldFees();

        uint256 accFeesAfterAccrual = vault.accumulatedFees();
        uint256 feesAtLastRbAfterAccrual = vault.feesAtLastRebalance();

        console.log("After accrual: accumulatedFees=%d", accFeesAfterAccrual);
        console.log("After accrual: feesAtLastRebalance=%d", feesAtLastRbAfterAccrual);

        // feesAtLastRebalance is only updated by rebalance() or withdrawFees().
        // accrueYieldFees just updates accumulatedFees and lastStrategyBalance.
        // So feesAtLastRebalance is still 0 at this point.
        assertEq(feesAtLastRbAfterAccrual, 0, "HYP-08: feesAtLastRebalance starts at 0");
        assertGt(accFeesAfterAccrual, 0, "HYP-08: fees should have accrued");

        // Record the accumulated fees that represent "profit since last rebalance"
        uint256 feesBeforeWithdraw = accFeesAfterAccrual;

        // --- WITHDRAWFEES: drains accumulatedFees → resets feesAtLastRebalance to 0 ---
        vm.prank(gov); // gov == strategist in this setup
        vault.withdrawFees(gov);

        uint256 accFeesAfterWithdraw = vault.accumulatedFees();
        uint256 feesAtLastRbAfterWithdraw = vault.feesAtLastRebalance();

        console.log("After withdrawFees: accumulatedFees=%d", accFeesAfterWithdraw);
        console.log("After withdrawFees: feesAtLastRebalance=%d", feesAtLastRbAfterWithdraw);

        // ASSERTION: both should be 0 after full withdrawal
        assertEq(accFeesAfterWithdraw, 0, "HYP-08: accumulatedFees drained to 0");
        assertEq(feesAtLastRbAfterWithdraw, 0, "HYP-08: feesAtLastRebalance reset to 0");

        // --- NEW YIELD ACCRUES after withdrawFees ---
        // Mint MORE yield to strategy
        debt.mint(address(strategy), 1000e6); // another 1000 USDT yield
        vault.accrueYieldFees();

        uint256 accFeesAfterNewYield = vault.accumulatedFees();
        console.log("After new yield: accumulatedFees=%d", accFeesAfterNewYield);
        assertGt(accFeesAfterNewYield, 0, "HYP-08: new fees should accrue");

        // CORE ASSERTION: feesAtLastRebalance = 0, so the entire post-withdraw yield
        // will be counted as "since last rebalance" by processRebalanceBounty.
        // This is the overcounting: the keeper bounty basis is inflated by including
        // fees that accrued AFTER withdrawFees cleared the slate.
        //
        // The bounty formula: feesSinceLastRebalance = accumulatedFees - feesAtLastRebalance
        //                                             = accFeesAfterNewYield - 0
        //                                             = FULL post-withdraw amount
        //
        // If withdrawFees had NOT reset feesAtLastRebalance to 0, and a prior rebalance
        // had set it to some value V, then feesSinceLastRebalance = accumulatedFees - V,
        // which would correctly exclude fees paid out before this rebalance window.
        uint256 feesSinceLastRebalance = accFeesAfterNewYield - feesAtLastRbAfterWithdraw;
        uint256 bountyAtDefaultRate = (feesSinceLastRebalance * vault.rebalanceBountyRate()) / 1e18;

        console.log("HYP-08: feesSinceLastRebalance (bounty basis)=%d", feesSinceLastRebalance);
        console.log("HYP-08: keeper bounty at 20% rate=%d", bountyAtDefaultRate);
        console.log("HYP-08: This equals the FULL post-withdraw yield -- feesAtLastRebalance=0");

        // FIXED (M-05): withdrawFees no longer force-resets feesAtLastRebalance. In THIS scenario
        // no rebalance has occurred, so the checkpoint is legitimately 0 (its initial value) — the
        // fix ensures withdrawFees does not touch it. The meaningful case (preserving a NON-zero
        // checkpoint set by a prior rebalance so the bounty baseline can't be zeroed by a fee
        // withdrawal) is exercised by the fee-accounting invariant suite.
        assertEq(
            vault.feesAtLastRebalance(),
            0,
            "M-05: checkpoint unchanged by withdrawFees (0 here - no prior rebalance)"
        );
        assertGt(feesSinceLastRebalance, 0, "post-withdraw yield accrued");
    }

    // ============================================================
    //  HYP-10 / CH-04: Split Slippage Authority (chain of HYP-04 + HYP-07)
    // ============================================================

    /// @notice Code-trace PoC for chain: HYP-04 postcondition (old strategy.owner retained)
    ///         enables the split-authority scenario from HYP-07.
    ///
    ///   HYP-04: After failed gov rotation, old gov key retains strategy.owner
    ///   HYP-07: New gov cannot set strategy slippage below MIN_SLIPPAGE (1e15) via setParam
    ///           because strategy.setSlippage reverts with SlippageExceeded for values < 1e15.
    ///
    ///   Chain: Old gov (strategy.owner) can call strategy.setSlippage directly with any
    ///          valid value (1e15..5e16). New gov, lacking strategy.owner, cannot update
    ///          strategy slippage directly AT ALL (only via vault's setParam which propagates
    ///          to strategy.setSlippage — but that call succeeds for valid values too).
    ///          The real split authority risk: old gov can LOWER slippage below what new gov
    ///          wants (or conversely raise it to MAX within range), with no on-chain recourse
    ///          for new gov since re-sync is blocked.
    function test_POC_HYP10_SplitSlippageAuthority() public {
        // FIXED (M-02): the chain's enabler — a silent strategy-ownership-propagation failure
        // that leaves the old key as strategy.owner — can no longer occur. acceptRole now reverts
        // atomically when the strategy can't accept the new owner, so the dual-authority split
        // (old key keeps strategy.setSlippage / rescueERC20 while new gov controls the vault)
        // is structurally impossible.
        strategy.setRevertOnOwnerTransfer(true);

        vm.prank(gov);
        vault.transferRole(1, newGov);
        vm.warp(block.timestamp + vault.GOV_GUARDIAN_TRANSFER_DELAY() + 1);

        // Rotation reverts — the divergence precondition is never established.
        vm.prank(newGov);
        vm.expectRevert();
        vault.acceptRole(1);

        // gov and strategy.owner remain the same single key — no split authority.
        assertEq(vault.gov(), gov, "CH04 FIXED: vault.gov unchanged");
        assertEq(strategy.owner(), gov, "CH04 FIXED: strategy.owner == vault.gov (no split)");

        console.log("HYP-10/CH-04 FIXED: gov/strategy-owner split cannot be created");
    }

    // ============================================================
    //  HYP-12 (Low): maxDeposit ignores depositsPaused
    // ============================================================

    /// @notice PoC: maxDeposit() does NOT check depositsPaused, returns non-zero
    ///         while deposit() reverts with DepositsArePaused.
    function test_POC_HYP12_MaxDepositIgnoresDepositsPaused() public {
        // Confirm initial state: deposits not paused, maxDeposit returns non-zero
        assertFalse(vault.depositsPaused(), "HYP-12: deposits not paused initially");
        uint256 maxBefore = vault.maxDeposit(address(this));
        assertGt(maxBefore, 0, "HYP-12: maxDeposit non-zero initially");

        // Guardian pauses deposits
        vm.prank(gov); // gov == guardian in this setup
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused(), "HYP-12: deposits now paused");

        // ASSERTION A (FIXED L-01): maxDeposit now returns 0 while deposits are paused,
        // consistent with deposit() reverting (EIP-4626 compliant).
        uint256 maxAfterPause = vault.maxDeposit(address(this));
        assertEq(maxAfterPause, 0, "L-01: maxDeposit returns 0 while deposits paused");

        // ASSERTION B: deposit() still reverts — now consistent with maxDeposit == 0.
        address depositor = makeAddr("depositor2");
        collateral.mint(depositor, 1e8);
        vm.startPrank(depositor);
        collateral.approve(address(vault), 1e8);
        vm.expectRevert(); // DepositsArePaused
        vault.deposit(1e8, depositor);
        vm.stopPrank();

        console.log("L-01 FIXED: maxDeposit returns 0 while depositsPaused; consistent with deposit() revert");
    }

    // ============================================================
    //  HYP-17 (Low): cancelEmergencyMode leaves depositsPaused set
    // ============================================================

    /// @notice PoC: cancelEmergencyMode() clears emergencyMode but NOT depositsPaused.
    ///         If guardian called pauseDeposits before enterEmergencyMode, or if
    ///         enterEmergencyMode was preceded by a pause, deposits remain blocked
    ///         after cancellation with no automated clearing.
    function test_POC_HYP17_CancelEmergencyModeLeavesPausedSet() public {
        // Step 1: Guardian pauses deposits
        vm.prank(gov); // gov == guardian here
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused(), "HYP-17: deposits paused");

        // Step 2: Guardian enters emergency mode
        vm.prank(gov);
        vault.enterEmergencyMode();
        assertTrue(vault.emergencyMode(), "HYP-17: emergency mode active");

        // Step 3: Gov cancels emergency mode (before any steps execute)
        vm.prank(gov);
        vault.cancelEmergencyMode();
        assertFalse(vault.emergencyMode(), "HYP-17: emergency mode cancelled");

        // ASSERTION: depositsPaused is STILL true after cancelEmergencyMode
        assertTrue(
            vault.depositsPaused(),
            "HYP-17 BUG: depositsPaused still set after cancelEmergencyMode"
        );

        // ASSERTION: deposits are still blocked
        address depositor = makeAddr("depositor3");
        collateral.mint(depositor, 1e8);
        vm.startPrank(depositor);
        collateral.approve(address(vault), 1e8);
        vm.expectRevert(); // DepositsArePaused
        vault.deposit(1e8, depositor);
        vm.stopPrank();

        // To resume, gov must explicitly call resumeDeposits()
        vm.prank(gov);
        vault.resumeDeposits();
        assertFalse(vault.depositsPaused(), "HYP-17: deposits resumed after explicit call");

        console.log("HYP-17 CONFIRMED: depositsPaused remains set after cancelEmergencyMode");
        console.log("HYP-17: gov must call resumeDeposits() separately -- not obvious from interface");
    }
}
