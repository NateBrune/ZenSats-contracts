// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { NgScrvUsdLpStakeDaoStrategy } from
    "../src/strategies/lp/NgScrvUsdLpStakeDaoStrategy.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

/// @title ScrvUsdNgStrategyFork
/// @notice Standalone fork test for the scrvUSD building block: NgScrvUsdLpStakeDaoStrategy on the
///         reUSD/scrvUSD Curve StableSwapNG pool (the deepest live scrvUSD pool, ~$7M) staked in
///         Stake DAO. Exercises the novel crvUSD⇄scrvUSD ERC-4626 wrap/unwrap legs and the
///         two-unit balanceOf bridge without the full vault harness — the test contract stands in
///         as the vault so it can drive deposit/withdraw directly.
/// @dev The scrvUSD coin index is derived from the pool at setUp, so the test is robust to coin
///      ordering. Run with a mainnet fork:
///        forge test --match-path test/ScrvUsdNgStrategy.fork.t.sol --fork-url $MAINNET_RPC_URL -vv
contract ScrvUsdNgStrategyFork is Test {
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant SCRVUSD = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;

    // reUSD/scrvUSD — deepest live scrvUSD NG pool, staked in Stake DAO.
    address constant POOL = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50;
    address constant SD_REWARD_VAULT = 0xC5F79C63715cc7F3d65818b6b7B585Eb5b00AA74;
    address constant GAUGE = 0xaF01d68714E7eA67f43f08b5947e367126B889b1;

    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;

    NgScrvUsdLpStakeDaoStrategy internal strategy;
    CrvToCrvUsdSwapper internal crvSwapper;
    int128 internal scrvIndex;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Derive the scrvUSD index from the pool (robust to coin ordering).
        scrvIndex = ICurveStableSwapNG(POOL).coins(0) == SCRVUSD ? int128(0) : int128(1);
        require(
            ICurveStableSwapNG(POOL).coins(uint256(uint128(scrvIndex))) == SCRVUSD,
            "scrvUSD not found in pool"
        );

        crvSwapper = new CrvToCrvUsdSwapper(
            address(this), CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        // vault == owner == this test contract, so deposit/withdraw (onlyVault) can be driven here.
        strategy = new NgScrvUsdLpStakeDaoStrategy(
            CRVUSD,
            address(this),
            address(this),
            POOL,
            SD_REWARD_VAULT,
            address(crvSwapper),
            GAUGE,
            scrvIndex,
            CRVUSD_USD_ORACLE,
            CRV_USD_ORACLE
        );
        crvSwapper.setAuthorizedCaller(address(strategy));
    }

    function _depositCrvUsd(uint256 amount) internal returns (uint256 underlyingDeposited) {
        deal(CRVUSD, address(this), amount);
        IERC20(CRVUSD).approve(address(strategy), amount);
        underlyingDeposited = strategy.deposit(amount);
    }

    // ============ Wiring ============

    function test_constructorWiring() public view {
        assertEq(address(strategy.SCRVUSD()), SCRVUSD, "scrvUSD wired");
        assertEq(strategy.lpCrvUsdIndex(), scrvIndex, "scrvUSD index stored");
        assertEq(address(strategy.lpAsset()), CRVUSD, "lpAsset is crvUSD");
        assertTrue(address(strategy.otherCoin()) != SCRVUSD, "otherCoin is the paired coin");
        assertGt(strategy.cachedVirtualPrice(), 0, "VP cache primed at deploy");
    }

    // ============ Deposit wraps crvUSD -> scrvUSD and stakes ============

    function test_depositWrapsAndStakes() public {
        uint256 amount = 100_000e18;
        _depositCrvUsd(amount);

        // Strategy now holds Stake DAO reward-vault shares (the staked LP).
        assertGt(
            IERC20(SD_REWARD_VAULT).balanceOf(address(strategy)), 0, "strategy holds staked LP"
        );

        // balanceOf reports in crvUSD (debt) terms and must track the deposit within slippage.
        uint256 bal = strategy.balanceOf();
        assertApproxEqRel(bal, amount, 0.01e18, "balanceOf within 1% of deposit");

        // Nothing is stranded at the strategy: crvUSD fully wrapped+added, no leftover scrvUSD.
        assertLt(IERC20(CRVUSD).balanceOf(address(strategy)), 1e15, "no stranded crvUSD");
        assertLt(IERC20(SCRVUSD).balanceOf(address(strategy)), 1e15, "no stranded scrvUSD");
    }

    // ============ Full round-trip: crvUSD -> LP -> crvUSD ============

    function test_roundTripWithinSlippage() public {
        uint256 amount = 100_000e18;
        _depositCrvUsd(amount);

        uint256 bal = strategy.balanceOf();
        uint256 received = strategy.withdraw(bal); // crvUSD sent back to vault (this contract)

        assertApproxEqRel(received, amount, 0.01e18, "round-trip within 1%");

        int256 bps = (int256(received) - int256(amount)) * 10_000 / int256(amount);
        if (bps >= 0) console.log("round-trip: +%d bps", uint256(bps));
        else console.log("round-trip: -%d bps", uint256(-bps));
    }

    // ============ Donation absorption ============

    /// @notice Donated other-coin (reUSD) and scrvUSD balances must be swept into the LP position
    ///         on the next deposit — they are protected from rescue, so the two-sided add is their
    ///         only way out of the contract.
    function test_donationsAbsorbedIntoPosition() public {
        address other = address(strategy.otherCoin());
        deal(other, address(strategy), 1_000e18); // donated reUSD
        deal(SCRVUSD, address(strategy), 1_000e18); // donated scrvUSD

        uint256 amount = 10_000e18;
        _depositCrvUsd(amount);

        assertEq(IERC20(other).balanceOf(address(strategy)), 0, "donated reUSD absorbed");
        assertLt(IERC20(SCRVUSD).balanceOf(address(strategy)), 1e15, "donated scrvUSD absorbed");

        // The ~2000 crvUSD-worth of donations lands in the position as a windfall on top of
        // the 10k deposit.
        assertGt(strategy.balanceOf(), amount + 1_500e18, "balance includes donation windfall");
    }

    // ============ Capacity sweep: round-trip cost vs deposit size ============

    /// @notice Deposit → immediate withdraw round-trip cost across sizes, to characterize the
    ///         exit-liquidity depth of the reUSD/scrvUSD leg. Reverts cleanly per-size are logged
    ///         rather than failing the suite (pool depth varies run-to-run at the unpinned block).
    function test_capacitySweep() public {
        uint256[] memory sizes = new uint256[](6);
        sizes[0] = 10_000e18;
        sizes[1] = 100_000e18;
        sizes[2] = 500_000e18;
        sizes[3] = 1_000_000e18;
        sizes[4] = 2_000_000e18;
        sizes[5] = 5_000_000e18;

        console.log("=== reUSD/scrvUSD round-trip cost sweep ===");
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshot();
            try this.probeRoundTrip(sizes[i]) returns (int256 bps) {
                if (bps >= 0) console.log("  %d crvUSD: +%d bps", sizes[i] / 1e18, uint256(bps));
                else console.log("  %d crvUSD: -%d bps", sizes[i] / 1e18, uint256(-bps));
            } catch {
                console.log("  %d crvUSD: REVERT (exceeds slippage budget / depth)", sizes[i] / 1e18);
            }
            vm.revertTo(snap);
        }
    }

    /// @dev External so the sweep can try/catch each size independently.
    function probeRoundTrip(uint256 amount) external returns (int256 bps) {
        require(msg.sender == address(this), "internal");
        _depositCrvUsd(amount);
        uint256 received = strategy.withdraw(strategy.balanceOf());
        bps = (int256(received) - int256(amount)) * 10_000 / int256(amount);
    }

    // ============ Worst-case: single-sided exit from a rebalanced pool ============

    /// @notice Deposit (skews pool scrvUSD-heavy), let an arb restore balance (paired coin → scrvUSD),
    ///         then exit single-sided from the balanced pool. Unlike the immediate round-trip — where
    ///         entry/exit impact cancels — this pays the full single-sided exit cost, the real number
    ///         the vault sees when it exits a position it has held.
    function test_roundTripAfterRebalance() public {
        uint256 amount = 500_000e18;
        _depositCrvUsd(amount);

        _arbRestoreBalance();

        uint256 received = strategy.withdraw(strategy.balanceOf());
        int256 bps = (int256(received) - int256(amount)) * 10_000 / int256(amount);
        if (bps >= 0) console.log("rebalanced round-trip (500k): +%d bps", uint256(bps));
        else console.log("rebalanced round-trip (500k): -%d bps", uint256(-bps));

        // Even the adversarial single-sided exit should stay within the 1% slippage budget.
        assertGe(bps, -100, "single-sided exit from balanced pool exceeds 1%");
    }

    /// @dev The strategy added scrvUSD single-sided, so the pool is scrvUSD-heavy. An arb sells the
    ///      paired coin in to buy back the excess scrvUSD, restoring the pre-deposit ratio. Fees from
    ///      that swap accrue to LP holders (the strategy).
    function _arbRestoreBalance() internal {
        ICurveStableSwapNG pool = ICurveStableSwapNG(POOL);
        uint256 otherIdx = scrvIndex == int128(0) ? 1 : 0;
        uint256 scrvBal = pool.balances(uint256(uint128(scrvIndex)));
        uint256 otherBal = pool.balances(otherIdx);
        if (scrvBal <= otherBal) return; // already balanced or other-heavy

        // Sell roughly half the imbalance in the paired coin to move the ratio back toward parity.
        uint256 otherToSwap = (scrvBal - otherBal) / 2;
        if (otherToSwap == 0) return;

        address other = address(strategy.otherCoin());
        address arb = makeAddr("arb");
        deal(other, arb, otherToSwap);
        vm.startPrank(arb);
        IERC20(other).approve(POOL, otherToSwap);
        pool.exchange(int128(uint128(otherIdx)), scrvIndex, otherToSwap, 0);
        vm.stopPrank();

        // Refresh the VP cache so the oracle floor reflects the arb's fee accrual.
        strategy.updateCachedVirtualPrice();
    }

    function test_withdrawAllClearsPosition() public {
        uint256 amount = 50_000e18;
        _depositCrvUsd(amount);

        uint256 received = strategy.withdrawAll();
        assertApproxEqRel(received, amount, 0.01e18, "withdrawAll within 1%");
        assertEq(
            IERC20(SD_REWARD_VAULT).balanceOf(address(strategy)), 0, "all LP unstaked and exited"
        );
    }
}
