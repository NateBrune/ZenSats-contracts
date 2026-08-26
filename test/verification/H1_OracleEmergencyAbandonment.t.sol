// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title H1: Oracle outage defeats emergency escape -> silent LP abandonment
///
/// HYPOTHESIS (HIGH):
///   When the crvUSD/USD or USDT/USD Chainlink feed is stale > 25h (MAX_USDT_CRVUSD_STALENESS
///   = 90000s), BOTH withdrawAll() AND emergencyWithdraw() of the USDT-debt LP strategy revert
///   through the SAME oracle-gated path:
///     _withdrawAll()/_emergencyWithdraw()
///       -> _swapYieldAssetToDebt(...) [UsdtCrvUsdLpStakeDaoStrategy._crvUsdToUsdt]
///       -> CurveUsdtSwapLib.swapCrvUsdToUsdt
///       -> _oracleFloor18to6 -> _getOraclePrices -> revert StaleOrInvalidOracle
///
///   Inside ZenjiCoreLib.executeEmergencyStep(step=0) the double-catch swallows BOTH reverts,
///   leaving `withdrawn = 0`. ZenjiAdmin.emergencyStep then UNCONDITIONALLY sets
///   `emergencyStepsCompleted |= 0x1` and emits EmergencyYieldRedeemed(0). The LP capital is
///   still fully staked in Stake DAO, but the step is marked done -- with NO 3-day gov veto that
///   the explicit emergencySkipStep(0) path requires.
///
/// EXPECTED (correct): an emergency that recovers nothing should NOT silently mark step 0 done.
/// ACTUAL (buggy):     step 0 marked done, LP abandoned, EmergencyYieldRedeemed(0).
///
/// This test uses a mock harness (real Zenji
/// vault + real UsdtCrvUsdLpStakeDaoStrategy + real ZenjiAdmin + real CurveUsdtSwapLib;
/// only the external Curve pools / oracles / Stake DAO vault are mocked). The oracle staleness
/// revert is REAL audited-code behavior (CurveUsdtSwapLib.StaleOrInvalidOracle).

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../../src/Zenji.sol";
import { ZenjiViewHelper } from "../../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../../src/lenders/AaveLoanManager.sol";
import {
    UsdtCrvUsdLpStakeDaoStrategy
} from "../../src/strategies/lp/UsdtCrvUsdLpStakeDaoStrategy.sol";
import { CurveUsdtSwapLib } from "../../src/libraries/CurveUsdtSwapLib.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IAavePool } from "../../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mocks (external Curve pools / oracles / Stake DAO vault) ============

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;

    constructor(uint8 d, int256 p) {
        decimals = d;
        price = p;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 p) external {
        price = p;
        updatedAt = block.timestamp;
    }

    /// @notice Push updatedAt > 25h into the past to force StaleOrInvalidOracle.
    function setStale() external {
        updatedAt = block.timestamp - 100000;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

/// @notice USDT<->crvUSD pool with 6/18 dec scaling.
contract MockCurveStableSwap {
    MockERC20 public immutable usdt;
    MockERC20 public immutable crvUSD;
    int128 public immutable usdtIdx;
    int128 public immutable crvUsdIdx;

    constructor(address _usdt, address _crvUSD, int128 _usdtIdx, int128 _crvUsdIdx) {
        usdt = MockERC20(_usdt);
        crvUSD = MockERC20(_crvUSD);
        usdtIdx = _usdtIdx;
        crvUsdIdx = _crvUsdIdx;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        if (i == usdtIdx && j == crvUsdIdx) {
            usdt.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx * 1e12;
            crvUSD.mint(msg.sender, out);
            return out;
        }
        if (i == crvUsdIdx && j == usdtIdx) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx / 1e12;
            usdt.mint(msg.sender, out);
            return out;
        }
        return 0;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if (i == usdtIdx && j == crvUsdIdx) return dx * 1e12;
        if (i == crvUsdIdx && j == usdtIdx) return dx / 1e12;
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        if (i == uint256(uint128(usdtIdx))) return address(usdt);
        if (i == uint256(uint128(crvUsdIdx))) return address(crvUSD);
        return address(0);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice Legacy 2-coin crvUSD pool with LP minting.
contract MockCurveStableSwapNG {
    MockERC20 public immutable crvUSD;
    MockERC20 public otherCoin;
    MockERC20 public lpToken;
    int128 public immutable crvUsdIdx;
    uint256 public otherCoinIdx;

    constructor(address _crvUSD, int128 _crvUsdIdx) {
        crvUSD = MockERC20(_crvUSD);
        crvUsdIdx = _crvUsdIdx;
        otherCoinIdx = _crvUsdIdx == int128(0) ? 1 : 0;
    }

    function setLpToken(address _lpToken) external {
        lpToken = MockERC20(_lpToken);
    }

    function setOtherCoin(address _otherCoin) external {
        otherCoin = MockERC20(_otherCoin);
    }

    function add_liquidity(uint256[2] calldata amounts, uint256) external returns (uint256) {
        uint256 crvUsdAmount = amounts[uint256(uint128(crvUsdIdx))];
        uint256 otherCoinAmount = amounts[otherCoinIdx];
        if (crvUsdAmount > 0) crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount);
        if (otherCoinAmount > 0 && address(otherCoin) != address(0)) {
            otherCoin.transferFrom(msg.sender, address(this), otherCoinAmount);
        }
        uint256 totalMinted = crvUsdAmount + otherCoinAmount;
        if (totalMinted > 0) lpToken.mint(msg.sender, totalMinted);
        return totalMinted;
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external
        returns (uint256)
    {
        lpToken.transferFrom(msg.sender, address(this), burn_amount);
        crvUSD.mint(msg.sender, burn_amount);
        return burn_amount;
    }

    function calc_token_amount(uint256[2] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIdx))] + amounts[otherCoinIdx];
    }

    function calc_withdraw_one_coin(uint256 burn_amount, int128) external pure returns (uint256) {
        return burn_amount;
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }

    function N_COINS() external pure returns (uint256) {
        return 2;
    }

    function coins(uint256 i) external view returns (address) {
        return i == uint256(uint128(crvUsdIdx)) ? address(crvUSD) : address(otherCoin);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }

    function exchange(int128, int128, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function get_dy(int128, int128, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockAccountant {
    MockERC20 public rewardToken;
    mapping(address => mapping(address => uint256)) public rewards;

    constructor(address _rewardToken) {
        rewardToken = MockERC20(_rewardToken);
    }

    function setRewards(address account, uint256 amount) external {
        rewards[address(0)][account] = amount;
    }

    function getPendingRewards(address, address account) external view returns (uint256) {
        return rewards[address(0)][account];
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        uint256 pending = rewards[address(0)][receiver];
        if (pending > 0) {
            rewards[address(0)][receiver] = 0;
            rewardToken.mint(receiver, pending);
        }
    }
}

contract MockRewardVault is ERC4626 {
    MockERC20 public rewardToken;
    address public immutable _accountant;
    mapping(address => uint256) public pendingRewards;

    constructor(address _lpToken, address _rewardToken, address accountant_)
        ERC4626(OZ_IERC20(_lpToken))
        ERC20("Mock Reward Vault", "mRV")
    {
        rewardToken = MockERC20(_rewardToken);
        _accountant = accountant_;
    }

    function ACCOUNTANT() external view returns (address) {
        return _accountant;
    }

    function addRewards(address account, uint256 amount) external {
        pendingRewards[account] += amount;
        MockAccountant(_accountant).setRewards(account, pendingRewards[account]);
    }
}

contract MockCrvSwapper {
    MockERC20 public immutable crv;
    MockERC20 public immutable crvUSD;

    constructor(address _crv, address _crvUSD) {
        crv = MockERC20(_crv);
        crvUSD = MockERC20(_crvUSD);
    }

    function swap(uint256 amount) external returns (uint256) {
        crvUSD.mint(msg.sender, amount);
        return amount;
    }
}

contract MockSwapper {
    MockERC20 public immutable collateral;
    MockERC20 public immutable debt;

    constructor(address _collateral, address _debt) {
        collateral = MockERC20(_collateral);
        debt = MockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) {
        return d;
    }

    function swapCollateralForDebt(uint256 a) external returns (uint256) {
        debt.mint(msg.sender, a);
        return a;
    }

    function swapDebtForCollateral(uint256 a) external returns (uint256) {
        collateral.mint(msg.sender, a);
        return a;
    }

    function setSlippage(uint256) external { }
}

contract MockAavePool is IAavePool {
    IERC20 public immutable collateral;
    IERC20 public immutable debtAsset;
    MockERC20 public immutable aToken;
    MockERC20 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        collateral = IERC20(_collateral);
        debtAsset = IERC20(_debtAsset);
        aToken = MockERC20(_aToken);
        variableDebtToken = MockERC20(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        variableDebtToken.burnFrom(onBehalfOf, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 burnAmount = amount;
        uint256 balance = aToken.balanceOf(msg.sender);
        if (burnAmount > balance) burnAmount = balance;
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
        MockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }

    function setUserEMode(uint8) external { }

    function getUserEMode(address) external pure returns (uint256) {
        return 0;
    }
}

// ============ Verification Contract ============

contract H1_OracleEmergencyAbandonmentTest is Test {
    MockERC20 wbtc;
    MockERC20 usdt;
    MockERC20 crvUSD;
    MockERC20 crv;
    MockERC20 otherCoin;
    MockERC20 lpToken;
    MockERC20 aToken;
    MockERC20 debtToken;

    MockAavePool aavePool;
    MockOracle collateralOracle;
    MockOracle debtOracle;
    MockOracle crvUsdOracle;
    MockOracle usdtOracle;
    MockOracle crvOracle;
    MockCurveStableSwap usdtCrvUsdPool;
    MockCurveStableSwapNG lpPool;
    MockAccountant accountant;
    MockRewardVault rewardVault;
    MockCrvSwapper crvSwapper;

    AaveLoanManager loanManager;
    UsdtCrvUsdLpStakeDaoStrategy strategy;
    Zenji vault;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner"); // gov + strategist + guardian in this single-owner deploy
    address user = makeAddr("user");

    event EmergencyYieldRedeemed(uint256 debtAssetReceived);

    function setUp() public {
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usdt = new MockERC20("USDT", "USDT", 6);

        bytes memory erc20Code = address(new MockERC20("x", "x", 18)).code;
        vm.etch(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, erc20Code); // CRVUSD
        vm.etch(0xD533a949740bb3306d119CC777fa900bA034cd52, erc20Code); // crv
        crvUSD = MockERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        crv = MockERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
        otherCoin = new MockERC20("OTHER", "OTHER", 18);
        lpToken = new MockERC20("USDT/crvUSD LP", "LP", 18);
        aToken = new MockERC20("aWBTC", "aWBTC", 8);
        debtToken = new MockERC20("vUSDT", "vUSDT", 6);

        aavePool =
            new MockAavePool(address(wbtc), address(usdt), address(aToken), address(debtToken));
        collateralOracle = new MockOracle(8, 1e8);
        debtOracle = new MockOracle(8, 1e8);
        crvUsdOracle = new MockOracle(8, 1e8);
        usdtOracle = new MockOracle(8, 1e8);
        crvOracle = new MockOracle(8, 0.5e8);

        usdtCrvUsdPool = new MockCurveStableSwap(address(usdt), address(crvUSD), 0, 1);
        lpPool = new MockCurveStableSwapNG(address(crvUSD), 1);
        lpPool.setLpToken(address(lpToken));
        lpPool.setOtherCoin(address(otherCoin));
        accountant = new MockAccountant(address(crv));
        rewardVault = new MockRewardVault(address(lpToken), address(crv), address(accountant));
        crvSwapper = new MockCrvSwapper(address(crv), address(crvUSD));
        address gauge = makeAddr("pmusdGauge");

        viewHelper = new ZenjiViewHelper();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        MockSwapper swapper = new MockSwapper(address(wbtc), address(usdt));

        loanManager = new AaveLoanManager(
            address(wbtc),
            address(usdt),
            address(aToken),
            address(debtToken),
            address(aavePool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            predictedVault,
            0,
            3600
        );

        strategy = new UsdtCrvUsdLpStakeDaoStrategy(
            address(usdt),
            predictedVault,
            owner,
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            gauge,
            0, // usdtIndex
            1, // crvUsdIndex
            1, // lpCrvUsdIndex
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle),
            "USDT -> USDT/crvUSD LP Strategy"
        );

        vault = new Zenji(
            address(wbtc),
            address(usdt),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == predictedVault, "Vault address mismatch");

        wbtc.mint(user, 10e8);
        vm.prank(user);
        wbtc.approve(address(vault), type(uint256).max);
    }

    /// @notice Helper: refresh the loan-manager oracles (BTC/USDT for Aave path) WITHOUT
    ///         refreshing the strategy's crvUSD/USDT swap oracles, isolating the LP-swap revert.
    function _refreshLoanOracles() internal {
        collateralOracle.setPrice(collateralOracle.price());
        debtOracle.setPrice(debtOracle.price());
    }

    /// @notice FIX VERIFICATION: with a stale crvUSD/USD oracle, emergencyStep(0) emits
    ///         EmergencyYieldRedeemed(0) but does NOT mark step 0 complete — the guardian
    ///         must retry after the oracle heals, or use the timelocked emergencySkipStep(0).
    function test_H1_oracleStale_step0_abandonsLP_silently() public {
        // 1. User deposits -> LP position created and staked in Stake DAO.
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 lpStakedBefore = rewardVault.balanceOf(address(strategy));
        uint256 strategyValueBefore = strategy.balanceOf();
        assertGt(lpStakedBefore, 0, "precondition: LP must be staked");
        assertGt(strategyValueBefore, 0, "precondition: strategy must report value");

        console.log("=== BEFORE EMERGENCY ===");
        console.log("Stake DAO LP shares held by strategy:", lpStakedBefore);
        console.log("Strategy reported value (USDT 6dec):", strategyValueBefore);

        // 2. Oracle outage: crvUSD/USD feed goes stale (> 25h). This is the exact condition that
        //    triggers the emergency in the first place. Keep loan-manager oracles fresh so this
        //    isolates the strategy-swap revert (the bug under test).
        vm.warp(block.timestamp + 100001);
        crvUsdOracle.setStale();
        _refreshLoanOracles();

        // Sanity: confirm BOTH withdrawAll() and emergencyWithdraw() revert on the SAME oracle path.
        vm.prank(address(vault));
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        strategy.withdrawAll();

        vm.prank(address(vault));
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        strategy.emergencyWithdraw();

        console.log("Confirmed: withdrawAll() AND emergencyWithdraw() both revert StaleOrInvalidOracle");

        // 3. Guardian runs the emergency escape: enter + step 0.
        vm.prank(owner);
        vault.enterEmergencyMode();

        // The double-catch in ZenjiCoreLib.executeEmergencyStep(0) swallows both reverts.
        // Step 0 therefore does NOT revert and emits EmergencyYieldRedeemed(0).
        vm.expectEmit(true, true, true, true, address(vault));
        emit EmergencyYieldRedeemed(0);
        vm.prank(owner);
        vault.emergencyStep(0);

        // 4. Observe the abandonment.
        uint8 stepsCompleted = vault.emergencyStepsCompleted();
        uint256 lpStakedAfter = rewardVault.balanceOf(address(strategy));
        uint256 vaultUsdtAfter = usdt.balanceOf(address(vault));

        console.log("=== AFTER emergencyStep(0) ===");
        console.log("emergencyStepsCompleted bitmask:", stepsCompleted);
        console.log("Stake DAO LP shares STILL held by strategy:", lpStakedAfter);
        console.log("USDT recovered to vault:", vaultUsdtAfter);

        // FIX ASSERTION 1: step 0 is NOT marked complete — nothing was recovered.
        assertEq(stepsCompleted & 0x1, 0, "FIX: step 0 must NOT be marked when nothing recovered");

        // FIX ASSERTION 2: LP remains staked (the guardian must retry or skip explicitly).
        assertEq(lpStakedAfter, lpStakedBefore, "LP still staked: guardian must retry");
        assertEq(vaultUsdtAfter, 0, "no USDT recovered yet");

        // FIX ASSERTION 3: because step 0 is NOT yet resolved, emergencySkipStep(0) is
        // available and properly timelocked — the guardian can use the vetoed skip path.
        vm.prank(owner);
        vault.emergencySkipStep(0); // first call: proposes skip with 3-day delay (should NOT revert)

        console.log("[H1 FIX VERIFIED] Step 0 not marked; guardian can retry or use timelocked skip.");
    }

    /// @notice FIX VERIFICATION: with a stale oracle, emergencyStep(0) does NOT mark step 0
    ///         complete, so the guardian is forced to use the properly-gated emergencySkipStep(0)
    ///         (3-day delay with gov-veto window) rather than having silent silent bypass.
    function test_H1_emergencyRescue2_alsoBlockedByStaleOracle() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 lpStakedBefore = rewardVault.balanceOf(address(strategy));
        assertGt(lpStakedBefore, 0, "precondition: LP staked");

        vm.warp(block.timestamp + 100001);
        crvUsdOracle.setStale();
        _refreshLoanOracles();

        vm.prank(owner);
        vault.enterEmergencyMode();

        // With the fix: emergencyStep(0) does NOT mark step 0 complete when oracle is stale.
        vm.prank(owner);
        vault.emergencyStep(0);
        assertEq(vault.emergencyStepsCompleted() & 0x1, 0, "step 0 resolved");

        // LP is still staked — no silent abandonment.
        assertEq(
            rewardVault.balanceOf(address(strategy)),
            lpStakedBefore,
            "LP still staked: stale oracle correctly blocks step 0 completion"
        );

        // The guardian's only recourse is emergencySkipStep(0) (3-day timelocked, gov-vetoable).
        vm.prank(owner);
        vault.emergencySkipStep(0); // first call: proposes skip (should succeed)

        console.log("[H1 FIX] Step 0 not silently resolved; guardian must use timelocked skip path.");
    }

    /// @notice CONTRAST: with FRESH oracles, the same step 0 actually recovers the LP to USDT.
    ///         Proves the abandonment is caused specifically by oracle staleness, not by setup.
    function test_H1_freshOracle_step0_recoversLP() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 lpStakedBefore = rewardVault.balanceOf(address(strategy));
        assertGt(lpStakedBefore, 0, "precondition: LP staked");

        vm.prank(owner);
        vault.enterEmergencyMode();

        // Oracles are fresh here.
        vm.prank(owner);
        vault.emergencyStep(0);

        uint256 lpStakedAfter = rewardVault.balanceOf(address(strategy));
        uint256 vaultUsdtAfter = usdt.balanceOf(address(vault));

        assertEq(lpStakedAfter, 0, "fresh oracle: LP fully unstaked");
        assertGt(vaultUsdtAfter, 0, "fresh oracle: USDT recovered to vault");

        console.log("[H1 CONTRAST] Fresh oracle: LP recovered, USDT to vault:", vaultUsdtAfter);
    }

    /// @notice SEVERITY BOUND (devil's advocate): emergencyStep() does NOT guard against
    ///         re-execution of an already-completed step (no `if (completed & 0x1) revert`).
    ///         So once the Chainlink feed RECOVERS, the guardian can call emergencyStep(0)
    ///         AGAIN and recover the LP. This proves the abandonment is RECOVERABLE (temporary),
    ///         NOT a permanent loss -- the impact is a recovery-delay + a bypassed gov-veto +
    ///         a misleading EmergencyYieldRedeemed(0) signal, while step 2 could be reached
    ///         prematurely if the guardian doesn't notice nothing was recovered.
    function test_H1_recoverable_afterOracleHeals() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 lpStakedBefore = rewardVault.balanceOf(address(strategy));
        assertGt(lpStakedBefore, 0, "precondition: LP staked");

        // Oracle outage -> guardian does the (failed-silently) step 0.
        vm.warp(block.timestamp + 100001);
        crvUsdOracle.setStale();
        _refreshLoanOracles();

        vm.prank(owner);
        vault.enterEmergencyMode();
        vm.prank(owner);
        vault.emergencyStep(0);

        assertEq(vault.emergencyStepsCompleted() & 0x1, 0, "FIX: step 0 NOT marked when oracle stale");
        assertEq(
            rewardVault.balanceOf(address(strategy)), lpStakedBefore, "nothing recovered yet"
        );

        // Chainlink heals: refresh the crvUSD oracle (price update bumps updatedAt to now).
        crvUsdOracle.setPrice(1e8);
        usdtOracle.setPrice(1e8);

        // Guardian re-runs step 0 -- NOT blocked despite bit 0x1 already set.
        vm.prank(owner);
        vault.emergencyStep(0);

        uint256 lpStakedAfter = rewardVault.balanceOf(address(strategy));
        uint256 vaultUsdtAfter = usdt.balanceOf(address(vault));

        assertEq(lpStakedAfter, 0, "recovery: LP fully unstaked after oracle heals");
        assertGt(vaultUsdtAfter, 0, "recovery: USDT recovered to vault after oracle heals");

        console.log("[H1 BOUND] Recoverable once oracle heals; USDT recovered:", vaultUsdtAfter);
    }

    /// @notice EDGE CASE: step 0 on a legitimately EMPTY strategy must still mark the step
    ///         complete. withdrawAll() on an empty strategy succeeds returning 0 (clean no-op),
    ///         which is distinct from the stale-oracle revert case — requiring `withdrawn > 0`
    ///         would force an idle/already-drained vault through the 3-day skip path for no
    ///         reason. Success-without-revert is the completion signal, not the amount.
    function test_H1_emptyStrategy_step0_marksComplete() public {
        // No deposit: the strategy holds nothing and reports zero value.
        assertEq(rewardVault.balanceOf(address(strategy)), 0, "precondition: no LP staked");
        assertEq(strategy.balanceOf(), 0, "precondition: strategy empty");

        vm.prank(owner);
        vault.enterEmergencyMode();

        // withdrawAll() succeeds with 0 — the exit ran to completion on an empty strategy.
        vm.expectEmit(true, true, true, true, address(vault));
        emit EmergencyYieldRedeemed(0);
        vm.prank(owner);
        vault.emergencyStep(0);

        assertEq(
            vault.emergencyStepsCompleted() & 0x1,
            0x1,
            "FIX: step 0 marked complete for an empty strategy (no forced 3-day skip)"
        );

        console.log("[H1 EDGE] Empty strategy: step 0 completes cleanly, no skip path needed.");
    }
}
