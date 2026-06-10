// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title M-06: Guardian key loss -> up to 4-week emergency blindness
///
/// HYPOTHESIS (MEDIUM/LOW):
///   All emergency entry points are onlyGuardian:
///       enterEmergencyMode(), emergencyStep(), emergencySkipStep(), rescueAssets(),
///       emergencyRescue(), pauseDeposits().
///   Guardian rotation uses GOV_GUARDIAN_TRANSFER_DELAY = 4 weeks (ZenjiConstants), with no
///   accelerated path. There is NO Gov fallback that can call enterEmergencyMode() directly.
///   Therefore if the guardian key is lost on day 0, the SOONEST a freshly-rotated guardian can
///   act is day 28 (4 weeks). During that window the ONLY way to trigger emergency mode is the
///   OLD (lost) guardian key.
///
/// This is a fork-free unit test. We demonstrate:
///   (1) GOV_GUARDIAN_TRANSFER_DELAY == 4 weeks,
///   (2) gov.transferRole(2, newGuardian) starts a 4-week timer,
///   (3) newGuardian.acceptRole(2) reverts before the delay elapses,
///   (4) gov CANNOT call enterEmergencyMode() directly (onlyGuardian),
///   (5) earliest day the new guardian can act == day 28.
///
/// FIX UNDER TEST (M-06 break-glass):
///   govEnterEmergencyMode() lets gov enter emergency mode behind a 48h timelock
///   (GOV_EMERGENCY_DELAY), cutting the key-loss blackout from 4 weeks to 2 days. Scope is
///   minimal: gov gains only ENTRY (a defensive stop); emergency steps stay guardian-only so a
///   compromised gov cannot force a lossy liquidation. The guardian (or gov) can veto a pending
///   proposal via cancelGovEmergency() during the 48h window.

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../../src/Zenji.sol";
import { ZenjiViewHelper } from "../../src/ZenjiViewHelper.sol";
import { TimelockLib } from "../../src/libraries/TimelockLib.sol";
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

contract MinimalStrategy is IYieldStrategy {
    address public override vault;
    address public initializer;
    IERC20 public debt;

    constructor(address _debt) {
        debt = IERC20(_debt);
        initializer = msg.sender;
    }

    function initializeVault(address v) external {
        require(msg.sender == initializer, "init");
        vault = v;
        initializer = address(0);
    }

    function deposit(uint256) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256) external pure returns (uint256) {
        return 0;
    }

    function withdrawAll() external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function emergencyWithdraw() external pure returns (uint256) {
        return 0;
    }

    function asset() external view returns (address) {
        return address(debt);
    }

    function underlyingAsset() external view returns (address) {
        return address(debt);
    }

    function balanceOf() external pure returns (uint256) {
        return 0;
    }

    function costBasis() external pure returns (uint256) {
        return 0;
    }

    function unrealizedProfit() external pure returns (uint256) {
        return 0;
    }

    function pendingRewards() external pure returns (uint256) {
        return 0;
    }

    function name() external pure returns (string memory) {
        return "Minimal";
    }

    function transferOwnerFromVault(address) external { }

    function setSlippage(uint256) external { }

    function updateCachedVirtualPrice() external { }
}

