// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Minimal Mocks ============

contract MockERC20H1 is ERC20 {
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

/// @notice Minimal loan manager stub. No real Aave, just enough for Zenji to construct and
///         run the emergency path. emergencyStep(1) is exercised via emergencySkipStep(1)
///         so unwindPosition is never actually called.
contract MockLoanManagerH1 is ILoanManager {
    address public collateralAsset;
    address public debtAsset;

    constructor(address _collateral, address _debt) {
        collateralAsset = _collateral;
        debtAsset = _debt;
    }

    function createLoan(uint256, uint256) external override {}
    function addCollateral(uint256) external override {}
    function borrowMore(uint256, uint256) external override {}
    function repayDebt(uint256) external override {}
    function removeCollateral(uint256) external override {}
    function unwindPosition(uint256) external override {}
    function transferCollateral(address, uint256) external override {}
    function transferDebt(address, uint256) external override {}
    function maxLtvBps() external pure override returns (uint256) { return type(uint256).max; }
    function checkOracleFreshness() external view override {}

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

/// @notice Minimal yield strategy stub. withdrawAll() transfers any held USDT to the vault.
///         The vault address is passed as a constructor argument to avoid circular dependency.
contract MockYieldStrategyH1 is IYieldStrategy {
    address public asset;
    address public vault;
    MockERC20H1 private _token;

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
        _token = MockERC20H1(_asset);
    }

    /// @notice withdrawAll sends whatever USDT this contract holds to the vault.
    ///         The vault pre-loads the USDT by direct mint.
    function withdrawAll() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) {
            _token.transfer(vault, bal);
        }
        return bal;
    }

    function deposit(uint256) external pure override returns (uint256) { return 0; }
    function withdraw(uint256 amt) external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        uint256 out = amt < bal ? amt : bal;
        if (out > 0) _token.transfer(vault, out);
        return out;
    }
    function harvest() external pure override returns (uint256) { return 0; }
    function emergencyWithdraw() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) {
            _token.transfer(vault, bal);
        }
        return bal;
    }
    function underlyingAsset() external view override returns (address) { return asset; }
    function balanceOf() external view override returns (uint256) {
        return _token.balanceOf(address(this));
    }
    function costBasis() external pure override returns (uint256) { return 0; }
    function unrealizedProfit() external pure override returns (uint256) { return 0; }
    function pendingRewards() external pure override returns (uint256) { return 0; }
    function name() external pure override returns (string memory) { return "MockStrategy"; }
    function transferOwnerFromVault(address) external override {}
    function setSlippage(uint256) external override {}

    function updateCachedVirtualPrice() external { }
}

/// @notice Minimal swapper - safe because emergency step 1 is skipped.
contract MockSwapperH1 is ISwapper {
    MockERC20H1 public immutable collateralToken;
    MockERC20H1 public immutable debtToken;

    constructor(address _collateral, address _debt) {
        collateralToken = MockERC20H1(_collateral);
        debtToken = MockERC20H1(_debt);
    }

    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) { return d; }
    function swapCollateralForDebt(uint256 a) external returns (uint256) {
        debtToken.mint(msg.sender, a);
        return a;
    }
    function swapDebtForCollateral(uint256 a) external returns (uint256) {
        collateralToken.mint(msg.sender, a);
        return a;
    }
}

// ============ Test Contract ============

