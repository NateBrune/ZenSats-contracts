// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title XautPmUsdCrvUsdAave
/// @notice Fork tests for XAUT/USDT + pmUSD/crvUSD (Stake DAO) strategy on Aave with eMode 43
/// @dev XAUT has 6 decimals. Aave eMode category 43 ("XAUt USDC USDT GHO") is activated,
///      but the vault is conservatively configured at 65% LTV.
contract XautPmUsdCrvUsdAave is ZenjiForkTestBase {
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_XAUT = 0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    uint8 constant AAVE_EMODE_XAUT = 43; // "XAUt USDC USDT GHO"

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant XAUT_USDT_V3_FEE = 500; // 0.05%

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    // NOTE: XAU/USD oracle has a 24h heartbeat — oracles are mocked in tests
    address constant XAU_USD_ORACLE = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniversalRouterV3SingleHopSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    PmUsdCrvUsdStrategy public strategy;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return XAUT;
    }

    /// @notice 1 XAUT = 1e6 (6 decimals, ~$3000/oz)
    function _unit() internal pure override returns (uint256) {
        return 1e6;
    }

    /// @notice 0.01 XAUT ~ $30 — matches VIRTUAL_SHARE_OFFSET
    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e4;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](4);
        oracles[0] = XAU_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return XAU_USD_ORACLE;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _collateralStalenessWarp() internal pure override returns (uint256) {
        return 90001; // XAU/USD Chainlink heartbeat is 24 h; staleness window is 90000 s
    }

    function _maxTargetLtv() internal pure override returns (uint256) {
        return 60e16; // XAUT loan manager maxLtvBps = 6000 (60%)
    }

    /// @notice XAUT/USDT V3 pool (0.05%) has limited depth; at 60% LTV + 1% slippage
    /// the redeem swap reverts above ~2000 XAUT. Cap fuzz well below the cliff.
    function _fuzzMax() internal pure override returns (uint256) {
        return _unit() * 1000; // 1000 XAUT — ~50% of ~2000 XAUT cliff
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return _unit() * 1000; // 1000 XAUT — same cap as single-user
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    // ============ Vault deployment ============

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD index not found");
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
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000 // XAU/USD heartbeat is 24h
        );

        strategy = new PmUsdCrvUsdStrategy(
            USDT,
            CRVUSD,
            CRV,
            PMUSD,
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
            XAUT,
            USDT,
            AAVE_A_XAUT,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            6000,
            7500,
            expectedVaultAddress,
            AAVE_EMODE_XAUT,
            90000 // XAU/USD heartbeat is 24h
        );

        vault = new Zenji(
            XAUT,
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
        vm.startPrank(owner);
        swapper.setSlippage(1e16);
        // XAUT loan manager maxLtvBps = 6000 (60%), but base Zenji defaults to 65%.
        // Lower targetLtv to 60% so the vault doesn't borrow more than the loan manager allows.
        vault.setParam(1, 60e16);
        vm.stopPrank();
        _syncAndMockOracles();
    }

    // ============ eMode-Specific Test ============

    /// @notice Verify that the loan manager activated eMode category 43 on Aave
    function test_eModeCategory_isSet() public {
        _deployVault();
        uint256 category = IAavePool(AAVE_POOL).getUserEMode(address(loanManager));
        assertEq(category, AAVE_EMODE_XAUT, "eMode category should be 43 (XAUt USDC USDT GHO)");
    }

    // ============ Swapper-Specific Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        UniversalRouterV3SingleHopSwapper newSwapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000
        );

        vm.prank(vault.gov());
        vault.proposeSwapper(address(newSwapper));

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        vault.executeSwapper();

        vm.warp(block.timestamp + 1 weeks + 1);
        _syncAndMockOracles();

        vm.prank(vault.gov());
        vault.executeSwapper();
        assertEq(address(vault.swapper()), address(newSwapper), "Swapper should be updated");

        UniversalRouterV3SingleHopSwapper anotherSwapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000
        );
        vm.prank(vault.gov());
        vault.proposeSwapper(address(anotherSwapper));

        vm.prank(vault.gov());
        vault.cancelSwapper();

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        vault.executeSwapper();
    }

    function test_setSlippage() public {
        _deployVault();

        assertEq(swapper.slippage(), 1e16, "Slippage should be 1% after deploy setup");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.setSlippage(10e16);

        vm.prank(owner);
        swapper.setSlippage(10e16);
        assertEq(swapper.slippage(), 10e16, "Slippage should be 10%");
    }

    /// @notice A 100 XAUT position (~$300K) can fully exit at the 2% production default
    function test_largeDeposit_fullRedeem_succeedsAt2Percent() public {
        bool passed = _runSlippageScenario(2e16, 100e6); // 100 XAUT
        assertTrue(passed, "100 XAUT full redeem should succeed at 2% slippage");
    }

    /// @notice Slippage below the 0.05% pool fee (< 5 bps) should cause the redeem to revert
    function test_largeDeposit_fullRedeem_revertsAtTinySlippage() public {
        bool passed = _runSlippageScenario(1e13, 100e6); // 0.1 bps — below 5 bps pool fee
        assertFalse(passed, "100 XAUT full redeem should revert when slippage < pool fee (0.05%)");
    }

    function _runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) internal returns (bool) {
        _syncAndMockOracles();
        _deployVault();

        deal(XAUT, user1, depositAmount);

        if (swapper.slippage() != targetSlippage) {
            vm.prank(owner);
            swapper.setSlippage(targetSlippage);
        }

        _depositAs(user1, depositAmount);

        uint256 shares = vault.balanceOf(user1);
        if (shares == 0) return false;

        vm.prank(user1);
        try vault.redeem(shares, user1, user1) {
            return true;
        } catch {
            return false;
        }
    }

    function runSlippageScenario(uint256 targetSlippage, uint256 depositAmount) external returns (bool) {
        return _runSlippageScenario(targetSlippage, depositAmount);
    }

    function tryDepositChunk(address depositor, uint256 amount) external returns (bool) {
        if (msg.sender != address(this)) revert("self only");
        _depositAs(depositor, amount);
        return true;
    }

    /// @dev Decode a low-level revert bytes into a human-readable string for test output.
    function _decodeRevertReason(bytes memory err, string memory step) internal pure returns (string memory) {
        if (err.length < 4) return string(abi.encodePacked(step, ": revert (no data)"));
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }

        if (sel == bytes4(keccak256("ExchangeFailed()")))
            return string(abi.encodePacked(step, ": ExchangeFailed (step 1 USDT->crvUSD: pool get_dy output falls below oracle floor at 1% slippage)"));
        if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)")))
            return string(abi.encodePacked(step, ": SwapperUnderperformed (Uniswap USDT->XAUT output below 1% oracle floor)"));
        if (sel == bytes4(keccak256("SlippageExceeded()")))
            return string(abi.encodePacked(step, ": SlippageExceeded (Uniswap minAmountOut not met)"));
        if (sel == bytes4(keccak256("InsufficientCollateral()")))
            return string(abi.encodePacked(step, ": InsufficientCollateral (recovered XAUT < minOut after unwind)"));
        if (sel == bytes4(keccak256("HealthTooLow()")))
            return string(abi.encodePacked(step, ": HealthTooLow (Aave position health < 1.1)"));
        if (sel == bytes4(keccak256("Error(string)"))) {
            // ABI-decode the string message
            if (err.length > 68) {
                bytes memory msg_ = new bytes(err.length - 68);
                for (uint256 i = 0; i < msg_.length; i++) msg_[i] = err[68 + i];
                return string(abi.encodePacked(step, ": require(", string(msg_), ")"));
            }
            return string(abi.encodePacked(step, ": require (empty message)"));
        }

        // fallback: print raw selector hex
        bytes memory h = new bytes(8);
        bytes16 chars = "0123456789abcdef";
        for (uint256 k = 0; k < 4; k++) {
            h[k * 2]     = chars[uint8(sel[k]) >> 4];
            h[k * 2 + 1] = chars[uint8(sel[k]) & 0xf];
        }
        return string(abi.encodePacked(step, ": unknown selector 0x", string(h)));
    }

    function test_slippageSweep_bySlippage() public {
        uint256[] memory levels = new uint256[](8);
        levels[0] = 1e16;  // 1.0%
        levels[1] = 2e16;  // 2.0%
        levels[2] = 3e16;  // 3.0%
        levels[3] = 5e16;  // 5.0%
        levels[4] = 10e16; // 10.0%
        levels[5] = 15e16; // 15.0%
        levels[6] = 20e16; // 20.0%
        levels[7] = 30e16; // 30.0%

        uint256 firstPass = 0;
        uint256 depositAmt = 10e6; // 10 XAUT

        for (uint256 i = 0; i < levels.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(levels[i], depositAmt) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("XAUT Sweep slippage=%s bps passed=%s", levels[i] / 1e14, passed ? 1 : 0);
            if (passed && firstPass == 0) {
                firstPass = levels[i];
            }
        }

        console.log("XAUT Sweep firstPass(bps)=%s", firstPass == 0 ? 0 : firstPass / 1e14);
        assertTrue(firstPass > 0 && firstPass <= 2e16, "Full redeem should succeed within 2% slippage");
    }

    function test_slippageSweep_bySize() public {
        uint256[] memory sizes = new uint256[](8);
        sizes[0] = 1e6;    //    1 XAUT ~$3K
        sizes[1] = 5e6;    //    5 XAUT ~$15K
        sizes[2] = 10e6;   //   10 XAUT ~$30K
        sizes[3] = 25e6;   //   25 XAUT ~$75K
        sizes[4] = 50e6;   //   50 XAUT ~$150K
        sizes[5] = 100e6;  //  100 XAUT ~$300K
        sizes[6] = 250e6;  //  250 XAUT ~$750K
        sizes[7] = 500e6;  //  500 XAUT ~$1.5M

        uint256 slippage = 1e16; // 1%
        uint256 lastPass = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);
            console.log("XAUT SizeSweep slippage=100bps deposit=%s XAUT passed=%s", sizes[i] / 1e6, passed ? 1 : 0);
            if (passed) {
                lastPass = sizes[i];
            }
        }

        console.log("XAUT SizeSweep lastPass=%s XAUT", lastPass == 0 ? 0 : lastPass / 1e6);
        assertGt(lastPass, 0, "At least the smallest size must exit at 1% slippage");
    }

    /// @notice Refine the liquidity threshold at 1% slippage in a tighter XAUT band.
    function test_liquiditySweep_bySize_refined() public {
        uint256[] memory sizes = new uint256[](7);
        sizes[0] = 50e6;  //  50 XAUT ~$150K
        sizes[1] = 75e6;  //  75 XAUT ~$225K
        sizes[2] = 100e6; // 100 XAUT ~$300K
        sizes[3] = 125e6; // 125 XAUT ~$375K
        sizes[4] = 150e6; // 150 XAUT ~$450K
        sizes[5] = 200e6; // 200 XAUT ~$600K
        sizes[6] = 250e6; // 250 XAUT ~$750K

        uint256 slippage = 1e16; // 1%
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "XAUT RefinedSizeSweep slippage=100bps deposit=%s XAUT passed=%s",
                sizes[i] / 1e6,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("XAUT RefinedSizeSweep lastPass=%s XAUT", lastPass == 0 ? 0 : lastPass / 1e6);
        console.log("XAUT RefinedSizeSweep firstFail=%s XAUT", firstFail == 0 ? 0 : firstFail / 1e6);
        assertGt(lastPass, 0, "Refined sweep should have at least one passing size");
    }

    /// @notice Ultra-refined sweep narrowing around the XAUT/USDT liquidity cliff.
    function test_liquiditySweep_bySize_ultraRefined() public {
        uint256[] memory sizes = new uint256[](6);
        sizes[0] = 100e6; // 100 XAUT
        sizes[1] = 110e6; // 110 XAUT
        sizes[2] = 120e6; // 120 XAUT
        sizes[3] = 130e6; // 130 XAUT
        sizes[4] = 140e6; // 140 XAUT
        sizes[5] = 150e6; // 150 XAUT

        uint256 slippage = 1e16; // 1%
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "XAUT UltraRefined slippage=100bps deposit=%s XAUT passed=%s",
                sizes[i] / 1e6,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("XAUT UltraRefined lastPass=%s XAUT", lastPass == 0 ? 0 : lastPass / 1e6);
        console.log("XAUT UltraRefined firstFail=%s XAUT", firstFail == 0 ? 0 : firstFail / 1e6);
        assertGt(lastPass, 0, "Ultra-refined sweep should have at least one passing size");
    }

    /// @notice Extended sweep probing per-tx deposit capacity above 250 XAUT at 1% slippage.
    /// @dev Finds the Uniswap XAUT/USDT liquidity cliff for the borrowing-then-redeposit swap path.
    function test_liquiditySweep_bySize_extended() public {
        uint256[] memory sizes = new uint256[](10);
        sizes[0] = 250e6;   //  250 XAUT ~$750K
        sizes[1] = 350e6;   //  350 XAUT ~$1.05M
        sizes[2] = 500e6;   //  500 XAUT ~$1.5M
        sizes[3] = 650e6;   //  650 XAUT ~$1.95M
        sizes[4] = 750e6;   //  750 XAUT ~$2.25M
        sizes[5] = 900e6;   //  900 XAUT ~$2.7M
        sizes[6] = 1000e6;  // 1000 XAUT ~$3M
        sizes[7] = 1250e6;  // 1250 XAUT ~$3.75M
        sizes[8] = 1500e6;  // 1500 XAUT ~$4.5M
        sizes[9] = 2000e6;  // 2000 XAUT ~$6M

        uint256 slippage = 1e16; // 1%
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "XAUT ExtendedSizeSweep slippage=100bps deposit=%s XAUT passed=%s",
                sizes[i] / 1e6,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        console.log("XAUT ExtendedSizeSweep lastPass=%s XAUT (~$%sK)", lastPass / 1e6, lastPass * 3 / 1e9);
        console.log("XAUT ExtendedSizeSweep firstFail=%s XAUT (~$%sK)", firstFail / 1e6, firstFail * 3 / 1e9);
        assertGt(lastPass, 0, "Extended sweep: at least 250 XAUT should pass");
    }

    /// @notice Pinpoints the Uniswap pool's per-tx USDT→XAUT slippage cliff at exactly 1% (swapper level).
    /// @dev On every redeem, the vault withdraws 105% of proportional debt from the strategy. The 5%
    ///      surplus USDT is swapped back to XAUT via Uniswap (swapDebtForCollateral). This is the ONLY
    ///      Uniswap interaction; its size = deposit × targetLtv × collateralPrice × 5%.
    ///      Quoter analysis: $360K USDT→XAUT = 0.63% slippage; $900K = 2.27%. Boundary ≈ $480K USDT
    ///      ⟹ max single depositor at 1% ≈ 480K / (0.60 × $4524 × 0.05) ≈ 3,500 XAUT.
    ///      Note: Aave XAUT supply cap headroom at this fork block ≈ 12,700 XAUT — no cap interference up to 5k.
    function test_uniswapSlippageCeiling_1pct() public {
        // Sized around estimated 3,500 XAUT boundary with fine resolution in the cliff region
        uint256[] memory sizes = new uint256[](12);
        sizes[0]  = 2000e6;  // 2000 XAUT — known passing baseline
        sizes[1]  = 2500e6;  // 2500 XAUT ~$11.3M
        sizes[2]  = 3000e6;  // 3000 XAUT ~$13.6M
        sizes[3]  = 3250e6;  // 3250 XAUT ~$14.7M
        sizes[4]  = 3500e6;  // 3500 XAUT ~$15.8M  ← estimated boundary
        sizes[5]  = 3750e6;  // 3750 XAUT ~$17.0M
        sizes[6]  = 4000e6;  // 4000 XAUT ~$18.1M
        sizes[7]  = 4500e6;  // 4500 XAUT ~$20.4M
        sizes[8]  = 5000e6;  // 5000 XAUT ~$22.6M
        sizes[9]  = 6000e6;  // 6000 XAUT ~$27.1M
        sizes[10] = 8000e6;  // 8000 XAUT ~$36.2M
        sizes[11] = 10000e6; // 10000 XAUT ~$45.2M

        uint256 slippage = 1e16; // 1% – same as the swapper's internal oracle floor
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            // Report swap size: surplus = deposit × 0.60 LTV × XAUT_price × 5% buffer
            // Approximated as deposit × 135 (derived from oracle price at fork block)
            uint256 approxSwapUsdt = sizes[i] * 135 / 1e6 / 1000; // thousands of USDT
            console.log(
                "UniswapCeiling slippage=100bps deposit=%s XAUT swapEst=$%sK passed=%s",
                sizes[i] / 1e6,
                approxSwapUsdt,
                passed ? 1 : 0
            );

            if (passed) {
                lastPass = sizes[i];
            } else if (firstFail == 0) {
                firstFail = sizes[i];
            }
        }

        uint256 approxLastPassUsd = lastPass * 4524 / 1e6 / 1000; // $K
        uint256 approxFirstFailUsd = firstFail * 4524 / 1e6 / 1000;

        console.log("--- Uniswap USDT->XAUT slippage ceiling at 1% ---");
        console.log("lastPass : %s XAUT (~$%sM TVL single depositor)", lastPass / 1e6, approxLastPassUsd / 1000);
        console.log("firstFail: %s XAUT (~$%sM TVL single depositor)", firstFail / 1e6, approxFirstFailUsd / 1000);
        if (lastPass > 0 && firstFail > 0) {
            // surplus = deposit_XAUT × 60% LTV × ~$4524/XAUT × 5% buffer ≈ deposit × $135.72
            // lastPass/1e6 gives XAUT count; multiply by 135.72 gives USDT surplus
            uint256 surplusLastPassUsdt  = lastPass  * 13572 / 1e6 / 100; // USDT, 0 decimals
            uint256 surplusFirstFailUsdt = firstFail * 13572 / 1e6 / 100;
            console.log("Surplus USDT at lastPass : ~$%s", surplusLastPassUsdt);
            console.log("Surplus USDT at firstFail: ~$%s", surplusFirstFailUsdt);
        }

        assertGt(lastPass, 0, "At least 2000 XAUT should pass at 1% slippage");
    }

    /// @notice Bisect the 3000–3500 XAUT cliff with 50 XAUT resolution.
    /// @dev The coarse sweep (test_uniswapSlippageCeiling_1pct) estimates the per-tx USDT→XAUT
    ///      slippage boundary at ~3,500 XAUT. This test refines that cliff at 50 XAUT resolution
    ///      to find the exact safe single-deposit cap.
    function test_uniswapSlippageCeiling_1pct_finegrain() public {
        // pmUSD/crvUSD pool is ~$15.8M; at 60% LTV observed cliff is ~2000–3000 XAUT
        uint256[] memory sizes = new uint256[](10);
        sizes[0] = 2000e6;
        sizes[1] = 2100e6;
        sizes[2] = 2200e6;
        sizes[3] = 2300e6;
        sizes[4] = 2400e6;
        sizes[5] = 2500e6;
        sizes[6] = 2600e6;
        sizes[7] = 2700e6;
        sizes[8] = 2800e6;
        sizes[9] = 2900e6;

        uint256 slippage = 1e16;
        uint256 lastPass = 0;
        uint256 firstFail = 0;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, sizes[i]) returns (bool ok) {
                passed = ok;
            } catch {
                passed = false;
            }
            vm.revertTo(snap);

            console.log(
                "UniswapFine slippage=100bps deposit=%s XAUT passed=%s",
                sizes[i] / 1e6,
                passed ? 1 : 0
            );

            if (passed) { lastPass = sizes[i]; }
            else if (firstFail == 0) { firstFail = sizes[i]; }
        }

        console.log("UniswapFine lastPass=%s XAUT  firstFail=%s XAUT", lastPass / 1e6, firstFail / 1e6);
        assertGt(lastPass, 0, "Fine-grain: at least 2000 XAUT should pass at 1% slippage");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single-depositor safe TVL cap: one deposit → one full redeem, 1% slippage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Determines the maximum amount a single depositor can deposit and withdraw
    ///         in exactly two transactions while staying within 1% slippage.
    ///
    /// @dev Flow (matches real-world usage):
    ///   Tx 1 – deposit(amount)   : vault supplies XAUT to Aave → borrows USDT → invests in pmUSD/crvUSD LP
    ///   (block advances)
    ///   Tx 2 – redeem(allShares) : vault exits LP → repays USDT debt → withdraws XAUT from Aave
    ///                              → swaps 5% USDT surplus back to XAUT via Uniswap V3 fee=500
    ///
    ///   The ONLY Uniswap interaction is the USDT→XAUT surplus swap in Tx 2.
    ///   Its size ≈ deposit × targetLtv (30%) × debtRatio × 5% buffer
    ///   (with 30% target LTV the actual borrow is 30% of collateral value = ~$135 USDT per XAUT deposited)
    ///
    ///   Ceiling is set by the Uniswap XAUT/USDT 0.05% pool depth:
    ///   Quoter shows slippage crosses 1% around $560K USDT per swap ≈ 4,100 XAUT.
    ///
    ///   Binary search over [4100, 4150] at 10 XAUT resolution confirms the exact boundary.
    /// @notice Finds the exact single-depositor safe cap at 1% slippage via open-ended binary search.
    ///
    /// @dev Fully dynamic — no hardcoded brackets. Runs three phases:
    ///   Phase 1 — coarse sweep (500 XAUT steps, 500..10000) to bracket the cliff.
    ///   Phase 2 — binary search within that bracket at 10 XAUT resolution.
    ///   Phase 3 — clean deposit + redeem at the safe cap to measure actual round-trip cost.
    ///   Phase 4 — trace the first failing size to expose the exact revert reason.
    ///
    ///   The vault's only Uniswap interaction is swapping the 5% USDT surplus back to XAUT after
    ///   each redemption. The ceiling is set by the Uniswap XAUT/USDT 0.05% pool depth.
    function test_singleDepositorSafeTvlCap_1pct() public {
        uint256 slippage = 1e16; // 1%

        // ── Phase 1: coarse sweep at 500 XAUT steps to find bracket ──────────────────
        uint256 clo = 0;
        uint256 chi = 0;
        {
            uint256[] memory coarse = new uint256[](20);
            for (uint256 i = 0; i < 20; i++) coarse[i] = (i + 1) * 500e6; // 500..10000 XAUT
            for (uint256 i = 0; i < coarse.length; i++) {
                uint256 snap = vm.snapshot();
                bool passed;
                try this.runSlippageScenario(slippage, coarse[i]) returns (bool ok) { passed = ok; } catch {}
                vm.revertTo(snap);
                if (passed) { clo = coarse[i]; }
                else if (chi == 0) { chi = coarse[i]; break; }
            }
        }
        require(clo > 0, "Not even 500 XAUT passes at 1% - pool is broken");
        require(chi > 0, "Everything passes at coarse resolution - extend upper bound");

        // ── Phase 2: binary search within [clo, chi] at 10 XAUT resolution ──────────
        uint256 lo = clo;
        uint256 hi = chi;
        while (hi - lo > 10e6) {
            uint256 mid = lo + ((hi - lo) / 2 / 10e6) * 10e6;
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, mid) returns (bool ok) { passed = ok; } catch {}
            vm.revertTo(snap);
            if (passed) lo = mid;
            else        hi = mid;
        }
        uint256 safeCap  = lo; // last passing size
        uint256 firstFail = hi; // first failing size

        // ── Phase 3: clean measurement at safeCap ─────────────────────────────────────
        uint256 depositUsd;
        uint256 redeemUsd;
        uint256 roundTripBps;
        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(XAUT, user1, safeCap);
            vm.prank(owner); swapper.setSlippage(slippage);

            _depositAs(user1, safeCap);
            _syncAndMockOracles();

            uint256 sharesAll = vault.balanceOf(user1);
            vm.prank(user1);
            uint256 xautOut = vault.redeem(sharesAll, user1, user1);

            // XAU/USD oracle: 8-decimal Chainlink price. 1 XAUT (1e6 units) = 1 troy oz.
            (, int256 rawPrice,,,) = IChainlinkOracle(XAU_USD_ORACLE).latestRoundData();
            uint256 price8 = uint256(rawPrice);
            depositUsd   = (safeCap * price8) / 1e14; // whole dollars
            redeemUsd    = (xautOut * price8) / 1e14;
            roundTripBps = safeCap > xautOut ? ((safeCap - xautOut) * 10000) / safeCap : 0;

            vm.revertTo(snap);
        }

        // ── Phase 4: trace the first failing size ─────────────────────────────────────
        // Use runSlippageScenario (external call) for isolation. If that also passes
        // (pool state drifted), walk up 10 XAUT at a time to find the actual cliff.
        string memory failReason = "not found";
        uint256 traceTarget = firstFail;
        for (uint256 probe = firstFail; probe <= firstFail + 200e6; probe += 10e6) {
            uint256 snap = vm.snapshot();
            bool passed;
            try this.runSlippageScenario(slippage, probe) returns (bool ok) { passed = ok; } catch {}
            vm.revertTo(snap);
            if (!passed) { traceTarget = probe; break; }
        }

        {
            uint256 snap = vm.snapshot();
            _syncAndMockOracles();
            _deployVault();
            deal(XAUT, user1, traceTarget);
            vm.prank(owner); swapper.setSlippage(slippage);

            // Step A: try deposit (can fail if Curve strategy exchange exceeds slippage)
            vm.startPrank(user1);
            IERC20(XAUT).approve(address(vault), traceTarget);
            bool depositOk;
            try vault.deposit(traceTarget, user1) returns (uint256) {
                depositOk = true;
            } catch (bytes memory err) {
                depositOk = false;
                failReason = _decodeRevertReason(err, "deposit");
            }
            vm.stopPrank();

            // Step B: if deposit succeeded, advance block then try redeem
            if (depositOk) {
                vm.roll(block.number + 1);
                _syncAndMockOracles();
                uint256 sharesAll = vault.balanceOf(user1);
                vm.prank(user1);
                try vault.redeem(sharesAll, user1, user1) returns (uint256) {
                    failReason = "passed in trace (pool state shifted)";
                } catch (bytes memory err) {
                    failReason = _decodeRevertReason(err, "redeem");
                }
            }
            vm.revertTo(snap);
        }

        // ── Report ─────────────────────────────────────────────────────────────────────
        console.log("=== Single-depositor safe TVL cap at 1%% slippage ===");
        console.log("Max safe deposit:    %s XAUT",  safeCap / 1e6);
        console.log("First failing size:  %s XAUT",  firstFail / 1e6);
        console.log("Deposit value:      ~$%s",       depositUsd);
        console.log("Redeem  value:      ~$%s",       redeemUsd);
        console.log("Round-trip cost:     %s bps",    roundTripBps);
        console.log("Failure reason:      %s",        failReason);

        assertGt(safeCap, 0, "Must find a passing size");
        assertLe(roundTripBps, 100, "Round-trip cost at cap must be within 1%%");
    }

    /// @notice Fresh (no snapshots) diagnostic: shows exactly WHY deposits fail above the ~4000 XAUT cliff.
    /// @dev Run with `forge test --match-test test_singleDepositorFailureDiagnosis -vv` to see the failure step.
    ///      The vault borrows USDT and deposits it into the Curve pmUSD/crvUSD strategy; at large sizes Curve's
    ///      exchange() minOut check fails before any Uniswap interaction even occurs.
    ///
    /// Slippage check inside CurveUsdtSwapLib.swapUsdtToCrvUsd():
    ///   poolQuote   = pool.get_dy(usdtIndex, crvUsdIndex, usdtIn)          ← pool spot quote
    ///   oracleFloor = usdtIn * usdtPrice * 1e12 / crvUsdPrice * 0.99       ← oracle-based minimum
    ///   minOut      = max(poolQuote * 0.99, oracleFloor)
    ///   exchange reverts when actual_out < minOut  (==ExchangeFailed)
    ///
    /// At large sizes the pool degrades: poolQuote < oracleFloor (pool gives you fewer crvUSD
    /// than the oracle says USDT is worth), so even the pool's own quote fails the oracle floor.
    function test_singleDepositorFailureDiagnosis() public {
        uint256 slippage = 1e16; // 1%

        // Use a size comfortably above the known ~4450 XAUT cliff so it reliably fails.
        uint256 failSize = 5000e6; // 5000 XAUT ~ $22.5M (above the ceiling)
        uint256 safeSize = 4000e6; // 4000 XAUT ~ $18M (known to pass)

        _syncAndMockOracles();
        _deployVault();
        vm.prank(owner); swapper.setSlippage(slippage);

        // ── Curve pool pre-trade analysis ──────────────────────────────────────
        console.log("");
        console.log("=== Deposit path analysis: XAUT vault two-hop Curve flow ===");
        console.log("  Flow: XAUT collateral -> borrow USDT -> [USDT/crvUSD pool] ->");
        console.log("        crvUSD -> [pmUSD/crvUSD pool] -> LP staked in Stake DAO");
        console.log("  Slippage check 1: 1%% (user-set), Slippage check 2: 0.5%% (LP_SLIPPAGE hardcoded)");
        console.log("");

        (, int256 xauRawPrice,,,) = IChainlinkOracle(XAU_USD_ORACLE).latestRoundData();
        (, int256 usdtRawPrice,,,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();
        (, int256 crvUsdRawPrice,,,) = IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        uint256 xauPrice8 = uint256(xauRawPrice);   // 8 dec, USD/oz
        uint256 usdtPrice8 = uint256(usdtRawPrice); // 8 dec
        uint256 crvUsdPrice8 = uint256(crvUsdRawPrice); // 8 dec

        console.log("  Oracles at fork block:");
        console.log("    XAU/USD:   $%s.%s", xauPrice8 / 1e8, (xauPrice8 % 1e8) / 1e4);
        console.log("    USDT/USD:  %s (8 dec)", usdtPrice8);
        console.log("    crvUSD/USD:%s (8 dec)", crvUsdPrice8);
        console.log("");

        _logCurveAnalysis("FAILING", failSize, xauPrice8, usdtPrice8, crvUsdPrice8, slippage);
        console.log("");
        _logCurveAnalysis("PASSING", safeSize, xauPrice8, usdtPrice8, crvUsdPrice8, slippage);
        console.log("");

        // ── Live deposit attempt at failing size ───────────────────────────────
        console.log("=== Live vault.deposit(%s XAUT, 1%% slippage) ===", failSize / 1e6);
        deal(XAUT, user1, failSize);
        vm.startPrank(user1);
        IERC20(XAUT).approve(address(vault), failSize);
        bool depositOk;
        try vault.deposit(failSize, user1) returns (uint256 shares) {
            depositOk = true;
            console.log("  Deposit PASSED, shares: %s", shares);
        } catch (bytes memory err) {
            depositOk = false;
            console.log("  Deposit FAILED: %s", _decodeRevertReason(err, "deposit"));
        }
        vm.stopPrank();

        if (depositOk) {
            // ── Step B: if deposit somehow passed, try redeem ──────────────────
            vm.roll(block.number + 1);
            _syncAndMockOracles();
            uint256 shares = vault.balanceOf(user1);
            vm.prank(user1);
            try vault.redeem(shares, user1, user1) returns (uint256 xautOut) {
                console.log("  Redeem PASSED, received: %s XAUT", xautOut / 1e6);
                console.log("  --> Neither step failed (pool liquidity shifted at fork block)");
            } catch (bytes memory err) {
                console.log("  Redeem FAILED: %s", _decodeRevertReason(err, "redeem"));
            }
        } else {
            console.log("  --> Failure at DEPOSIT (Curve), not at redeem-time Uniswap swap.");
        }

        // The test is informational; it asserts the deposit fails so CI catches pool liquidity changes.
        require(!depositOk, "Expected deposit to fail at 5000 XAUT with 1% slippage");
    }

    /// @dev Internal helper: prints a full two-step Curve deposit analysis for a given deposit size.
    ///
    ///  Step 1 — USDT → crvUSD  (USDT/crvUSD pool, 1% slippage)
    ///    minOut = max(pool.get_dy * 0.99, oracleFloor)
    ///    oracleFloor = usdtIn * usdtPrice * 1e12 / crvUsdPrice * 0.99
    ///
    ///  Step 2 — crvUSD → pmUSD/crvUSD LP  (pmUSD/crvUSD pool, LP_SLIPPAGE=0.5%)
    ///    minLp = max(calc_token_amount * 0.995, crvUsdIn * 0.995 / virtualPrice)
    function _logCurveAnalysis(
        string memory label,
        uint256 depositXaut,   // XAUT amount (6 dec)
        uint256 xauPrice8,     // XAU/USD 8-dec
        uint256 usdtPrice8,    // USDT/USD 8-dec
        uint256 crvUsdPrice8,  // crvUSD/USD 8-dec
        uint256 slippage       // 1e16 = 1%
    ) internal view {
        uint256 LP_SLIPPAGE = 5e15; // 0.5% — hardcoded in PmUsdCrvUsdStrategy

        // ── Step 1: USDT → crvUSD via USDT_CRVUSD_POOL ───────────────────────
        uint256 estimatedUsdt = (depositXaut * xauPrice8 * vault.targetLtv()) / 1e26;

        uint256 s1PoolQuote    = ICurveStableSwapNG(USDT_CRVUSD_POOL).get_dy(0, 1, estimatedUsdt);
        uint256 s1OracleExpect = (estimatedUsdt * usdtPrice8 * 1e12) / crvUsdPrice8;
        uint256 s1OracleFloor  = (s1OracleExpect * (1e18 - slippage)) / 1e18;
        uint256 s1PoolMin      = (s1PoolQuote    * (1e18 - slippage)) / 1e18;
        uint256 s1EffectiveMin = s1PoolMin > s1OracleFloor ? s1PoolMin : s1OracleFloor;
        bool    s1Pass         = s1PoolQuote >= s1EffectiveMin;

        uint256 s1DegBps;
        bool s1Below = s1PoolQuote < s1OracleExpect;
        if (s1Below) {
            s1DegBps = ((s1OracleExpect - s1PoolQuote) * 10000) / s1OracleExpect;
        } else {
            s1DegBps = ((s1PoolQuote - s1OracleExpect) * 10000) / s1OracleExpect;
        }

        // ── Step 2: crvUSD → pmUSD/crvUSD LP via PMUSD_CRVUSD_POOL ──────────
        // Uses step 1 pool quote as input (best-case: full amount makes it through)
        int128 lpCrvUsdIdx = strategy.lpCrvUsdIndex();
        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIdx))] = s1PoolQuote; // crvUSD slot
        // pmUSD slot stays 0 (no pmUSD in normal deposit)

        uint256 s2ExpectedLp  = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).calc_token_amount(amounts, true);
        uint256 s2VP          = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).get_virtual_price();
        uint256 s2PoolMin     = (s2ExpectedLp * (1e18 - LP_SLIPPAGE)) / 1e18;
        // oracleMinLp = crvUsdIn * (1 - LP_SLIPPAGE) / VP
        uint256 s2OracleMin   = (s1PoolQuote  * (1e18 - LP_SLIPPAGE)) / s2VP;
        uint256 s2EffectiveMin= s2OracleMin > s2PoolMin ? s2OracleMin : s2PoolMin;
        bool    s2Pass        = s2ExpectedLp >= s2EffectiveMin;

        console.log("  [%s] Deposit: %s XAUT", label, depositXaut / 1e6);
        console.log("  Step 1: USDT -> crvUSD  (USDT/crvUSD pool, slippage=%s bps)", slippage / 1e14);
        console.log("    USDT in (est.):      $%s", estimatedUsdt / 1e6);
        console.log("    Pool get_dy quote:    %s crvUSD", s1PoolQuote / 1e18);
        console.log("    Oracle expected out:  %s crvUSD", s1OracleExpect / 1e18);
        console.log("    Oracle floor (min):   %s crvUSD  <- binding min", s1OracleFloor / 1e18);
        if (s1Below) {
            console.log("    Pool degradation:    -%s bps vs oracle  (pool gives LESS)", s1DegBps);
        } else {
            console.log("    Pool premium:        +%s bps vs oracle  (pool gives MORE)", s1DegBps);
        }
        console.log("    Result: %s", s1Pass ? "PASS" : "FAIL -> ExchangeFailed() at USDT_CRVUSD_POOL");

        if (s1Pass) {
            console.log("  Step 2: crvUSD -> LP  (pmUSD/crvUSD pool, LP_SLIPPAGE=0.5%%)");
            console.log("    crvUSD in:           %s crvUSD", s1PoolQuote / 1e18);
            console.log("    calc_token_amount:   %s LP", s2ExpectedLp / 1e18);
            console.log("    VP (virtual price):  %s.%s (e3)", s2VP / 1e15, (s2VP % 1e15) / 1e12);
            console.log("    Oracle min LP:       %s LP  (crvUsdIn/VP*0.995)", s2OracleMin / 1e18);
            console.log("    Pool min LP:         %s LP  (calc*0.995)", s2PoolMin / 1e18);
            console.log("    Result: %s", s2Pass ? "PASS" : "FAIL -> add_liquidity minLp not met");
        } else {
            console.log("  Step 2: SKIPPED (step 1 failed)");
        }
    }

    function test_multiDepositors_maxTvl() public {
        _deployVault();

        vm.prank(vault.gov()); vault.setParam(1, 30e16);
        vm.prank(vault.gov()); vault.setParam(4, 5e16);

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];
        uint256 targetTvlUsdt = 20_000_000e6; // push toward $20M
        uint256 chunk = 200e6; // 200 XAUT per tx
        uint256 minChunk = 1e5;
        uint256 tvlUsdt = 0;
        uint256 iter = 0;

        while (iter < 300 && tvlUsdt < targetTvlUsdt) {
            address depositor = users[iter % users.length];
            deal(XAUT, depositor, chunk);
            bool ok;
            try this.tryDepositChunk(depositor, chunk) returns (bool success) {
                ok = success;
            } catch {
                ok = false;
            }
            if (!ok) {
                if (chunk <= minChunk) break;
                chunk = chunk / 2;
                iter++;
                continue;
            }
            iter++;
            if (iter % 4 == 0) _refreshOracles();
            tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        console.log("XAUT MaxTvl reached TVL(USDT 6d)=%d", tvlUsdt);
        console.log("XAUT MaxTvl final chunk size=%d XAUT", chunk / 1e6);
        assertGt(tvlUsdt, 3_000_000e6, "Should exceed $3M TVL");
    }

    /// @notice Exhaustively deposits until the protocol refuses all deposit sizes, reporting true TVL ceiling.
    /// @dev Uses adaptive chunk halving: starts at 500 XAUT, halves on failure, stops at 1e5 (0.1 XAUT).
    ///      Ceiling is hit when chunk reaches minChunk and still fails, or iteration cap (500) is reached.
    function test_tvlCeiling_exhaustive() public {
        _deployVault();

        vm.prank(vault.gov()); vault.setParam(1, 30e16); // 30% target LTV
        vm.prank(vault.gov()); vault.setParam(4, 5e16);  // 5% slippage

        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];
        uint256 chunk = 500e6;   // 500 XAUT starting chunk
        uint256 minChunk = 1e5;  // 0.1 XAUT floor
        uint256 consecutiveFails = 0;
        uint256 tvlUsdt = 0;
        string memory stopReason = "iter_cap";

        for (uint256 i = 0; i < 500; i++) {
            address depositor = users[i % users.length];
            deal(XAUT, depositor, chunk);

            bool ok;
            try this.tryDepositChunk(depositor, chunk) returns (bool success) {
                ok = success;
            } catch {
                ok = false;
            }

            if (!ok) {
                consecutiveFails++;
                if (chunk > minChunk) {
                    chunk = chunk / 2;
                    consecutiveFails = 0; // reset — smaller chunk might work
                    continue;
                } else {
                    // minChunk is also failing — we've hit the ceiling
                    stopReason = "ceiling_hit";
                    break;
                }
            }

            consecutiveFails = 0;
            if (i % 4 == 0) _refreshOracles();
            tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());

            // Log progress at each order-of-magnitude milestone
            if (tvlUsdt >= 5_000_000e6  && tvlUsdt < 5_001_000e6)  console.log("XAUT Ceiling milestone: $5M");
            if (tvlUsdt >= 10_000_000e6 && tvlUsdt < 10_001_000e6) console.log("XAUT Ceiling milestone: $10M");
            if (tvlUsdt >= 20_000_000e6 && tvlUsdt < 20_001_000e6) console.log("XAUT Ceiling milestone: $20M");
            if (tvlUsdt >= 30_000_000e6 && tvlUsdt < 30_001_000e6) console.log("XAUT Ceiling milestone: $30M");
            if (tvlUsdt >= 40_000_000e6 && tvlUsdt < 40_001_000e6) console.log("XAUT Ceiling milestone: $40M");
            if (tvlUsdt >= 50_000_000e6 && tvlUsdt < 50_001_000e6) console.log("XAUT Ceiling milestone: $50M");
        }

        tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        console.log("XAUT TVL Ceiling stop_reason=%s", stopReason);
        console.log("XAUT TVL Ceiling final_tvl_usdt6=%d", tvlUsdt);
        console.log("XAUT TVL Ceiling final_chunk_xaut=%d", chunk / 1e6);
        assertGt(tvlUsdt, 0, "Should have deposited something");
    }

    function test_strategyBalance_afterDeposit() public {
        _deployVault();
        _depositAs(user1, _unit());

        assertGt(strategy.balanceOf(), 0, "Strategy should report balance");
        uint256 rvShares = strategy.rewardVault().balanceOf(address(strategy));
        assertGt(rvShares, 0, "Reward vault should hold shares");
    }

    function test_strategyName() public {
        _deployVault();
        assertEq(strategy.name(), "USDT -> pmUSD/crvUSD LP Strategy");
    }

    function test_pendingRewards_view() public {
        _deployVault();
        _depositAs(user1, _unit());
        uint256 pending = strategy.pendingRewards();
        assertGe(pending, 0, "Pending rewards view should not revert");
    }

    function test_harvestYield_afterTimePassed() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        uint256 stratBefore = strategy.balanceOf();
        uint256 crvBefore = IERC20(CRV).balanceOf(address(strategy));
        console.log("Before warp: stratBalance=%d crvBalance=%d", stratBefore, crvBefore);

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        vm.prank(owner);
        vault.harvestYield();

        uint256 stratAfter = strategy.balanceOf();
        uint256 crvAfter = IERC20(CRV).balanceOf(address(strategy));
        console.log("After harvest: stratBalance=%d crvBalance=%d", stratAfter, crvAfter);

        assertGe(stratAfter, stratBefore, "Strategy balance must not decrease after harvest");
    }

    function test_multiDepositors_reach3mTvl() public {
        _deployVault();

        vm.prank(vault.gov());
        vault.setParam(1, 30e16);
        vm.prank(vault.gov());
        vault.setParam(4, 5e16);

        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");

        address[4] memory users = [user1, user2, user3, user4];
        uint256 targetTvlUsdt = 3_000_000e6; // $3M — conservative for XAUT/USDT pool depth
        uint256 chunk = 10e6; // 10 XAUT per deposit tx
        uint256 minChunk = 1e5; // 0.1 XAUT
        uint256 tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());

        for (uint256 i = 0; i < 160 && tvlUsdt < targetTvlUsdt; i++) {
            address depositor = users[i % users.length];
            deal(XAUT, depositor, chunk);
            bool ok;
            try this.tryDepositChunk(depositor, chunk) returns (bool success) {
                ok = success;
            } catch {
                ok = false;
            }
            if (!ok) {
                if (chunk <= minChunk) break;
                chunk = chunk / 2;
                continue;
            }
            if (i % 4 == 3) {
                _refreshOracles();
            }
            tvlUsdt = loanManager.getCollateralValue(vault.getTotalCollateral());
        }

        assertGe(tvlUsdt, 3_000_000e6, "TVL should reach at least $3M");
        console.log("XAUT multi-user TVL(USDT 6d)=%d", tvlUsdt);
    }

    function test_largeWithdraw_doesNotBankruptRemaining() public {
        _deployVault();

        uint256 smallDeposit = 1e5; // 0.1 XAUT
        uint256 largeDeposit = 5e6; // 5 XAUT (50x)
        deal(XAUT, user1, smallDeposit);
        deal(XAUT, user2, largeDeposit);

        _depositAs(user1, smallDeposit);
        _depositAs(user2, largeDeposit);

        uint256 user1SharesBefore = vault.balanceOf(user1);
        _refreshOracles();
        _redeemAllAs(user2);

        uint256 user1SharesAfter = vault.balanceOf(user1);
        assertEq(user1SharesAfter, user1SharesBefore, "Shares unchanged after large withdrawal");

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining depositor must withdraw");
        assertGe(received * 100, smallDeposit * 50, "Remaining depositor lost >50%");
    }

    function test_withdrawAfterInterestAccrual_7days() public {
        _deployVault();
        _depositAs(user1, 2e6); // 2 XAUT

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 7 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));
        assertGe(valueAfter * 100, valueBefore * 95, "7-day value loss >5%");

        _refreshOracles();
        // XAUT/USD has a 24 h oracle heartbeat; after 7 days on a frozen fork the pool price
        // can diverge from Chainlink by just over 1%.  Use 2 % slippage (the recommended
        // production setting for this pool) to absorb that divergence.
        vm.prank(owner);
        swapper.setSlippage(2e16);
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 7 days");
        _assertValuePreserved(2e6, withdrawn, 500, "7-day withdraw: >5% loss");
        console.log("7-day withdraw: deposited=2e6 withdrawn=%d", withdrawn);
    }

    function test_threeUserSequentialWithdrawals() public {
        _deployVault();
        address user3 = makeAddr("user3");

        uint256 d1 = 1e6; // 1 XAUT
        uint256 d2 = 2e6;
        uint256 d3 = 3e6;
        deal(XAUT, user1, d1);
        deal(XAUT, user2, d2);
        deal(XAUT, user3, d3);

        _depositAs(user1, d1);
        _depositAs(user2, d2);
        vm.startPrank(user3);
        IERC20(XAUT).approve(address(vault), d3);
        vault.deposit(d3, user3);
        vm.stopPrank();
        vm.roll(block.number + 1);

        _refreshOracles();

        uint256 shares3 = vault.balanceOf(user3);
        vm.prank(user3);
        uint256 w3 = vault.redeem(shares3, user3, user3);

        _refreshOracles();
        uint256 w2 = _redeemAllAs(user2);

        _refreshOracles();
        uint256 w1 = _redeemAllAs(user1);

        assertGt(w1, 0, "User1 must withdraw");
        assertGt(w2, 0, "User2 must withdraw");
        assertGt(w3, 0, "User3 must withdraw");
        assertGe(w1 * 100, d1 * 80, "User1: >20% loss");
        assertGe(w2 * 100, d2 * 80, "User2: >20% loss");
        assertGe(w3 * 100, d3 * 80, "User3: >20% loss");

        console.log("3-user sequential: w1=%d w2=%d w3=%d", w1, w2, w3);
    }

    function test_fullLifecycle_depositRebalanceWithdraw() public {
        _deployVault();
        vm.prank(owner);
        vault.setParam(1, 55e16);

        _depositAs(user1, 3e6); // 3 XAUT

        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(XAU_USD_ORACLE).latestRoundData();
        int256 upPrice = (answer * 115) / 100;
        vm.mockCall(
            XAU_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, upPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 ltvBefore = loanManager.getCurrentLTV();
        vault.rebalance();
        uint256 ltvAfterUp = loanManager.getCurrentLTV();
        assertGt(ltvAfterUp, ltvBefore, "LTV should increase after upward rebalance");

        vm.clearMockedCalls();
        _syncAndMockOracles();

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after lifecycle");
        _assertValuePreserved(3e6, withdrawn, 500, "Lifecycle: >5% loss");
        console.log("Lifecycle: deposited=3e6 withdrawn=%d", withdrawn);
    }

    function test_interestAccrual_30days() public {
        _deployVault();
        _depositAs(user1, 2e6); // 2 XAUT

        uint256 valueBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.warp(block.timestamp + 30 days);
        _syncAndMockOracles();

        uint256 valueAfter = vault.convertToAssets(vault.balanceOf(user1));
        assertGe(valueAfter * 100, valueBefore * 90, "30-day value loss >10%");

        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw after 30 days");
        _assertValuePreserved(2e6, withdrawn, 1000, "30-day withdraw: >10% total loss");
        console.log("30-day withdraw: deposited=2e6 withdrawn=%d", withdrawn);
    }

    function test_strategyDebtProportionality_afterPartialWithdraw() public {
        _deployVault();
        _depositAs(user1, 4e6); // 4 XAUT

        _refreshOracles();

        (, uint256 debtBefore) = loanManager.getPositionValues();
        uint256 stratBefore = strategy.balanceOf();

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vault.redeem(shares / 2, user1, user1);

        (, uint256 debtAfter) = loanManager.getPositionValues();
        uint256 stratAfter = strategy.balanceOf();

        if (debtBefore > 0 && stratBefore > 0) {
            uint256 debtRatio = (debtAfter * 1e18) / debtBefore;
            uint256 stratRatio = (stratAfter * 1e18) / stratBefore;
            uint256 diff = debtRatio > stratRatio ? debtRatio - stratRatio : stratRatio - debtRatio;
            assertLe(diff, 25e16, "Strategy/debt divergence >25% after partial withdraw");
            console.log("Proportionality: debtRatio=%d stratRatio=%d diff=%d", debtRatio, stratRatio, diff);
        }
    }

    function testFuzz_largeRatioDeposits_noBankruptcy(uint256 ratio) public {
        _deployVault();
        ratio = bound(ratio, 10, 100);

        uint256 smallAmount = 1e4; // 0.01 XAUT
        uint256 largeAmount = smallAmount * ratio;
        deal(XAUT, user1, smallAmount);
        deal(XAUT, user2, largeAmount);

        _depositAs(user1, smallAmount);
        _depositAs(user2, largeAmount);

        _refreshOracles();
        _redeemAllAs(user2);

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Remaining user must be able to withdraw");
        assertGe(received * 100, smallAmount * 40, "Remaining user lost >60%");
    }

    /// @notice Verifies that a deposit at 1e4 units (5x MIN_DEPOSIT, 10x VIRTUAL_SHARE_OFFSET) can redeem.
    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        uint256 dustAmount = 1e4; // 0.01 XAUT — 5x MIN_DEPOSIT(2000), 10x VIRTUAL_SHARE_OFFSET(1e3)
        deal(XAUT, user1, dustAmount);

        vm.prank(user1);
        IERC20(XAUT).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        console.log("Dust deposit: %d units", dustAmount);
        console.log("Shares minted: %d", sharesMinted);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);
        console.log("Dust redemption succeeded.");
    }

    /// @notice Detailed trace through the full deposit→redeem path for a dust deposit.
    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        uint256 dustAmount = 1e4; // 0.01 XAUT ~ $30
        deal(XAUT, user1, dustAmount);

        vm.prank(user1);
        IERC20(XAUT).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (units):    ", dustAmount);
        console.log("sharesMinted:          ", sharesMinted);
        console.log("Aave collateral (u6):  ", posCollateral);
        console.log("Aave debt (USDT e6):   ", posDebt);
        console.log("Strategy bal (USDT e6):", stratBal);
        console.log("Vault idle XAUT (u6):  ", IERC20(XAUT).balanceOf(address(vault)));
        console.log("Vault idle USDT (e6):  ", IERC20(USDT).balanceOf(address(vault)));

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        uint256 collateralNeeded = vault.previewRedeem(sharesMinted);
        console.log("=== Projected unwind ===");
        console.log("collateralNeeded (u6): ", collateralNeeded);
        if (posCollateral > 0) {
            uint256 debtToRepay = posDebt * collateralNeeded / posCollateral;
            console.log("debtToRepay (USDT e6): ", debtToRepay);
            console.log("debtNeeded 105% (e6):  ", debtToRepay * 105 / 100);
        }
        console.log("maxSlippage (bps):     ", vault.maxSlippage() / 1e14);
        console.log("swapper slippage (bps):", swapper.slippage() / 1e14);

        console.log("=== Attempting vault.redeem ===");
        vm.prank(user1);
        try vault.redeem(sharesMinted, user1, user1) returns (uint256 amount) {
            console.log("Redeem SUCCEEDED (u6):", amount);
        } catch (bytes memory err) {
            console.log("Redeem REVERTED. Raw error bytes length:", err.length);
            if (err.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(err, 32)) }
                if (selector == Zenji.InsufficientWithdrawal.selector) {
                    console.log("=> InsufficientWithdrawal: strategy LP underperformed maxSlippage");
                } else if (selector == Zenji.InsufficientCollateral.selector) {
                    console.log("=> InsufficientCollateral: not enough XAUT recovered after unwind");
                } else if (selector == Zenji.SwapperUnderperformed.selector) {
                    console.log("=> SwapperUnderperformed: Uniswap/oracle divergence on small swap");
                } else if (selector == bytes4(keccak256("V3TooLittleReceived()"))) {
                    console.log("=> V3TooLittleReceived: Uniswap minAmountOut not met");
                } else {
                    console.log("=> Unknown selector");
                }
            }
        }
    }

    /// @notice Show that a realistic minimum deposit (10x VIRTUAL_SHARE_OFFSET) succeeds for 4 users.
    /// @dev VIRTUAL_SHARE_OFFSET = 1e3 (0.001 XAUT ~$4.50); economic minimum = 1e4 (0.01 XAUT ~$45).
    function test_realisticMinimum_succeeds() public {
        _deployVault();

        uint256 realAmount = 1e5; // 0.1 XAUT ~$300 at $3K/oz
        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];

        for (uint256 i = 0; i < users.length; i++) {
            deal(XAUT, users[i], realAmount);
            vm.prank(users[i]);
            IERC20(XAUT).approve(address(vault), realAmount);
            vm.prank(users[i]);
            vault.deposit(realAmount, users[i]);
        }

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 shares = vault.balanceOf(users[i]);
            if (shares > 0) {
                vm.prank(users[i]);
                uint256 collateralReceived = vault.redeem(shares, users[i], users[i]);
                assertGt(collateralReceived, 0, "Realistic deposit should redeem non-zero collateral");
                console.log("User %d redeemed %d shares for %d units", i, shares, collateralReceived);
            }
        }
    }

    /// @notice Document the vault's economic minimum based on virtual offset + swap slippage.
    function test_documentEconomicMinimum() public pure {
        // MIN_DEPOSIT = 2000 units = 0.002 XAUT ≈ $9 (at $4500/oz)
        uint256 contractMinimum = 2000;

        // VIRTUAL_SHARE_OFFSET = 1e3 units = 0.001 XAUT ~$4.50 dead capital (at $4500/oz)
        uint256 virtualOffset = 1e3;

        // Economic minimum = 10x the virtual offset (empirically safe)
        // = 1e4 units = 0.01 XAUT ~$45
        uint256 economicMinimum = virtualOffset * 10;

        console.log("Contract MIN_DEPOSIT:  %d units", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d units", virtualOffset);
        console.log("Economic minimum:      %d units", economicMinimum);
        console.log("Why dust fails on mainnet:");
        console.log("1. Tiny deposit passes MIN_DEPOSIT check");
        console.log("2. Shares minted = (assets * (supply + offset))");
        console.log("3. Tiny deposit means very few shares created");
        console.log("4. Redeem tries to swap tiny USDT amount -> XAUT");
        console.log("5. Swap output < oracle-expected due to liquidity");
        console.log("6. Vault reverts: SwapperUnderperformed");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    /// @notice Single shot: deposit 1e4 units (0.01 XAUT ~ $30) then redeem with trace
    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 1e4;
        deal(XAUT, user1, depositAmount);
        vm.prank(user1); IERC20(XAUT).approve(address(vault), depositAmount);
        vm.prank(user1); vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_units=%d debt_usdt6=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    function test_withdrawWithUnrealizedStrategyLoss() public {
        _deployVault();
        _depositAs(user1, 2e6); // 2 XAUT

        _refreshOracles();

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
            IChainlinkOracle(CRVUSD_USD_ORACLE).latestRoundData();
        int256 depegPrice = (answer * 95) / 100;
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, depegPrice, block.timestamp, block.timestamp, answeredInRound)
        );

        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Must withdraw with strategy loss");
        console.log("Strategy loss: deposited=2e6 withdrawn=%d", withdrawn);
    }

    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 1e4; // 0.01 XAUT

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;  //  1%
        slippageLevels[1] = 2e16;  //  2%
        slippageLevels[2] = 3e16;  //  3%
        slippageLevels[3] = 5e16;  //  5%
        slippageLevels[4] = 10e16; // 10%
        slippageLevels[5] = 20e16; // 20%

        uint256 firstSuccess = 0;

        console.log("=== XAUT Swapper Slippage Sweep for 1e4 unit deposit ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();

            _deployVault();

            if (slippageLevels[i] != swapper.slippage()) {
                vm.prank(owner);
                swapper.setSlippage(slippageLevels[i]);
            }

            deal(XAUT, user1, depositAmount);
            vm.prank(user1);
            IERC20(XAUT).approve(address(vault), depositAmount);
            vm.prank(user1);
            vault.deposit(depositAmount, user1);

            uint256 shares = vault.balanceOf(user1);
            _syncAndMockOracles();
            vm.roll(block.number + 1);

            bool ok;
            bytes memory errData;
            vm.prank(user1);
            try vault.redeem(shares, user1, user1) returns (uint256) {
                ok = true;
            } catch (bytes memory err) {
                ok = false;
                errData = err;
            }

            bytes4 selector;
            if (errData.length >= 4) {
                assembly { selector := mload(add(errData, 32)) }
            }

            console.log("slippage_bps=%d redeem=%d errLen=%d", slippageLevels[i] / 1e14, ok ? 1 : 0, errData.length);
            if (!ok) {
                if (selector == bytes4(keccak256("InsufficientWithdrawal()"))) {
                    console.log("  => InsufficientWithdrawal");
                } else if (selector == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)"))) {
                    console.log("  => SwapperUnderperformed (oracle floor not met)");
                } else if (selector == bytes4(keccak256("V3TooLittleReceived()"))) {
                    console.log("  => V3TooLittleReceived (Uniswap minAmountOut not met)");
                } else {
                    console.log("  => Unknown selector");
                }
            }
            if (ok && firstSuccess == 0) {
                firstSuccess = slippageLevels[i];
            }

            vm.revertTo(snap);
        }

        console.log("XAUT firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14);
    }

    /// @notice Deposit exactly vault.MIN_DEPOSIT() and fully redeem.
    /// Confirms the contract-minimum path succeeds end-to-end on mainnet liquidity.
    function test_minimumDeposit_fullRedeem() public {
        _deployVault();

        // Use the vault's own MIN_DEPOSIT() — production ZenjiXautPmUsd returns 2000 (~$9),
        // the base Zenji used in fork tests returns 1e4 (~$45).
        uint256 minAmount = vault.MIN_DEPOSIT();
        deal(XAUT, user1, minAmount);

        uint256 shares = _depositAs(user1, minAmount);
        assertGt(shares, 0, "Should receive shares for minimum deposit");

        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Should receive collateral back for minimum deposit");
        console.log("MinDeposit: deposited=%d units received=%d units", minAmount, received);
    }

    /// @notice Deposit 222 XAUT (~$1M at $4,500/oz) and fully redeem.
    /// Confirms a large round-trip well below the safe TVL cap succeeds.
    function test_oneMillion_depositAndRedeem() public {
        // 222 XAUT ≈ $999,000 at $4,500/oz — well within the ~2800 XAUT safe TVL cap
        uint256 depositAmount = 222e6;
        bool passed = _runSlippageScenario(2e16, depositAmount);
        assertTrue(passed, "222 XAUT (~$1M) full redeem should succeed at 2% slippage");
        console.log("$1M test: 222 XAUT deposit+redeem at 2%% slippage passed");
    }
}
