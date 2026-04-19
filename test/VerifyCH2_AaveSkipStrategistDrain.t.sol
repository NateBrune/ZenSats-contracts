// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Minimal Mocks ============

contract MockERC20CH2 is ERC20 {
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

contract MockLoanManagerCH2 is ILoanManager {
    address public collateralAsset;
    address public debtAsset;

    constructor(address _collateral, address _debt) {
        collateralAsset = _collateral;
        debtAsset = _debt;
    }

    function createLoan(uint256, uint256) external override {}
    function addCollateral(uint256) external override {}
    function borrowMore(uint256, uint256) external override {}
    function repayDebt(uint256) external override {}
    function removeCollateral(uint256) external override {}
    function unwindPosition(uint256) external override {}
    function transferCollateral(address, uint256) external override {}
    function transferDebt(address, uint256) external override {}
    function maxLtvBps() external pure override returns (uint256) { return type(uint256).max; }
    function checkOracleFreshness() external view override {}

    function getCurrentLTV() external pure override returns (uint256) { return 0; }
    function getCurrentCollateral() external pure override returns (uint256) { return 0; }
    function getCurrentDebt() external pure override returns (uint256) { return 0; }
    function getHealth() external pure override returns (int256) { return 1e18; }
    function loanExists() external pure override returns (bool) { return false; }
    function getCollateralValue(uint256 a) external pure override returns (uint256) { return a; }
    function getDebtValue(uint256 a) external pure override returns (uint256) { return a; }
    function calculateBorrowAmount(uint256, uint256) external pure override returns (uint256) { return 0; }
    function healthCalculator(int256, int256) external pure override returns (int256) { return 1e18; }
    function minCollateral(uint256, uint256) external pure override returns (uint256) { return 0; }
    function getPositionValues() external pure override returns (uint256, uint256) { return (0, 0); }
    function getNetCollateralValue() external pure override returns (uint256) { return 0; }
    function getCollateralBalance() external pure override returns (uint256) { return 0; }
    function getDebtBalance() external pure override returns (uint256) { return 0; }
}

contract MockYieldStrategyCH2 is IYieldStrategy {
    address public asset;
    address public vault;
    MockERC20CH2 private _token;

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
        _token = MockERC20CH2(_asset);
    }

    function withdrawAll() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) _token.transfer(vault, bal);
        return bal;
    }

    function deposit(uint256) external pure override returns (uint256) { return 0; }

    function withdraw(uint256 amt) external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        uint256 out = amt < bal ? amt : bal;
        if (out > 0) _token.transfer(vault, out);
        return out;
    }

    function harvest() external pure override returns (uint256) { return 0; }

    function emergencyWithdraw() external override returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        if (bal > 0) _token.transfer(vault, bal);
        return bal;
    }

    function underlyingAsset() external view override returns (address) { return asset; }

    function balanceOf() external view override returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function costBasis() external pure override returns (uint256) { return 0; }
    function unrealizedProfit() external pure override returns (uint256) { return 0; }
    function pendingRewards() external pure override returns (uint256) { return 0; }
    function name() external pure override returns (string memory) { return "MockStrategy"; }
    function transferOwnerFromVault(address) external override {}
    function setSlippage(uint256) external override {}
    function updateCachedVirtualPrice() external {}
}

contract MockSwapperCH2 is ISwapper {
    MockERC20CH2 public immutable collateralToken;
    MockERC20CH2 public immutable debtToken;

    constructor(address _collateral, address _debt) {
        collateralToken = MockERC20CH2(_collateral);
        debtToken = MockERC20CH2(_debt);
    }

    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) { return d; }

    function swapCollateralForDebt(uint256 a) external returns (uint256) {
        debtToken.mint(msg.sender, a);
        return a;
    }

    function swapDebtForCollateral(uint256 a) external returns (uint256) {
        collateralToken.mint(msg.sender, a);
        return a;
    }
}

// ============ Test Contract ============

