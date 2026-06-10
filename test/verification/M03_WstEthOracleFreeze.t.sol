// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title M-03: wstETH vault freeze at ETH/USD staleness + emergency step-1 unwind (FIXED)
///
/// ORIGINAL HYPOTHESIS (MEDIUM):
///   (a) WstEthOracle.latestRoundData() hard-reverts ("ETH/USD: stale") when the ETH/USD
///       Chainlink feed is stale past its window. Because the wstETH vault uses WstEthOracle as
///       its loan-manager collateral oracle, an ETH/USD outage reverts every collateral-priced
///       operation -> user-facing deposit/withdraw freeze. This part is INHERENT: shares cannot
///       be priced without a working collateral feed, and it self-resolves with the feed.
///
///   (b) During the SAME outage, the guardian's emergency escape was blocked: emergencyStep(1)
///       routed to AaveLoanManager.unwindPosition(), whose FIRST statement was
///       _checkOracleFreshness() -> WstEthOracle.latestRoundData() -> revert "ETH/USD: stale".
///       The only path forward was a lossy 3-day emergencySkipStep(1).
///
/// FIX UNDER TEST:
///   emergencyStep(1) now routes through ILoanManager.emergencyUnwindPosition(), which skips the
///   oracle freshness gate. The vault sends its full debt-asset balance to the loan manager
///   up-front (no oracle-gated repayDebt call), so when step-0 proceeds cover the Aave debt the
///   entire exit — repay + withdraw-all-collateral — is oracle-free. The trailing debt->collateral
///   swap is best-effort while the feed is stale. Residual limitation (documented): if the debt
///   is NOT covered, the flashloan path's swap sizing is oracle-priced and still reverts.
///   The normal-path unwindPosition() keeps its freshness gate unchanged.
///
/// This is a real-fork PoC against the live wstETH + USDT + pmUSD/crvUSD (Stake DAO) vault.
/// The WstEthOracle and AaveLoanManager behaviour is REAL audited-code behaviour, not mocks.

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "../base/ZenjiForkTestBase.sol";
import { Zenji } from "../../src/Zenji.sol";
import { AaveLoanManager } from "../../src/lenders/AaveLoanManager.sol";
import { UniswapMixedTwoHopSwapper } from "../../src/swappers/base/UniswapMixedTwoHopSwapper.sol";
import { WstEthOracle } from "../../src/WstEthOracle.sol";
import { CrvToCrvUsdSwapper } from "../../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import {
    UsdtNgCrvUsdLpStakeDaoStrategy
} from "../../src/strategies/lp/UsdtNgCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";