/// @title H1_H4 Emergency USDT Stranding
///
/// Hypothesis H-1 (High): Flash loan slippage DoS enables permanent USDT stranding.
/// Hypothesis H-4 (Medium): _redeemEmergency ignores debtAsset. Code defect is present
///                          regardless of HOW step 1 is bypassed.
///
/// BUG MECHANISM:
///   Zenji._redeemEmergency() at line 893 calculates shareholder payouts as:
///
///     availableCollateral = collateralAsset.balanceOf(address(this))
///     collateralAmount    = (availableCollateral * shareAmount) / supply
///
///   It uses ONLY collateralAsset.balanceOf(). Any USDT (debtAsset) sitting in the vault
///   after emergencyStep(0) is NEVER included in this calculation.
///
///   Additionally, ZenjiCoreLib.executeRescueAssets() explicitly reverts when the token is
///   debtAsset - so there is no recovery path via rescueAssets() either.
///
contract H1_H4_EmergencyUSDTStranding is Test {
    // Tokens
    MockERC20H1 collateral;
    MockERC20H1 usdt;

    // Infrastructure
    MockLoanManagerH1 lm;
    MockYieldStrategyH1 strategy;
    MockSwapperH1 swapper;
    ZenjiViewHelper viewHelper;
    Zenji vault;

    address guardian = makeAddr("guardian");
    address user1 = makeAddr("user1");

    // Amounts
    uint256 constant COLLATERAL_DEPOSIT = 100e18;  // 100 units collateral
    uint256 constant USDT_IN_STRATEGY   = 65e6;    // 65 USDT deployed to yield strategy

    function setUp() public {
        // Deploy tokens
        collateral = new MockERC20H1("WBTC", "WBTC", 18);
        usdt       = new MockERC20H1("USDT", "USDT", 6);

        // Predict vault address so strategy can be given the correct vault reference
        uint256 startNonce = vm.getNonce(address(this));
        // After tokens: lm=+0, strategy=+1, swapper=+2, viewHelper=+3, vault=+4
        address expectedVault = vm.computeCreateAddress(address(this), startNonce + 4);

        lm       = new MockLoanManagerH1(address(collateral), address(usdt));
        strategy = new MockYieldStrategyH1(address(usdt), expectedVault);
        swapper  = new MockSwapperH1(address(collateral), address(usdt));
        viewHelper = new ZenjiViewHelper();

        vault = new Zenji(
            address(collateral),
            address(usdt),
            address(lm),
            address(strategy),
            address(swapper),
            guardian,
            address(viewHelper)
        );
        require(address(vault) == expectedVault, "vault address mismatch");

        // Set idle=true so collateral stays in vault (mock LM does nothing in non-idle mode)
        vm.prank(guardian);
        vault.setIdle(true);

        // Deposit collateral for user1
        collateral.mint(user1, COLLATERAL_DEPOSIT);
        vm.startPrank(user1);
        collateral.approve(address(vault), COLLATERAL_DEPOSIT);
        vault.deposit(COLLATERAL_DEPOSIT, user1);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    /// @notice H-4 STANDALONE: Proves _redeemEmergency ignores debtAsset sitting in vault.
    ///
    /// This is the minimal code defect test. It does NOT require flash loan failure - any reason
    /// for USDT to remain in the vault (including normal step 0 recovery) suffices.
    ///
    /// Code path proven:
    ///   Zenji.sol:893 - availableCollateral = collateralAsset.balanceOf(address(this))
    ///   No debtAsset.balanceOf() is ever included in emergency redemption calculation.
    function test_H4_redeemEmergency_ignores_USDT_in_vault() public {
        uint256 sharesUser1 = vault.balanceOf(user1);
        assertGt(sharesUser1, 0, "H4: user1 must hold shares");

        // Simulate USDT arriving at vault from step 0 (strategy withdrawal)
        // Direct mint is used here because test_H1 covers the actual step 0 path.
        uint256 usdtStranded = 1000e6; // $1,000 USDT
        usdt.mint(address(vault), usdtStranded);

        // Run emergency sequence: skip step 0 and 1, complete liquidation
        vm.startPrank(guardian);
        vault.enterEmergencyMode();
        vault.emergencySkipStep(0);
        vault.emergencySkipStep(1);
        vault.emergencyStep(2); // sets liquidationComplete = true
        vm.stopPrank();

        assertTrue(vault.liquidationComplete(), "H4: liquidationComplete must be true");

        uint256 user1UsdtBefore = usdt.balanceOf(user1);
        uint256 vaultUsdtBefore = usdt.balanceOf(address(vault));
        assertEq(vaultUsdtBefore, usdtStranded, "H4: vault must hold the seeded USDT");

        // Shareholder redeems all shares
        vm.prank(user1);
        uint256 collateralReceived = vault.redeem(sharesUser1, user1, user1);

        uint256 user1UsdtAfter = usdt.balanceOf(user1);
        uint256 vaultUsdtAfter = usdt.balanceOf(address(vault));

        // ASSERTION 1: Shareholder receives proportional USDT (user1 = 100% of supply)
        assertEq(
            user1UsdtAfter - user1UsdtBefore,
            usdtStranded,
            "H4 FIXED: shareholder receives full USDT proportional share"
        );

        // ASSERTION 2: No USDT remains stranded after full redemption
        assertEq(
            vaultUsdtAfter,
            0,
            "H4 FIXED: no USDT stranded after emergency redemption"
        );

        console.log("H4: user1 collateral received:  %d", collateralReceived);
        console.log("H4: user1 USDT received:        %d (6 decimals)", user1UsdtAfter - user1UsdtBefore);
        console.log("[H4 FIXED] _redeemEmergency now distributes debtAsset proportionally");
    }

    /// @notice H-1 CHAIN: Full chain PoC - emergencyStep(0) deposits USDT, step 1 skipped.
    ///
    /// This test models the complete H-1 attack path:
    ///   Step 0: emergencyStep(0) -> strategy.withdrawAll() -> USDT transferred to vault
    ///   Step 1: emergencySkipStep(1) -> guardian skips because flash loan would revert
    ///   Step 2: emergencyStep(2) -> liquidationComplete = true
    ///   Redeem: shareholder gets 0 USDT (only collateral in formula)
    ///   Rescue: rescueAssets(usdt) reverts - no recovery path exists
    ///
    /// The strategy is pre-loaded with USDT to simulate deployed yield.
    /// emergencyStep(0) triggers withdrawAll() which transfers USDT from strategy to vault.
    function test_H1_flashLoanSkip_permanentUSDTStranding() public {
        uint256 sharesUser1 = vault.balanceOf(user1);
        assertGt(sharesUser1, 0, "H1: user1 must hold shares");

        // Pre-load strategy with USDT (simulates deployed yield capital)
        // Direct mint to strategy contract mimics IPOR vault holdings
        usdt.mint(address(strategy), USDT_IN_STRATEGY);
        assertEq(strategy.balanceOf(), USDT_IN_STRATEGY, "H1: strategy must hold USDT");

        // Enter emergency mode
        vm.startPrank(guardian);
        vault.enterEmergencyMode();

        // STEP 0: emergencyStep(0) -> calls yieldStrategy.withdrawAll() via ZenjiCoreLib
        // withdrawAll() detects USDT in strategy and transfers it to vault
        vault.emergencyStep(0);
        vm.stopPrank();

        uint256 vaultUsdtAfterStep0 = usdt.balanceOf(address(vault));
        console.log("H1: USDT in vault after step 0:  %d (6 dec)", vaultUsdtAfterStep0);
        assertEq(
            vaultUsdtAfterStep0,
            USDT_IN_STRATEGY,
            "H1: step 0 must transfer USDT from strategy to vault"
        );

        // STEP 1: emergencySkipStep(1)
        // In production: Guardian skips because emergencyStep(1) would call
        // loanManager.unwindPosition() which triggers a flash loan. If market slippage
        // exceeds 5% (MIN_SWAP_OUT_BPS = 9500), the swapper reverts with
        // SwapperUnderperformed, causing the entire emergencyStep(1) to revert.
        // Guardian has no choice but to call emergencySkipStep(1).
        vm.prank(guardian);
        vault.emergencySkipStep(1);

        assertEq(
            usdt.balanceOf(address(vault)),
            vaultUsdtAfterStep0,
            "H1: USDT must remain in vault after skip (step 1 never executed)"
        );

        // STEP 2: emergencyStep(2) -> liquidationComplete = true
        vm.prank(guardian);
        vault.emergencyStep(2);
        assertTrue(vault.liquidationComplete(), "H1: liquidationComplete must be true");

        // REDEMPTION: Shareholder calls redeem()
        // _redeemEmergency() uses only collateralAsset.balanceOf() - USDT not included
        uint256 user1UsdtBefore = usdt.balanceOf(user1);
        uint256 totalSupply = vault.totalSupply();
        uint256 vaultCollateral = collateral.balanceOf(address(vault));

        vm.prank(user1);
        uint256 collateralReceived = vault.redeem(sharesUser1, user1, user1);

        uint256 user1UsdtAfter = usdt.balanceOf(user1);
        uint256 vaultUsdtAfterRedeem = usdt.balanceOf(address(vault));

        // ASSERTION 1: Shareholder receives proportional USDT (user1 = 100% of supply)
        assertEq(
            user1UsdtAfter - user1UsdtBefore,
            USDT_IN_STRATEGY,
            "H1 FIXED: shareholder receives USDT from emergency redemption"
        );

        // ASSERTION 2: No USDT stranded after full redemption
        assertEq(
            vaultUsdtAfterRedeem,
            0,
            "H1 FIXED: USDT fully distributed to shareholders"
        );

        console.log("H1: total supply before redeem:  %d shares", totalSupply);
        console.log("H1: vault collateral before:     %d", vaultCollateral);
        console.log("H1: user1 collateral received:   %d", collateralReceived);
        console.log("H1: user1 USDT received:         %d (6 dec)", user1UsdtAfter - user1UsdtBefore);

        // ASSERTION 3: rescueAssets(debtAsset) still reverts by design (debtAsset on blocklist)
        // The fix is in _redeemEmergency itself; rescue path remains blocked as a safeguard.
        vm.prank(guardian);
        vm.expectRevert(Zenji.InvalidAddress.selector);
        vault.rescueAssets(address(usdt), guardian);

        console.log("[H1 FIXED] _redeemEmergency now distributes debtAsset proportionally");
        console.log("H1 SUMMARY: %d USDT (6 dec) properly returned to shareholders", USDT_IN_STRATEGY);
    }
}
