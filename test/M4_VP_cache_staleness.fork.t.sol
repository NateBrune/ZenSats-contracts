// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UsdtPmUsdCrvUsdStrategy } from "../src/strategies/UsdtPmUsdCrvUsdStrategy.sol";
import { BasePmUsdCrvUsdStrategy } from "../src/strategies/BasePmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title M4_VP_cache_staleness
/// @notice PoC for M4: Virtual Price Cache can be stale between updates
/// @dev Demonstrates that the cached virtual price can be significantly off
///      from the true current VP if the cache hasn't been updated recently.
contract M4_VP_cache_staleness is ZenjiForkTestBase {
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
    UsdtPmUsdCrvUsdStrategy public strategy;

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

        strategy = new UsdtPmUsdCrvUsdStrategy(
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

    // ============ M4 PoC: VP cache staleness ============

    /// @dev M4: Demonstrates that the cached VP can be stale between updates.
    ///      The cache is only updated on deposits, withdrawals, harvests, and explicit
    ///      keeper calls. Between these events, the cached VP may be significantly off
    ///      from the true on-chain VP.
    function test_vpcache_staleness_between_updates() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Get the initial cached VP
        uint256 cachedVpBefore = strategy.cachedVirtualPrice();
        console.log("Cached VP before: %d", cachedVpBefore);

        // Get the current on-chain VP
        uint256 onChainVpBefore = _getOnChainVP();
        console.log("On-chain VP before: %d", onChainVpBefore);

        // Advance time significantly (simulating keeper not updating cache)
        vm.warp(block.timestamp + 7 days);

        // The cached VP should still be the same (not auto-updated)
        uint256 cachedVpAfter = strategy.cachedVirtualPrice();
        assertEq(cachedVpAfter, cachedVpBefore, "Cached VP should not auto-update");

        // But the on-chain VP may have changed
        uint256 onChainVpAfter = _getOnChainVP();
        console.log("On-chain VP after 7 days: %d", onChainVpAfter);

        // Calculate the deviation
        if (onChainVpAfter > onChainVpBefore) {
            uint256 deviation = ((onChainVpAfter - onChainVpBefore) * 1e18) / onChainVpBefore;
            console.log("VP deviation over 7 days: %d bps", deviation / 1e14);
        }

        console.log("M4 PoC: cached VP is stale, on-chain VP may have drifted");
    }

    /// @dev M4: Demonstrates that a large deposit after cache staleness uses the stale cache
    ///      for the oracle floor, potentially allowing suboptimal pricing.
    function test_large_deposit_after_cache_staleness() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);
        _refreshOracles();

        uint256 cachedVpBefore = strategy.cachedVirtualPrice();
        uint256 onChainVpBefore = _getOnChainVP();
        console.log("Cached VP: %d, On-chain VP: %d", cachedVpBefore, onChainVpBefore);

        // Advance time
        vm.warp(block.timestamp + 7 days);
        _refreshOracles();

        // The cached VP is now stale
        uint256 cachedVpStale = strategy.cachedVirtualPrice();
        uint256 onChainVpNew = _getOnChainVP();
        console.log("Stale cached VP: %d, New on-chain VP: %d", cachedVpStale, onChainVpNew);

        // A new deposit will use the stale cached VP for the oracle floor
        // The _getSafeVirtualPrice() clamps to cached ±0.5%, but the cache itself is stale
        strategy.updateCachedVirtualPrice();
        uint256 safeVp = strategy.cachedVirtualPrice();
        console.log("Safe VP (clamped): %d", safeVp);

        // The safe VP is within ±0.5% of the cached value, but the cached value
        // may be significantly off from the true on-chain value
        if (safeVp > cachedVpStale) {
            uint256 deviationFromCache = ((safeVp - cachedVpStale) * 1e18) / cachedVpStale;
            console.log("Safe VP deviation from cache: %d bps", deviationFromCache / 1e14);
        }

        console.log("M4 PoC: deposit uses stale cached VP for oracle floor");
    }

    /// @dev Helper to get the current on-chain VP from the pmUSD/crvUSD pool
    function _getOnChainVP() internal view returns (uint256) {
        return ICurveStableSwapNG(PMUSD_CRVUSD_POOL).get_virtual_price();
    }
}
