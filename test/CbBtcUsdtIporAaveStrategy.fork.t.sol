// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
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

contract CbBtcUsdtIporAaveStrategyForkTest is Test {
    // Mainnet addresses
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    // Curve pool for USDT <-> crvUSD
    address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;

    // Curve TwoCrypto: cbBTC <-> WBTC
    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX = 1;

    // Curve TriCrypto: WBTC <-> USDT
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;

    address constant CBBTC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    Zenji vault;
    ZenjiViewHelper viewHelper;
    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    CbBtcWbtcUsdtSwapper swapper;

    IERC20 cbbtc;
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
        (,, uint256 cbBtcUpdate,,) = IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        if (cbBtcUpdate + 1 > block.timestamp) {
            vm.warp(cbBtcUpdate + 1);
        }
        _mockOracles(50000e8, 1e8);

        cbbtc = IERC20(CBBTC);
        usdt = IERC20(USDT);
        iporVault = IYieldVault(IPOR_PLASMA_VAULT);

        viewHelper = new ZenjiViewHelper();
        swapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            CBBTC_INDEX,
            WBTC_INDEX,
            TRICRYPTO_POOL,
            TRICRYPTO_WBTC_INDEX,
            TRICRYPTO_USDT_INDEX
        );

        loanManager = new AaveLoanManager(
            CBBTC,
            USDT,
            AAVE_A_CBBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            CBBTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7500,
            8000,
            address(0)
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
            CBBTC,
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

        vm.prank(CBBTC_WHALE);
        cbbtc.transfer(user, 1e8); // 1 cbBTC
        vm.prank(user);
        cbbtc.approve(address(vault), type(uint256).max);
    }

    function test_deposit_borrowsUsdt_and_depositsIntoIpor() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) return;

        uint256 depositAmount = 1e6; // 0.01 cbBTC (8 decimals)
        vm.prank(user);
        vault.deposit(depositAmount, user);

        assertGt(loanManager.getCurrentDebt(), 0, "USDT debt should be > 0");
        assertGt(strategy.balanceOf(), 0, "Strategy balance should be > 0");
        assertGt(iporVault.balanceOf(address(strategy)), 0, "IPOR shares should be > 0");
    }

    function test_unwindAndWithdraws() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) return;

        uint256 depositAmount = 2e6; // 0.02 cbBTC
        vm.prank(user);
        vault.deposit(depositAmount, user);

        assertTrue(loanManager.loanExists(), "Loan should exist");
        assertGt(loanManager.getCurrentDebt(), 0, "Debt should be > 0");

        uint256 shares = vault.balanceOf(user);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        _mockOracles(50000e8, 1e8);

        vm.prank(user);
        uint256 partialReceived = vault.redeem(shares / 2, user, user);
        assertGt(partialReceived, 0, "Partial redeem should return cbBTC");
        assertLt(vault.balanceOf(user), shares, "Shares should decrease");

        vm.prank(owner);
        vault.setIdle(true);

        assertLt(loanManager.getCurrentDebt(), 1, "Debt should be cleared");

        uint256 remainingShares = vault.balanceOf(user);
        uint256 balanceBefore = cbbtc.balanceOf(user);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        _mockOracles(50000e8, 1e8);

        vm.prank(user);
        uint256 finalReceived = vault.redeem(remainingShares, user, user);

        assertGt(finalReceived, 0, "Final redeem should return cbBTC");
        assertEq(vault.balanceOf(user), 0, "Shares should be zero");
        assertGt(cbbtc.balanceOf(user), balanceBefore, "User cbBTC should increase");
    }

    function _mockOracles(uint256 cbBtcPrice, uint256 usdtPrice) internal {
        vm.mockCall(
            CBBTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(cbBtcPrice), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            USDT_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdtPrice), block.timestamp, block.timestamp, uint80(1))
        );
    }
}
