// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { VaultTracker } from "../src/VaultTracker.sol";
import { ZenjiRebalanceKeeper } from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { WstEthOracle } from "../src/WstEthOracle.sol";
import { UniswapV3TwoHopSwapper } from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { ZenjiWstEthPmUsd } from "../src/implementations/ZenjiWstEthPmUsd.sol";

/// @notice Deploys wstETH/USDT vault with pmUSD/crvUSD Stake DAO strategy on Aave
contract DeployPmUsdWstEth is Script {
    // Assets
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    // Chainlink oracles
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Uniswap V3
    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 3000;

    // Curve / Stake DAO
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    int128 constant USDT_INDEX = 0;
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

        UniswapV3TwoHopSwapper swapper = new UniswapV3TwoHopSwapper(
            gov,
            WSTETH,
            USDT,
            WETH,
            UNISWAP_ROUTER,
            FEE_WSTETH_WETH,
            FEE_WETH_USDT,
            address(wstEthOracle),
            USDT_USD_ORACLE
        );

        int128 lpCrvUsdIndex = _lpCrvUsdIndex();

        PmUsdCrvUsdStrategy strategy = new PmUsdCrvUsdStrategy(
            USDT,
            CRVUSD,
            CRV,
            PMUSD,
            address(0),
            gov,
            USDT_CRVUSD_POOL,
            PMUSD_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            USDT_INDEX,
            CRVUSD_INDEX,
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE
        );

        AaveLoanManager loanManager = new AaveLoanManager(
            WSTETH,
            USDT,
            AAVE_A_WSTETH,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            address(wstEthOracle),
            USDT_USD_ORACLE,
            address(swapper),
            7800,
            8100,
            address(0),
            0, // eMode: disabled
            3600 // ETH/USD Chainlink heartbeat is 1h
        );

        ZenjiWstEthPmUsd vault = new ZenjiWstEthPmUsd(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        //VaultTracker vaultTracker = new VaultTracker(address(vault));

        ZenjiRebalanceKeeper rebalanceKeeper = new ZenjiRebalanceKeeper(address(vault), owner);

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));
        swapper.setVault(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper", address(viewHelper));
        console2.log("WstEthOracle", address(wstEthOracle));
        console2.log("CrvToCrvUsdSwapper", address(crvSwapper));
        console2.log("UniswapSwapper", address(swapper));
        console2.log("LoanManager", address(loanManager));
        console2.log("Strategy", address(strategy));
        console2.log("Vault", address(vault));
        //console2.log("VaultTracker", address(vaultTracker));
        console2.log("RebalanceKeeper", address(rebalanceKeeper));
    }

    function _lpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        if (coin0 == CRVUSD) return int128(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD not in pmUSD pool");
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
