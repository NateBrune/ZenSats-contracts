// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UsdtNgCrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol";
import { BaseNgCrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/BaseNgCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { ICurveStableSwap } from "../src/interfaces/ICurveStableSwap.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IStakeDaoRewardVault } from "../src/interfaces/IStakeDaoRewardVault.sol";

/// @title M2_UsdtPmUsdCrvUsd_withdraw_stuck_crvUSD
/// @notice PoC for M2: _withdraw temporarily stuck crvUSD on swap failure
/// @dev Demonstrates that if _removeLiquidity succeeds but _swapCrvUsdToUsdt fails,
///      crvUSD remains stuck in the strategy contract because EVM revert doesn't
///      undo external token transfers.
contract M2_UsdtPmUsdCrvUsd_withdraw_stuck_crvUSD is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
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
            0,
            1,
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
            0,
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

    // ============ M2 PoC: crvUSD stuck on swap failure ============

    /// @dev Regression: if _removeLiquidity succeeds but the later crvUSD->USDT swap
    ///      reverts, the whole strategy withdrawal reverts atomically. External token
    ///      transfers in the reverted call tree are rolled back, so no crvUSD is stuck.
    function test_withdraw_swap_failure_rolls_back_crvUSD() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        // Mock accountant.claim to skip the pmUSD transfer that fails on mainnet fork.
        address accountant = IStakeDaoRewardVault(STAKE_DAO_REWARD_VAULT).ACCOUNTANT();
        vm.mockCallRevert(
            accountant,
            abi.encodeWithSelector(bytes4(keccak256("claim(address[],bytes[],address)"))),
            bytes("")
        );

        _depositAs(user1, depositAmount);

        // Verify strategy has balance
        uint256 stratBalanceBefore = strategy.balanceOf();
        assertGt(stratBalanceBefore, 0, "Strategy should have balance");
        console.log("Strategy balance before withdraw: %d", stratBalanceBefore);

        // Get current crvUSD balance of strategy (should be 0 before withdraw)
        uint256 crvUsdBefore = IERC20(CRVUSD).balanceOf(address(strategy));
        console.log("Strategy crvUSD before withdraw: %d", crvUsdBefore);
        assertEq(crvUsdBefore, 0, "Strategy should have 0 crvUSD before withdraw");

        // Get oracle prices
        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdated,) =
            IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();

        // DEFLATE USDT oracle to 0.1% (USDT at $0.001 instead of $1.00).
        // This makes the oracle floor for crvUSD→USDT extremely high (oracle expects
        // ~1000x more USDT per crvUSD), causing the swap to fail because
        // oracleMinOut > pool.get_dy.
        // Note: inflating USDT would LOWER the floor (USDT is output token).
        int256 deflatedUsdtPrice = (usdtPrice * 1) / 1000;
        vm.mockCall(
            USDT_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(usdtRoundId, deflatedUsdtPrice, block.timestamp, block.timestamp, usdtRoundId)
        );

        // Try to withdraw from the strategy.
        // The strategy's withdraw() calls:
        // 1. _claimAndCompound() — mocked to skip
        // 2. _redeemFromRewardVault() — gets LP tokens
        // 3. _removeLiquidity() — removes LP from pmUSD/crvUSD pool → crvUSD transferred to strategy
        // 4. _swapCrvUsdToDebt() — tries to swap crvUSD → USDT (FAILS due to oracle floor)
        // Step 4 reverts, and the crvUSD transfer from step 3 is rolled back.
        uint256 strategyBalance = strategy.balanceOf();
        vm.prank(address(vault));
        bool reverted = false;
        try strategy.withdraw(strategyBalance) {
            // If we get here, the swap succeeded (unexpected)
        } catch {
            reverted = true;
        }

        // After the revert, check that no crvUSD is stuck in the strategy.
        uint256 crvUsdAfter = IERC20(CRVUSD).balanceOf(address(strategy));
        console.log("Strategy crvUSD after failed withdraw: %d", crvUsdAfter);
        console.log("Withdraw reverted: %s", reverted ? "true" : "false");

        assertTrue(reverted, "M2 PoC: withdraw should have reverted");
        assertEq(crvUsdAfter, crvUsdBefore, "Failed withdraw must not strand crvUSD");
        console.log("M2 regression: failed withdraw rolled back without stranding crvUSD");
    }

    /// @dev Regression: repeated failed withdrawals must not accumulate crvUSD dust.
    function test_multiple_failed_withdraws_do_not_accumulate_crvUSD() public {
        _deployVault();

        // Deposit multiple users
        _depositAs(user1, _baseDeposit());
        _depositAs(user2, _baseDeposit());

        uint256 stratBalanceBefore = strategy.balanceOf();
        console.log("Strategy balance before: %d", stratBalanceBefore);

        // Get oracle prices
        (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdated,) =
            IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();

        // Deflate USDT price to trigger oracle floor
        int256 deflatedUsdtPrice2 = (usdtPrice * 1) / 1000;
        vm.mockCall(
            USDT_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(usdtRoundId, deflatedUsdtPrice2, block.timestamp, block.timestamp, usdtRoundId)
        );

        uint256 crvUsdBefore = IERC20(CRVUSD).balanceOf(address(strategy));

        // User1 withdraws and reverts atomically.
        vm.prank(address(vault));
        try strategy.withdraw(strategy.balanceOf()) {
            // Should not reach here
            assert(false);
        } catch {
            console.log("User1 withdraw reverted (expected)");
        }

        uint256 crvUsdAfter1 = IERC20(CRVUSD).balanceOf(address(strategy));
        console.log("After user1 withdraw, strategy crvUSD: %d", crvUsdAfter1);

        // User2 withdraws and reverts atomically.
        try strategy.withdraw(strategy.balanceOf()) {
            assert(false);
        } catch {
            console.log("User2 withdraw reverted (expected)");
        }

        uint256 crvUsdAfter2 = IERC20(CRVUSD).balanceOf(address(strategy));
        console.log("After user2 withdraw, strategy crvUSD: %d", crvUsdAfter2);

        assertEq(crvUsdAfter1, crvUsdBefore, "First failed withdraw must not strand crvUSD");
        assertEq(crvUsdAfter2, crvUsdBefore, "Repeated failed withdraws must not accumulate crvUSD");
        console.log("M2 regression: repeated failures did not strand crvUSD");
    }
}
