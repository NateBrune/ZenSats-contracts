// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IporVaultStrategyTestBase } from "./base/IporVaultStrategyTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { UsdtIporStrategy } from "../src/strategies/vault/UsdtIporStrategy.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title WstEthAaveExtensive
/// @notice Fork tests for wstETH + USDT + IPOR (Aave) vault configuration
contract WstEthAaveExtensive is IporVaultStrategyTestBase {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 3000;

    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    UniswapV3TwoHopSwapper public swapper;
    WstEthOracle public wstEthOracle;

    // ============ ZenjiForkTestBase hook implementations ============

    function _collateral() internal pure override returns (address) {
        return WSTETH;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](4);
        oracles[0] = STETH_ETH_ORACLE;
        oracles[1] = ETH_USD_ORACLE;
        oracles[2] = USDT_USD_ORACLE;
        oracles[3] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return ETH_USD_ORACLE;
    }

    function _baseDeposit() internal pure override returns (uint256) {
        return 10e18;
    }

    function _fuzzMin() internal pure override returns (uint256) {
        return 1e18;
    }

    function _fuzzMax() internal pure override returns (uint256) {
        return 50e18;
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return 25e18;
    }

    function _deployVaultContracts() internal override {
        wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new UniswapV3TwoHopSwapper(
            owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
            address(wstEthOracle), USDT_USD_ORACLE, 3_600
        );

        UsdtIporStrategy strategy = new UsdtIporStrategy(
            USDT, CRVUSD, expectedVaultAddress, USDT_CRVUSD_POOL, IPOR_PLASMA_VAULT, 0, 1,
            CRVUSD_USD_ORACLE, USDT_USD_ORACLE
        );
        strategy.transferOwner(owner);

        loanManager = new AaveLoanManager(
            WSTETH, USDT, AAVE_A_WSTETH, AAVE_VAR_DEBT_USDT, AAVE_POOL, address(wstEthOracle),
            USDT_USD_ORACLE, address(swapper), 7100, 7600, expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        vault = new Zenji(
            WSTETH, USDT, address(loanManager), address(strategy), address(swapper), owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault));
        yieldStrategy = strategy;
    }

    // ============ ZenjiStrategyTestBase hook implementations ============

    function _newSwapper() internal override returns (address) {
        return address(
            new UniswapV3TwoHopSwapper(
                owner, WSTETH, USDT, WETH, UNISWAP_ROUTER, FEE_WSTETH_WETH, FEE_WETH_USDT,
                address(wstEthOracle), USDT_USD_ORACLE, 3_600
            )
        );
    }

    function _initialSwapperSlippage() internal pure override returns (uint256) {
        return 1e16;
    }

    function _largeDepositAmount() internal pure override returns (uint256) {
        return 50e18; // 50 wstETH
    }

    function _oneMillionAmount() internal pure override returns (uint256) {
        return 250e18; // 250 wstETH ~ $1M
    }

    function _oneMillionLabel() internal pure override returns (string memory) {
        return "250 wstETH (~$1M)";
    }

    function _ratioTestSmallAmount() internal pure override returns (uint256) {
        return 1e17; // 0.1 wstETH
    }

    function _tvlChunk() internal pure override returns (uint256) {
        return 50e18; // 50 wstETH
    }

    function _tvlMinChunk() internal pure override returns (uint256) {
        return 1e17; // 0.1 wstETH
    }

    function _tvlIterCap() internal pure override returns (uint256) {
        return 200;
    }

    function _tvlLabel() internal pure override returns (string memory) {
        return "wstETH Aave TVL(USDT 6d)=";
    }
}
