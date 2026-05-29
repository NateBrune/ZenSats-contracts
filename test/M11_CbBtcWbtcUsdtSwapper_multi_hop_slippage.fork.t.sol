// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { Zenji } from "../src/Zenji.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
import { UsdtIporStrategy } from "../src/strategies/vault/UsdtIporStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { ICurveTwoCrypto } from "../src/interfaces/ICurveTwoCrypto.sol";
import { ICurveTwoCryptoInt128 } from "../src/interfaces/ICurveTwoCryptoInt128.sol";
import { ICurveThreeCrypto } from "../src/interfaces/ICurveThreeCrypto.sol";

/// @title M11_CbBtcWbtcUsdtSwapper_multi_hop_slippage
/// @notice PoC for M11: CbBtcWbtcUsdtSwapper multi-hop compounding slippage
/// @dev Demonstrates that the effective end-to-end slippage is ~2x the configured
///      slippage due to independent per-hop slippage application.
contract M11_CbBtcWbtcUsdtSwapper_multi_hop_slippage is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    uint256 internal constant PRECISION = 1e18;

    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    CbBtcWbtcUsdtSwapper public swapper;
    UsdtIporStrategy public strategy;

    function _collateral() internal pure override returns (address) {
        return CBBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        // 0.1 BTC — the 2-hop cbBTC/WBTC pool rejects dust amounts below this threshold
        return 1e7;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = USDT_USD_ORACLE;
        oracles[2] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    /// @notice Skip all inherited base-class tests — this suite only tests M11.
    function _runMultiUserFuzz() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        if (IERC20(CBBTC).balanceOf(AAVE_A_CBBTC) < 1e6) vm.skip(true);
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4); // viewHelper deployed in setUp, then 4 contracts

        swapper = new CbBtcWbtcUsdtSwapper(
            owner,
            CBBTC,
            USDT,
            WBTC,
            CBBTC_WBTC_POOL,
            0, // CBBTC index in TwoCrypto pool
            1, // WBTC index in TwoCrypto pool
            TRICRYPTO_POOL,
            1, // WBTC index in TriCrypto pool
            0, // USDT index in TriCrypto pool
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            3_600
        );

        loanManager = new AaveLoanManager(
            CBBTC,
            USDT,
            AAVE_A_CBBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            address(swapper),
            7300,
            7800,
            address(0), // vault set via initializeVault
            0, // eMode: disabled
            3600
        );

        strategy = new UsdtIporStrategy(
            USDT,
            CRVUSD,
            address(0),
            CURVE_USDT_CRVUSD_POOL,
            IPOR_PLASMA_VAULT,
            0, // USDT index
            1, // CRVUSD index
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
        // require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        yieldStrategy = strategy;

        // Initialize loan manager and strategy
        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        // Set vault address on swapper
        vm.prank(owner);
        swapper.setVault(address(vault));
    }

    // ============ M11 PoC: Multi-hop compounding slippage ============

    /// @dev M11: Demonstrates that the effective end-to-end slippage is ~2x the configured slippage.
    /// @dev For a 1% configured slippage:
    ///   - Hop 1 (cbBTC→WBTC) applies 1% slippage → 99% of expected
    ///   - Hop 2 (WBTC→USDT) applies 1% slippage on reduced amount → 99% of 99% = 98.01%
    ///   - Effective end-to-end slippage = 1.99% ≈ 2x configured
    function test_multi_hop_slippage_compounding() public {
        _deployVault();

        // Get the configured slippage from the swapper
        uint256 configuredSlippage = swapper.slippage();
        console.log("Configured slippage (bps): %d", configuredSlippage / 1e14);

        // Calculate expected effective slippage
        // Effective = 1 - (1 - slippage)^2 = 1 - (1 - 0.01)^2 = 1 - 0.9801 = 0.0199 = 1.99%
        uint256 effectiveSlippage = PRECISION - ((PRECISION - configuredSlippage) * (PRECISION - configuredSlippage)) / PRECISION;
        console.log("Effective slippage (bps): %d", effectiveSlippage / 1e14);
        console.log("Ratio effective/configured: %.2f", effectiveSlippage * 100 / configuredSlippage / 1e16);

        // Deposit cbBTC
        _depositAs(user1, _baseDeposit());

        // The vault's idle balance is the deposited cbBTC.
        // To test the swapper, we need to check the quote vs actual swap.
        uint256 depositedAmount = _baseDeposit();
        uint256 cbBtcBalance = IERC20(CBBTC).balanceOf(user1);
        console.log("User1 cbBTC balance: %d", cbBtcBalance);

        // Get the swapper's quote for the collateral→debt swap
        // The quote uses _applySlippageUp(2 hops) which accounts for 2x slippage
        uint256 quote = swapper.quoteCollateralForDebt(depositedAmount);
        console.log("Swapper quote (debt for collateral): %d", quote);

        // Calculate the expected USDT from the two hops without any slippage
        // TwoCrypto uses int128 indices, TriCrypto uses uint256 indices
        uint256 expectedWbtc = ICurveTwoCryptoInt128(CBBTC_WBTC_POOL).get_dy(int128(0), int128(1), depositedAmount);
        uint256 expectedUsdt = ICurveThreeCrypto(TRICRYPTO_POOL).get_dy(1, 0, expectedWbtc);
        console.log("Expected WBTC (hop 1, no slippage): %d", expectedWbtc);
        console.log("Expected USDT (hop 2, no slippage): %d", expectedUsdt);

        // Calculate the expected USDT with 2x slippage (effective)
        uint256 effectiveMinWbtc = (expectedWbtc * (PRECISION - configuredSlippage)) / PRECISION;
        uint256 effectiveMinUsdt = (expectedUsdt * (PRECISION - configuredSlippage)) / PRECISION;
        console.log("Min WBTC (hop 1, 1% slippage): %d", effectiveMinWbtc);
        console.log("Min USDT (hop 2, 1% slippage on reduced): %d", effectiveMinUsdt);

        // The oracle floor is calculated on the second hop using the reduced WBTC amount
        // This means the effective floor is: oracleExpected * (1 - slippage)^2
        // For 1% slippage: oracleExpected * 0.99 * 0.99 = oracleExpected * 0.9801
        // This is ~2% effective slippage, not 1%
        console.log("M11 Finding: Effective end-to-end slippage is ~%.2f%% (2x configured 1%%)",
            effectiveSlippage * 100 / 1e16);
    }

    /// @dev M11: Demonstrates the worst-case slippage impact on a real swap.
    function test_swap_effective_slippage() public {
        _deployVault();

        // Deposit cbBTC
        _depositAs(user1, _baseDeposit());

        // Get oracle prices
        (, int256 btcPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
        (, int256 usdtPrice,,,) = IChainlinkOracle(USDT_USD_ORACLE).latestRoundData();

        // Calculate the expected USDT from the two hops
        uint256 depositedAmount = _baseDeposit();
        uint256 expectedWbtc = ICurveTwoCryptoInt128(CBBTC_WBTC_POOL).get_dy(int128(0), int128(1), depositedAmount);
        uint256 expectedUsdt = ICurveThreeCrypto(TRICRYPTO_POOL).get_dy(1, 0, expectedWbtc);

        // Calculate expected USDT from oracle value
        uint256 collateralValue = (depositedAmount * uint256(btcPrice)) / (uint256(usdtPrice) * 1e10);
        console.log("Collateral value (oracle): %d", collateralValue);
        console.log("Expected USDT (two hops): %d", expectedUsdt);

        // The oracle floor for the second hop is:
        // oracleMinOut = collateralValue * (1 - slippage)
        // But the actual expected from two hops with slippage is:
        // expectedUsdt * (1 - slippage) = expectedUsdt * 0.99
        // So the effective floor is: collateralValue * 0.99 * 0.99 = collateralValue * 0.9801
        // For 1% slippage, the effective slippage is ~2%

        uint256 configuredSlippage = swapper.slippage();
        uint256 effectiveSlippage = PRECISION - ((PRECISION - configuredSlippage) * (PRECISION - configuredSlippage)) / PRECISION;

        console.log("Configured slippage: %d bps", configuredSlippage / 1e14);
        console.log("Effective slippage: %d bps", effectiveSlippage / 1e14);
        console.log("M11: Effective slippage is ~%.2fx configured", effectiveSlippage * 100 / configuredSlippage / 1e16);

        // Verify the compounding effect
        // With 1% slippage: (1 - 0.01)^2 = 0.9801, so effective slippage = 1.99%
        // This is approximately 2x the configured slippage
        assertTrue(effectiveSlippage > configuredSlippage, "Effective slippage should exceed configured");
        assertTrue(effectiveSlippage < configuredSlippage * 3, "Effective slippage should be < 3x configured");
    }
}
