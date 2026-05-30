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
    UsdtNgCrvUsdLpStakeDaoStrategy
} from "../src/strategies/lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title M6_balanceOf_stale_oracle
/// @notice PoC for M6: balanceOf() reverts on stale oracle (USDT variant only)
/// @dev Demonstrates that when the USDT/USD or crvUSD/USD oracle goes stale,
///      UsdtNgCrvUsdLpStakeDaoStrategy.balanceOf() reverts with StaleOrInvalidOracle(),
///      breaking vault withdraw() and external consumers.
contract M6_balanceOf_stale_oracle is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniversalRouterV3SingleHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    UsdtNgCrvUsdLpStakeDaoStrategy public strategy;

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

        strategy = new UsdtNgCrvUsdLpStakeDaoStrategy(
            USDT,
            expectedVaultAddress,
            owner,
            USDT_CRVUSD_POOL,
            PMUSD_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            0, // USDT index
            1, // crvUSD index
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE
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
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    // ============ M6 PoC: balanceOf reverts on stale USDT oracle ============

    /// @dev M6: Demonstrates that balanceOf() reverts when the USDT/USD oracle is stale.
    function test_balanceOf_reverts_on_stale_usdt_oracle() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        uint256 stratBalanceBefore = strategy.balanceOf();
        assertGt(stratBalanceBefore, 0, "Strategy should have balance");
        console.log("Strategy balance before stale oracle: %d", stratBalanceBefore);

        // Warp past the MAX_ORACLE_STALENESS (90000s = 25 hours)
        vm.warp(block.timestamp + 90100);

        // Re-mock oracles so the staleness check triggers
        _mockOracle(USDT_USD_ORACLE);

        // balanceOf() should revert with StaleOrInvalidOracle()
        vm.expectRevert();
        strategy.balanceOf();

        console.log("M6 PoC: balanceOf() reverted on stale USDT oracle");
    }

    /// @dev M6: Demonstrates that balanceOf() reverts when the crvUSD/USD oracle is stale.
    function test_balanceOf_reverts_on_stale_crvusd_oracle() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        uint256 stratBalanceBefore = strategy.balanceOf();
        assertGt(stratBalanceBefore, 0, "Strategy should have balance");
        console.log("Strategy balance before stale oracle: %d", stratBalanceBefore);

        // Warp past the MAX_ORACLE_STALENESS (90000s = 25 hours)
        vm.warp(block.timestamp + 90100);

        // Re-mock the crvUSD oracle to trigger staleness
        _mockOracle(CRVUSD_USD_ORACLE);

        // balanceOf() should revert with StaleOrInvalidOracle()
        vm.expectRevert();
        strategy.balanceOf();

        console.log("M6 PoC: balanceOf() reverted on stale crvUSD oracle");
    }

    /// @dev M6: Demonstrates that vault withdraw() is broken when the oracle is stale.
    ///      The vault calls strategy.balanceOf() during the unwind path.
    function test_withdraw_reverts_on_stale_oracle() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Warp past MAX_ORACLE_STALENESS and stale the USDT oracle
        vm.warp(block.timestamp + 90100);
        _mockOracle(USDT_USD_ORACLE);

        uint256 shares = vault.balanceOf(user1);
        assertGt(shares, 0, "User should have shares");

        // withdraw() calls _unwindPosition() -> strategy.balanceOf() -> revert
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1, user1, user1);

        console.log("M6 PoC: vault.withdraw() reverted on stale USDT oracle");
    }

    /// @dev M6: Demonstrates the full impact - a user can deposit fine, but after
    ///      oracle staleness they cannot redeem via withdraw() because balanceOf() reverts.
    ///      Note: emergency redeem bypasses balanceOf() (pro-rata collateral distribution).
    function test_full_impact_deposit_then_stale_withdraw_fails() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Verify normal operation works
        uint256 stratBal = strategy.balanceOf();
        assertGt(stratBal, 0, "Strategy should have balance");

        // Advance time past oracle staleness window
        vm.warp(block.timestamp + 90100);

        // Stale the USDT oracle
        _mockOracle(USDT_USD_ORACLE);

        // Now balanceOf reverts
        vm.expectRevert();
        strategy.balanceOf();

        // And so does the vault's withdraw path
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1, user1, user1);

        // Emergency redeem requires full emergency step sequence first.
        // Steps 0 and 1 skip because oracle is stale (withdrawAll would call
        // _harvest -> _claimAndCompound -> rewardVault.claimRewards() -> accountant.claim()
        // which is Unauthorized in this fork setup).
        // emergencySkipStep is a two-call pattern: propose then execute after delay.
        vm.prank(owner);
        vault.enterEmergencyMode();

        // Skip step 0: propose
        vm.prank(owner);
        vault.emergencySkipStep(0);
        // Skip step 1: propose
        vm.prank(owner);
        vault.emergencySkipStep(1);

        // Warp past both delays
        vm.warp(block.timestamp + vault.EMERGENCY_SKIP_DELAY() * 2);
        _mockOracle(USDT_USD_ORACLE);

        // Skip step 0: execute
        vm.prank(owner);
        vault.emergencySkipStep(0);
        // Skip step 1: execute
        vm.prank(owner);
        vault.emergencySkipStep(1);

        // Step 2: complete liquidation
        vm.prank(owner);
        vault.emergencyStep(2);

        uint256 shares = vault.balanceOf(user1);
        // Steps 0 and 1 were skipped, so vault has no WBTC to distribute.
        // The redeem returns 0 because collateral was never returned to the vault.
        vm.prank(user1);
        uint256 redeemed = vault.redeem(shares, user1, user1);
        assertEq(redeemed, 0, "Emergency redeem returns 0 when steps skipped");

        console.log(
            "M6 PoC: withdraw blocked by stale oracle, emergency redeem returns 0 (steps skipped)"
        );
    }

    /// @dev M6: Documents the desired post-fix behavior - balanceOf() should return
    ///      a conservative estimate instead of reverting when oracle is stale.
    function test_balanceOf_should_return_conservative_estimate_when_stale() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        uint256 stratBalanceBefore = strategy.balanceOf();
        console.log("Normal balanceOf: %d", stratBalanceBefore);

        // Warp past staleness
        vm.warp(block.timestamp + 90100);
        _mockOracle(USDT_USD_ORACLE);

        // After fix: balanceOf should NOT revert, but return a conservative estimate.
        // The key is that it returns a value instead of reverting.
        //
        // Currently it reverts - this test documents the desired behavior.
        // Uncomment after fix:
        // uint256 conservativeBalance = strategy.balanceOf();
        // assertLe(conservativeBalance, stratBalanceBefore, "Conservative should be <= actual");
        // console.log("Conservative balance (stale oracle): %d", conservativeBalance);

        console.log("M6: Post-fix expected behavior documented (currently reverts)");
    }
}
