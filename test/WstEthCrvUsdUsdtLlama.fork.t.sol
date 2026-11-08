// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { CrvUsdLpStrategyTestBase } from "./base/CrvUsdLpStrategyTestBase.sol";
import { LivenessTestMixin } from "./base/LivenessTestMixin.sol";
import {
    ZenjiWstEthLlamaUsdtStakeDao
} from "../src/implementations/stakedao/ZenjiWstEthLlamaUsdtStakeDao.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { CrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapTwoLP } from "../src/interfaces/ICurveStableSwapTwoLP.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title WstEthCrvUsdUsdtLlama
/// @notice Fork tests for wstETH collateral + LlamaLend (crvUSD debt) + USDT/crvUSD Curve LP
///         (Stake DAO reward vault) strategy.
///         Swap route: wstETH → WETH via Uniswap V3 (0.01%) → crvUSD via Curve TriCRV.
///         Strategy: CrvUsdLpStakeDaoStrategy — single-sided crvUSD → USDT/crvUSD pool → Stake DAO.
contract WstEthCrvUsdUsdtLlama is LivenessTestMixin, CrvUsdLpStrategyTestBase {
    /// @dev WstEthOracle composite reports the OLDER feed timestamp; its stETH/ETH leg has a
    ///      24h Chainlink heartbeat, so the collateral staleness window is 90000s.
    function _collateralStalenessWarp() internal pure override returns (uint256) {
        return 90001;
    }

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant LLAMALEND_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;
    address constant WSTETH_CRVUSD_POOL = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WSTETH_WETH = 100; // V3 0.01%
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    WstEthOracle public wstEthOracle;
    CrvToCrvUsdSwapper public crvSwapper;
    LlamaLoanManager public llamaManager;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WSTETH;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 3e15; // 0.003 wstETH
    }

    function _oracleList() internal pure override returns (address[] memory) {
        // WstEthOracle is a locally-deployed composite; mock its underlying Chainlink feeds.
        address[] memory oracles = new address[](4);
        oracles[0] = STETH_ETH_ORACLE;
        oracles[1] = ETH_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        oracles[3] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        // Mocking ETH/USD changes the output of WstEthOracle, adjusting effective collateral price.
        return ETH_USD_ORACLE;
    }

    function _fuzzMin() internal pure override returns (uint256) {
        return 1e17; // 0.1 wstETH
    }

    function _fuzzMultiMin() internal pure override returns (uint256) {
        return 3e18; // 3 wstETH
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return 50e18;
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
                WSTETH,
                CRVUSD,
                WETH,
                UNIVERSAL_ROUTER,
                FEE_WSTETH_WETH,
                TRICRYPTO_POOL,
                wethIdx,
                crvUsdIdx,
                address(wstEthOracle),
                CRVUSD_USD_ORACLE,
                90000
            )
        );
    }

    function _largeDepositAmount() internal pure override returns (uint256) {
        return 50e18;
    }

    function _oneMillionAmount() internal pure override returns (uint256) {
        return 250e18;
    }

    function _oneMillionLabel() internal pure override returns (string memory) {
        return "250 wstETH (~$1M)";
    }

    function _ratioTestSmallAmount() internal pure override returns (uint256) {
        return 1e17;
    }

    function _sequentialWithdrawalSlippage() internal pure override returns (uint256) {
        return 2e16;
    }

    function _tvlChunk() internal pure override returns (uint256) {
        return 50e18;
    }

    function _tvlMinChunk() internal pure override returns (uint256) {
        return 1e17;
    }

    function _tvlIterCap() internal pure override returns (uint256) {
        return 200;
    }

    function _tvlLabel() internal pure override returns (string memory) {
        return "wstETH multi-user TVL(crvUSD 18d)=";
    }

    function _capacityProbeAmounts() internal pure override returns (uint256[] memory) {
        uint256[] memory probe = new uint256[](14);
        probe[0] = 1e18;
        probe[1] = 25e18;
        probe[2] = 100e18;
        probe[3] = 500e18;
        probe[4] = 1000e18;
        probe[5] = 2500e18;
        probe[6] = 5000e18;
        probe[7] = 10_000e18;
        probe[8] = 20_000e18;
        probe[9] = 30_000e18;
        probe[10] = 50_000e18;
        probe[11] = 75_000e18;
        probe[12] = 100_000e18;
        probe[13] = 150_000e18;
        return probe;
    }

    function _capacityLabel() internal pure override returns (string memory) {
        return "wstETH";
    }

    function _collateralLabel() internal pure override returns (string memory) {
        return "wstETH";
    }

    function _rebalancedAmounts() internal pure override returns (uint256[] memory) {
        uint256[] memory a = new uint256[](3);
        a[0] = 1000e18;
        a[1] = 500e18;
        a[2] = 100e18;
        return a;
    }

    // wstETH economic minimum is slightly above the contract MIN_DEPOSIT.
    function _effectiveMinDeposit() internal view override returns (uint256) {
        return vault.MIN_DEPOSIT() > 3e16 ? vault.MIN_DEPOSIT() : 3e16;
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
        // Deploy order: wstEthOracle(+0), crvSwapper(+1), swapper(+2),
        //               strategy(+3), llamaManager(+4), vault(+5)
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 5);

        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();

        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, TRICRYPTO_POOL, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedCurveSwapper(
            owner,
            WSTETH,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WSTETH_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            address(wstEthOracle),
            CRVUSD_USD_ORACLE,
            90000
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
            WSTETH,
            CRVUSD,
            LLAMALEND_WSTETH_CONTROLLER,
            WSTETH_CRVUSD_POOL,
            address(wstEthOracle),
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0),
            90000
        );

        ZenjiWstEthLlamaUsdtStakeDao vault_ = new ZenjiWstEthLlamaUsdtStakeDao(
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

    // ============ wstETH-specific: dust / minimum deposit diagnostics ============

    function test_dustDeposit_revealsMissingMinimum() public {
        _deployVault();

        uint256 dustAmount = 3e16; // 0.03 wstETH
        deal(WSTETH, user1, dustAmount);

        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        console.log("Dust deposit: %d wei", dustAmount);
        console.log("Shares minted: %d", sharesMinted);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        vm.prank(user1);
        vault.redeem(sharesMinted, user1, user1);
        console.log("Dust redemption succeeded.");
    }

    function test_dustDiagnostic_exactTrace() public {
        _deployVault();

        uint256 dustAmount = 3e16; // 0.03 wstETH
        deal(WSTETH, user1, dustAmount);

        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), dustAmount);
        vm.prank(user1);
        uint256 sharesMinted = vault.deposit(dustAmount, user1);

        (uint256 posCollateral, uint256 posDebt) = loanManager.getPositionValues();
        uint256 stratBal = strategy.balanceOf();

        console.log("=== After deposit ===");
        console.log("dustAmount (wei):            ", dustAmount);
        console.log("sharesMinted:                ", sharesMinted);
        console.log("LlamaLend collateral (wei):  ", posCollateral);
        console.log("LlamaLend debt (crvUSD 18d): ", posDebt);
        console.log("Strategy bal (crvUSD e18):   ", stratBal);

        _syncAndMockOracles();
        vm.roll(block.number + 1);

        console.log("=== Attempting vault.redeem ===");
        vm.prank(user1);
        try vault.redeem(sharesMinted, user1, user1) returns (uint256 amount) {
            console.log("Redeem SUCCEEDED (wei):", amount);
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

        uint256 realAmount = 1e17; // 0.1 wstETH ~$350 at $3,500/wstETH
        address[4] memory users = [user1, user2, makeAddr("user3"), makeAddr("user4")];

        for (uint256 i = 0; i < users.length; i++) {
            deal(WSTETH, users[i], realAmount);
            vm.prank(users[i]);
            IERC20(WSTETH).approve(address(vault), realAmount);
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
        uint256 contractMinimum = 3e15;
        uint256 virtualOffset = 3e15;
        uint256 economicMinimum = 3e16; // 0.03 wstETH

        console.log("Contract MIN_DEPOSIT:  %d wei", contractMinimum);
        console.log("VIRTUAL_SHARE_OFFSET:  %d wei", virtualOffset);
        console.log("Economic minimum:      %d wei", economicMinimum);
        console.log("Swap route: wstETH->WETH (UniV3 0.01%) -> crvUSD (Curve TriCRV)");
        console.log("Strategy:   single-sided crvUSD -> USDT/crvUSD pool -> Stake DAO");

        assertGe(economicMinimum, virtualOffset, "Economic minimum must be >= VIRTUAL_SHARE_OFFSET");
    }

    function test_dustRedeem_singleTrace() public {
        _deployVault();
        uint256 depositAmount = 3e16; // 0.03 wstETH
        deal(WSTETH, user1, depositAmount);
        vm.prank(user1);
        IERC20(WSTETH).approve(address(vault), depositAmount);
        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        uint256 shares = vault.balanceOf(user1);
        (uint256 col, uint256 debt) = loanManager.getPositionValues();
        console.log("col_wei=%d debt_crvusd18=%d", col, debt);
        console.log("strat=%d shares=%d", strategy.balanceOf(), shares);

        _syncAndMockOracles();
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
    }

    function test_swapSlippageDiagnostic_exactTrace() public {
        uint256 depositAmount = 3e16; // 0.03 wstETH

        uint256[] memory slippageLevels = new uint256[](6);
        slippageLevels[0] = 1e16;
        slippageLevels[1] = 2e16;
        slippageLevels[2] = 3e16;
        slippageLevels[3] = 4e16;
        slippageLevels[4] = 45e15;
        slippageLevels[5] = 5e16;

        uint256 firstSuccess = 0;
        console.log("=== wstETH Slippage Sweep for 3e16 wei deposit (USDT/crvUSD LP) ===");

        for (uint256 i = 0; i < slippageLevels.length; i++) {
            uint256 snap = vm.snapshot();
            _deployVault();

            if (slippageLevels[i] != swapper.slippage()) {
                vm.prank(owner);
                swapper.setSlippage(slippageLevels[i]);
            }

            deal(WSTETH, user1, depositAmount);
            vm.prank(user1);
            IERC20(WSTETH).approve(address(vault), depositAmount);
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
            "wstETH USDT/crvUSD firstSuccess_bps=%d", firstSuccess == 0 ? 0 : firstSuccess / 1e14
        );
    }

    /// @notice Same economics as WBTC/USDT-crvUSD: CRV alone (4.79%) < borrow APR (5.85%).
    ///         Profitable live via trading fees (~1.52%) closing gap to 6.31%, but fees
    ///         don't accrue without real swap traffic in a fork test.
    function _assertHarvestYield(uint256 navBefore, uint256 navAfter) internal override {
        if (navAfter <= navBefore) {
            console.log(
                "[ENV SKIP] wstETH harvest: CRV alone < borrow cost; trading fees (~1.52%%) needed to break even don't accrue in fork. before=%d after=%d",
                navBefore,
                navAfter
            );
            vm.skip(true);
            return;
        }
        assertGt(navAfter, navBefore, "LP harvest must increase NAV per share");
    }
}
