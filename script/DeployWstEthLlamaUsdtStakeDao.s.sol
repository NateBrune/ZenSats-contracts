// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ZenjiRebalanceKeeper } from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { CrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import {
    ZenjiWstEthLlamaStakeDao
} from "../src/implementations/stakedao/ZenjiWstEthLlamaStakeDao.sol";

/// @notice Deploys wstETH/crvUSD vault with USDT/crvUSD Stake DAO strategy on LlamaLend.
///         Yield path: LlamaLend borrows crvUSD → single-sided crvUSD deposit into the
///         USDT/crvUSD Curve pool → Stake DAO reward vault.
///         Swap route: wstETH -> WETH (Uniswap V3 0.01%) -> crvUSD (Curve TriCRV).
contract DeployWstEthLlamaUsdtStakeDao is Script {
    // Assets
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // Chainlink oracles (composites via WstEthOracle deployed below)
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // LlamaLend wstETH market
    address constant LLAMALEND_WSTETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;

    // LlamaLend LLAMMA pool (health factor / oracle only — not used for swapping)
    address constant WSTETH_CRVUSD_POOL = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    // Uniswap V3 wstETH/WETH (0.01%) + Curve TriCRV for WETH↔crvUSD
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WSTETH_WETH = 100; // V3 0.01%
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    uint256 constant MAX_COLLATERAL_STALENESS = 90000; // 25h — WstEthOracle's stETH/ETH leg has a 24h heartbeat

    // CRV -> crvUSD harvest swapper (same TriCRV pool)
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    // Stake DAO / Curve USDT/crvUSD
    // coin(0)=USDT, coin(1)=crvUSD  =>  crvUSD index = 1
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant STAKEDAO_USDT_CRVUSD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
    int128 constant CRVUSD_INDEX = 1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = _envOrAddress("OWNER", vm.addr(pk));
        address gov = _envOrAddress("GOV", owner);

        vm.startBroadcast(pk);

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        WstEthOracle wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            gov, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        (uint256 wethIdx, uint256 crvUsdIdx) = _triCryptoIndices();

        UniswapMixedCurveSwapper swapper = new UniswapMixedCurveSwapper(
            gov,
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
            MAX_COLLATERAL_STALENESS
        );

        CrvUsdLpStakeDaoStrategy strategy = new CrvUsdLpStakeDaoStrategy(
            CRVUSD,
            address(0),
            gov,
            USDT_CRVUSD_POOL,
            STAKEDAO_USDT_CRVUSD_VAULT,
            address(crvSwapper),
            USDT_CRVUSD_GAUGE,
            CRVUSD_INDEX,
            CRVUSD_USD_ORACLE,
            CRV_USD_ORACLE,
            "crvUSD -> USDT/crvUSD LP (Stake DAO)"
        );

        LlamaLoanManager loanManager = new LlamaLoanManager(
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

        ZenjiWstEthLlamaStakeDao vault = new ZenjiWstEthLlamaStakeDao(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        ZenjiRebalanceKeeper rebalanceKeeper = new ZenjiRebalanceKeeper(address(vault), owner);

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));
        swapper.setVault(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper               ", address(viewHelper));
        console2.log("WstEthOracle             ", address(wstEthOracle));
        console2.log("CrvToCrvUsdSwapper       ", address(crvSwapper));
        console2.log("UniswapMixedCurveSwapper ", address(swapper));
        console2.log("LoanManager              ", address(loanManager));
        console2.log("Strategy                 ", address(strategy));
        console2.log("Vault                    ", address(vault));
        console2.log("RebalanceKeeper          ", address(rebalanceKeeper));
    }

    function _triCryptoIndices() internal view returns (uint256 wethIdx, uint256 crvUsdIdx) {
        ICurveTriCrypto pool = ICurveTriCrypto(TRICRYPTO_POOL);
        for (uint256 i = 0; i < 3; i++) {
            address coin = pool.coins(i);
            if (coin == WETH) wethIdx = i;
            else if (coin == CRVUSD) crvUsdIdx = i;
        }
    }

    function _envOrAddress(string memory key, address defaultValue)
        internal
        view
        returns (address)
    {
        try vm.envAddress(key) returns (address val) {
            if (val != address(0)) return val;
            return defaultValue;
        } catch {
            return defaultValue;
        }
    }
}
