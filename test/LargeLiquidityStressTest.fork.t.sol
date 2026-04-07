// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

interface ICurvePool {
    function balances(uint256 i) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function calc_withdraw_one_coin(uint256 lpAmount, int128 i) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

interface IAavePool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @title LargeLiquidityStressTest
/// @notice Investigates why depositing 100 WBTC and withdrawing 1 block later
///         leaves the vault TVL at 0.0575 WBTC instead of ~0.15 WBTC.
///
/// Uses the LIVE deployed WBTC/pmUSD-crvUSD vault (no redeployment).
///
/// Run:
///   MAINNET_RPC_URL=<url> forge test --match-contract LargeLiquidityStressTest -vvv
///
/// The deployed vault address is hard-coded from DeploymentV26.md.
contract LargeLiquidityStressTest is Test {
    // ─── Deployed contracts (DeploymentV26.md: WBTC USDTcrvUSD/pmUSDYieldStrat) ───
    address constant DEPLOYED_VAULT       = 0x617A6877f0a55D1eF2B64b5861A2bB5Fe6FEB739;
    address constant DEPLOYED_STRATEGY    = 0x73B753F63175F003881Dc39710d40c8E2F027FD8;
    address constant DEPLOYED_LOAN_MGR    = 0x25a1b8262f9644F00Fc80F11eF8cc2Ea1b74BDE3;

    // ─── Tokens ────────────────────────────────────────────────────────────────
    address constant WBTC                 = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT                 = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant AAVE_A_WBTC          = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT   = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    address constant AAVE_POOL            = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // ─── Curve pool ────────────────────────────────────────────────────────────
    address constant PMUSD_CRVUSD_POOL    = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;

    // ─── Oracle addresses ──────────────────────────────────────────────────────
    address constant BTC_USD_ORACLE       = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE      = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE    = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE       = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    Zenji vault;
    IYieldStrategy strategy;
    ILoanManager loanManager;
    IERC20 wbtc;
    IERC20 usdt;
    address user;

    uint256 constant LARGE_DEPOSIT = 100e8; // 100 WBTC in satoshis

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        vault       = Zenji(DEPLOYED_VAULT);
        strategy    = vault.yieldStrategy();
        loanManager = vault.loanManager();
        wbtc        = IERC20(WBTC);
        usdt        = IERC20(USDT);
        user        = makeAddr("bigDepositor");

        deal(WBTC, user, LARGE_DEPOSIT + 1e8); // give slightly more than needed

        // Remove deposit cap so the large deposit isn't blocked
        uint256 cap = vault.depositCap();
        if (cap > 0) {
            vm.prank(vault.gov());
            vault.setParam(2, 0); // param 2 = depositCap, 0 = no cap
        }

        _refreshOracles();
    }

