// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title CbBtcAaveExtensive
/// @notice Fork tests for cbBTC + USDT + IPOR (Aave) vault configuration
contract CbBtcAaveExtensive is ZenjiForkTestBase {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX = 1;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;

    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    CbBtcWbtcUsdtSwapper public swapper;

    // ============ Abstract implementations ============

    function _collateral() internal pure override returns (address) {
        return CBBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
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

        swapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            CBBTC_INDEX,
            WBTC_INDEX,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE
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
            expectedVaultAddress
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

        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        // Increase swapper slippage for fork (1% default may be too tight for cbBTC two-hop swaps)
        vm.store(address(swapper), bytes32(uint256(0)), bytes32(uint256(5e16)));
    }

    // ============ Swapper-Specific Tests ============

    function test_swapperTimelock() public {
        _deployVault();
        _depositAs(user1, _unit());

        CbBtcWbtcUsdtSwapper newSwapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            CBBTC_INDEX,
            WBTC_INDEX,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE
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

        CbBtcWbtcUsdtSwapper anotherSwapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            CBBTC_INDEX,
            WBTC_INDEX,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE
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

        assertEq(swapper.slippage(), 5e16, "Initial slippage should be 5%");

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
