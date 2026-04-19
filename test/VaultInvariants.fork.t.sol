// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiWbtcPmUsd } from "../src/implementations/ZenjiWbtcPmUsd.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { UniversalRouterV3SingleHopSwapper } from "../src/swappers/base/UniversalRouterV3SingleHopSwapper.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";

/// @title VaultInvariants
/// @notice Six scenario tests covering edge cases not caught by the original suite:
///   1. Withdrawal-ordering independence: no depositor should recover differently based on who exits first
///   2. Cumulative partial withdrawal tax: N chunked withdrawals ≈ one full withdrawal
///   3. Last-depositor cleanup: after full drain, no value is stranded in sub-contracts
///   4. Fee checkpoint resurrection: lastStrategyBalance resets cleanly after zero TVL
///   5. Non-zero flash loan premium: executeOperation handles real Aave fees without reverting
///   6. setIdle transition accounting: deposit-during-idle and re-deploy leave no value leak
///
/// Fork tests deploy FRESH contracts on each run — no shared mainnet state.
/// Non-fork tests (#5) use inline mocks.

contract VaultInvariants is Test {
    // ─── Mainnet protocol addresses (used by freshly-deployed contracts) ───────
    address constant WBTC              = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT              = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant BTC_USD_ORACLE    = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDT_USD_ORACLE   = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE    = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    // Aave V3
    address constant AAVE_POOL           = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC         = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT  = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // Uniswap V3
    address constant UNIVERSAL_ROUTER    = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24  constant WBTC_USDT_V3_FEE    = 3000;

    // pmUSD/crvUSD Stake DAO strategy
    address constant CRVUSD              = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV                 = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant PMUSD               = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;
    address constant USDT_CRVUSD_POOL    = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address constant PMUSD_CRVUSD_POOL   = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD_CRVUSD_GAUGE  = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_VAULT     = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRI      = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    int128  constant USDT_INDEX          = 0;
    int128  constant CRVUSD_INDEX        = 1;

    Zenji vault;
    IYieldStrategy strategy;
    ILoanManager loanManager;
    IERC20 wbtc;
    address owner;

    // Slippage / loss tolerance constants (basis points)
    uint256 constant ROUNDING_LOSS_BPS = 50;   // 0.5% – acceptable dust from rounding
    uint256 constant SLIPPAGE_LOSS_BPS = 100;  // 1%   – acceptable unwind slippage per withdrawal

    // ─── Test accounts ─────────────────────────────────────────────────────────
    address alice;
    address bob;
    address carol;
    address dave;
    address eve;
    // Snapshot taken after the one-time fork+deploy in setUp()
    uint256 private _forkSnapshot;

    // ═════════════════════════════════════════════════════════════════════════
    //  One-time setup: fork + deploy (runs once per test CONTRACT, not per run)
    // ═════════════════════════════════════════════════════════════════════════

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpcUrl);

        wbtc  = IERC20(WBTC);
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");
        dave  = makeAddr("dave");
        eve   = makeAddr("eve");

        _refreshOracles();
        _deployFresh();
        _refreshOracles();

        // Snapshot clean state after deploy. Each test/fuzz-run reverts here.
        _forkSnapshot = vm.snapshotState();
    }
    // ═══════════════════════════════════════════════════════════════════════════
    //  Shared helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reverts to the clean post-deploy snapshot. Called at the top of every
    ///      test and every fuzz run so each run starts with zero depositors.
    ///      Re-applies oracle mocks after revert because vm.mockCall state is NOT
    ///      restored by revertToState — stale mocks from prior runs can have
    ///      updatedAt > block.timestamp after revert, causing underflow in OracleLib.
    function _initFork() internal {
        vm.revertToState(_forkSnapshot);
        _refreshOracles();
    }

    /// @dev Deploy a brand-new vault + loan manager + strategy — no shared mainnet state.
    function _deployFresh() internal {
        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        CrvToCrvUsdSwapper crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRI, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        UniversalRouterV3SingleHopSwapper swapper = new UniversalRouterV3SingleHopSwapper(
            owner, WBTC, address(IERC20(USDT)), UNIVERSAL_ROUTER,
            WBTC_USDT_V3_FEE, BTC_USD_ORACLE, USDT_USD_ORACLE, 3_600
        );

        // Derive crvUSD LP index from the pool at fork time
        int128 lpCrvUsdIndex;
        {
            address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
            lpCrvUsdIndex = (coin0 == CRVUSD) ? int128(0) : int128(1);
        }

        PmUsdCrvUsdStrategy strat = new PmUsdCrvUsdStrategy(
            address(IERC20(USDT)), CRVUSD, CRV, PMUSD,
            address(0),   // vault — set later
            owner,
            USDT_CRVUSD_POOL, PMUSD_CRVUSD_POOL,
            STAKE_DAO_VAULT, address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            USDT_INDEX, CRVUSD_INDEX, lpCrvUsdIndex,
            CRVUSD_USD_ORACLE, USDT_USD_ORACLE, CRV_USD_ORACLE
        );

        AaveLoanManager lm = new AaveLoanManager(
            WBTC, address(IERC20(USDT)),
            AAVE_A_WBTC, AAVE_VAR_DEBT_USDT, AAVE_POOL,
            BTC_USD_ORACLE, USDT_USD_ORACLE,
            address(swapper),
            7300, 7800,
            address(0),  // vault — set later
            0,           // eMode disabled
            3600
        );

        ZenjiWbtcPmUsd v = new ZenjiWbtcPmUsd(
            address(lm), address(strat), address(swapper), owner, address(viewHelper)
        );

        lm.initializeVault(address(v));
        strat.initializeVault(address(v));
        vm.prank(owner);
        swapper.setVault(address(v));

        vault       = v;
        strategy    = IYieldStrategy(address(strat));
        loanManager = ILoanManager(address(lm));
    }

    /// @dev No-op — kept so existing test bodies don't need changing.
    function _patchVaultCode() internal {}

    function _refreshOracles() internal {
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        address[4] memory oracles =
            [BTC_USD_ORACLE, USDT_USD_ORACLE, CRVUSD_USD_ORACLE, CRV_USD_ORACLE];
        for (uint256 i = 0; i < oracles.length; i++) {
            (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
                IChainlinkOracle(oracles[i]).latestRoundData();
            // Always use block.timestamp — after vm.revertToState, stale mocks
            // can have updatedAt > block.timestamp causing underflow in OracleLib.
            vm.mockCall(
                oracles[i],
                abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
            );
        }
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        deal(WBTC, user, amount);
        vm.startPrank(user);
        wbtc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
        vm.roll(block.number + 1);
        _refreshOracles();
    }

    function _redeemAll(address user) internal returns (uint256 collateral) {
        uint256 shares = vault.balanceOf(user);
        require(shares > 0, "no shares");
        vm.prank(user);
        collateral = vault.redeem(shares, user, user);
        vm.roll(block.number + 1);
        _refreshOracles();
    }

    function _redeemFraction(address user, uint256 numerator, uint256 denominator)
        internal
        returns (uint256 collateral)
    {
        uint256 shares = vault.balanceOf(user) * numerator / denominator;
        require(shares > 0, "no shares for fraction");
        vm.prank(user);
        collateral = vault.redeem(shares, user, user);
        vm.roll(block.number + 1);
        _refreshOracles();
    }

    /// @dev Share-price based value estimate (same formula as vault)
    function _valueOf(address user) internal view returns (uint256) {
        uint256 shares = vault.balanceOf(user);
        if (shares == 0) return 0;
        uint256 offset = vault.VIRTUAL_SHARE_OFFSET();
        return shares * (vault.totalAssets() + offset) / (vault.totalSupply() + offset);
    }

    function _assertWithinBps(uint256 a, uint256 b, uint256 toleranceBps, string memory label)
        internal
        pure
    {
        uint256 larger = a > b ? a : b;
        uint256 diff   = a > b ? a - b : b - a;
        // avoid division by zero on truly zero amounts
        if (larger == 0) return;
        uint256 deviationBps = diff * 10_000 / larger;
        assertLe(
            deviationBps,
            toleranceBps,
            string(abi.encodePacked(label, ": deviation exceeds tolerance"))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 1: Withdrawal ordering independence
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Three depositors enter at a 3:5:2 ratio. We run three orderings and assert
    // each depositor's recovery ratio is within SLIPPAGE_LOSS_BPS of the others
    // regardless of who exits first. If ordering matters, the fix introduces bias.

    /// @notice Scenario helper: three depositors, exits in given order, returns their recoveries
    function _threeDepositorRound(
        uint256 d0, uint256 d1, uint256 d2,
        uint256[3] memory order  // indices into [alice,bob,carol]
    )
        internal
        returns (uint256[3] memory got)
    {
        _initFork();
        _patchVaultCode();

        uint256[3] memory deposits = [d0, d1, d2];
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory shares;

        for (uint256 i = 0; i < 3; i++) {
            shares[i] = _deposit(users[i], deposits[i]);
        }

        // Withdraw in the requested order
        for (uint256 step = 0; step < 3; step++) {
            uint256 idx = order[step];
            got[idx] = _redeemAll(users[idx]);
        }
    }

    function testInvariant_withdrawOrder_ABC() public {
        uint256[3] memory got = _threeDepositorRound(
            3e8, 5e8, 2e8,
            [uint256(0), 1, 2]  // A, B, C
        );

        uint256 r0 = got[0] * 10_000 / 3e8;  // recovery bps
        uint256 r1 = got[1] * 10_000 / 5e8;
        uint256 r2 = got[2] * 10_000 / 2e8;

        console.log("=== ORDER A,B,C ===");
        console.log("Alice recovery bps:  %d", r0);
        console.log("Bob   recovery bps:  %d", r1);
        console.log("Carol recovery bps:  %d", r2);

        // All three should recover within SLIPPAGE_LOSS_BPS of each other
        _assertWithinBps(r0, r1, SLIPPAGE_LOSS_BPS * 2, "A-first vs B-second");
        _assertWithinBps(r1, r2, SLIPPAGE_LOSS_BPS * 2, "B-second vs C-last");

        // Everyone should get back at least 95% of their deposit
        assertGe(got[0], 3e8 * 95 / 100, "Alice < 95% recovery");
        assertGe(got[1], 5e8 * 95 / 100, "Bob   < 95% recovery");
        assertGe(got[2], 2e8 * 95 / 100, "Carol < 95% recovery");
    }

    function testInvariant_withdrawOrder_CBA() public {
        uint256[3] memory got = _threeDepositorRound(
            3e8, 5e8, 2e8,
            [uint256(2), 1, 0]  // C, B, A
        );

        uint256 r0 = got[0] * 10_000 / 3e8;
        uint256 r1 = got[1] * 10_000 / 5e8;
        uint256 r2 = got[2] * 10_000 / 2e8;

        console.log("=== ORDER C,B,A ===");
        console.log("Alice recovery bps:  %d", r0);
        console.log("Bob   recovery bps:  %d", r1);
        console.log("Carol recovery bps:  %d", r2);

        _assertWithinBps(r0, r1, SLIPPAGE_LOSS_BPS * 2, "A-last vs B-middle");
        _assertWithinBps(r1, r2, SLIPPAGE_LOSS_BPS * 2, "B-middle vs C-first");

        assertGe(got[0], 3e8 * 95 / 100, "Alice < 95% recovery");
        assertGe(got[1], 5e8 * 95 / 100, "Bob   < 95% recovery");
        assertGe(got[2], 2e8 * 95 / 100, "Carol < 95% recovery");
    }

    /// @notice Fuzz: for any three deposit amounts, the last-to-exit never recovers
    ///         materially less than the first-to-exit when the vault is healthy.
    function testFuzz_withdrawOrder_lastNotPunished(
        uint256 rawA, uint256 rawB, uint256 rawC
    ) public {
        // Lower bound at 0.05 WBTC — the minimum realistic deposit for this strategy.
        uint256 dA = bound(rawA, 5e6, 5e8);
        uint256 dB = bound(rawB, 5e6, 5e8);
        uint256 dC = bound(rawC, 5e6, 5e8);

        console.log("=== FUZZ WITHDRAW ORDER ===");
        console.log("dA=%d dB=%d dC=%d", dA, dB, dC);
        console.log("Total TVL = %d sat (%d WBTC)", dA + dB + dC, (dA + dB + dC) / 1e8);

        // Run A-first then C-first orderings
        uint256[3] memory gotFirst = _threeDepositorRound(
            dA, dB, dC, [uint256(0), 1, 2]
        );
        uint256[3] memory gotLast = _threeDepositorRound(
            dA, dB, dC, [uint256(2), 1, 0]
        );

        // ── Round-trip: in vs out ─────────────────────────────────────────────
        // Positive net = gained sats; negative net = lost sats (slippage/fees).
        bool firstNet_positive = gotFirst[0] >= dA;
        uint256 firstNet_abs   = firstNet_positive ? gotFirst[0] - dA : dA - gotFirst[0];
        bool lastNet_positive  = gotLast[0] >= dA;
        uint256 lastNet_abs    = lastNet_positive  ? gotLast[0]  - dA : dA - gotLast[0];

        console.log("Alice deposited:   %d sat", dA);
        console.log("Alice first-out:   %d sat", gotFirst[0]);
        if (firstNet_positive) {
            console.log("  net (first):    +%d sat (+%d bps)", firstNet_abs, firstNet_abs * 10_000 / dA);
        } else {
            console.log("  net (first):    -%d sat (-%d bps)", firstNet_abs, firstNet_abs * 10_000 / dA);
        }
        console.log("Alice last-out:    %d sat", gotLast[0]);
        if (lastNet_positive) {
            console.log("  net (last):     +%d sat (+%d bps)", lastNet_abs, lastNet_abs * 10_000 / dA);
        } else {
            console.log("  net (last):     -%d sat (-%d bps)", lastNet_abs, lastNet_abs * 10_000 / dA);
        }

        // ── Ordering sensitivity ──────────────────────────────────────────────
        uint256 larger = gotFirst[0] > gotLast[0] ? gotFirst[0] : gotLast[0];
        uint256 diff   = gotFirst[0] > gotLast[0] ? gotFirst[0] - gotLast[0] : gotLast[0] - gotFirst[0];
        uint256 devBps = larger > 0 ? diff * 10_000 / larger : 0;
        uint256 orderingLoss = diff / 2; // each side differs by half the spread vs midpoint

        console.log("Ordering spread:   %d sat  (%d bps of deposit, tolerance: %d)",
            orderingLoss,
            orderingLoss * 10_000 / dA,
            SLIPPAGE_LOSS_BPS
        );
        console.log("Deviation bps:     %d / 10000", devBps);

        // Alice's recovery should not differ dramatically based on her exit order.
        // With 0.05-5 WBTC deposits, Curve unwind slippage is modest; ordering
        // sensitivity beyond 100 bps signals a vault accounting bug.
        _assertWithinBps(
            gotFirst[0], gotLast[0],
            SLIPPAGE_LOSS_BPS,
            "Alice recovery changed by ordering"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 2: Cumulative partial withdrawal tax
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Hypothesis: if the fix creates extra slippage on each partial unwind, then
    // a user who splits their withdrawal into N chunks pays more total slippage than
    // one who withdraws everything at once.
    //
    // We compare:
    //   - Alice: one full redemption
    //   - Bob: 5 redemptions of 20% each (same starting deposit)
    // Both users share the vault, so each fork run is independent.

    function testInvariant_chunkedWithdrawal_noCumulativeTax() public {
        // ─── Run A: single withdrawal ───────────────────────────────────────
        _initFork();
        _patchVaultCode();

        uint256 depositAmount = 5e8; // 5 WBTC

        uint256 aliceShares = _deposit(alice, depositAmount);
        // A second depositor to keep the vault non-trivially funded during partial withdrawals
        _deposit(bob, 10e8);

        (aliceShares); // used
        uint256 singleWithdrawal = _redeemAll(alice);

        // ─── Run B: 5×20% withdrawals ───────────────────────────────────────
        _initFork();  // fresh fork resets all state
        _patchVaultCode();

        _deposit(alice, depositAmount);
        _deposit(bob, 10e8);

        uint256 chunkedTotal;
        // Redeem 1/5 each time. After 4 chunks Alice still has ~20% left; final chunk cleans up.
        for (uint256 i = 0; i < 4; i++) {
            // Always redeem 1/(5-i) of remaining shares to get equal-chunk behaviour
            // Simpler: just redeem 20% of original shares each time
            uint256 chunk = vault.balanceOf(alice) / (5 - i);
            vm.prank(alice);
            chunkedTotal += vault.redeem(chunk, alice, alice);
            vm.roll(block.number + 1);
            _refreshOracles();
        }
        // Final chunk (all remaining)
        chunkedTotal += _redeemAll(alice);

        console.log("=== CHUNKED vs SINGLE WITHDRAWAL ===");
        console.log("Single withdrawal:   %d sat", singleWithdrawal);
        console.log("Chunked (5 pieces):  %d sat", chunkedTotal);
        int256 diff = int256(chunkedTotal) - int256(singleWithdrawal);
        console.log("Difference:          %d sat", diff);

        // Chunked must not recover MORE than 1% less than single (no compounding tax)
        uint256 toleranceSat = singleWithdrawal / 100;
        assertGe(
            chunkedTotal + toleranceSat,
            singleWithdrawal,
            "Chunked (5x) withdrawal recovered >1% less than single withdrawal -- slippage compounding"
        );
    }

    /// @notice Fuzz: for random chunk counts (2–10) and deposit sizes, chunking does not
    ///         compound materially more slippage than a single withdrawal.
    function testFuzz_chunkedWithdrawal_noCumulativeTax(
        uint256 rawDeposit,
        uint256 rawChunks
    ) public {
        uint256 depositAmount = bound(rawDeposit, 1e8, 10e8);  // 1–10 WBTC
        uint256 chunks        = bound(rawChunks,  2,    8);

        // ─── Single withdrawal baseline ─────────────────────────────────────
        _initFork();
        _patchVaultCode();
        _deposit(alice, depositAmount);
        _deposit(bob, depositAmount * 2); // background depositor
        uint256 singleGot = _redeemAll(alice);

        // ─── Chunked withdrawals ─────────────────────────────────────────────
        _initFork();
        _patchVaultCode();
        _deposit(alice, depositAmount);
        _deposit(bob, depositAmount * 2);

        uint256 chunkedTotal;
        for (uint256 i = 0; i < chunks - 1; i++) {
            uint256 remaining = vault.balanceOf(alice);
            uint256 chunk = remaining / (chunks - i);
            if (chunk == 0) chunk = remaining;
            vm.prank(alice);
            chunkedTotal += vault.redeem(chunk, alice, alice);
            vm.roll(block.number + 1);
            _refreshOracles();
        }
        chunkedTotal += _redeemAll(alice);

        console.log("Chunks=%d deposit=%d sat", chunks, depositAmount);
        console.log("  single=%d sat chunked=%d sat", singleGot, chunkedTotal);

        // Allow 1% tolerance to account for gas/rounding, not compounding slippage
        uint256 tolerance = singleGot / 100;
        assertGe(
            chunkedTotal + tolerance,
            singleGot,
            "Chunked withdrawal suffered cumulative slippage tax"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 3: Last depositor cleanup — no stranded value
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // After the final depositor redeems (isFinalWithdraw path), all sub-contracts
    // should be drained: zero debt, zero collateral, zero strategy balance, zero
    // idle debt/collateral in the vault itself.

    function testInvariant_lastDepositor_noStrandedValue() public {
        _initFork();
        _patchVaultCode();

        // Alice is the only depositor
        _deposit(alice, 2e8);

        // Full redeem → isFinalWithdraw path
        uint256 received = _redeemAll(alice);

        console.log("=== LAST DEPOSITOR CLEANUP ===");
        console.log("Alice received:              %d sat", received);
        console.log("Debt remaining:              %d", loanManager.getCurrentDebt());
        console.log("Collateral remaining:        %d", loanManager.getCurrentCollateral());
        console.log("Strategy balance remaining:  %d", strategy.balanceOf());
        console.log("Vault USDT balance:          %d", IERC20(USDT).balanceOf(address(vault)));
        console.log("Vault WBTC balance:          %d", wbtc.balanceOf(address(vault)));
        console.log("totalSupply after:           %d", vault.totalSupply());

        // All positions fully closed
        assertEq(loanManager.getCurrentDebt(), 0, "Debt not cleared after final withdrawal");
        assertEq(loanManager.getCurrentCollateral(), 0, "Collateral not cleared after final withdrawal");

        // Strategy fully exited
        assertEq(strategy.balanceOf(), 0, "Strategy not cleared after final withdrawal");

        // Vault holds nothing (no dust USDT, no orphaned collateral)
        assertEq(
            IERC20(USDT).balanceOf(address(vault)), 0,
            "Vault holds residual USDT after final withdrawal"
        );
        assertEq(
            wbtc.balanceOf(address(vault)), 0,
            "Vault holds residual WBTC after final withdrawal"
        );

        // totalSupply is 0
        assertEq(vault.totalSupply(), 0, "totalSupply not zero after final withdrawal");

        // Alice got something meaningful
        assertGt(received, 0, "Alice received nothing");
        // Should recover at least 95% of 2 WBTC deposited
        assertGe(received, 2e8 * 95 / 100, "Alice recovered <95%");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 4: Fee checkpoint resurrection after zero TVL
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // After a complete drain (single depositor → full redeem), lastStrategyBalance
    // and accumulatedFees should both be 0. A new depositor after the drain should
    // not be incorrectly charged fees against a stale baseline.

    function testInvariant_feeCheckpoint_clearedAfterFullDrain() public {
        _initFork();
        _patchVaultCode();

        // Confirm fee rate is non-zero (otherwise no charge is possible)
        uint256 feeRate = vault.feeRate();
        if (feeRate == 0) {
            console.log("SKIP: feeRate == 0, no fees to check");
            return;
        }

        // Era 1: Alice deposits and fully redeems (singletons use isFinalWithdraw path)
        _deposit(alice, 2e8);

        // Do a full redeem — clears strategy
        _redeemAll(alice);

        // Check storage: lastStrategyBalance and accumulatedFees should both be 0
        uint256 lastStratBal = vault.lastStrategyBalance();
        uint256 accFees      = vault.accumulatedFees();

        console.log("=== FEE CHECKPOINT AFTER DRAIN ===");
        console.log("lastStrategyBalance after drain: %d", lastStratBal);
        console.log("accumulatedFees after drain:     %d", accFees);

        assertEq(lastStratBal, 0, "lastStrategyBalance not reset after full drain");
        assertEq(accFees, 0, "accumulatedFees not reset after full drain");

        // Era 2: Bob deposits fresh after the drain
        _deposit(bob, 2e8);

        uint256 lastStratBalAfterBob = vault.lastStrategyBalance();
        console.log("lastStrategyBalance after Bob deposits: %d", lastStratBalAfterBob);

        // Bob's deposit should set a fresh checkpoint -- not erroneously charge fees from era 1
        // accumulatedFees immediately after deposit should be ~0 (no yield earned yet)
        uint256 pendingFees = vault.accumulatedFees();
        console.log("accumulatedFees immediately after Bob deposits: %d", pendingFees);

        // Allow a tiny rounding tolerance but no structural fee overcharge
        assertLe(
            pendingFees,
            lastStratBalAfterBob / 1000,  // < 0.1% of strategy balance = rounding, not a real charge
            "New depositor charged fees from prior era's strategy balance"
        );

        // Bob should be able to redeem without unexpected fee overhang
        uint256 bobReceived = _redeemAll(bob);
        assertGe(bobReceived, 2e8 * 95 / 100, "Bob recovered <95%: fee checkpoint issue");
        console.log("Bob received: %d sat", bobReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 5: Non-zero flash loan premium handled correctly
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // The MockAavePool in the unit tests passes premium=0. Real Aave charges ~5 bps.
    // This verifies that executeOperation handles a non-zero fee without reverting
    // or leaving residual debt. This is a unit test (no fork needed).

    function testUnit_flashLoanFee_handledCorrectly() public {
        // This test uses the unit test mock infrastructure inline.
        // We import the relevant contracts and set them up manually so there's
        // no fork dependency.
        _runFlashLoanFeeTest(9); // 9 bps — above Aave's actual 5 bps for extra margin
    }

    function testFuzz_flashLoanFee_anyFeeHandled(uint256 rawFeeBps) public {
        // Test any fee from 0 to 30 bps (realistic Aave range is 0–9 bps)
        uint256 feeBps = bound(rawFeeBps, 0, 30);
        _runFlashLoanFeeTest(feeBps);
    }

    function _runFlashLoanFeeTest(uint256 feeBps) internal {
        // Deploy mock infrastructure
        MockERC20Flash collateral = new MockERC20Flash("WBTC", "WBTC", 8);
        MockERC20Flash debt       = new MockERC20Flash("USDT", "USDT", 6);
        MockERC20Flash aToken     = new MockERC20Flash("aWBTC", "aWBTC", 8);
        MockERC20Flash vDebt      = new MockERC20Flash("vUSDT", "vUSDT", 6);
        MockSwapper    swapper    = new MockSwapper(collateral, debt);
        MockOracle collOracle     = new MockOracle(8,  int256(85_000e8));  // $85k BTC
        MockOracle debtOracle     = new MockOracle(8,  int256(1e8));       // $1 USDT
        FeeAwareAavePool pool     = new FeeAwareAavePool(
            address(collateral), address(debt), address(aToken), address(vDebt)
        );
        pool.setFeeBps(feeBps);

        address vaultAddr = makeAddr("vaultForFlashTest");

        AaveLoanManagerFlash mgr = new AaveLoanManagerFlash(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collOracle),
            address(debtOracle),
            address(swapper),
            vaultAddr
        );

        // Set up a position: 100 collateral, 65 debt (createLoan requires onlyVault)
        collateral.mint(address(mgr), 100e8);
        vm.prank(vaultAddr);
        mgr.createLoan(100e8, 65e6);
        // Clear the borrowed debt from manager so it simulates "deployed to strategy"
        debt.burnFrom(address(mgr), debt.balanceOf(address(mgr)));

        // Full unwind — exercises the flash loan path with a real fee
        vm.prank(vaultAddr);
        mgr.unwindPosition(type(uint256).max);

        console.log("=== FLASH LOAN FEE TEST (feeBps=%d) ===", feeBps);
        console.log("Debt after unwind:       %d", vDebt.balanceOf(address(mgr)));
        console.log("Collateral returned:     %d", collateral.balanceOf(vaultAddr));

        assertEq(vDebt.balanceOf(address(mgr)), 0, "Residual debt after fee-bearing flash loan");
        assertGt(collateral.balanceOf(vaultAddr), 0, "No collateral returned after fee-bearing flash loan");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Test 6: setIdle transition accounting — no value leak at mode boundaries
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Flow:
    //   1. Alice deposits 3 WBTC (strategy active)
    //   2. gov calls setIdle(true) — unwinds position, holds collateral idle
    //   3. Bob deposits 2 WBTC during idle (no strategy deployment)
    //   4. gov calls setIdle(false) — redeploys combined collateral
    //   5. Both users redeem
    // Invariant: combined recovered ≈ combined deposited (within slippage bounds)
    // and neither party exploits the mode transition to capture value from the other.

    function testInvariant_idleTransition_noValueLeak() public {
        _initFork();
        _patchVaultCode();

        // ─── Step 1: Alice deposits ───────────────────────────────────────────
        uint256 aliceDeposit = 3e8;
        uint256 aliceShares  = _deposit(alice, aliceDeposit);
        assertGt(strategy.balanceOf(), 0, "Strategy should be funded after Alice's deposit");

        // ─── Step 2: Enter idle ───────────────────────────────────────────────
        vm.prank(owner);
        vault.setIdle(true);
        assertTrue(vault.idle(), "Vault should be in idle mode");

        uint256 debtAfterIdle = loanManager.getCurrentDebt();
        uint256 collAfterIdle = loanManager.getCurrentCollateral();
        console.log("=== AFTER setIdle(true) ===");
        console.log("Loan manager debt:       %d", debtAfterIdle);
        console.log("Loan manager collateral: %d", collAfterIdle);
        console.log("Strategy balance:        %d", strategy.balanceOf());

        // Position should be unwound
        assertEq(debtAfterIdle, 0,      "Debt should be 0 after entering idle");
        assertEq(debtAfterIdle, 0,      "Debt should be 0 after entering idle"); // repeated for clarity
        assertEq(strategy.balanceOf(), 0, "Strategy should be cleared after entering idle");

        // ─── Step 3: Bob deposits during idle ────────────────────────────────
        uint256 bobDeposit = 2e8;
        uint256 bobShares  = _deposit(bob, bobDeposit);
        assertEq(strategy.balanceOf(), 0, "Strategy should stay 0 in idle mode");

        // ─── Step 4: Exit idle — redeploy ────────────────────────────────────
        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);
        assertFalse(vault.idle(), "Vault should be active again");

        _refreshOracles();
        console.log("=== AFTER setIdle(false) ===");
        console.log("Strategy balance:        %d", strategy.balanceOf());
        console.log("Loan manager debt:       %d", loanManager.getCurrentDebt());

        assertGt(loanManager.getCurrentDebt(), 0,      "Position should be re-established");
        assertGt(strategy.balanceOf(), 0,              "Strategy should be re-funded");

        // ─── Step 5: Both redeem ─────────────────────────────────────────────
        uint256 aliceGot = _redeemAll(alice);
        uint256 bobGot   = _redeemAll(bob);

        console.log("=== IDLE TRANSITION RESULTS ===");
        console.log("Alice deposited: %d sat, received: %d sat", aliceDeposit, aliceGot);
        console.log("Bob   deposited: %d sat, received: %d sat", bobDeposit, bobGot);
        int256 aliceDelta = int256(aliceGot) - int256(aliceDeposit);
        int256 bobDelta   = int256(bobGot)   - int256(bobDeposit);
        console.log("Alice delta: %d sat", aliceDelta);
        console.log("Bob   delta: %d sat", bobDelta);

        // Both should recover at least 95% (2× slippage budget: enter idle + re-enter)
        assertGe(aliceGot, aliceDeposit * 95 / 100, "Alice recovered <95% through idle transition");
        assertGe(bobGot,   bobDeposit   * 95 / 100, "Bob recovered <95% depositing into idle vault");

        // Neither user should have extracted value from the other at mode transition.
        // Proportional fairness: ratio of (received/deposited) should be within 5% for both.
        uint256 aliceRatioBps = aliceGot * 10_000 / aliceDeposit;
        uint256 bobRatioBps   = bobGot   * 10_000 / bobDeposit;
        console.log("Alice recovery bps: %d", aliceRatioBps);
        console.log("Bob   recovery bps: %d", bobRatioBps);

        _assertWithinBps(aliceRatioBps, bobRatioBps, 500, "Idle transition creates unfair value split");

        // Verify supply is zero after both exit (no orphaned shares)
        assertEq(vault.totalSupply(), 0, "Shares stranded after both users exit");
    }

    /// @notice Fuzz: for any deposit sizes, the idle transition stays fair
    function testFuzz_idleTransition_bothUsersProtected(
        uint256 rawAlice, uint256 rawBob
    ) public {
        uint256 aliceDeposit = bound(rawAlice, 5e7, 5e8);  // 0.5–5 WBTC
        uint256 bobDeposit   = bound(rawBob,   5e7, 5e8);

        _initFork();
        _patchVaultCode();

        _deposit(alice, aliceDeposit);

        vm.prank(owner);
        vault.setIdle(true);

        _deposit(bob, bobDeposit);

        _refreshOracles();
        vm.prank(owner);
        vault.setIdle(false);

        _refreshOracles();

        uint256 aliceGot = _redeemAll(alice);
        uint256 bobGot   = _redeemAll(bob);

        assertGe(aliceGot, aliceDeposit * 95 / 100, "Alice <95% through fuzz idle transition");
        assertGe(bobGot,   bobDeposit   * 95 / 100, "Bob   <95% through fuzz idle transition");

        uint256 aliceRatioBps = aliceGot * 10_000 / aliceDeposit;
        uint256 bobRatioBps   = bobGot   * 10_000 / bobDeposit;
        _assertWithinBps(aliceRatioBps, bobRatioBps, 500, "Fuzz idle transition unfair");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Inline mock contracts for Test 5 (unit test, no fork)
// ═══════════════════════════════════════════════════════════════════════════════

import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";

contract MockERC20Flash {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public minter;

    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }

    function setMinter(address m) external { minter = m; }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply    += amt;
    }

    function burnFrom(address from, uint256 amt) external {
        require(balanceOf[from] >= amt, "burn exceeds balance");
        balanceOf[from] -= amt;
        totalSupply     -= amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt);
        balanceOf[msg.sender] -= amt;
        balanceOf[to]         += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= amt;
        require(balanceOf[from] >= amt, "ERC20: insufficient");
        balanceOf[from] -= amt;
        balanceOf[to]   += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

contract MockSwapper is ISwapper {
    MockERC20Flash public immutable collateralToken;
    MockERC20Flash public immutable debtToken;

    constructor(MockERC20Flash c, MockERC20Flash d) { collateralToken = c; debtToken = d; }

    /// @dev 1 WBTC ≈ $85,000 → 1 sat = 850 micro-USDT (8-dec in, 6-dec out)
    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount / 850;
    }

    /// @dev AaveLoanManager pushes collateral here before calling; we mint debt to caller.
    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256 debtReceived) {
        debtReceived = collateralAmount * 850;
        debtToken.mint(msg.sender, debtReceived);
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256 collateralReceived) {
        collateralReceived = debtAmount / 850;
        collateralToken.mint(msg.sender, collateralReceived);
    }
}

contract MockOracle {
    uint8 public immutable decimals;
    int256 public price;

    constructor(uint8 d, int256 p) { decimals = d; price = p; }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Aave mock that charges a configurable flash loan fee
contract FeeAwareAavePool is IAavePool {
    MockERC20Flash public immutable coll;
    MockERC20Flash public immutable debtAsset;
    MockERC20Flash public immutable aToken;
    MockERC20Flash public immutable variableDebtToken;
    uint256 public feeBps;

    constructor(address c, address d, address a, address v) {
        coll = MockERC20Flash(c);
        debtAsset = MockERC20Flash(d);
        aToken = MockERC20Flash(a);
        variableDebtToken = MockERC20Flash(v);
    }

    function setFeeBps(uint256 bps) external { feeBps = bps; }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        MockERC20Flash(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20Flash(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        uint256 actualDebt = variableDebtToken.balanceOf(onBehalfOf);
        uint256 repayAmount = amount == type(uint256).max ? actualDebt : amount;
        if (repayAmount > actualDebt) repayAmount = actualDebt;
        MockERC20Flash(asset).transferFrom(msg.sender, address(this), repayAmount);
        variableDebtToken.burnFrom(onBehalfOf, repayAmount);
        return repayAmount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 burnAmt = amount > bal ? bal : amount;
        aToken.burnFrom(msg.sender, burnAmt);
        MockERC20Flash(asset).transfer(to, burnAmt);
        return burnAmt;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        uint256 premium = amount * feeBps / 10_000;
        MockERC20Flash(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, premium, receiverAddress, params);
        MockERC20Flash(asset).transferFrom(receiverAddress, address(this), amount + premium);
    }

    function setUserEMode(uint8) external {}
    function getUserEMode(address) external pure returns (uint256) { return 0; }
}

/// @notice Thin AaveLoanManager subclass wired to the full 14-arg constructor.
contract AaveLoanManagerFlash is AaveLoanManager {
    constructor(
        address collateral_,
        address debt_,
        address aToken_,
        address vDebt_,
        address pool_,
        address collOracle_,
        address debtOracle_,
        address swapper_,
        address vault_
    )
        AaveLoanManager(
            collateral_,
            debt_,
            aToken_,
            vDebt_,
            pool_,
            collOracle_,
            debtOracle_,
            swapper_,
            7500,   // maxLtvBps
            8000,   // liquidationThresholdBps
            vault_,
            0,      // emodeCategory — disabled
            3600    // maxCollateralStaleness — 1 hour
        )
    {}
}
