// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ZenjiRebalanceKeeper } from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { CrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/CrvUsdLpStakeDaoStrategy.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { ZenjiWbtcLlamaStakeDao } from "../src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol";

/// @notice Deploys WBTC/crvUSD vault with USDT/crvUSD Stake DAO strategy on LlamaLend.
///         Yield path: LlamaLend borrows crvUSD → single-sided crvUSD deposit into the
///         USDT/crvUSD Curve pool → Stake DAO reward vault.
///         Swap route: WBTC -> WETH (Uniswap V3 0.05%) -> crvUSD (Curve TriCRV).
contract DeployWbtcLlamaUsdtStakeDao is Script {
    // Assets
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // Chainlink oracles
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // LlamaLend WBTC market
    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;

    // Uniswap V3 WBTC/WETH (0.05%) + Curve TriCRV (WETH <-> crvUSD)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500;
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    uint256 constant MAX_COLLATERAL_STALENESS = 3600; // 1h BTC/USD heartbeat

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

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            gov, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        (uint256 wethIdx, uint256 crvUsdIdx) = _triCryptoIndices();

        UniswapMixedCurveSwapper swapper = new UniswapMixedCurveSwapper(
            gov,
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

        ZenjiWbtcLlamaStakeDao vault = new ZenjiWbtcLlamaStakeDao(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        ZenjiRebalanceKeeper rebalanceKeeper = new ZenjiRebalanceKeeper(address(vault), owner);

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));
        swapper.setVault(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper              ", address(viewHelper));
        console2.log("CrvToCrvUsdSwapper      ", address(crvSwapper));
        console2.log("UniswapMixedCurveSwapper", address(swapper));
        console2.log("LoanManager             ", address(loanManager));
        console2.log("Strategy                ", address(strategy));
        console2.log("Vault                   ", address(vault));
        console2.log("RebalanceKeeper         ", address(rebalanceKeeper));
    }

    function _triCryptoIndices() internal view returns (uint256 wethIdx, uint256 crvUsdIdx) {
        ICurveTriCrypto pool = ICurveTriCrypto(TRICRYPTO_POOL);
        for (uint256 i = 0; i < 3; i++) {
            address coin = pool.coins(i);
            if (coin == WETH) wethIdx = i;
            else if (coin == CRVUSD) crvUsdIdx = i;
        }
    }

    function _envOrAddress(string memory key, address defaultValue) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            if (val != address(0)) return val;
            return defaultValue;
        } catch {
            return defaultValue;
        }
    }
}
