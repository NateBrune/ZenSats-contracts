// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { CurveThreeCryptoSwapper } from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title WbtcAaveExtensive
/// @notice Fork tests for WBTC + USDT + IPOR (Aave) vault configuration
contract WbtcAaveExtensive is ZenjiForkTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    CurveThreeCryptoSwapper public swapper;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new CurveThreeCryptoSwapper(
            owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE
        );

        UsdtIporYieldStrategy strategy = new UsdtIporYieldStrategy(
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
            expectedVaultAddress
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

        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        // Increase swapper slippage from 1% to 2% — Chainlink oracle and Curve pool
        // prices diverge by ~1.4% on small amounts, causing flashloan premium swaps
        // to fail with Curve's Slippage error when minOut uses the 1% oracle floor.
        vm.prank(owner);
        swapper.proposeSlippage(2e16);
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        swapper.executeSlippage();
        _syncAndMockOracles();
    }

    // ============ Swapper-Specific Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        CurveThreeCryptoSwapper newSwapper = new CurveThreeCryptoSwapper(
            owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE
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

        CurveThreeCryptoSwapper anotherSwapper = new CurveThreeCryptoSwapper(
            owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE
        );
        vm.prank(vault.gov());
        vault.proposeSwapper(address(anotherSwapper));

        vm.prank(vault.gov());
        vault.cancelSwapper();

        vm.prank(vault.gov());
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        vault.executeSwapper();
    }

    function test_slippageTimelock() public {
        _deployVault();

        assertEq(swapper.slippage(), 2e16, "Slippage should be 2% after deploy setup");

        vm.prank(owner);
        swapper.proposeSlippage(10e16);

        vm.prank(owner);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        swapper.executeSlippage();

        vm.warp(block.timestamp + 1 weeks + 1);
        _syncAndMockOracles();

        vm.prank(owner);
        swapper.executeSlippage();
        assertEq(swapper.slippage(), 10e16, "Slippage should be 10%");
    }
}
