// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { CrvUsdLpStrategyTestBase } from "./base/CrvUsdLpStrategyTestBase.sol";
import { ZenjiWbtcLlamaStakeDao } from "../src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { CrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapTwoLP } from "../src/interfaces/ICurveStableSwapTwoLP.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title WbtcCrvUsdUsdtLlama
/// @notice Fork tests for WBTC collateral + LlamaLend (crvUSD debt) + USDT/crvUSD Curve LP
///         (Stake DAO reward vault) strategy.
///         Swap route: WBTC → WETH via Uniswap V3 (0.05%) → crvUSD via Curve TriCRV.
///         Strategy: CrvUsdLpStakeDaoStrategy — single-sided crvUSD → USDT/crvUSD pool → Stake DAO.
contract WbtcCrvUsdUsdtLlama is CrvUsdLpStrategyTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500;
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    CrvToCrvUsdSwapper public crvSwapper;
    LlamaLoanManager public llamaManager;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e6; // 0.01 WBTC
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

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return 2e8;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    // -- LP-specific abstracts --
    function _newSwapper() internal override returns (address) {
        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();
        return address(
            new UniswapMixedCurveSwapper(
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
            )
        );
    }

    function _largeDepositAmount() internal pure override returns (uint256) {
        return 10e8;
    }

    function _oneMillionAmount() internal pure override returns (uint256) {
        return 10e8;
    }

    function _oneMillionLabel() internal pure override returns (string memory) {
        return "10 BTC (~$1M)";
    }

    function _ratioTestSmallAmount() internal pure override returns (uint256) {
        return 1e6;
    }

    function _sequentialWithdrawalSlippage() internal pure override returns (uint256) {
        return 3e16;
    }

    function _tvlChunk() internal pure override returns (uint256) {
        return 5e8;
    }

    function _tvlMinChunk() internal pure override returns (uint256) {
        return 1e7;
    }

    function _tvlIterCap() internal pure override returns (uint256) {
        return 160;
    }

    function _tvlLabel() internal pure override returns (string memory) {
        return "WBTC multi-user TVL(crvUSD 18d)=";
    }

    function _capacityProbeAmounts() internal pure override returns (uint256[] memory) {
        uint256[] memory probe = new uint256[](20);
        probe[0] = 1e8;
        probe[1] = 5e8;
        probe[2] = 10e8;
        probe[3] = 25e8;
        probe[4] = 50e8;
        probe[5] = 100e8;
        probe[6] = 200e8;
        probe[7] = 500e8;
        probe[8] = 750e8;
        probe[9] = 1000e8;
        probe[10] = 1500e8;
        probe[11] = 2000e8;
        probe[12] = 3000e8;
        probe[13] = 5000e8;
        probe[14] = 7500e8;
        probe[15] = 10_000e8;
        probe[16] = 12_500e8;
        probe[17] = 15_000e8;
        probe[18] = 17_500e8;
        probe[19] = 20_000e8;
        return probe;
    }

    function _capacityLabel() internal pure override returns (string memory) {
        return "WBTC";
    }

    function _collateralLabel() internal pure override returns (string memory) {
        return "WBTC";
    }

    function _rebalancedAmounts() internal pure override returns (uint256[] memory) {
        uint256[] memory a = new uint256[](3);
        a[0] = 100e8;
        a[1] = 50e8;
        a[2] = 25e8;
        return a;
    }

    // ============ Vault deployment ============

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

    // ============ WBTC-specific: dust / minimum deposit diagnostics ============

    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        uint256 dustAmount = 1e5; // 0.001 WBTC
        deal(WBTC, user1, dustAmount);

        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        console.log("Dust deposit: %d sat", dustAmount);
        console.log("Shares minted: %d", sharesMinted);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);
        console.log("Dust redemption succeeded.");
    }

    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        uint256 dustAmount = 1e4; // 0.0001 WBTC
        deal(WBTC, user1, dustAmount);

        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (sat):           ", dustAmount);
        console.log("sharesMinted:               ", sharesMinted);
        console.log("LlamaLend collateral (sat): ", posCollateral);
        console.log("LlamaLend debt (crvUSD e18):", posDebt);
        console.log("Strategy bal (crvUSD e18):  ", stratBal);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        console.log("=== Attempting vault.redeem ===");
        vm.prank(user1);
        try vault.redeem(sharesMinted, user1, user1) returns (uint256 amount) {
            console.log("Redeem SUCCEEDED (sat):", amount);
        } catch (bytes memory err) {
            console.log("Redeem REVERTED. Raw error bytes length:", err.length);
            if (err.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(err, 32)) }
                if (sel == Zenji.InsufficientWithdrawal.selector) {
                    console.log("=> InsufficientWithdrawal");
                } else if (sel == Zenji.InsufficientCollateral.selector) {
                    console.log("=> InsufficientCollateral");
                } else if (sel == Zenji.SwapperUnderperformed.selector) {
                    console.log("=> SwapperUnderperformed");
                } else {
                    console.log("=> Unknown selector");
                }
            }
        }
    }

    function test_realisticMinimum_succeeds() public {
        _deployVault();

        uint256 realAmount = 1e6; // 0.01 BTC ~$1000 at $100k/BTC
        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];

        for (uint256 i = 0; i < users.length; i++) {
            deal(WBTC, users[i], realAmount);
            vm.prank(users[i]);
            IERC20(WBTC).approve(address(vault), realAmount);
            vm.prank(users[i]);
            vault.deposit(realAmount, users[i]);
        }

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 shares = vault.balanceOf(users[i]);
            if (shares > 0) {
                vm.prank(users[i]);
                uint256 received = vault.redeem(shares, users[i], users[i]);
                assertGt(received, 0, "Realistic deposit should redeem non-zero collateral");
            }
        }
    }

    function test_documentEconomicMinimum() public pure {
        uint256 contractMinimum = 1e4;
        uint256 virtualOffset = 1e4;
        uint256 economicMinimum = 1e5; // 0.001 WBTC = 1e5 sat

        console.log("Contract MIN_DEPOSIT:  %d sat", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d sat", virtualOffset);
        console.log("Economic minimum:      %d sat", economicMinimum);
        console.log("Swap route: WBTC->WETH (UniV3 0.05%) -> crvUSD (Curve TriCRV)");
        console.log("Strategy:   single-sided crvUSD -> USDT/crvUSD pool -> Stake DAO");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 1e4;
        deal(WBTC, user1, depositAmount);
        vm.prank(user1);
        IERC20(WBTC).approve(address(vault), depositAmount);
        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_sat=%d debt_crvusd18=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 1e4; // 0.0001 WBTC

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;
        slippageLevels[1] = 2e16;
        slippageLevels[2] = 3e16;
        slippageLevels[3] = 4e16;
        slippageLevels[4] = 45e15;
        slippageLevels[5] = 5e16;

        uint256 firstSuccess = 0;
        console.log("=== WBTC Slippage Sweep for 1e4 sat deposit (USDT/crvUSD LP) ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();
            _deployVault();

            if (slippageLevels[i] != swapper.slippage()) {
                vm.prank(owner);
                swapper.setSlippage(slippageLevels[i]);
            }

            deal(WBTC, user1, depositAmount);
            vm.prank(user1);
            IERC20(WBTC).approve(address(vault), depositAmount);
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

            console.log("slippage_bps=%d redeem=%d", slippageLevels[i] / 1e14, ok ? 1 : 0);
            if (!ok && errData.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(errData, 32)) }
                if (sel == bytes4(keccak256("InsufficientWithdrawal()"))) {
                    console.log("  => InsufficientWithdrawal");
                } else if (sel == bytes4(keccak256("SwapperUnderperformed(uint256,uint256)"))) {
                    console.log("  => SwapperUnderperformed");
                } else if (sel == bytes4(keccak256("InsufficientCollateral()"))) {
                    console.log("  => InsufficientCollateral");
                } else {
                    console.log("  => unknown selector");
                }
            }
            if (ok && firstSuccess == 0) firstSuccess = slippageLevels[i];
            vm.revertTo(snap);
        }

        console.log(
            "WBTC USDT/crvUSD firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14
        );
    }
}