contract MinimalLoanManager is ILoanManager {
    IERC20 public coll;
    IERC20 public dbt;

    constructor(address _c, address _d) {
        coll = IERC20(_c);
        dbt = IERC20(_d);
    }

    function createLoan(uint256, uint256) external { }

    function addCollateral(uint256) external { }

    function borrowMore(uint256, uint256) external { }

    function repayDebt(uint256) external { }

    function removeCollateral(uint256) external { }

    function unwindPosition(uint256) external { }

    function emergencyUnwindPosition() external { }

    function getCurrentLTV() external pure returns (uint256) {
        return 0;
    }

    function getCurrentCollateral() external pure returns (uint256) {
        return 0;
    }

    function getCurrentDebt() external pure returns (uint256) {
        return 0;
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

    function loanExists() external pure returns (bool) {
        return false;
    }

    function getCollateralValue(uint256 a) external pure returns (uint256) {
        return a;
    }

    function getDebtValue(uint256 a) external pure returns (uint256) {
        return a;
    }

    function calculateBorrowAmount(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function healthCalculator(int256, int256) external pure returns (int256) {
        return 2e18;
    }

    function minCollateral(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPositionValues() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function getNetCollateralValue() external pure returns (uint256) {
        return 0;
    }

    function checkOracleFreshness() external view { }

    function maxLtvBps() external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferCollateral(address, uint256) external { }

    function transferDebt(address, uint256) external { }

    function getCollateralBalance() external pure returns (uint256) {
        return 0;
    }

    function getDebtBalance() external pure returns (uint256) {
        return 0;
    }
}

contract MinimalSwapper is ISwapper {
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

contract M06_GuardianKeyLossTest is Test {
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MinimalStrategy strategy;
    MinimalLoanManager loanManager;
    MinimalSwapper swapper;
    ZenjiViewHelper viewHelper;
    Zenji vault;

    address owner = makeAddr("owner"); // initial deploy holds all three roles; guardian stays here
    address govAddr = makeAddr("govAddr"); // distinct gov after role separation
    address strategistAddr = makeAddr("strategistAddr");
    address newGuardian = makeAddr("newGuardian");

    error Unauthorized();

    // Stored (not local) to defeat optimizer re-reading block.timestamp for these snapshots.
    uint256 internal s_lossTime;
    uint256 internal s_expectedAcceptTime;

    uint8 constant STRATEGIST_ROLE = 0;
    uint8 constant GOV_ROLE = 1;
    uint8 constant GUARDIAN_ROLE = 2;

    function setUp() public {
        vm.warp(1_710_000_000);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        viewHelper = new ZenjiViewHelper();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        loanManager = new MinimalLoanManager(address(wbtc), address(crvUSD));
        strategy = new MinimalStrategy(address(crvUSD));
        swapper = new MinimalSwapper();

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

        // Separate roles so guardian is uniquely held by `owner`, gov by `govAddr`,
        // strategist by `strategistAddr`. This makes the "no gov fallback" claim provable
        // (otherwise a single-owner deploy holds all three roles and the negative checks
        // are trivially satisfied by the wrong role).
        _separateRoles();
    }

    /// @notice Rotate strategist (1wk) and gov (4wk) to distinct addresses; guardian stays `owner`.
    function _separateRoles() internal {
        // Strategist transfer (ROLE_TRANSFER_DELAY = 1 week)
        vm.prank(owner);
        vault.transferRole(STRATEGIST_ROLE, strategistAddr);
        // Gov transfer (GOV_GUARDIAN_TRANSFER_DELAY = 4 weeks)
        vm.prank(owner);
        vault.transferRole(GOV_ROLE, govAddr);

        vm.warp(block.timestamp + 4 weeks);
        vm.prank(strategistAddr);
        vault.acceptRole(STRATEGIST_ROLE);
        vm.prank(govAddr);
        vault.acceptRole(GOV_ROLE);

        assertEq(vault.gov(), govAddr, "gov separated");
        assertEq(vault.strategist(), strategistAddr, "strategist separated");
        assertEq(vault.guardian(), owner, "guardian remains owner");
    }

    /// @notice Full quantification of the guardian-key-loss blindness window.
    function test_M06_guardianKeyLoss_4weekBlindness() public {
        // (1) The delay is 4 weeks.
        uint256 delay = vault.GOV_GUARDIAN_TRANSFER_DELAY();
        assertEq(delay, 4 weeks, "GOV_GUARDIAN_TRANSFER_DELAY must be 4 weeks");
        console.log("GOV_GUARDIAN_TRANSFER_DELAY (seconds):", delay);
        console.log("GOV_GUARDIAN_TRANSFER_DELAY (days)   :", delay / 1 days);

        // Mark the moment the guardian key is lost as "day 0".
        s_lossTime = block.timestamp;
        s_expectedAcceptTime = s_lossTime + 4 weeks;

        // (4) Gov has NO direct emergency power. enterEmergencyMode is onlyGuardian.
        vm.prank(govAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.enterEmergencyMode();
        console.log("Confirmed: gov CANNOT call enterEmergencyMode() (onlyGuardian, no fallback)");

        // (2) Gov starts guardian rotation on day 0 -> 4-week timer begins.
        vm.prank(govAddr);
        vault.transferRole(GUARDIAN_ROLE, newGuardian);
        // The pending acceptance timestamp must be exactly s_lossTime + 4 weeks.
        assertEq(vault.pendingGuardianTimestamp(), s_expectedAcceptTime, "rotation timer = 4 weeks");

        // (3) newGuardian cannot accept 1 second before the delay elapses.
        vm.warp(s_expectedAcceptTime - 1);
        vm.prank(newGuardian);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.acceptRole(GUARDIAN_ROLE);
        console.log("1s before deadline: acceptRole(2) reverts TimelockNotReady");

        // newGuardian STILL cannot enter emergency (not yet guardian).
        vm.prank(newGuardian);
        vm.expectRevert(Unauthorized.selector);
        vault.enterEmergencyMode();
        console.log("Before deadline: newGuardian CANNOT enterEmergencyMode (not guardian yet)");

        // (5) Earliest the new guardian can act: exactly s_lossTime + 4 weeks.
        vm.warp(s_expectedAcceptTime);
        vm.prank(newGuardian);
        vault.acceptRole(GUARDIAN_ROLE);
        assertEq(vault.guardian(), newGuardian, "newGuardian accepted at day 28");

        // Now the new guardian can finally act.
        vm.prank(newGuardian);
        vault.enterEmergencyMode();
        assertTrue(vault.emergencyMode(), "emergency finally reachable at day 28");

        // Quantification: the gate is exactly 4 weeks = 28 days from key loss.
        assertEq(s_expectedAcceptTime - s_lossTime, 4 weeks, "blindness window = 4 weeks");
        assertEq((s_expectedAcceptTime - s_lossTime) / 1 days, 28, "= 28 days");
        console.log("=== QUANTIFICATION ===");
        console.log("Guardian key lost on day 0.");
        console.log("Earliest day a rotated guardian can act (days):", (s_expectedAcceptTime - s_lossTime) / 1 days);
        console.log("=> up to 28 days of emergency blindness if the OLD key is unusable.");
        console.log("[M06 CONFIRMED] 4-week guardian rotation, no accelerated path, no gov fallback");
    }

    /// @notice The OLD guardian key is the ONLY path to emergency during the window.
    ///         (If the key is merely lost, not compromised, this path is unavailable in practice.)
    function test_M06_onlyOldGuardianCanTriggerEmergency() public {
        // gov queues rotation; before acceptance only the current guardian (`owner`) can act.
        vm.prank(govAddr);
        vault.transferRole(GUARDIAN_ROLE, newGuardian);

        // gov cannot trigger emergency.
        vm.prank(govAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.enterEmergencyMode();

        // strategist cannot.
        vm.prank(strategistAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.enterEmergencyMode();

        // Only the current (old) guardian can.
        vm.prank(owner);
        vault.enterEmergencyMode();
        assertTrue(vault.emergencyMode(), "only old guardian could trigger emergency");
        console.log("[M06] During rotation window, ONLY the old guardian key works.");
    }

    // ============ M-06 FIX: gov break-glass via 48h timelock ============

    /// @notice FIX VERIFICATION: with the guardian key lost, gov enters emergency mode after
    ///         exactly 48h — blackout cut from 28 days to 2.
    function test_M06fix_govBreakGlass_entersEmergencyAfter48h() public {
        assertEq(vault.GOV_EMERGENCY_DELAY(), 48 hours, "break-glass delay is 48h");

        uint256 lossTime = block.timestamp;

        // Direct entry is still guardian-only — the fix does not weaken that.
        vm.prank(govAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.enterEmergencyMode();

        // Day 0: gov proposes (and starts the 4-week guardian rotation in parallel).
        vm.prank(govAddr);
        vault.govEnterEmergencyMode();
        assertEq(
            vault.pendingGovEmergencyTimestamp(), lossTime + 48 hours, "proposal timer = 48h"
        );
        assertFalse(vault.emergencyMode(), "proposal alone must not enter emergency");

        // 1 second early: execution reverts.
        vm.warp(lossTime + 48 hours - 1);
        vm.prank(govAddr);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.govEnterEmergencyMode();

        // At 48h: the second call executes.
        vm.warp(lossTime + 48 hours);
        vm.prank(govAddr);
        vault.govEnterEmergencyMode();
        assertTrue(vault.emergencyMode(), "FIX: emergency reachable at 48h without guardian");
        assertEq(vault.pendingGovEmergencyTimestamp(), 0, "proposal consumed");

        // Scope stays minimal: emergency STEPS remain guardian-only even for gov.
        vm.prank(govAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.emergencyStep(0);

        console.log("[M06 FIX] Gov break-glass: emergency entry at 48h (was 28 days);");
        console.log("          steps remain guardian-only pending the 4-week rotation.");
    }

    /// @notice FIX VERIFICATION: a live guardian can veto a (possibly compromised) gov's
    ///         pending break-glass proposal; the veto does not consume gov's ability to
    ///         re-propose later.
    function test_M06fix_guardianCanVetoGovProposal() public {
        vm.prank(govAddr);
        vault.govEnterEmergencyMode();
        assertGt(vault.pendingGovEmergencyTimestamp(), 0, "proposal pending");

        // Guardian vetoes during the 48h window.
        vm.prank(owner); // owner = guardian
        vault.cancelGovEmergency();
        assertEq(vault.pendingGovEmergencyTimestamp(), 0, "proposal vetoed");

        // After the original deadline, gov's call is a fresh PROPOSAL, not an execution.
        // (vm.getBlockTimestamp() instead of block.timestamp: via-IR re-inlines
        // block.timestamp-derived locals across vm.warp, skewing the expected value.)
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        vm.prank(govAddr);
        vault.govEnterEmergencyMode();
        assertFalse(vault.emergencyMode(), "vetoed proposal cannot be executed; only re-proposed");
        assertEq(
            vault.pendingGovEmergencyTimestamp(),
            vm.getBlockTimestamp() + 48 hours,
            "fresh 48h timer after veto"
        );

        console.log("[M06 FIX] Guardian veto resets the break-glass timer.");
    }

    /// @notice FIX VERIFICATION: only gov can propose; only gov/guardian can veto.
    function test_M06fix_accessControl() public {
        vm.prank(strategistAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.govEnterEmergencyMode();

        vm.prank(owner); // guardian cannot use the gov path either (it has direct entry)
        vm.expectRevert(Unauthorized.selector);
        vault.govEnterEmergencyMode();

        // Strategist cannot veto a pending proposal.
        vm.prank(govAddr);
        vault.govEnterEmergencyMode();
        vm.prank(strategistAddr);
        vm.expectRevert(Unauthorized.selector);
        vault.cancelGovEmergency();

        console.log("[M06 FIX] Access control: gov proposes, gov/guardian veto, no one else.");
    }
}