contract VerifyCH2_AaveSkipStrategistDrain is Test {
    MockERC20CH2 collateral;
    MockERC20CH2 usdt;

    MockLoanManagerCH2 lm;
    MockYieldStrategyCH2 strategy;
    MockSwapperCH2 swapper;
    ZenjiViewHelper viewHelper;
    Zenji vault;

    address owner = makeAddr("owner"); // owner = strategist = gov = guardian
    address user1 = makeAddr("user1");
    address feeRecipient = makeAddr("feeRecipient");

    uint256 constant COLLATERAL_DEPOSIT = 100e18;
    uint256 constant USDT_IN_STRATEGY = 65e6;

    function setUp() public {
        collateral = new MockERC20CH2("WBTC", "WBTC", 18);
        usdt = new MockERC20CH2("USDT", "USDT", 6);

        uint256 startNonce = vm.getNonce(address(this));
        address expectedVault = vm.computeCreateAddress(address(this), startNonce + 4);

        lm = new MockLoanManagerCH2(address(collateral), address(usdt));
        strategy = new MockYieldStrategyCH2(address(usdt), expectedVault);
        swapper = new MockSwapperCH2(address(collateral), address(usdt));
        viewHelper = new ZenjiViewHelper();

        vault = new Zenji(
            address(collateral),
            address(usdt),
            address(lm),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );
        require(address(vault) == expectedVault, "vault address mismatch");

        // Set fee rate (gov = owner)
        vm.prank(owner);
        vault.setParam(0, 1e17); // 10% fee rate

        // Set idle so collateral stays in vault
        vm.prank(owner);
        vault.setIdle(true);

        // Seed strategy with USDT (simulating deployed debt)
        usdt.mint(address(strategy), USDT_IN_STRATEGY);

        // User deposits collateral
        collateral.mint(user1, COLLATERAL_DEPOSIT);
        vm.startPrank(user1);
        collateral.approve(address(vault), COLLATERAL_DEPOSIT);
        vault.deposit(COLLATERAL_DEPOSIT, user1);
        vm.stopPrank();

        // Simulate yield growth in strategy so fees accrue
        usdt.mint(address(strategy), 10e6); // 10 USDT yield growth

        // Trigger fee accrual via another deposit
        vm.roll(block.number + 1);
        collateral.mint(user1, 1e18);
        vm.startPrank(user1);
        collateral.approve(address(vault), 1e18);
        vault.deposit(1e18, user1);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    /// @notice CH-2 PRIMARY TEST: After emergencyStep(0) + emergencySkipStep(1),
    ///         can strategist drain USDT via withdrawFees()?
    ///
    /// CLAIM: depositors receive ~0% recovery because WBTC is stranded AND
    ///        strategist drains the remaining USDT via withdrawFees().
    ///
    /// RESULT: FALSE_POSITIVE - emergencyStep(0) zeroes accumulatedFees,
    ///         so withdrawFees() after step 0 transfers nothing.
    function test_CH2_strategist_cannot_drain_USDT_after_emergency() public {
        uint256 feesBeforeEmergency = vault.accumulatedFees();
        console.log("Accumulated fees before emergency:", feesBeforeEmergency);
        assertGt(feesBeforeEmergency, 0, "precondition: fees must exist");

        uint256 strategyBalBefore = usdt.balanceOf(address(strategy));
        console.log("Strategy USDT before emergency:", strategyBalBefore);

        // ===== EMERGENCY SEQUENCE =====
        vm.startPrank(owner);

        // Enter emergency mode
        vault.enterEmergencyMode();

        // Step 0: withdraw yield (zeroes accumulatedFees and lastStrategyBalance)
        vault.emergencyStep(0);

        uint256 feesAfterStep0 = vault.accumulatedFees();
        console.log("Accumulated fees after step 0:", feesAfterStep0);
        assertEq(feesAfterStep0, 0, "emergencyStep(0) zeroes accumulatedFees");

        uint256 vaultUsdtAfterStep0 = usdt.balanceOf(address(vault));
        console.log("Vault USDT after step 0:", vaultUsdtAfterStep0);
        assertGt(vaultUsdtAfterStep0, 0, "vault holds USDT from strategy withdrawal");

        // Skip step 1 (WBTC stranded)
        vault.emergencySkipStep(1);
        vm.stopPrank();

        // ===== ATTACK: Strategist tries to drain USDT =====
        uint256 recipientBefore = usdt.balanceOf(feeRecipient);

        vm.prank(owner); // owner = strategist
        vault.withdrawFees(feeRecipient);

        uint256 drained = usdt.balanceOf(feeRecipient) - recipientBefore;
        console.log("USDT drained by strategist:", drained);

        // Complete liquidation
        vm.prank(owner);
        vault.emergencyStep(2);

        uint256 vaultUsdtForUsers = usdt.balanceOf(address(vault));
        console.log("Vault USDT remaining for users:", vaultUsdtForUsers);

        // ===== HARM ASSERTIONS =====
        // CH-2 claims strategist drains USDT -> ~0% user recovery
        // Defense: accumulatedFees was zeroed by step 0, so drain = 0
        assertEq(drained, 0, "DEFENSE HOLDS: strategist cannot drain any USDT after step 0");
        assertEq(
            vaultUsdtForUsers,
            vaultUsdtAfterStep0,
            "DEFENSE HOLDS: all USDT remains for user redemption"
        );
    }

    /// @notice Variant: Strategist front-runs emergencyStep(0) to extract fees.
    ///         Tests whether strategist can take MORE than their legitimate fees.
    ///
    /// Note: In this test setup, lastStrategyBalance starts at 0, so all 75M USDT
    /// appears as yield growth (fees = 10% of 75M = 7.5M). In production,
    /// lastStrategyBalance tracks deployed principal, so fees would only be on
    /// actual yield above principal -- a much smaller fraction.
    function test_CH2_variant_frontrun_extracts_only_legitimate_fees() public {
        uint256 feesBeforeEmergency = vault.accumulatedFees();
        uint256 strategyBalBefore = usdt.balanceOf(address(strategy));
        console.log("Fees before emergency:", feesBeforeEmergency);
        console.log("Strategy balance:", strategyBalBefore);

        // Enter emergency
        vm.prank(owner);
        vault.enterEmergencyMode();

        // Strategist front-runs: withdraws fees BEFORE step 0
        uint256 recipientBefore = usdt.balanceOf(feeRecipient);
        vm.prank(owner);
        vault.withdrawFees(feeRecipient);
        uint256 feeDrained = usdt.balanceOf(feeRecipient) - recipientBefore;
        console.log("Fees front-run withdrawn:", feeDrained);

        // Strategist can only take their accumulated fees, not arbitrary amounts
        assertLe(feeDrained, feesBeforeEmergency, "can only take accumulatedFees");

        // Now continue emergency
        vm.startPrank(owner);
        vault.emergencyStep(0);
        vault.emergencySkipStep(1);
        vault.emergencyStep(2);
        vm.stopPrank();

        uint256 vaultUsdtForUsers = usdt.balanceOf(address(vault));
        uint256 totalRecovered = vaultUsdtForUsers + feeDrained;
        console.log("USDT for users:", vaultUsdtForUsers);
        console.log("Total USDT recovered (users+fees):", totalRecovered);

        // All USDT is accounted for: users get strategy balance minus fees
        assertEq(totalRecovered, strategyBalBefore, "All USDT accounted for (fees + user recovery)");

        // Users recover at least 90% of strategy balance (fees are at most feeRate % of balance)
        // In production where lastStrategyBalance tracks principal, this would be much higher
        assertGe(
            vaultUsdtForUsers,
            strategyBalBefore * 90 / 100,
            "Users recover >=90% of strategy balance even after fee front-run"
        );
    }
}
