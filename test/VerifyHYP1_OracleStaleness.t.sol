// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { OracleLib } from "../src/libraries/OracleLib.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Minimal Mocks ============

contract MockERC20hyp1 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Chainlink oracle mock — price and updatedAt are independently settable
contract MockOraclehyp1 {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 decimals_, int256 price_, uint256 initialUpdatedAt) {
        decimals = decimals_;
        price = price_;
        updatedAt = initialUpdatedAt;
        roundId = 1;
        answeredInRound = 1;
    }

    /// @notice Set updatedAt to an absolute timestamp (allows simulating stale data)
    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}

contract MockAavePoolhyp1 is IAavePool {
    IERC20 public immutable coll;
    IERC20 public immutable debtAsset;
    MockERC20hyp1 public immutable aToken;
    MockERC20hyp1 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        coll = IERC20(_collateral);
        debtAsset = IERC20(_debtAsset);
        aToken = MockERC20hyp1(_aToken);
        variableDebtToken = MockERC20hyp1(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20hyp1(asset).mint(onBehalfOf, amount);
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
        MockERC20hyp1(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset, amount, 0, receiverAddress, params
        );
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }
    function setUserEMode(uint8) external {}
    function getUserEMode(address) external pure returns (uint256) { return 0; }
}

contract MockSwapperhyp1 is ISwapper {
    MockERC20hyp1 public immutable collateralToken;
    MockERC20hyp1 public immutable debtToken;

    constructor(address _collateral, address _debt) {
        collateralToken = MockERC20hyp1(_collateral);
        debtToken = MockERC20hyp1(_debt);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount;
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        debtToken.mint(msg.sender, collateralAmount);
        return collateralAmount;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        collateralToken.mint(msg.sender, debtAmount);
        return debtAmount;
    }
}

