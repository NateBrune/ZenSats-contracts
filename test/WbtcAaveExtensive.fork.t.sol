// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IporVaultStrategyTestBase } from "./base/IporVaultStrategyTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniversalRouterV3SingleHopSwapper } from
    "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { UsdtIporStrategy } from "../src/strategies/vault/UsdtIporStrategy.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title WbtcAaveExtensive
/// @notice Fork tests for WBTC + USDT + IPOR (Aave) vault configuration
contract WbtcAaveExtensive is IporVaultStrategyTestBase {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    UniversalRouterV3SingleHopSwapper public swapper;

    // ============ ZenjiForkTestBase hook implementations ============

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

        swapper = new UniversalRouterV3SingleHopSwapper(
            owner, WBTC, USDT, UNIVERSAL_ROUTER, WBTC_USDT_V3_FEE, BTC_USD_ORACLE, USDT_USD_ORACLE, 3_600
        );

        UsdtIporStrategy strategy = new UsdtIporStrategy(
            USDT, CRVUSD, expectedVaultAddress, USDT_CRVUSD_POOL, IPOR_PLASMA_VAULT, 0, 1,
            CRVUSD_USD_ORACLE, USDT_USD_ORACLE
        );
        // Hand off strategy ownership to `owner` so vault.verifyStrategyOwnership()
        // returns true. Not enforced at construction (see Zenji.sol comment) but operationally
        // the right pattern — strategy.owner should always equal vault.gov.
        strategy.transferOwner(owner);

        loanManager = new AaveLoanManager(
            WBTC, USDT, AAVE_A_WBTC, AAVE_VAR_DEBT_USDT, AAVE_POOL, BTC_USD_ORACLE,
            USDT_USD_ORACLE, address(swapper), 7500, 8000, expectedVaultAddress,
            0, // eMode: disabled
            3600
        );

        vault = new Zenji(
            WBTC, USDT, address(loanManager), address(strategy), address(swapper), owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.setVault(address(vault));
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        // Chainlink oracle and Curve pool prices diverge by ~1.4% on small amounts;
        // relax the swapper floor to 2% so fork tests don't fail on that divergence.
        vm.prank(owner);
        swapper.setSlippage(2e16);
        _syncAndMockOracles();
    }

    // ============ ZenjiStrategyTestBase hook implementations ============

    function _newSwapper() internal override returns (address) {
        return address(
            new UniversalRouterV3SingleHopSwapper(
                owner, WBTC, USDT, UNIVERSAL_ROUTER, WBTC_USDT_V3_FEE, BTC_USD_ORACLE,
                USDT_USD_ORACLE, 3_600
            )
        );
    }

    function _initialSwapperSlippage() internal pure override returns (uint256) {
        return 2e16;
    }

    function _largeDepositAmount() internal pure override returns (uint256) {
        return 10e8; // 10 WBTC
    }

    function _oneMillionAmount() internal pure override returns (uint256) {
        return 10e8; // 10 WBTC ~ $1M
    }

    function _oneMillionLabel() internal pure override returns (string memory) {
        return "10 BTC (~$1M)";
    }

    function _ratioTestSmallAmount() internal pure override returns (uint256) {
        return 1e6; // 0.01 WBTC
    }

    function _tvlChunk() internal pure override returns (uint256) {
        return 5e8; // 5 WBTC
    }

    function _tvlMinChunk() internal pure override returns (uint256) {
        return 1e7; // 0.1 WBTC
    }

    function _tvlIterCap() internal pure override returns (uint256) {
        return 160;
    }

    function _tvlLabel() internal pure override returns (string memory) {
        return "WBTC Aave TVL(USDT 6d)=";
    }
}
