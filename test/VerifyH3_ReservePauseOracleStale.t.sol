// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice PoC for H-3: Aave Reserve Pause + Oracle Stale -> permanent WBTC collateral loss
///
/// Hypothesis H-3 (as described in hypotheses.md / chain agent notes):
///   IF Aave WBTC or USDT reserve is paused (EP-2) AND BTC/USD oracle is stale >1h (OR-1),
///   THEN Guardian is forced to call emergencySkipStep(1), permanently stranding ALL WBTC
///   collateral in Aave with no recovery path, BECAUSE neither emergencyStep(1) nor
///   emergencyRescue(0) can unwind the Aave position when the oracle is stale AND the reserve
///   is paused simultaneously.
///
/// Goal of this PoC: verify whether emergencyRescue(0) — which calls
/// loanManager.transferCollateral -> aavePool.withdraw WITHOUT an oracle freshness check —
/// provides a recovery path that bypasses H-1's oracle DoS when the reserve is NOT paused,
/// but is itself blocked when the reserve IS paused, jointly creating permanent loss.
///
/// Key code references:
///   - AaveLoanManager.transferCollateral (line 561-575): NO _checkOracleFreshness() call.
///     Transfers idle collateral first, then aavePool.withdraw() for the remainder.
///   - Zenji.emergencyRescue(0) (line 745-757): calls ZenjiCoreLib.executeEmergencyRescue
///     -> loanManager.transferCollateral(vault, balance)
///   - Zenji.emergencySkipStep (line 728-734): only sets bitmask, never unwinds.
///
/// Reserve pause semantics (Aave V3): when reservePaused=true, supply/withdraw/borrow/repay
/// all revert with RESERVE_PAUSED. No oracle is consulted on this path.

import { Test, console } from "forge-std/Test.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { OracleLib } from "../src/libraries/OracleLib.sol";

contract H3MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function burnFrom(address f, uint256 a) external {
        _burn(f, a);
    }
}

contract H3MockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 p) {
        decimals = d;
        price = p;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 u) external {
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}

/// @notice Mock Aave pool that can be "paused" to simulate Aave reserve pause
contract H3MockAavePool is IAavePool {
    IERC20 public immutable coll;
    IERC20 public immutable dbt;
    H3MockERC20 public immutable aToken;
    H3MockERC20 public immutable variableDebtToken;

    // Reserve pause flags (Aave V3 semantics — pause applies per-reserve)
    bool public collateralReservePaused;
    bool public debtReservePaused;

    error ReservePaused();

    constructor(address _c, address _d, address _a, address _dt) {
        coll = IERC20(_c);
        dbt = IERC20(_d);
        aToken = H3MockERC20(_a);
        variableDebtToken = H3MockERC20(_dt);
    }

    function setCollateralReservePaused(bool p) external {
        collateralReservePaused = p;
    }

    function setDebtReservePaused(bool p) external {
        debtReservePaused = p;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (asset == address(coll) && collateralReservePaused) revert ReservePaused();
        if (asset == address(dbt) && debtReservePaused) revert ReservePaused();
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        if (asset == address(dbt) && debtReservePaused) revert ReservePaused();
        H3MockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        if (asset == address(dbt) && debtReservePaused) revert ReservePaused();
        uint256 debtBal = variableDebtToken.balanceOf(onBehalfOf);
        uint256 toRepay = amount > debtBal ? debtBal : amount;
        IERC20(asset).transferFrom(msg.sender, address(this), toRepay);
        variableDebtToken.burnFrom(onBehalfOf, toRepay);
        return toRepay;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // Aave V3: withdraw is blocked when the withdrawn reserve is paused
        if (asset == address(coll) && collateralReservePaused) revert ReservePaused();
        if (asset == address(dbt) && debtReservePaused) revert ReservePaused();
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 burnAmount = amount == type(uint256).max ? bal : (amount > bal ? bal : amount);
        aToken.burnFrom(msg.sender, burnAmount);
        IERC20(asset).transfer(to, burnAmount);
        return burnAmount;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        // Aave V3: flashloans also blocked on paused reserve
        if (asset == address(dbt) && debtReservePaused) revert ReservePaused();
        H3MockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }

    function setUserEMode(uint8) external { }

    function getUserEMode(address) external pure returns (uint256) {
        return 0;
    }
}

contract H3MockSwapper is ISwapper {
    function quoteCollateralForDebt(uint256 a) external pure returns (uint256) {
        return a;
    }

    function swapCollateralForDebt(uint256) external pure returns (uint256) {
        return 0;
    }

    function swapDebtForCollateral(uint256) external pure returns (uint256) {
        return 0;
    }

    function slippage() external pure returns (uint256) {
        return 1e16;
    }
}