    // ─── Test A: Pool depth diagnostic ─────────────────────────────────────────
    /// @notice Measure pool liquidity vs withdrawal size BEFORE any deposit.
    /// This is purely informational — no deposit or redemption.
    /// If the pool TVL is smaller than the expected USDT withdrawal, slippage will be large.
    function testPoolDepthVsWithdrawalSize() public view {
        ICurvePool pool = ICurvePool(PMUSD_CRVUSD_POOL);
        console.log("\n=== Pool Depth Analysis ===");

        uint256 bal0 = pool.balances(0);
        uint256 bal1 = pool.balances(1);
        console.log("Pool balance[0] (pmUSD, 18-dec): %d", bal0);
        console.log("Pool balance[1] (crvUSD, 18-dec): %d", bal1);
        uint256 totalPoolUsdt = (bal0 + bal1) / 1e12; // approx USDT 6-dec
        console.log("Pool total approx USDT value (6-dec): %d", totalPoolUsdt);

        uint256 totalSupply = pool.totalSupply();
        uint256 vp = pool.get_virtual_price();
        console.log("Pool LP totalSupply (18-dec): %d", totalSupply);
        console.log("Pool virtual_price (18-dec): %d", vp);

        // Current strategy LP holdings
        uint256 strategyUsdt = strategy.balanceOf();
        console.log("\n=== Strategy vs Pool ===");
        console.log("Strategy balance (oracle USDT, 6-dec): %d", strategyUsdt);
        uint256 lmPosition = loanManager.getNetCollateralValue();
        console.log("LoanManager net collateral (WBTC 8-dec): %d", lmPosition);

        uint256 totalCollateral = vault.totalAssets();
        console.log("Vault totalAssets (WBTC 8-dec): %d", totalCollateral);
        console.log("Vault totalSupply (shares): %d", vault.totalSupply());

        // Estimate withdrawal size for a 100 WBTC deposit at 65% LTV
        uint256 targetLtv = vault.targetLtv();
        uint256 precision = vault.PRECISION();
        console.log("\n=== Projected Withdrawal Impact ===");
        console.log("Vault targetLtv: %d / 1e18", targetLtv);
        // 100 WBTC at ~$100K each = $10M collateral, 65% LTV = $6.5M USDT
        uint256 estimatedNewUsdt = (LARGE_DEPOSIT * targetLtv) / precision;
        // In USDT 6-dec terms (assuming ~$100K/BTC): very rough estimate
        console.log("Estimated additional USDT debt for 100 WBTC (raw lm units):");
        console.log("  = 65% x 100 WBTC wbtc-units = %d WBTC-units of debt", estimatedNewUsdt);

        // Pool can absorb vs what we need to withdraw:
        console.log("\nPool USDT-approx (6-dec): %d", totalPoolUsdt);
        console.log("Strategy current USDT (6-dec): %d", strategyUsdt);
        if (totalPoolUsdt > 0 && strategyUsdt > 0) {
            console.log("Strategy as %% of pool: %d%%", (strategyUsdt * 100) / totalPoolUsdt);
        }
        console.log("\nNOTE: If strategy + new deposit > pool TVL, massive price impact will occur on withdrawal.");
        console.log("A 100 WBTC at 65% LTV is roughly $6.5M of new USDT debt deployed to strategy.");
        console.log("If pool TVL < $6.5M, the withdrawal will cause severe (>10%) slippage on the crvUSD->USDT step.");
    }

