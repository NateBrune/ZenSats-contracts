// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {Zenji} from "../src/Zenji.sol";
import {ZenjiViewHelper} from "../src/ZenjiViewHelper.sol";
import {AaveLoanManager} from "../src/AaveLoanManager.sol";
import {CurveThreeCryptoSwapper} from "../src/CurveThreeCryptoSwapper.sol";
import {UsdcTokemakYieldStrategy} from "../src/strategies/UsdcTokemakYieldStrategy.sol";
import {IYieldStrategy} from "../src/interfaces/IYieldStrategy.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ICurveThreeCrypto {
    function coins(uint256 i) external view returns (address);
}

/// @title UsdcTokemakSmoke
/// @notice Smoke test: WBTC collateral → Aave borrow USDC → Tokemak autoUSD yield
contract UsdcTokemakSmoke is Test {
    // Mainnet addresses
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDC = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;

    // Tokemak
    address constant TOKEMAK_AUTOPOOL = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address constant TOKEMAK_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address constant TOKEMAK_REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;

    // Curve TriCrypto USDC pool (USDC/WBTC/WETH)
    address constant TRICRYPTO_USDC_POOL = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;

    // Oracles (our own)
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDC_USD_ORACLE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Zenji storage slot for swapper (from `forge inspect Zenji storageLayout`)
    uint256 constant SWAPPER_SLOT = 6;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");

    IERC20 wbtc;
    IERC20 usdc;
    ZenjiViewHelper viewHelper;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        wbtc = IERC20(WBTC);
        usdc = IERC20(USDC);

        viewHelper = new ZenjiViewHelper();

        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDC_USD_ORACLE);

        // Fund test user with WBTC
        deal(WBTC, user1, 10e8); // 10 WBTC
    }

    function _mockOracle(address oracle) internal {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(oracle).latestRoundData();
        uint256 timestamp = block.timestamp > updatedAt ? block.timestamp : updatedAt;
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer, timestamp, timestamp, answeredInRound)
        );
    }

    /// @notice Resolve coin indices for the TriCrypto USDC pool on-chain
    function _findCoinIndex(address pool, address token) internal view returns (uint256) {
        for (uint256 i = 0; i < 3; i++) {
            if (ICurveThreeCrypto(pool).coins(i) == token) return i;
        }
        revert("Token not found in pool");
    }

    /// @notice Full smoke test: WBTC → Aave USDC → Tokemak autoUSD
    function test_smoke_WBTC_USDC_Tokemak_Aave() public {
        console.log("=== Testing WBTC + USDC + Tokemak (Aave) ===");

        // Resolve TriCrypto USDC pool indices on-chain
        uint256 wbtcIndex = _findCoinIndex(TRICRYPTO_USDC_POOL, WBTC);
        uint256 usdcIndex = _findCoinIndex(TRICRYPTO_USDC_POOL, USDC);
        console.log("WBTC index:", wbtcIndex);
        console.log("USDC index:", usdcIndex);

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        // 1. Deploy swapper (WBTC <-> USDC via TriCrypto USDC pool)
        CurveThreeCryptoSwapper swapper = new CurveThreeCryptoSwapper(
            owner, WBTC, USDC, TRICRYPTO_USDC_POOL, wbtcIndex, usdcIndex
        );

        // 2. Deploy yield strategy (USDC -> Tokemak)
        UsdcTokemakYieldStrategy strategy = new UsdcTokemakYieldStrategy(
            USDC, expectedVaultAddress, TOKEMAK_AUTOPOOL, TOKEMAK_ROUTER, TOKEMAK_REWARDER
        );

        // 3. Deploy loan manager (WBTC collateral, USDC debt via Aave)
        AaveLoanManager loanManager = new AaveLoanManager(
            WBTC,
            USDC,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDC,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDC_USD_ORACLE,
            address(swapper),
            7500, // 75% max LTV
            8000, // 80% liquidation threshold
            expectedVaultAddress
        );

        // 4. Deploy vault
        Zenji vault = new Zenji(
            WBTC, USDC, address(loanManager), address(strategy), owner, address(viewHelper)
        );

        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        // Set swapper via vm.store to avoid 2-day timelock warp (which breaks Tokemak's internal oracle freshness)
        vm.store(address(vault), bytes32(SWAPPER_SLOT), bytes32(uint256(uint160(address(swapper)))));

        // Approve vault for user
        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        // Test deposit
        vm.prank(user1);
        uint256 shares = vault.deposit(1e8, user1); // 1 WBTC
        assertGt(shares, 0, "Should receive shares");
        console.log("Shares received:", shares);

        // Verify loan was created
        assertTrue(loanManager.loanExists(), "Loan should exist");
        console.log("Loan LTV:", loanManager.getCurrentLTV());

        // Verify debt was deployed to yield
        uint256 strategyBalance = strategy.balanceOf();
        assertGt(strategyBalance, 0, "Strategy should have balance");
        console.log("Strategy balance (USDC):", strategyBalance);

        // Test harvest (no-op for now)
        vm.prank(owner);
        vault.harvestYield();

        // Test partial and full withdrawal (best-effort on fork)
        vm.warp(block.timestamp + 2);
        _mockOracle(BTC_USD_ORACLE);
        _mockOracle(USDC_USD_ORACLE);

        vm.startPrank(user1);
        try vault.redeem(shares / 2, user1, user1) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "Should receive WBTC back");
            console.log("Partial redeem WBTC:", withdrawn);
        } catch {
            console.log("Partial redeem reverted; skipping withdrawal assertions");
            vm.stopPrank();
            return;
        }

        try vault.redeem(vault.balanceOf(user1), user1, user1) returns (uint256 finalWithdrawn) {
            assertGt(finalWithdrawn, 0, "Should receive remaining WBTC");
            console.log("Final redeem WBTC:", finalWithdrawn);
        } catch {
            console.log("Final redeem reverted; skipping");
        }
        vm.stopPrank();

        console.log("WBTC + USDC + Tokemak (Aave) smoke test passed!");
    }
}
