// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import {
    UniversalRouterV3SingleHopSwapper
} from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import {
    UsdtCrvUsdLpStakeDaoStrategy
} from "../src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import {
    ZenjiXautAaveUsdtStakeDao
} from "../src/implementations/stakedao/ZenjiXautAaveUsdtStakeDao.sol";

/// @notice Deploys XAUT/USDT vault with crvUSD/USDT Stake DAO strategy on Aave
/// @dev Uses eMode category 43 ("XAUt USDC USDT GHO").
///      Aave eMode params: 70% max LTV, 75% liquidation threshold.
///      Vault target LTV = 60% (conservative), liquidationThresholdBps = 7500 (Aave actual).
///      Health at target: 0.75 / 0.60 = 1.25 — well above MIN_HEALTH (1.1).
///      Yield leg uses the crvUSD/USDT Curve pool for BOTH the USDT<->crvUSD swap and the LP
///      deposit (deeper liquidity than pmUSD/crvUSD — see UsdtCrvUsdLpStakeDaoStrategy notes).
contract DeployXautAaveUsdtStakeDao is Script {
    // Assets
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

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

    // Stake DAO / Curve crvUSD/USDT — same pool used for both the swap leg and the LP leg
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant STAKE_DAO_REWARD_VAULT = 0xF980f195A93577DcCe48e91e98124D3B71C4a066;
    address constant USDT_CRVUSD_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    // Expected coin ordering in the crvUSD/USDT pool. Both are asserted on-chain at deploy time
    // by _assertCoinOrdering() — the swap leg and the LP leg share this pool, so a single check
    // covers all three index arguments.
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

        _assertCoinOrdering();

        UsdtCrvUsdLpStakeDaoStrategy strategy = new UsdtCrvUsdLpStakeDaoStrategy(
            USDT,
            address(0),
            gov,
            USDT_CRVUSD_POOL,
            USDT_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            USDT_CRVUSD_GAUGE,
            USDT_INDEX,
            CRVUSD_INDEX,
            CRVUSD_INDEX, // lpCrvUsdIndex — same pool, same ordering
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE,
            CRV_USD_ORACLE,
            "USDT -> crvUSD/USDT LP Strategy"
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

        ZenjiXautAaveUsdtStakeDao vault = new ZenjiXautAaveUsdtStakeDao(
            address(loanManager), address(strategy), address(swapper), owner, address(viewHelper)
        );

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));
        swapper.setVault(address(vault));
        // REQUIRED: CrvToCrvUsdSwapper.swap() reverts Unauthorized until this is set ("fully
        // locked until setAuthorizedCaller is called"). BaseCurveStakeDaoStrategy wraps the
        // harvest swap in try/catch, so omitting this does NOT revert -- CRV simply never
        // compounds, CrvSwapDeferred fires on every harvest, and the vault silently
        // underperforms. Both LlamaLend deploy scripts do this; this script did not.
        crvSwapper.setAuthorizedCaller(address(strategy));

        vm.stopBroadcast();

        console2.log("ViewHelper", address(viewHelper));
        console2.log("CrvToCrvUsdSwapper", address(crvSwapper));
        console2.log("UniversalRouterV3Swapper", address(swapper));
        console2.log("LoanManager", address(loanManager));
        console2.log("Strategy", address(strategy));
        console2.log("Vault", address(vault));
    }

    /// @dev Deploy-time safety assert: the pool must be ordered USDT=coins(0), crvUSD=coins(1),
    ///      matching USDT_INDEX/CRVUSD_INDEX. Reverting here is far cheaper than deploying a
    ///      strategy that swaps and LPs against inverted indices.
    function _assertCoinOrdering() internal view {
        address coin0 = ICurveStableSwapNG(USDT_CRVUSD_POOL).coins(uint256(uint128(USDT_INDEX)));
        address coin1 = ICurveStableSwapNG(USDT_CRVUSD_POOL).coins(uint256(uint128(CRVUSD_INDEX)));
        if (coin0 != USDT) revert("USDT is not coins(0) in the crvUSD/USDT pool");
        if (coin1 != CRVUSD) revert("crvUSD is not coins(1) in the crvUSD/USDT pool");
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
