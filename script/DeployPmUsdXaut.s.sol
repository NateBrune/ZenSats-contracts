// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ZenjiRebalanceKeeper } from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { ZenjiXautPmUsd } from "../src/implementations/ZenjiXautPmUsd.sol";

/// @notice Deploys XAUT/USDT vault with pmUSD/crvUSD Stake DAO strategy on Aave
/// @dev Uses eMode category 43 ("XAUt USDC USDT GHO").
///      Aave eMode params: 70% max LTV, 75% liquidation threshold.
///      Vault target LTV = 60% (conservative), liquidationThresholdBps = 7500 (Aave actual).
///      Health at target: 0.75 / 0.60 = 1.25 — well above MIN_HEALTH (1.1).
contract DeployPmUsdXaut is Script {
    // Assets
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;

    // Chainlink oracles
    // NOTE: XAU/USD oracle heartbeat is 24h — ensure keepers tolerate this update frequency
    address constant XAU_USD_ORACLE = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_XAUT = 0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    uint8 constant AAVE_EMODE_XAUT = 43; // "XAUt USDC USDT GHO"

    // Uniswap Universal Router + XAUT/USDT v3 pool (0.05% fee)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant XAUT_USDT_V3_FEE = 500;

    // Stake DAO
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

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            gov, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        UniversalRouterV3SingleHopSwapper swapper = new UniversalRouterV3SingleHopSwapper(
            gov,
            XAUT,
            USDT,
            UNIVERSAL_ROUTER,
            XAUT_USDT_V3_FEE,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            90_000 // XAU/USD heartbeat is 24h
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
            XAUT,
            USDT,
            AAVE_A_XAUT,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            XAU_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            6000,
            7500,
            address(0),
            AAVE_EMODE_XAUT,
            90000 // XAU/USD Chainlink heartbeat is 24h; allow 25h
        );

        ZenjiXautPmUsd vault = new ZenjiXautPmUsd(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        ZenjiRebalanceKeeper rebalanceKeeper = new ZenjiRebalanceKeeper(address(vault), owner);

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));
        swapper.setVault(address(vault));

        vm.stopBroadcast();

        console2.log("ViewHelper", address(viewHelper));
        console2.log("CrvToCrvUsdSwapper", address(crvSwapper));
        console2.log("UniversalRouterV3Swapper", address(swapper));
        console2.log("LoanManager", address(loanManager));
        console2.log("Strategy", address(strategy));
        console2.log("Vault", address(vault));
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
