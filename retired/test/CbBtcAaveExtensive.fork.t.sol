// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IporVaultStrategyTestBase } from "./base/IporVaultStrategyTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { CbBtcUniswapV3TwoHopSwapper } from "../src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { UsdtIporStrategy } from "../src/strategies/vault/UsdtIporStrategy.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title CbBtcAaveExtensive
/// @notice Fork tests for cbBTC + USDT + IPOR (Aave) vault configuration
contract CbBtcAaveExtensive is IporVaultStrategyTestBase {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    // Uniswap V3: cbBTC/WBTC 0.01% pool, WBTC/USDT 0.3% pool
    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant CBBTC_WBTC_FEE = 100; // 0.01%
    uint24 constant WBTC_USDT_FEE = 3000; // 0.3%

    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    CbBtcUniswapV3TwoHopSwapper public swapper;

    // ============ ZenjiForkTestBase hook implementations ============

    function _collateral() internal pure override returns (address) {
        return CBBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e7; // 0.1 cbBTC
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](3);
        oracles[0] = CBBTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return CBBTC_USD_ORACLE;
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new CbBtcUniswapV3TwoHopSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            UNISWAP_ROUTER,
            CBBTC_WBTC_FEE,
            WBTC_USDT_FEE,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE
        );

        UsdtIporStrategy strategy = new UsdtIporStrategy(
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
        strategy.transferOwner(owner);

        loanManager = new AaveLoanManager(
            CBBTC,
            USDT,
            AAVE_A_CBBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500,
            8000,
            expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        vault = new Zenji(
            CBBTC,
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
        // cbBTC can trade at a persistent basis vs the BTC oracle; relax the floor for fork realism.
        vm.prank(owner);
        swapper.setSlippage(5e16);
    }

    // ============ ZenjiStrategyTestBase hook implementations ============

    function _newSwapper() internal override returns (address) {
        return address(
            new CbBtcUniswapV3TwoHopSwapper(
                owner,
                CBBTC,
                USDT,
                WBTC,
                UNISWAP_ROUTER,
                CBBTC_WBTC_FEE,
                WBTC_USDT_FEE,
                CBBTC_USD_ORACLE,
                USDT_USD_ORACLE
            )
        );
    }

    function _initialSwapperSlippage() internal pure override returns (uint256) {
        return 5e16;
    }

    function _largeDepositAmount() internal pure override returns (uint256) {
        return 10e8; // 10 cbBTC
    }

    function _oneMillionAmount() internal pure override returns (uint256) {
        return 10e8; // 10 cbBTC ~ $1M
    }

    function _oneMillionLabel() internal pure override returns (string memory) {
        return "10 cbBTC (~$1M)";
    }

    function _ratioTestSmallAmount() internal pure override returns (uint256) {
        return 1e7; // 0.1 cbBTC
    }

    function _tvlChunk() internal pure override returns (uint256) {
        return 5e8; // 5 cbBTC
    }

    function _tvlMinChunk() internal pure override returns (uint256) {
        return 1e7; // 0.1 cbBTC
    }

    function _tvlIterCap() internal pure override returns (uint256) {
        return 160;
    }

    function _tvlLabel() internal pure override returns (string memory) {
        return "cbBTC Aave TVL(USDT 6d)=";
    }

    // ============ cbBTC-specific tests ============

    function runOnePercentScenario(uint256 amount) external {
        _runOnePercentScenario(amount);
    }

    function test_cbbtcLiquiditySweep_bySize_atOnePercent() public {
        _deployVault();

        // Force 1% slippage for this capacity test
        vm.store(address(swapper), bytes32(uint256(0)), bytes32(uint256(1e16)));
        assertEq(swapper.slippage(), 1e16, "Sweep slippage must be 1%");

        uint256 baseline = vm.snapshot();
        uint256 lastPass;
        uint256 firstFail;

        // Sweep 1..100 cbBTC in 1 cbBTC steps
        for (uint256 c = 1; c <= 100; c++) {
            uint256 amount = c * 1e8;
            vm.revertTo(baseline);
            baseline = vm.snapshot();

            try this.runOnePercentScenario(amount) {
                lastPass = amount;
            } catch {
                if (firstFail == 0) firstFail = amount;
                break;
            }
        }

        emit log_named_uint("cbBTC lastPass @1% (sats)", lastPass);
        emit log_named_uint("cbBTC firstFail @1% (sats)", firstFail);
        if (lastPass > 0) emit log_named_uint("cbBTC lastPass @1% (whole)", lastPass / 1e8);
        if (firstFail > 0) emit log_named_uint("cbBTC firstFail @1% (whole)", firstFail / 1e8);

        // Diagnostic sweep: no-pass outcome is allowed and indicates 1% is too strict.
        assertGt(firstFail, 0, "Sweep did not execute any size checks");
    }

    function test_cbbtcLiquiditySweep_bySize_slippageLadder() public {
        _deployVault();

        uint256[] memory slippages = new uint256[](4);
        slippages[0] = 2e16; // 2%
        slippages[1] = 3e16; // 3%
        slippages[2] = 4e16; // 4%
        slippages[3] = 5e16; // 5%

        for (uint256 s = 0; s < slippages.length; s++) {
            uint256 targetSlippage = slippages[s];
            vm.store(address(swapper), bytes32(uint256(0)), bytes32(targetSlippage));
            assertEq(swapper.slippage(), targetSlippage, "Sweep slippage mismatch");

            uint256 baseline = vm.snapshot();
            uint256 lastPass;
            uint256 firstFail;

            // Sweep 1..100 cbBTC in 1 cbBTC steps
            for (uint256 c = 1; c <= 100; c++) {
                uint256 amount = c * 1e8;
                vm.revertTo(baseline);
                baseline = vm.snapshot();

                try this.runOnePercentScenario(amount) {
                    lastPass = amount;
                } catch {
                    if (firstFail == 0) firstFail = amount;
                    break;
                }
            }

            emit log_named_uint("slippage (1e18)", targetSlippage);
            emit log_named_uint("lastPass (sats)", lastPass);
            emit log_named_uint("firstFail (sats)", firstFail);
            if (lastPass > 0) emit log_named_uint("lastPass (whole cbBTC)", lastPass / 1e8);
            if (firstFail > 0) emit log_named_uint("firstFail (whole cbBTC)", firstFail / 1e8);
        }
    }

    function _runOnePercentScenario(uint256 amount) internal {
        _syncAndMockOracles();
        deal(CBBTC, user1, amount);
        _depositAs(user1, amount);
        _refreshOracles();
        uint256 withdrawn = _redeemAllAs(user1);
        assertGt(withdrawn, 0, "Should redeem > 0");
    }

    function test_liveOracleStaleness_withoutRemocking() public {
        _deployVault();

        // Remove setUp/remock overrides and read live feed timestamps from the forked chain.
        vm.clearMockedCalls();

        (,,, uint256 collateralUpdatedAt,) = IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        uint256 collateralAge =
            block.timestamp > collateralUpdatedAt ? block.timestamp - collateralUpdatedAt : 0;

        emit log_named_uint("cbBTC oracle updatedAt", collateralUpdatedAt);
        emit log_named_uint("cbBTC oracle age (sec)", collateralAge);
        emit log_named_uint(
            "MAX_COLLATERAL_ORACLE_STALENESS", swapper.MAX_COLLATERAL_ORACLE_STALENESS()
        );

        if (collateralAge <= swapper.MAX_COLLATERAL_ORACLE_STALENESS()) {
            emit log("Live cbBTC feed is fresh at this fork block; stale-path not asserted");
            return;
        }

        deal(CBBTC, user1, _tinyDeposit());
        vm.startPrank(user1);
        collateralToken.approve(address(vault), _tinyDeposit());
        vm.expectRevert();
        vault.deposit(_tinyDeposit(), user1);
        vm.stopPrank();
    }
}
