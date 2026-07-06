// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { ZenjiWbtcLlamaStakeDao } from "../src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { CrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title WhaleExitUnwindRepro
/// @notice Regression tests for two size-dependent unwind failures observed on the deployed
///         WBTC/LlamaLend/USDT-crvUSD vault (0xB415bce7d24ef95405006e8A1a9381119F7fc31F,
///         DeploymentV27 2.0) when a ~100 BTC (~$6.2M) depositor exits.
///
///         Case 1 — PartialUnwindFailed (0xc03ecc6c) on a near-total redeem:
///         The vault carries a dust seed deposit (deployed vault: 665,170 sats ≈ $415),
///         so the whale's redeem is NOT a final withdraw and takes the partial unwind.
///         The strategy round-trip returns slightly less crvUSD than the whale's
///         proportional debt share (repay is balance-capped in LlamaLoanManager._unwindPosition
///         step 3), so the shortfall (~$130-400 at current pool state) lands as residual
///         debt on the dust seed position. remove_collateral() of the whale's collateral
///         then leaves ~$415 collateral carrying ~$400 debt — LlamaLend's
///         _calculate_debt_n1 rejects it with "Debt too high", which the loan manager's
///         narrow dust-escalation guard (only "Amount too low" escalates to a full close)
///         wraps into PartialUnwindFailed. The whale's exit is bricked.
///
///         Case 2 — V3TooLittleReceived (0x39d35496) on mid-size partial withdrawals:
///         Partial unwinds withdraw a 5% debt buffer; the unspent surplus is swapped
///         crvUSD→WETH (Curve TriCRV)→WBTC (Uni V3) under a 1% oracle floor. The TriCRV
///         pool (~$2.2M TVL, ~445 WETH) fills a $20k order ~3-6% below Chainlink, so any
///         withdrawal producing >$5-10k of buffer surplus reverts in the Universal Router.
///
///         Fixes under test (2026-06-11):
///         - Case 1: pro-rata shortfall guard in LlamaLoanManager._unwindPosition scales
///           the collateral removal to the debt actually repaid, so the residual LTV
///           cannot worsen and the withdrawer absorbs the shortfall via share re-pricing.
///         - Case 2: partial unwinds no longer force-swap the buffer surplus; the loan
///           manager leaves it for the vault (LlamaLoanManager step 7 gated on fullyClose)
///           and the vault redeposits it into the strategy (Zenji._unwindPosition step 5).
///
///         NOTE: scenarios depend on live pool conditions (TriCRV depth/dislocation,
///         USDT/crvUSD exit cost); pin FORK_BLOCK for determinism.
contract WhaleExitUnwindRepro is ZenjiForkTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500;
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant CRVUSD_INDEX = 1; // coin(0)=USDT, coin(1)=crvUSD
    address constant STAKEDAO_USDT_CRVUSD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    /// @dev Seed size mirrors the live vault's seed deposit (665,170 sats ≈ 0.0066 BTC).
    uint256 constant SEED_DEPOSIT = 665_170;
    uint256 constant WHALE_DEPOSIT = 100e8;

    CrvToCrvUsdSwapper public crvSwapper;
    UniswapMixedCurveSwapper public swapper;
    CrvUsdLpStakeDaoStrategy public strategy;
    LlamaLoanManager public llamaManager;

    address seeder = makeAddr("seeder");

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
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = CRVUSD_USD_ORACLE;
        oracles[2] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _getWethCrvUsdIndices() internal view returns (uint256 wethIdx, uint256 crvUsdIdx) {
        ICurveTriCrypto pool = ICurveTriCrypto(TRICRYPTO_POOL);
        for (uint256 i = 0; i < 3; i++) {
            address coin = pool.coins(i);
            if (coin == WETH) wethIdx = i;
            else if (coin == CRVUSD) crvUsdIdx = i;
        }
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        // Deploy order: crvSwapper(+0), swapper(+1), strategy(+2), llamaManager(+3), vault(+4)
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, TRICRYPTO_POOL, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedCurveSwapper(
            owner,
            WBTC,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WBTC_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            3600
        );

        strategy = new CrvUsdLpStakeDaoStrategy(
            CRVUSD,
            address(0),
            owner,
            USDT_CRVUSD_POOL,
            STAKEDAO_USDT_CRVUSD_VAULT,
            address(crvSwapper),
            USDT_CRVUSD_GAUGE,
            CRVUSD_INDEX,
            CRVUSD_USD_ORACLE,
            CRV_USD_ORACLE,
            "crvUSD -> USDT/crvUSD LP Strategy"
        );

        llamaManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0),
            3600
        );

        ZenjiWbtcLlamaStakeDao vault_ = new ZenjiWbtcLlamaStakeDao(
            address(llamaManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(vault_) == expectedVaultAddress, "Vault address mismatch");

        llamaManager.initializeVault(address(vault_));
        strategy.initializeVault(address(vault_));

        vm.prank(owner);
        swapper.setVault(address(vault_));

        loanManager = AaveLoanManager(address(llamaManager));
        vault = vault_;
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        _syncAndMockOracles();
    }

    // ============ Case 1: dust residual position bricks the whale's exit ============

    /// @dev Whale (100 BTC) + dust seed (0.0066 BTC). The whale's redeem-all routes
    ///      through the partial unwind; the strategy round-trip shortfall lands on the
    ///      dust residual position, LlamaLend rejects remove_collateral with
    ///      "Debt too high", and the loan manager surfaced PartialUnwindFailed.
    ///      Fixed by the pro-rata shortfall guard in LlamaLoanManager._unwindPosition:
    ///      the collateral removal is scaled to the debt actually repaid, so the
    ///      residual LTV cannot worsen and the whale absorbs the shortfall.
    function test_repro_whaleRedeemAll_dustResidual_succeeds() public {
        _deployVault();
        deal(WBTC, seeder, SEED_DEPOSIT);
        deal(WBTC, user1, WHALE_DEPOSIT);
        _depositAs(seeder, SEED_DEPOSIT);
        _depositAs(user1, WHALE_DEPOSIT);
        _refreshOracles();

        (uint256 posCol, uint256 posDebt) = loanManager.getPositionValues();
        console.log("position: %d sat collateral, %d crvUSD debt", posCol, posDebt / 1e18);

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 received = vault.redeem(shares, user1, user1);
        console.log("whale received: %d sat", received);
        assertGe(
            received, (WHALE_DEPOSIT * 99) / 100, "whale should exit within the 1% slippage budget"
        );

        // The dust residual position must remain healthy and exitable: the seeder's
        // follow-up redeem (now the final withdraw → full close) must not be bricked
        // or socialized with the whale's slippage.
        _refreshOracles();
        uint256 seedShares = vault.balanceOf(seeder);
        vm.prank(seeder);
        uint256 seedReceived = vault.redeem(seedShares, seeder, seeder);
        console.log("seeder received: %d sat", seedReceived);
        assertGe(seedReceived, (SEED_DEPOSIT * 80) / 100, "seeder must not absorb whale slippage");
    }

    /// @dev Control: same dust seed, 25 BTC whale — the proportionally smaller repay
    ///      shortfall keeps the residual position healthy and the exit succeeds.
    function test_repro_whaleRedeemAll_25btc_control_succeeds() public {
        _deployVault();
        deal(WBTC, seeder, SEED_DEPOSIT);
        deal(WBTC, user1, 25e8);
        _depositAs(seeder, SEED_DEPOSIT);
        _depositAs(user1, 25e8);
        _refreshOracles();

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 received = vault.redeem(shares, user1, user1);
        console.log("25 BTC control received: %d sat", received);
        assertGt(received, 0, "25 BTC whale exit should succeed");
    }

    // ============ Case 2: 5% buffer surplus swap breaches the oracle floor ============

    /// @dev Single depositor (100 BTC) withdraws a 10 BTC slice. The partial unwind
    ///      over-withdraws a 5% debt buffer (~$20k surplus crvUSD) which used to be
    ///      force-swapped crvUSD->WETH->WBTC; the TriCRV leg (~$2.2M pool) fills
    ///      ~3-6% below Chainlink, breaching the swapper's 1% oracle floor
    ///      (Universal Router V3TooLittleReceived). Fixed: partial unwinds now
    ///      redeposit the surplus into the strategy instead of swapping it.
    function test_repro_partialWithdraw10btc_surplusRedeposited() public {
        _deployVault();
        deal(WBTC, user1, WHALE_DEPOSIT);
        _depositAs(user1, WHALE_DEPOSIT);
        _refreshOracles();

        vm.prank(user1);
        uint256 burned = vault.withdraw(10e8, user1, user1);
        console.log("10 BTC slice burned %d shares", burned);
        assertGt(burned, 0, "10 BTC slice should succeed");

        // Surplus buffer must be back in the strategy, not stranded in the vault,
        // and strategy/debt coverage must stay balanced (no rebalance drift).
        assertLe(
            IERC20(CRVUSD).balanceOf(address(vault)), 1e18, "surplus crvUSD stranded in vault"
        );
        uint256 ratio = vault.strategyToDebtRatio();
        console.log("strategyToDebtRatio after slice: %d", ratio);
        assertGe(ratio, 99e16, "strategy underfunded vs debt after withdraw");
        assertLe(ratio, 106e16, "strategy overfunded vs debt after withdraw");
    }

    /// @dev Control: a 2 BTC slice produces only ~$4k of surplus, which squeaks under
    ///      the 1% floor at current TriCRV depth.
    function test_repro_partialWithdraw2btc_control_succeeds() public {
        _deployVault();
        deal(WBTC, user1, WHALE_DEPOSIT);
        _depositAs(user1, WHALE_DEPOSIT);
        _refreshOracles();

        vm.prank(user1);
        uint256 burned = vault.withdraw(2e8, user1, user1);
        console.log("2 BTC slice control burned %d shares", burned);
        assertGt(burned, 0, "2 BTC slice should succeed");
    }
}