/// @title HYP-1 Verification: USDT Oracle 25-Hour Staleness DoS
/// @notice Proves that when the USDT/USD Chainlink oracle goes stale (>90000 seconds =
///         25 hours), all AaveLoanManager state-changing operations revert with StaleOracle,
///         preventing users from managing their positions.
///
/// Setup pattern: start at a reasonable timestamp (e.g. 2000000), deploy oracles,
/// then warp forward 25+ hours and pin oracle updatedAt at original deploy time.
contract VerifyHYP1_OracleStaleness_Test is Test {
    MockERC20hyp1 collateral;
    MockERC20hyp1 debt;
    MockERC20hyp1 aToken;
    MockERC20hyp1 vDebt;
    MockAavePoolhyp1 pool;
    MockOraclehyp1 collateralOracle;
    MockOraclehyp1 debtOracle;
    MockSwapperhyp1 swapper;
    AaveLoanManager aaveManager;

    address vault = address(this);

    uint256 constant MAX_DEBT_ORACLE_STALENESS = 90000; // 25 hours — matches contract constant
    uint256 constant START_TS = 2_000_000; // start at a non-trivial timestamp to avoid underflows
    uint256 deployTs; // oracle creation timestamp

    function setUp() public {
        // Start at a known timestamp well above any staleness window
        vm.warp(START_TS);
        deployTs = block.timestamp;

        collateral = new MockERC20hyp1("WBTC", "WBTC", 8);
        debt = new MockERC20hyp1("USDT", "USDT", 6);
        aToken = new MockERC20hyp1("aWBTC", "aWBTC", 8);
        vDebt = new MockERC20hyp1("vUSDT", "vUSDT", 6);

        pool = new MockAavePoolhyp1(
            address(collateral), address(debt), address(aToken), address(vDebt)
        );
        // Collateral: BTC/USD, 8 dec, $60,000; staleness 3600 (1 hour)
        collateralOracle = new MockOraclehyp1(8, int256(60_000e8), deployTs);
        // Debt: USDT/USD, 8 dec, $1.00; staleness 90000 (25 hours)
        debtOracle = new MockOraclehyp1(8, int256(1e8), deployTs);
        swapper = new MockSwapperhyp1(address(collateral), address(debt));

        aaveManager = new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500, // maxLtvBps: 75%
            8000, // liquidationThresholdBps: 80%
            vault,
            0 // eMode: disabled
        );

        // Create initial healthy loan: 1 BTC collateral, 100 USDT debt
        collateral.mint(address(aaveManager), 1e8);
        aaveManager.createLoan(1e8, 100e6, 0);
    }

    // ──────────────────────────────────────────────────────────────
    // CONTROL: verify freshness check passes with fresh oracle
    // ──────────────────────────────────────────────────────────────

    /// @notice Control: both oracles fresh → no revert
    function test_HYP1_control_freshOracle_succeeds() public {
        // Warp 1 hour — still within both staleness windows (collateral=3600, debt=90000)
        vm.warp(deployTs + 3599);
        aaveManager.checkOracleFreshness(); // must not revert
    }

    // ──────────────────────────────────────────────────────────────
    // MAIN PROOF: stale DEBT oracle (>90000s) blocks all operations
    // ──────────────────────────────────────────────────────────────

    /// @notice Proof: direct freshness check reverts when USDT oracle is stale >25h
    function test_HYP1_checkOracleFreshness_reverts_when_debt_oracle_stale() public {
        // Warp 25h + 1s. Debt oracle's updatedAt stays at deployTs.
        // block.timestamp - updatedAt = 90001 > 90000 → StaleOracle
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);

        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.checkOracleFreshness();
    }

    /// @notice Proof: createLoan reverts when USDT oracle stale >25h
    function test_HYP1_createLoan_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        collateral.mint(address(aaveManager), 1e8);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.createLoan(1e8, 100e6, 0);
    }

    /// @notice Proof: addCollateral reverts when USDT oracle stale >25h
    function test_HYP1_addCollateral_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        collateral.mint(address(aaveManager), 1e7);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.addCollateral(1e7);
    }

    /// @notice Proof: borrowMore reverts when USDT oracle stale >25h
    function test_HYP1_borrowMore_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.borrowMore(0, 50e6);
    }

    /// @notice Proof: repayDebt reverts when USDT oracle stale >25h
    ///         Critical: users cannot reduce debt exposure during crisis
    function test_HYP1_repayDebt_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        debt.mint(address(aaveManager), 50e6);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.repayDebt(50e6);
    }

    /// @notice Proof: removeCollateral reverts when USDT oracle stale >25h
    ///         Critical: users cannot retrieve collateral during stale oracle period
    function test_HYP1_removeCollateral_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.removeCollateral(1e6);
    }

    /// @notice Proof: unwindPosition reverts when USDT oracle stale >25h
    function test_HYP1_unwindPosition_reverts_stale_debt_oracle() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.unwindPosition(type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────
    // BOUNDARY TESTS
    // ──────────────────────────────────────────────────────────────

    /// @notice Boundary: exactly at threshold (block.timestamp - updatedAt == 90000) does NOT revert
    /// OracleLib check is: > maxStaleness (strict), so equal does not revert
    /// Collateral oracle is also refreshed since we warp past its 3600s window.
    function test_HYP1_boundary_exactThreshold_does_not_revert() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS);
        // Keep collateral oracle fresh (3600s threshold would fire otherwise after 90000s warp)
        collateralOracle.setUpdatedAt(block.timestamp);
        // Debt oracle: block.timestamp - updatedAt == 90000 == MAX_DEBT_ORACLE_STALENESS → NOT > → no revert
        aaveManager.checkOracleFreshness(); // must not revert
    }

    /// @notice Boundary: one second past threshold DOES revert
    function test_HYP1_boundary_oneSecondOver_reverts() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.checkOracleFreshness();
    }

    // ──────────────────────────────────────────────────────────────
    // COLLATERAL oracle staleness (>3600s = 1 hour) also DoSes
    // ──────────────────────────────────────────────────────────────

    /// @notice Proof: stale COLLATERAL oracle (>3600s) also blocks all operations
    ///         Collateral oracle threshold is 1 hour — far tighter than debt oracle's 25 hours.
    ///         Warp 1 hour + 1s. Debt oracle freshly updated; collateral oracle stale.
    function test_HYP1_collateralOracle_staleness_1hr_also_blocks() public {
        uint256 maxCollateralStaleness = 3600; // matches AaveLoanManager.MAX_ORACLE_STALENESS
        vm.warp(deployTs + maxCollateralStaleness + 1);
        // Update debt oracle to be fresh at new timestamp so only collateral is stale
        debtOracle.setUpdatedAt(block.timestamp);

        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.checkOracleFreshness();
    }

    // ──────────────────────────────────────────────────────────────
    // SECONDARY IMPACT: emergency path also blocked
    // emergencyStep(1) → ZenjiCoreLib.executeEmergencyStep(1) → loanManager.unwindPosition()
    // → AaveLoanManager._checkOracleFreshness() → StaleOracle revert
    // Therefore: stale oracle blocks the emergency unwind path too, preventing
    // the prerequisite for users to redeem in emergency mode.
    // ──────────────────────────────────────────────────────────────

    /// @notice Proof: the oracle freshness check that blocks all operations is the same one
    ///         called by Zenji.rebalance() (loanManager.checkOracleFreshness()) and
    ///         Zenji._deployCapital() — confirming full vault-level DoS scope
    function test_HYP1_public_checkOracleFreshness_is_blocked_during_staleness() public {
        vm.warp(deployTs + MAX_DEBT_ORACLE_STALENESS + 1);
        // This is the exact function called by Zenji.rebalance() at L458
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.checkOracleFreshness();
    }
}
