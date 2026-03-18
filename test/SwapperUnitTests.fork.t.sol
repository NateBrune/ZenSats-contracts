// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { SwapperTestBase } from "./base/SwapperTestBase.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";
import { CurveThreeCryptoSwapper } from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";

// ============ Mainnet Addresses ============

address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;

address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

// ============ CurveTwoCryptoSwapper Tests ============

contract CurveTwoCryptoSwapperTest is SwapperTestBase {
    CurveTwoCryptoSwapper public swapper;

    function _deploySwapper() internal override {
        swapper = new CurveTwoCryptoSwapper(
            owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
        );
    }

    function _swapper() internal view override returns (BaseSwapper) {
        return swapper;
    }
}

// ============ CurveThreeCryptoSwapper Tests ============

contract CurveThreeCryptoSwapperTest is SwapperTestBase {
    CurveThreeCryptoSwapper public swapper;

    function _deploySwapper() internal override {
        swapper = new CurveThreeCryptoSwapper(
            owner, WBTC, USDT, TRICRYPTO_POOL, 1, 0, BTC_USD_ORACLE, USDT_USD_ORACLE
        );
    }

    function _swapper() internal view override returns (BaseSwapper) {
        return swapper;
    }
}

// ============ CbBtcWbtcUsdtSwapper Tests ============

contract CbBtcWbtcUsdtSwapperTest is SwapperTestBase {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX_CB = 1;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;

    CbBtcWbtcUsdtSwapper public swapper;

    function _deploySwapper() internal override {
        swapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            CBBTC_INDEX,
            WBTC_INDEX_CB,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE
        );
    }

    function _swapper() internal view override returns (BaseSwapper) {
        return swapper;
    }
}

// ============ UniswapV3TwoHopSwapper Tests ============

contract UniswapV3TwoHopSwapperTest is SwapperTestBase {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WSTETH_USD_ORACLE = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 500;

    UniswapV3TwoHopSwapper public swapper;

    function _deploySwapper() internal override {
        swapper = new UniswapV3TwoHopSwapper(
            owner,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            WSTETH_USD_ORACLE,
            USDT_USD_ORACLE
        );
    }

    function _swapper() internal view override returns (BaseSwapper) {
        return swapper;
    }
}

// ============ CrvToCrvUsdSwapper Tests ============

contract CrvToCrvUsdSwapperTest is SwapperTestBase {
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    CrvToCrvUsdSwapper public swapper;

    function _deploySwapper() internal override {
        swapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );
    }

    function _swapper() internal view override returns (BaseSwapper) {
        return swapper;
    }

    function _implementsISwapper() internal pure override returns (bool) {
        return false;
    }

    function test_zero_swap() public {
        assertEq(swapper.swap(0), 0, "Zero swap should return zero");
    }
}
