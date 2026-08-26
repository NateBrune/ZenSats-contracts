// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import {
    UniversalRouterV3SingleHopSwapper
} from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import {
    UsdtCrvUsdLpStakeDaoStrategy
} from "../src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title AC3_StaleOracle_WithdrawFreeze
/// @notice Attack Chain 3: Stale Oracle → balanceOf Revert → Full Withdrawal Freeze
/// @dev Demonstrates that when the USDT/USD or crvUSD/USD oracle goes stale,
///      the entire vault freezes -- no deposits, withdrawals, or rebalances possible.
///      This is a combined attack chain of M6 (balanceOf stale oracle) + M2 (stuck crvUSD).
contract AC3_StaleOracle_WithdrawFreeze is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
    address constant STAKE_DAO_REWARD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniversalRouterV3SingleHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    UsdtCrvUsdLpStakeDaoStrategy public strategy;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](4);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    // ============ Aave USDT liquidity guard ============

    address constant AAVE_A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    function setUp() public override {
        super.setUp();
        if (IERC20(USDT).balanceOf(AAVE_A_USDT) < 1000e6) vm.skip(true);
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
        );

        strategy = new UsdtCrvUsdLpStakeDaoStrategy(
            USDT,
            expectedVaultAddress,
            owner,
            USDT_CRVUSD_POOL,
            USDT_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            USDT_CRVUSD_GAUGE,
            0, // USDT index
            1, // crvUSD index
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE,
            "USDT -> USDT/crvUSD LP Strategy"
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
            0, // eMode: disabled
            3600
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

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(USDT_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(USDT_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    // ============ AC-3 PoC: Stale Oracle → Full Withdrawal Freeze ============

    /// @dev AC-3: Demonstrates the full attack chain:
    ///      Oracle stale → balanceOf reverts → withdraw/deposit/rebalance all freeze
    function test_AC3_staleOracle_freezes_all_vault_operations() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        // Step 1: Normal operation -- user deposits
        _depositAs(user1, depositAmount);
        uint256 shares = vault.balanceOf(user1);
        assertGt(shares, 0, "User should have shares");
        console.log("Step 1: User deposited %d, has %d shares", depositAmount, shares);

        // Step 2: Advance time past oracle staleness window (25 hours = 90000s)
        vm.warp(block.timestamp + 90100);

        // Step 3: Stale the USDT oracle
        _mockOracle(USDT_USD_ORACLE);

        // Step 4: Verify balanceOf reverts
        console.log("Step 2: USDT oracle now stale");
        vm.expectRevert();
        strategy.balanceOf();
        console.log("  PASS strategy.balanceOf() reverts");

        // Step 5: Verify withdraw reverts (calls _accrueYieldFees → balanceOf)
        console.log("Step 3: Testing vault.withdraw()...");
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(shares, user1, user1);
        console.log("  PASS vault.withdraw() reverts");

        // Step 6: Verify deposit reverts (calls _accrueYieldFees → balanceOf)
        console.log("Step 4: Testing vault.deposit()...");
        vm.prank(user2);
        IERC20(WBTC).approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount, user2);
        console.log("  PASS vault.deposit() reverts");

        // Step 7: Verify rebalance reverts (calls balanceOf)
        console.log("Step 5: Testing vault.rebalance()...");
        vm.prank(vault.gov());
        vm.expectRevert();
        vault.rebalance();
        console.log("  PASS vault.rebalance() reverts");

        console.log("\nAC-3 PoC COMPLETE: Stale oracle freezes ALL vault operations");
        console.log("Impact: Full DoS -- no deposits, withdrawals, or rebalances possible");
        console.log("Recovery: Guardian must enter emergency mode to bypass");
    }

    /// @dev AC-3 (updated for the M-01 fix): emergencyStep(0)'s try/catch still masks the
    ///      StaleOrInvalidOracle revert — BOTH withdrawAll() and emergencyWithdraw() fail and
    ///      yield is NOT recovered — but the step is no longer falsely marked complete.
    ///      The bit stays clear, so the guardian can retry after the oracle heals or take the
    ///      vetoable emergencySkipStep(0) path, which now correctly proposes the skip.
    function test_AC3_emergencyMode_masked_but_broken() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Advance time and stale the oracle
        vm.warp(block.timestamp + 90100);
        _mockOracle(USDT_USD_ORACLE);

        // Enter emergency mode (this works — no balanceOf call)
        vm.prank(vault.guardian());
        vault.enterEmergencyMode();
        console.log("Step 1: Guardian entered emergency mode PASS");

        // emergencyStep(0) does NOT revert — try/catch masks the error
        // But yield withdrawal FAILS silently (both withdrawAll and emergencyWithdraw fail)
        console.log("Step 2: Attempting emergencyStep(0)...");
        uint256 debtBalBefore = IERC20(USDT).balanceOf(address(vault));
        vm.prank(vault.guardian());
        vault.emergencyStep(0);
        uint256 debtBalAfter = IERC20(USDT).balanceOf(address(vault));
        // Yield was NOT recovered — both withdrawAll and emergencyWithdraw failed
        assertEq(debtBalAfter, debtBalBefore, "no yield recovered while oracle is stale");
        console.log("  PASS emergencyStep(0) did not revert (try/catch masks error)");
        console.log("  WARNING: Yield NOT recovered (both withdrawAll and emergencyWithdraw fail)");

        // M-01 FIX: the failed step 0 no longer sets the bitmask, so the guardian keeps both
        // recovery options: retry step 0 after the oracle heals, or propose the vetoable skip.
        assertEq(
            vault.emergencyStepsCompleted() & 0x1,
            0,
            "M-01 fix: failed step 0 must NOT be marked complete"
        );
        console.log("Step 3: emergencySkipStep(0) proposes the skip (bit correctly clear)");
        vm.prank(vault.guardian());
        vault.emergencySkipStep(0); // first call proposes with the 3-day gov-veto delay
        console.log("  PASS emergencySkipStep(0) proposal accepted");

        console.log("\nAC-3 PoC (post-fix): oracle staleness still blocks yield recovery, but");
        console.log("the step is no longer falsely marked complete; retry/skip paths remain open");
    }

    /// @dev AC-3: Demonstrates the same freeze with crvUSD oracle stale (USDT variant)
    function test_AC3_crvUsdOracle_stale_freezes_operations() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Advance time and stale the crvUSD oracle
        vm.warp(block.timestamp + 90100);
        _mockOracle(CRVUSD_USD_ORACLE);

        // balanceOf reverts
        vm.expectRevert();
        strategy.balanceOf();
        console.log("  PASS balanceOf() reverts on stale crvUSD oracle");

        // withdraw reverts
        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(shares, user1, user1);
        console.log("  PASS withdraw() reverts on stale crvUSD oracle");

        console.log("\nAC-3 PoC: Both USDT and crvUSD oracle staleness cause full freeze");
    }

    /// @dev AC-3: Demonstrates that the freeze is USDT-variant specific.
    ///      The crvUSD variant (CrvUsdLpStakeDaoStrategy) does NOT use oracles for balanceOf.
    ///      This test verifies the USDT variant is the vulnerable one.
    function test_AC3_impact_is_usdt_variant_only() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Advance time and stale the USDT oracle
        vm.warp(block.timestamp + 90100);
        _mockOracle(USDT_USD_ORACLE);

        // balanceOf reverts because strategy uses USDT variant
        vm.expectRevert();
        strategy.balanceOf();
        console.log("  PASS USDT variant: balanceOf() reverts on stale USDT oracle");

        // Note: If the vault used CrvUsdLpStakeDaoStrategy (crvUSD variant),
        // balanceOf() would NOT revert because it uses a 1:1 crvUSD pass-through
        // instead of oracle conversion.
    }
}
