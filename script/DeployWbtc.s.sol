// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { VaultTracker } from "../src/VaultTracker.sol";
// import {ZenjiRebalanceKeeper} from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { CurveThreeCryptoSwapper } from "../src/swappers/base/CurveThreeCryptoSwapper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { ZenjiWbtc } from "../src/implementations/ZenjiWbtc.sol";

contract DeployWbtc is Script {
    // Assets
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Chainlink oracles
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Curve TriCrypto
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;

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

        CurveThreeCryptoSwapper swapper = new CurveThreeCryptoSwapper(
            gov,
            WBTC,
            USDT,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE
        );

        AaveLoanManager loanManager = new AaveLoanManager(
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7300,
            7800,
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

        ZenjiWbtc vault = new ZenjiWbtc(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        VaultTracker vaultTracker = new VaultTracker(address(vault));

        // Optional: deploy Chainlink Automation receiver for rebalancing.
        // ZenjiRebalanceKeeper rebalanceKeeper = new ZenjiRebalanceKeeper(address(vault), owner);

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper", address(viewHelper));
        console2.log("Swapper", address(swapper));
        console2.log("LoanManager", address(loanManager));
        console2.log("Strategy", address(strategy));
        console2.log("Vault", address(vault));
        console2.log("VaultTracker", address(vaultTracker));
        // console2.log("RebalanceKeeper", address(rebalanceKeeper));
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
