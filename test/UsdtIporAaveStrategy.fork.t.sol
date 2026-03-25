// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldVault } from "../src/interfaces/IYieldVault.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract UsdtIporAaveStrategyForkTest is Test {
    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    // Curve pool for USDT <-> crvUSD
    address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;

    // Uniswap V3 WBTC/USDT swapper
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant WBTC_WHALE = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

    Zenji vault;
    ZenjiViewHelper viewHelper;
    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    UniversalRouterV3SingleHopSwapper swapper;

    IERC20 wbtc;
    IERC20 usdt;
    IYieldVault iporVault;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        require(bytes(rpcUrl).length > 0, "RPC URL required");
        vm.createSelectFork(rpcUrl);

        // Sync block time and mock oracles to prevent StaleOracle reverts
        (,, uint256 btcUpdate,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        if (btcUpdate + 1 > block.timestamp) {
            vm.warp(btcUpdate + 1);
        }
        _mockOracles(50000e8, 1e8);

        wbtc = IERC20(WBTC);
        usdt = IERC20(USDT);
        iporVault = IYieldVault(IPOR_PLASMA_VAULT);

        viewHelper = new ZenjiViewHelper();
        swapper = new UniversalRouterV3SingleHopSwapper(
            owner,
            WBTC,
            USDT,
            UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
        );

        loanManager = new AaveLoanManager(
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500,
            8000,
            address(0),
            0, // eMode: disabled
            3600
        );

        strategy = new UsdtIporYieldStrategy(
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

        vault = new Zenji(
            WBTC,
            USDT,
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        vm.prank(address(vault));
        strategy.setSlippage(5e16);

        vm.prank(WBTC_WHALE);
        wbtc.transfer(user, 1e8); // 1 WBTC
        vm.prank(user);
        wbtc.approve(address(vault), type(uint256).max);
    }

    function test_deposit_borrowsUsdt_and_depositsIntoIpor() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) return;

        uint256 depositAmount = 1e6; // 0.01 WBTC
        vm.prank(user);
        vault.deposit(depositAmount, user);

        assertGt(loanManager.getCurrentDebt(), 0, "USDT debt should be > 0");
        assertGt(strategy.balanceOf(), 0, "Strategy balance should be > 0");
        assertGt(iporVault.balanceOf(address(strategy)), 0, "IPOR shares should be > 0");
    }

    function _mockOracles(uint256 btcPrice, uint256 usdtPrice) internal {
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(btcPrice), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            USDT_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdtPrice), block.timestamp, block.timestamp, uint80(1))
        );
    }
}
