// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {WstEthOracle} from "../src/WstEthOracle.sol";
import {AaveLoanManager} from "../src/lenders/AaveLoanManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IChainlinkOracle} from "../src/interfaces/IChainlinkOracle.sol";

/// @title WstEthOracle Fork Integration Test
/// @notice Tests WstEthOracle with real Chainlink feeds — no mocked timestamps.
///         Validates that the composite oracle works correctly with feeds that have
///         different heartbeats (stETH/ETH = 24h, ETH/USD = 1h, USDT/USD = 24h).
contract WstEthOracleForkTest is Test {
    // Mainnet addresses
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Chainlink oracles
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    WstEthOracle oracle;
    AaveLoanManager loanManager;

    address owner = makeAddr("owner");
    address vaultAddr = makeAddr("vault");

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        oracle = new WstEthOracle(WSTETH, STETH_ETH_ORACLE, ETH_USD_ORACLE);

        // Dummy swapper — won't be called in view-only tests
        address dummySwapper = makeAddr("swapper");

        loanManager = new AaveLoanManager(
            WSTETH,
            USDT,
            AAVE_A_WSTETH,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            address(oracle),
            USDT_USD_ORACLE,
            dummySwapper,
            7100, // maxLtvBps
            7600, // liquidationThresholdBps
            vaultAddr
        );
    }

    // ============ WstEthOracle unit tests ============

    /// @notice Oracle returns a positive, sane wstETH/USD price
    function test_oracleReturnsValidPrice() public view {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertGt(answer, 0, "Price must be positive");
        // wstETH should be worth > $1000 and < $100,000 (8 decimals)
        assertGt(uint256(answer), 1000e8, "Price too low");
        assertLt(uint256(answer), 100_000e8, "Price too high");
        assertGt(updatedAt, 0, "updatedAt must be non-zero");

        uint8 dec = oracle.decimals();
        assertEq(dec, 8, "Decimals must be 8");
    }

    /// @notice latestAnswer matches latestRoundData answer
    function test_latestAnswerConsistent() public view {
        (, int256 roundDataAnswer,,,) = oracle.latestRoundData();
        int256 latestAns = oracle.latestAnswer();
        assertEq(roundDataAnswer, latestAns, "latestAnswer != latestRoundData answer");
    }

    /// @notice Oracle updatedAt now tracks ETH/USD feed, not min of both feeds
    function test_updatedAtTracksEthUsdFeed() public view {
        (,,, uint256 oracleUpdatedAt,) = oracle.latestRoundData();
        (,,, uint256 ethUsdUpdatedAt,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        assertEq(oracleUpdatedAt, ethUsdUpdatedAt, "updatedAt should equal ETH/USD updatedAt");
    }

    /// @notice Oracle roundId/answeredInRound track ETH/USD feed
    function test_roundMetadataTracksEthUsdFeed() public view {
        (uint80 oracleRoundId,,,, uint80 oracleAnsweredInRound) = oracle.latestRoundData();
        (uint80 ethRoundId,,,, uint80 ethAnsweredInRound) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        assertEq(oracleRoundId, ethRoundId, "roundId should match ETH/USD");
        assertEq(oracleAnsweredInRound, ethAnsweredInRound, "answeredInRound should match ETH/USD");
    }

    // ============ Staleness integration tests (real timestamps, no mocking) ============

    /// @notice LoanManager.checkOracleFreshness() succeeds with real, unmocked oracle timestamps.
    ///         This is the exact scenario that was reverting in production.
    function test_checkOracleFreshness_withRealTimestamps() public view {
        // No vm.mockCall — uses real Chainlink updatedAt values
        loanManager.checkOracleFreshness();
    }

    /// @notice All LoanManager view functions that touch oracles work with real timestamps
    function test_viewFunctions_withRealTimestamps() public view {
        // These all call _validatedPrice internally
        loanManager.getCollateralValue(1e18);
        loanManager.getDebtValue(1000e6);
        loanManager.calculateBorrowAmount(1e18, 5e17);
        loanManager.minCollateral(1000e6, 0);
    }

    /// @notice After 30 minutes, ETH/USD feed should still be fresh (1h heartbeat)
    function test_checkOracleFreshness_after30min() public {
        vm.warp(block.timestamp + 30 minutes);
        // Should still pass — ETH/USD heartbeat is 1h, USDT/USD is 24h
        // May revert if the fork block already had a nearly-stale ETH/USD feed,
        // but this tests the typical case
        try loanManager.checkOracleFreshness() {
            // success
        } catch {
            // Acceptable if ETH/USD was already ~30min stale at fork block
            (,,, uint256 ethUsdUpdatedAt,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
            uint256 age = block.timestamp - ethUsdUpdatedAt;
            assertGt(age, 3600, "Should only fail if ETH/USD is actually stale");
        }
    }

    /// @notice After 2 hours, the collateral oracle (ETH/USD component) should be stale
    function test_checkOracleFreshness_after2h_reverts() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(); // StaleOracle from ETH/USD being >1h old
        loanManager.checkOracleFreshness();
    }

    // ============ stETH/ETH internal staleness validation ============

    /// @notice WstEthOracle reverts if stETH/ETH feed is genuinely stale (>25h)
    function test_oracleReverts_ifStEthEthFeedStale() public {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(STETH_ETH_ORACLE).latestRoundData();

        // Mock stETH/ETH feed to be 26 hours old
        vm.mockCall(
            STETH_ETH_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer, updatedAt, block.timestamp - 93600, answeredInRound)
        );

        vm.expectRevert("stETH/ETH: stale");
        oracle.latestRoundData();
    }

    /// @notice WstEthOracle succeeds when stETH/ETH feed is 20h old (within 25h threshold)
    function test_oracleSucceeds_ifStEthEthFeed20hOld() public {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(STETH_ETH_ORACLE).latestRoundData();

        // Mock stETH/ETH feed to be 20 hours old — within the 25h tolerance
        vm.mockCall(
            STETH_ETH_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer, updatedAt, block.timestamp - 72000, answeredInRound)
        );

        (, int256 price,, uint256 compositeUpdatedAt,) = oracle.latestRoundData();
        assertGt(price, 0, "Should return valid price");

        // updatedAt should be from ETH/USD, not the stale stETH/ETH
        (,,, uint256 ethUsdUpdatedAt,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        assertEq(compositeUpdatedAt, ethUsdUpdatedAt, "updatedAt should be ETH/USD, not stETH/ETH");
    }

    // ============ Price sanity ============

    /// @notice wstETH price should be > stETH price (due to stEthPerToken ratio > 1)
    function test_wstEthPriceGtEthUsdPrice() public view {
        (, int256 wstEthUsd,,,) = oracle.latestRoundData();
        (, int256 ethUsd,,,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        // wstETH wraps stETH which accrues value, so wstETH/USD > ETH/USD
        assertGt(wstEthUsd, ethUsd, "wstETH should be worth more than ETH");
    }

    /// @notice wstETH price should be within reasonable range of ETH price (1x-2x)
    function test_wstEthPriceWithinRangeOfEth() public view {
        (, int256 wstEthUsd,,,) = oracle.latestRoundData();
        (, int256 ethUsd,,,) = IChainlinkOracle(ETH_USD_ORACLE).latestRoundData();
        // wstETH should be between 1x and 2x ETH price
        assertGt(wstEthUsd, ethUsd, "wstETH < ETH");
        assertLt(wstEthUsd, ethUsd * 2, "wstETH > 2x ETH");
    }
}
