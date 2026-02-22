// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ZenjiViewHelper} from "../src/ZenjiViewHelper.sol";
import {VaultTracker} from "../src/VaultTracker.sol";
import {WstEthOracle} from "../src/WstEthOracle.sol";
import {UniswapV3TwoHopSwapper} from "../src/swappers/base/UniswapV3TwoHopSwapper.sol";
import {AaveLoanManager} from "../src/lenders/AaveLoanManager.sol";
import {UsdtIporYieldStrategy} from "../src/strategies/UsdtIporYieldStrategy.sol";
import {ZenjiWstEth} from "../src/implementations/ZenjiWstEth.sol";

contract DeployWstEth is Script {
    // Assets
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Chainlink oracles
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Uniswap V3
    address constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 constant FEE_WSTETH_WETH = 100;
    uint24 constant FEE_WETH_USDT = 3000;

    // IPOR / Curve
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = _envOrAddress("OWNER", vm.addr(pk));
        address gov = _envOrAddress("GOV", owner);

        vm.startBroadcast(pk);

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        WstEthOracle wstEthOracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

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
            address(0)
        );

        UsdtIporYieldStrategy strategy = new UsdtIporYieldStrategy(
            USDT,
            CRVUSD,
            address(0),
            CURVE_USDT_CRVUSD_POOL,
            IPOR_PLASMA_VAULT,
            USDT_INDEX,
            CRVUSD_INDEX,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE
        );

        ZenjiWstEth vault = new ZenjiWstEth(
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        VaultTracker vaultTracker = new VaultTracker(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper", address(viewHelper));
        console2.log("WstEthOracle", address(wstEthOracle));
        console2.log("Swapper", address(swapper));
        console2.log("LoanManager", address(loanManager));
        console2.log("Strategy", address(strategy));
        console2.log("Vault", address(vault));
        console2.log("VaultTracker", address(vaultTracker));
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