contract VerifyH3_ReservePauseOracleStale is Test {
    H3MockERC20 collateral;
    H3MockERC20 debt;
    H3MockERC20 aToken;
    H3MockERC20 vDebt;
    H3MockAavePool pool;
    H3MockOracle btcOracle;
    H3MockOracle usdtOracle;
    H3MockSwapper swapper;
    AaveLoanManager aaveManager;

    address vault = makeAddr("vault");

    uint256 constant BTC_STALENESS = 3600;
    uint256 constant USDT_STALENESS = 90_000;
    uint256 constant COLLATERAL_AMT = 100e8;
    uint256 constant DEBT_AMT = 65_000e6;

    function setUp() public {
        vm.warp(1_000_000); // reasonable starting timestamp

        collateral = new H3MockERC20("WBTC", "WBTC", 8);
        debt = new H3MockERC20("USDT", "USDT", 6);
        aToken = new H3MockERC20("aWBTC", "aWBTC", 8);
        vDebt = new H3MockERC20("vUSDT", "vUSDT", 6);

        pool = new H3MockAavePool(address(collateral), address(debt), address(aToken), address(vDebt));

        btcOracle = new H3MockOracle(8, 100_000e8);
        usdtOracle = new H3MockOracle(8, 1e8);
        swapper = new H3MockSwapper();

        aaveManager = new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(btcOracle),
            address(usdtOracle),
            address(swapper),
            7500,
            8000,
            vault,
            0,
            BTC_STALENESS
        );

        // Seed the manager with collateral and create the loan as the vault
        collateral.mint(address(aaveManager), COLLATERAL_AMT);
        vm.prank(vault);
        aaveManager.createLoan(COLLATERAL_AMT, DEBT_AMT);
    }

    function _makeOracleStale() internal {
        // Force BTC oracle stale by warping beyond the 3600s window
        vm.warp(block.timestamp + BTC_STALENESS + 10);
        // Keep USDT oracle fresh by nudging its updatedAt to "now"
        usdtOracle.setUpdatedAt(block.timestamp);
    }

    // --- PHASE 1: ATTACKER — prove the compound blocks all recovery paths ---

    /// @notice With only oracle stale (reserve active): H-1 blocks unwindPosition, but
    /// emergencyRescue(0) -> transferCollateral -> aavePool.withdraw still works.
    /// This is the baseline that makes H-3 distinct from H-1.
    function testH3_OracleStaleAlone_RescuePathWorks() public {
        _makeOracleStale();

        // unwindPosition reverts (H-1 confirmed behavior)
        vm.prank(vault);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.unwindPosition(type(uint256).max);

        // BUT transferCollateral has NO oracle check — it calls aavePool.withdraw directly.
        // If the position still has outstanding debt, Aave would revert on withdraw
        // due to health-factor enforcement. To isolate the oracle-freshness question,
        // we first let the guardian repay debt using a debt balance already held by the
        // loan manager (simulating emergency rescue of debt first, or accrued balance).
        // This models the "debt already cleared via emergencyRescue(1) + externally repaid"
        // scenario used to demonstrate the oracle-bypass path.
        //
        // In the real protocol: emergencyRescue(1) sweeps debt from manager to vault,
        // then vault can approve + call loanManager.repayDebt — but repayDebt itself calls
        // _checkOracleFreshness() and would revert. So this path is only clean when
        // there is no outstanding debt in the first place.
        //
        // Narrow claim: IF there is no outstanding debt (e.g. small positions where debt was
        // repaid pre-oracle-stale), transferCollateral succeeds and recovers collateral
        // despite oracle staleness. This is the "rescue path" H-3 claims is blocked by pause.
        vm.prank(vault);
        // Burn debt to simulate a debt-free position
        vDebt.burnFrom(address(aaveManager), DEBT_AMT);

        uint256 collBefore = collateral.balanceOf(vault);
        vm.prank(vault);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);
        uint256 collAfter = collateral.balanceOf(vault);

        assertEq(collAfter - collBefore, COLLATERAL_AMT, "rescue should move WBTC to vault");
        console.log("Oracle-stale alone: rescue path recovered", COLLATERAL_AMT, "WBTC");
    }

    /// @notice With ONLY reserve paused (oracle fresh): unwindPosition reverts inside the Aave
    /// calls. emergencyRescue(0) also reverts because aavePool.withdraw is blocked by pause.
    /// This confirms reserve-pause alone blocks the rescue path.
    function testH3_ReservePausedAlone_RescuePathBlocked() public {
        pool.setCollateralReservePaused(true);

        // No debt to sidestep health-factor issue
        vm.prank(vault);
        vDebt.burnFrom(address(aaveManager), DEBT_AMT);

        // transferCollateral -> aavePool.withdraw reverts on paused reserve
        vm.prank(vault);
        vm.expectRevert(H3MockAavePool.ReservePaused.selector);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);

        console.log("Reserve-paused alone: rescue path BLOCKED by pause");
    }

    /// @notice Compound: reserve paused + oracle stale. H-3's exact scenario.
    /// emergencyStep(1) reverts on oracle. emergencyRescue(0) reverts on pause.
    /// Guardian has no on-chain path to recover WBTC until either condition lifts.
    function testH3_Compound_BothPathsBlocked() public {
        // Oracle stale
        _makeOracleStale();
        // Reserve paused
        pool.setCollateralReservePaused(true);
        pool.setDebtReservePaused(true);

        // Path 1: emergencyStep(1) -> unwindPosition -> _checkOracleFreshness reverts first
        vm.prank(vault);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.unwindPosition(type(uint256).max);

        // Path 2: emergencyRescue(0) -> transferCollateral -> aavePool.withdraw reverts on pause
        // Even if we imagine the debt had been cleared out-of-band (which itself is blocked
        // by pause via repay()), the withdraw still reverts.
        vm.prank(vault);
        vDebt.burnFrom(address(aaveManager), DEBT_AMT);
        vm.prank(vault);
        vm.expectRevert(H3MockAavePool.ReservePaused.selector);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);

        console.log("Compound H-3: BOTH unwindPosition and transferCollateral BLOCKED");
    }

    /// @notice If guardian calls emergencySkipStep(1), the bitmask is set and the vault can
    /// proceed to step 2 (liquidationComplete). But transferCollateral is STILL blocked by
    /// pause, so WBTC remains stranded in Aave even after liquidationComplete. Users in the
    /// pro-rata distribution path see 0 WBTC in the vault.
    function testH3_SkipThenRescue_StillBlockedByPause() public {
        _makeOracleStale();
        pool.setCollateralReservePaused(true);

        // Drop debt to sidestep orthogonal constraints — H-3 is about the pause block, not debt
        vm.prank(vault);
        vDebt.burnFrom(address(aaveManager), DEBT_AMT);

        // Simulate the Guardian calling emergencySkipStep(1): bitmask only, no call to Aave.
        // (We don't exercise the Zenji vault here — that's covered by H-1 / CH-2. What we're
        //  testing is whether a post-skip rescue path exists when the reserve remains paused.)
        // emergencyRescue(0) still calls transferCollateral.
        vm.prank(vault);
        vm.expectRevert(H3MockAavePool.ReservePaused.selector);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);

        // Confirm WBTC is still in Aave
        assertEq(
            aToken.balanceOf(address(aaveManager)),
            COLLATERAL_AMT,
            "WBTC still stranded post-skip when reserve remains paused"
        );
        console.log("Post-skip rescue blocked: 100 WBTC ($10M at $100k/BTC) stranded in Aave");
    }

    // --- PHASE 2: DEFENDER — is there ANY path to recover WBTC during the compound? ---

    /// @notice Check whether IDLE collateral (never posted to Aave) is still transferable.
    /// transferCollateral first moves idle balance before calling aavePool.withdraw, so if the
    /// manager happened to hold idle collateral, that portion could still be rescued.
    function testH3_IdleCollateralStillRescuable() public {
        _makeOracleStale();
        pool.setCollateralReservePaused(true);

        // Simulate leftover idle balance on the manager (e.g. residual from a prior partial
        // unwind that transferred aToken out but left some direct balance).
        uint256 idleAmount = 1e8; // 1 WBTC idle
        collateral.mint(address(aaveManager), idleAmount);

        uint256 before_ = collateral.balanceOf(vault);
        vm.prank(vault);
        // transferCollateral idle-first path: covers idle portion before reaching aavePool.withdraw
        // If we request only the idle amount, aavePool.withdraw is never called.
        aaveManager.transferCollateral(vault, idleAmount);
        uint256 after_ = collateral.balanceOf(vault);
        assertEq(after_ - before_, idleAmount, "idle portion recovered");

        // But any amount exceeding idle will fall through to aavePool.withdraw and revert
        vm.prank(vault);
        vm.expectRevert(H3MockAavePool.ReservePaused.selector);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);

        console.log("Defender: idle-only portion recoverable; Aave-locked portion stranded");
    }

    /// @notice If Aave governance unpauses the reserve OR the oracle recovers, rescue becomes
    /// possible. This is a temporary DoS that lifts automatically when either condition clears.
    function testH3_Recovery_WhenPauseLifts() public {
        _makeOracleStale();
        pool.setCollateralReservePaused(true);

        vm.prank(vault);
        vDebt.burnFrom(address(aaveManager), DEBT_AMT);

        // While paused -> blocked
        vm.prank(vault);
        vm.expectRevert(H3MockAavePool.ReservePaused.selector);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);

        // Unpause — rescue succeeds despite stale oracle (transferCollateral has no oracle check)
        pool.setCollateralReservePaused(false);
        vm.prank(vault);
        aaveManager.transferCollateral(vault, COLLATERAL_AMT);
        assertEq(collateral.balanceOf(vault), COLLATERAL_AMT, "WBTC recovered after unpause");

        console.log("Recovery confirmed: rescue succeeds once Aave reserve is unpaused");
    }
}