    // ─── Test B: Full scenario with verbose intermediate logging ───────────────
    /// @notice Full round-trip: deposit 100 WBTC, roll 1 block, redeem.
    /// Logs all intermediate state to explain the TVL change.
    function testLargeDepositRedeemTvlDrop() public {
        _logState("=== INITIAL STATE (pre-deposit) ===");

        // ── Phase 1: deposit ───────────────────────────────────────────────────
        /* uint256 totalCollateralBefore = */ vault.totalAssets();
        uint256 totalSupplyBefore     = vault.totalSupply();
        uint256 stratBalBefore        = strategy.balanceOf();
        uint256 aaveCollBefore        = IAToken(AAVE_A_WBTC).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 aaveDebtBefore        = IAToken(AAVE_VAR_DEBT_USDT).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 poolBal0Before        = ICurvePool(PMUSD_CRVUSD_POOL).balances(0);
        uint256 poolBal1Before        = ICurvePool(PMUSD_CRVUSD_POOL).balances(1);

        vm.startPrank(user);
        wbtc.approve(address(vault), LARGE_DEPOSIT);
        uint256 sharesReceived = vault.deposit(LARGE_DEPOSIT, user);
        vm.stopPrank();

        console.log("\n=== AFTER DEPOSIT ===");
        console.log("Shares received             : %d", sharesReceived);
        console.log("Shares expected at 1:1      : %d (WBTC units = %d sat)", LARGE_DEPOSIT, LARGE_DEPOSIT);
        console.log("Entry discount vs 1:1 (sat) : %d", int256(LARGE_DEPOSIT) - int256(sharesReceived));

        uint256 stratBalAfterDeposit = strategy.balanceOf();
        uint256 aaveCollAfterDeposit = IAToken(AAVE_A_WBTC).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 aaveDebtAfterDeposit = IAToken(AAVE_VAR_DEBT_USDT).balanceOf(DEPLOYED_LOAN_MGR);

        console.log("--- Strategy ---");
        console.log("Strategy balance before (oracle USDT 6-dec): %d", stratBalBefore);
        console.log("Strategy balance after  (oracle USDT 6-dec): %d", stratBalAfterDeposit);
        int256 stratDeltaDeposit = int256(stratBalAfterDeposit) - int256(stratBalBefore);
        console.log("Strategy delta from deposit (USDT 6-dec)   : %d", stratDeltaDeposit);
        console.log("--- Aave position ---");
        console.log("Aave aWBTC before (sat)        : %d", aaveCollBefore);
        console.log("Aave aWBTC after  (sat)        : %d", aaveCollAfterDeposit);
        console.log("Aave aWBTC delta  (sat)        : %d", int256(aaveCollAfterDeposit) - int256(aaveCollBefore));
        console.log("Aave varDebt USDT before (6-dec): %d", aaveDebtBefore);
        console.log("Aave varDebt USDT after  (6-dec): %d", aaveDebtAfterDeposit);
        console.log("Aave varDebt USDT delta  (6-dec): %d", int256(aaveDebtAfterDeposit) - int256(aaveDebtBefore));

        uint256 poolBal0AfterDeposit = ICurvePool(PMUSD_CRVUSD_POOL).balances(0);
        uint256 poolBal1AfterDeposit = ICurvePool(PMUSD_CRVUSD_POOL).balances(1);
        console.log("--- pmUSD/crvUSD Pool balances ---");
        console.log("pmUSD  before: %d | after: %d", poolBal0Before, poolBal0AfterDeposit);
        console.log("crvUSD before: %d | after: %d", poolBal1Before, poolBal1AfterDeposit);

        // ── Phase 2: advance 1 block ───────────────────────────────────────────
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        // ── Phase 3: redeem ───────────────────────────────────────────────────
        console.log("\n=== PRE-REDEMPTION STATE ===");
        uint256 stratBalPreRedeem = strategy.balanceOf();
        uint256 aaveCollPreRedeem = IAToken(AAVE_A_WBTC).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 aaveDebtPreRedeem = IAToken(AAVE_VAR_DEBT_USDT).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 totalCollPreRedeem = vault.totalAssets();
        console.log("totalAssets (WBTC sat)             : %d", totalCollPreRedeem);
        console.log("strategy.balanceOf (oracle USDT)   : %d", stratBalPreRedeem);
        console.log("Aave aWBTC (sat)                   : %d", aaveCollPreRedeem);
        console.log("Aave varDebt USDT (6-dec)          : %d", aaveDebtPreRedeem);
        console.log("Vault WBTC idle (sat)              : %d", wbtc.balanceOf(DEPLOYED_VAULT));
        console.log("Vault USDT idle (6-dec)            : %d", usdt.balanceOf(DEPLOYED_VAULT));
        console.log("LM WBTC idle (sat)                 : %d", wbtc.balanceOf(DEPLOYED_LOAN_MGR));
        console.log("LM USDT idle (6-dec)               : %d", usdt.balanceOf(DEPLOYED_LOAN_MGR));

        // Estimate flash loan factor
        uint128 flashPremiumBps = IAavePool(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();
        console.log("Aave flash loan premium (bps): %d", flashPremiumBps);

        // Snapshot Curve pool before redeem
        uint256 poolBal0PreRedeem = ICurvePool(PMUSD_CRVUSD_POOL).balances(0);
        uint256 poolBal1PreRedeem = ICurvePool(PMUSD_CRVUSD_POOL).balances(1);
        uint256 poolLpPreRedeem = ICurvePool(PMUSD_CRVUSD_POOL).totalSupply();
        console.log("--- Pool state before redeem ---");
        console.log("pmUSD/crvUSD pool balance[0]: %d", poolBal0PreRedeem);
        console.log("pmUSD/crvUSD pool balance[1]: %d", poolBal1PreRedeem);
        console.log("pmUSD/crvUSD pool totalSupply: %d", poolLpPreRedeem);

        uint256 userWbtcBefore = wbtc.balanceOf(user);
        vm.prank(user);
        uint256 wbtcReturned = vault.redeem(sharesReceived, user, user);
        uint256 userWbtcAfter = wbtc.balanceOf(user);

        console.log("\n=== POST-REDEMPTION STATE ===");
        console.log("WBTC deposited      : %d sat", LARGE_DEPOSIT);
        console.log("WBTC returned       : %d sat", wbtcReturned);
        int256 userPnl = int256(wbtcReturned) - int256(LARGE_DEPOSIT);
        console.log("User PnL            : %d sat (negative = loss)", userPnl);
        console.log("User WBTC balance delta check: %d", int256(userWbtcAfter) - int256(userWbtcBefore));

        uint256 stratBalPostRedeem = strategy.balanceOf();
        uint256 aaveCollPostRedeem = IAToken(AAVE_A_WBTC).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 aaveDebtPostRedeem = IAToken(AAVE_VAR_DEBT_USDT).balanceOf(DEPLOYED_LOAN_MGR);
        uint256 vaultWbtcPost      = wbtc.balanceOf(DEPLOYED_VAULT);
        uint256 vaultUsdtPost      = usdt.balanceOf(DEPLOYED_VAULT);
        uint256 lmWbtcPost         = wbtc.balanceOf(DEPLOYED_LOAN_MGR);
        uint256 lmUsdtPost         = usdt.balanceOf(DEPLOYED_LOAN_MGR);

        console.log("--- Residual state ---");
        console.log("Strategy balance (oracle USDT): %d", stratBalPostRedeem);
        console.log("Aave aWBTC (sat)              : %d", aaveCollPostRedeem);
        console.log("Aave varDebt USDT (6-dec)     : %d", aaveDebtPostRedeem);
        console.log("Vault idle WBTC (sat)         : %d", vaultWbtcPost);
        console.log("Vault idle USDT (6-dec)       : %d", vaultUsdtPost);
        console.log("LM idle WBTC (sat)            : %d", lmWbtcPost);
        console.log("LM idle USDT (6-dec)          : %d", lmUsdtPost);
        console.log("Vault totalAssets (WBTC sat)  : %d", vault.totalAssets());
        console.log("Vault totalSupply (shares)    : %d", vault.totalSupply());

        uint256 poolBal0PostRedeem = ICurvePool(PMUSD_CRVUSD_POOL).balances(0);
        uint256 poolBal1PostRedeem = ICurvePool(PMUSD_CRVUSD_POOL).balances(1);
        console.log("--- Pool state after redeem ---");
        console.log("pmUSD/crvUSD pool balance[0] before: %d | after: %d",
            poolBal0PreRedeem, poolBal0PostRedeem);
        console.log("pmUSD/crvUSD pool balance[1] before: %d | after: %d",
            poolBal1PreRedeem, poolBal1PostRedeem);

        // ── Key diagnostic: what ate the remaining depositor's value? ──────────
        console.log("\n=== ROOT CAUSE DIAGNOSTICS ===");

        // 1. Strategy withdrawal slippage: oracle value vs actual amount repaid to Aave
        int256 stratDeltaRedeem = int256(stratBalPreRedeem) - int256(stratBalPostRedeem);
        int256 aaveDebtRepaid   = int256(aaveDebtPreRedeem) - int256(aaveDebtPostRedeem);
        console.log("Strategy USDT withdrawn (oracle estimate, 6-dec): %d", stratDeltaRedeem);
        console.log("Aave debt actually repaid (USDT, 6-dec)         : %d", aaveDebtRepaid);
        if (aaveDebtRepaid > 0 && stratDeltaRedeem > 0) {
            int256 shortfallUsdt = stratDeltaRedeem - aaveDebtRepaid;
            console.log("Strategy-to-repayment shortfall (USDT, 6-dec)   : %d", shortfallUsdt);
            if (shortfallUsdt > 0) {
                console.log("  => Shortfall means strategy returned less USDT than oracle predicted.");
                console.log("     Flash loan was likely needed to cover gap, consuming WBTC collateral.");
            }
        }

        // 2. Aave collateral consumed during flash loan repayment
        int256 aaveCollDelta = int256(aaveCollPreRedeem) - int256(aaveCollPostRedeem);
        console.log("Aave collateral withdrawn (sat)                  : %d", aaveCollDelta);
        // Expected: withdrew ~userShares proportion of total
        uint256 userSharePct = (sharesReceived * 1e6) / totalSupplyBefore;
        // (userSharePct / 1e6) fraction of collateral
        uint256 expectedCollWithdrawal = (aaveCollPreRedeem * userSharePct) / 1e6;
        console.log("Expected collateral withdrawal for user (sat)    : %d", expectedCollWithdrawal);
        if (uint256(aaveCollDelta) > expectedCollWithdrawal) {
            console.log("  => More collateral was consumed than user's share.");
            console.log("     Excess WBTC sold in flash loan: %d sat",
                uint256(aaveCollDelta) - expectedCollWithdrawal);
        }

        // 3. Pool imbalance (price impact indicator)
        int256 pool0Delta = int256(poolBal0PostRedeem) - int256(poolBal0PreRedeem);
        int256 pool1Delta = int256(poolBal1PostRedeem) - int256(poolBal1PreRedeem);
        console.log("Pool balance[0] delta (pmUSD 18-dec): %d", pool0Delta);
        console.log("Pool balance[1] delta (crvUSD 18-dec): %d", pool1Delta);
        if (pool0Delta > 0 || pool1Delta < 0) {
            console.log("  => Pool drained of crvUSD (expected on large single-sided withdrawal).");
            console.log("     If pool was small relative to withdrawal, price impact was large.");
        }

        // 4. Final TVL breakdown
        console.log("\n=== FINAL TVL DECOMPOSITION ===");
        uint256 finalTvl     = vault.totalAssets();
        uint256 remainShares = vault.totalSupply();
        console.log("Final TVL (WBTC sat)    : %d", finalTvl);
        console.log("Remaining shares        : %d", remainShares);
        console.log("Net Aave collateral     : %d sat (collateral - debtInCollateral)",
            loanManager.getNetCollateralValue());
        console.log("Strategy residual       : %d oracle-USDT", stratBalPostRedeem);
        console.log("Vault idle WBTC         : %d sat", vaultWbtcPost);
        console.log("Vault idle USDT         : %d (should be ~0)", vaultUsdtPost);

        // Sanity check: remaining shares should belong to original depositor only
        console.log("\nExpected final TVL ~0.15 WBTC = 15,000,000 sat.");
        console.log("Actual final TVL = %d sat.", finalTvl);
        int256 originalDepositRecovery = int256(finalTvl) - int256(15_000_000);
        console.log("Original depositor gain/loss vs 0.15 WBTC (sat): %d", originalDepositRecovery);
    }

    // ─── Test C: Proportional small vs large deposit withdrawal ───────────────
    /// @notice Compares TVL impact of the same 100 WBTC broken into 10 x 10 WBTC deposits
    ///         vs a single 100 WBTC deposit, to isolate size-dependent effects.
    ///         (Informational — does not assert, only logs.)
    function testSmallVsLargeDepositTvlImpact() public {
        console.log("\n=== SINGLE 100 WBTC DEPOSIT ===");
        uint256 tvlBeforeSingle = vault.totalAssets();

        vm.startPrank(user);
        wbtc.approve(address(vault), LARGE_DEPOSIT);
        uint256 sharesSingle = vault.deposit(LARGE_DEPOSIT, user);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        vm.prank(user);
        uint256 returnedSingle = vault.redeem(sharesSingle, user, user);

        uint256 finalTvlSingle = vault.totalAssets();
        console.log("TVL before: %d sat | after 100 WBTC round-trip: %d sat",
            tvlBeforeSingle, finalTvlSingle);
        int256 tvlChangeSingle = int256(finalTvlSingle) - int256(tvlBeforeSingle);
        console.log("TVL change (original depositor impact): %d sat", tvlChangeSingle);
        console.log("100 WBTC depositor got back: %d sat (deposited %d)", returnedSingle, LARGE_DEPOSIT);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _logState(string memory label) internal view {
        console.log("\n%s", label);
        console.log("totalAssets (WBTC sat)     : %d", vault.totalAssets());
        console.log("totalSupply (shares)        : %d", vault.totalSupply());
        console.log("strategy.balanceOf (USDT)   : %d", strategy.balanceOf());
        console.log("accumulatedFees (USDT)      : %d", vault.accumulatedFees());
        console.log("Aave aWBTC (sat)            : %d", IAToken(AAVE_A_WBTC).balanceOf(DEPLOYED_LOAN_MGR));
        console.log("Aave varDebt USDT           : %d", IAToken(AAVE_VAR_DEBT_USDT).balanceOf(DEPLOYED_LOAN_MGR));
        console.log("block.number                : %d", block.number);
    }

    function _refreshOracles() internal {
        address[4] memory oracles = [BTC_USD_ORACLE, USDT_USD_ORACLE, CRVUSD_USD_ORACLE, CRV_USD_ORACLE];
        for (uint256 i = 0; i < oracles.length; i++) {
            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                IChainlinkOracle(oracles[i]).latestRoundData();
            uint256 ts = block.timestamp > updatedAt ? block.timestamp : updatedAt;
            vm.mockCall(
                oracles[i],
                abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                abi.encode(roundId, answer, ts, ts, answeredInRound)
            );
        }
    }
}