contract M03_WstEthOracleFreeze is ZenjiForkTestBase {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    address constant AAVE_A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_ETH_USDT = 500;
    int24 constant V4_TICK_SPACING = 10;

    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    /// ETH/USD staleness window enforced inside WstEthOracle (1h heartbeat + 5min grace).
    uint256 constant ETH_USD_MAX_STALENESS = 3900;

    UniswapMixedTwoHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    WstEthOracle public wstEthOracle;
    UsdtNgCrvUsdLpStakeDaoStrategy public strategy;

    // ============ Abstract base implementations ============

    function _collateral() internal pure override returns (address) {
        return WSTETH;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    /// WstEthOracle composite reports the OLDER feed timestamp; the stETH/ETH leg is 24h.
    function _collateralStalenessWarp() internal pure override returns (uint256) {
        return 90001;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](5);
        oracles[0] = STETH_ETH_ORACLE;
        oracles[1] = ETH_USD_ORACLE;
        oracles[2] = USDT_USD_ORACLE;
        oracles[3] = CRVUSD_USD_ORACLE;
        oracles[4] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return ETH_USD_ORACLE;
    }

    function setUp() public override {
        super.setUp();
        if (IERC20(USDT).balanceOf(AAVE_A_USDT) < 1000e6) vm.skip(true);
    }

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 5);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();

        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedTwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WSTETH_WETH,
            FEE_ETH_USDT,
            V4_TICK_SPACING,
            address(wstEthOracle),
            USDT_USD_ORACLE,
            90000
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
            WSTETH,
            USDT,
            AAVE_A_WSTETH,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            address(wstEthOracle),
            USDT_USD_ORACLE,
            address(swapper),
            7100,
            7600,
            expectedVaultAddress,
            0,
            90000
        );

        vault = new Zenji(
            WSTETH, USDT, address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault));
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        vm.prank(owner);
        swapper.setSlippage(1e16);
        _syncAndMockOracles();
    }

    /// @notice Re-mock every oracle EXCEPT ETH/USD, so the freeze is isolated to the 2h ETH/USD
    ///         staleness path. stETH/ETH stays fresh (its 24h leg would not be stale at 2h
    ///         anyway), and the stablecoin feeds stay fresh so step-0 yield withdraw is not the
    ///         blocker — proving step-1 is blocked specifically by WstEthOracle's ETH/USD revert.
    function _refreshAllButEthUsd() internal {
        _mockOracle(STETH_ETH_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
        _mockOracle(CRV_USD_ORACLE);
        // ETH_USD_ORACLE deliberately NOT re-mocked -> stale relative to block.timestamp.
    }

    // ============ M-03 PoC ============

    /// @notice CORE PROOF: an ETH/USD outage (1) reverts WstEthOracle and (2) freezes user
    ///         deposit/withdraw (inherent — shares cannot be priced without the feed), but
    ///         (3) FIX: emergencyStep(1) now unwinds the loan during the outage via the
    ///         oracle-free emergencyUnwindPosition() path.
    function test_M03_ethUsdStale_freezesUserOps_butEmergencyStep1Succeeds() public {
        _deployVault();

        // 1. Normal operation: user deposits, carry-trade position opens.
        uint256 dep = _baseDeposit() * 2; // 2 wstETH
        deal(WSTETH, user1, dep);
        _depositAs(user1, dep);
        uint256 shares = vault.balanceOf(user1);
        assertGt(shares, 0, "precondition: user holds shares");
        assertTrue(loanManager.loanExists(), "precondition: loan opened");

        // Sanity: oracle returns a price while fresh.
        _refreshOracles();
        (, int256 freshPrice,,,) = wstEthOracle.latestRoundData();
        assertGt(freshPrice, 0, "precondition: WstEthOracle prices while fresh");
        console.log("=== BEFORE OUTAGE ===");
        console.log("user shares:", shares);
        console.log("WstEthOracle price (8dec) fresh:", uint256(freshPrice));

        // 2. ETH/USD outage: warp just past the staleness window. Keep ALL OTHER feeds fresh so
        //    the revert is isolated to WstEthOracle's ETH/USD staleness check.
        vm.warp(block.timestamp + ETH_USD_MAX_STALENESS + 100);
        _refreshAllButEthUsd();

        // 3. (a) WstEthOracle.latestRoundData() hard-reverts on the ETH/USD staleness.
        vm.expectRevert(bytes("ETH/USD: stale"));
        wstEthOracle.latestRoundData();
        console.log("Confirmed (a): WstEthOracle reverts 'ETH/USD: stale' past the window");

        // 4. (a) Vault deposit reverts (collateral oracle gates the loan path).
        deal(WSTETH, user2, dep);
        vm.startPrank(user2);
        IERC20(WSTETH).approve(address(vault), dep);
        vm.expectRevert();
        vault.deposit(dep, user2);
        vm.stopPrank();
        console.log("Confirmed (a): deposit() reverts -> no new user can enter");

        // 5. (a) Vault withdraw reverts.
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1e16, user1, user1);
        console.log("Confirmed (a): withdraw() reverts -> existing user cannot exit");

        // 6. Guardian enters emergency mode (no oracle call -> succeeds).
        vm.prank(vault.guardian());
        vault.enterEmergencyMode();
        assertTrue(vault.emergencyMode(), "emergency mode entered");
        console.log("Guardian entered emergency mode");

        // 7. Step 0 (withdraw yield) is gated by the crvUSD/USDT stablecoin path, which is still
        //    fresh. It must complete so step-1 proceeds cover the Aave debt (the oracle-free
        //    exit needs the debt covered; a shortfall would route to the oracle-priced
        //    flashloan path). An unrelated environmental revert -> skip, not fail.
        vm.prank(vault.guardian());
        try vault.emergencyStep(0) {
            console.log("emergencyStep(0) completed (stablecoin feeds fresh)");
        } catch {
            console.log("[ENV SKIP] emergencyStep(0) reverted (pool-liquidity dependent)");
            vm.skip(true);
        }
        uint256 usdtRecovered = IERC20(USDT).balanceOf(address(vault));
        uint256 aaveDebt = loanManager.getCurrentDebt();
        console.log("USDT recovered by step 0:", usdtRecovered);
        console.log("Aave debt outstanding:   ", aaveDebt);

        // 8. FIX: emergencyStep(1) routes through emergencyUnwindPosition(), which has no
        //    oracle freshness gate. Covered debt is repaid oracle-free; if step-0 proceeds fell
        //    short (LP exit slippage + accrued interest), the stale-exit path withdraws all
        //    collateral except the sliver backing the residual dust debt at MIN_HEALTH (priced
        //    by Aave's own oracle). Previously this whole call reverted "ETH/USD: stale" and
        //    forced a lossy 3-day emergencySkipStep(1).
        vm.prank(vault.guardian());
        vault.emergencyStep(1);

        assertEq(
            vault.emergencyStepsCompleted() & 0x2,
            0x2,
            "FIX: step 1 marked complete during the ETH/USD outage"
        );
        uint256 vaultWstEth = IERC20(WSTETH).balanceOf(address(vault));
        uint256 residualDebt = loanManager.getCurrentDebt();
        // At least 90% of the deposited collateral must be back at the vault for distribution;
        // the residual loan (if any) is bounded to ~the step-0 shortfall, i.e. dust vs the debt.
        assertGt(vaultWstEth, (dep * 90) / 100, "FIX: bulk of collateral returned while stale");
        assertLt(residualDebt, aaveDebt / 50, "residual debt is dust (< 2% of original)");
        console.log("vault wstETH after stale-exit:", vaultWstEth);
        console.log("residual Aave debt (dust):    ", residualDebt);

        // 9. Once the ETH/USD feed heals, re-running step 1 (no completed-guard) closes the
        //    residual dust position via the normal flashloan path.
        _syncAndMockOracles();
        vm.prank(vault.guardian());
        vault.emergencyStep(1);
        assertFalse(loanManager.loanExists(), "post-heal re-run fully closes the residual loan");

        console.log("[M-03 FIX VERIFIED] ETH/USD staleness still freezes user ops (inherent),");
        console.log("                    but emergencyStep(1) now exits the loan while stale.");
    }

    /// @notice GATE RETAINED: the normal-path unwindPosition() must STILL revert on ETH/USD
    ///         staleness — the fix only exempts the dedicated emergency entry point, not
    ///         user-flow unwinds whose sizing depends on fresh prices.
    function test_M03_unwindPosition_normalPath_stillGatedByStaleOracle() public {
        _deployVault();

        uint256 dep = _baseDeposit();
        deal(WSTETH, user1, dep);
        _depositAs(user1, dep);
        assertTrue(loanManager.loanExists(), "precondition: loan opened");

        vm.warp(block.timestamp + ETH_USD_MAX_STALENESS + 100);
        _refreshAllButEthUsd();

        // unwindPosition is onlyVault; impersonate the vault to reach the oracle check directly.
        vm.prank(address(vault));
        vm.expectRevert(bytes("ETH/USD: stale"));
        loanManager.unwindPosition(type(uint256).max);

        console.log("[M-03 GATE] normal unwindPosition() still reverts on stale ETH/USD.");
    }

    /// @notice ISOLATED FIX PROOF: emergencyUnwindPosition() closes the position during the
    ///         ETH/USD outage when the loan manager's debt-token balance covers the debt —
    ///         the repay + withdraw-all path touches no oracle.
    function test_M03_emergencyUnwindPosition_succeedsWhileStale() public {
        _deployVault();

        uint256 dep = _baseDeposit();
        deal(WSTETH, user1, dep);
        _depositAs(user1, dep);
        assertTrue(loanManager.loanExists(), "precondition: loan opened");

        vm.warp(block.timestamp + ETH_USD_MAX_STALENESS + 100);
        _refreshAllButEthUsd();
        vm.expectRevert(bytes("ETH/USD: stale"));
        wstEthOracle.latestRoundData();

        // Cover the debt at the loan manager (in the real flow the vault transfers its
        // step-0 proceeds before calling emergencyUnwindPosition).
        uint256 debt = loanManager.getCurrentDebt();
        deal(USDT, address(loanManager), debt + 1e6);

        vm.prank(address(vault));
        loanManager.emergencyUnwindPosition();

        assertFalse(loanManager.loanExists(), "FIX: loan closed while ETH/USD is stale");
        assertGt(
            IERC20(WSTETH).balanceOf(address(vault)),
            0,
            "FIX: collateral withdrawn to vault while stale"
        );

        console.log("[M-03 FIX ISOLATED] emergencyUnwindPosition() oracle-free exit confirmed.");
    }

    /// @notice CONTRAST: at the SAME timestamp, refreshing ETH/USD too unblocks everything —
    ///         deposit/withdraw work and the loan can be unwound. Proves the freeze is caused
    ///         specifically by the 2h ETH/USD staleness, not by test setup.
    function test_M03_freshEthUsd_opsAndUnwindSucceed() public {
        _deployVault();

        uint256 dep = _baseDeposit();
        deal(WSTETH, user1, dep);
        _depositAs(user1, dep);
        assertTrue(loanManager.loanExists(), "precondition: loan opened");

        // Warp past 2h but refresh ALL feeds including ETH/USD.
        vm.warp(block.timestamp + ETH_USD_MAX_STALENESS + 100);
        _syncAndMockOracles();

        // Oracle prices fine now.
        (, int256 p,,,) = wstEthOracle.latestRoundData();
        assertGt(p, 0, "fresh: WstEthOracle prices");

        // unwindPosition succeeds (as vault).
        vm.prank(address(vault));
        loanManager.unwindPosition(type(uint256).max);
        assertFalse(loanManager.loanExists(), "fresh: loan fully unwound");

        console.log("[M-03 CONTRAST] Fresh ETH/USD: unwindPosition succeeds, loan closed.");
    }
}
