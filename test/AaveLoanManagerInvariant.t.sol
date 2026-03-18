// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mock ERC20 tokens ============

contract AaveMockCollateral is ERC20 {
    constructor() ERC20("Mock WBTC", "WBTC") { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract AaveMockDebt is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

// ============ Mock Chainlink Oracle ============

contract AaveMockOracle {
    int256 public price;
    uint8 public oracleDecimals;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        oracleDecimals = _decimals;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function decimals() external view returns (uint8) {
        return oracleDecimals;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function latestAnswer() external view returns (int256) {
        return price;
    }

    function description() external pure returns (string memory) {
        return "Mock Oracle";
    }
}

// ============ Mock aToken / variableDebtToken ============

contract AaveMockAToken is ERC20 {
    constructor() ERC20("Mock aWBTC", "aWBTC") { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract AaveMockVariableDebtToken is ERC20 {
    constructor() ERC20("Mock varDebtUSDT", "vdUSDT") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

// ============ Mock Aave V3 Pool ============

contract AaveMockPool {
    AaveMockCollateral public collateral;
    AaveMockDebt public debt;
    AaveMockAToken public aToken;
    AaveMockVariableDebtToken public variableDebtToken;

    uint256 public constant FLASHLOAN_PREMIUM_BPS = 5; // 0.05%

    constructor(address _collateral, address _debt, address _aToken, address _variableDebtToken) {
        collateral = AaveMockCollateral(_collateral);
        debt = AaveMockDebt(_debt);
        aToken = AaveMockAToken(_aToken);
        variableDebtToken = AaveMockVariableDebtToken(_variableDebtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(collateral), "Wrong asset");
        collateral.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        require(asset == address(debt), "Wrong asset");
        debt.mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        require(asset == address(debt), "Wrong asset");
        uint256 currentDebt = variableDebtToken.balanceOf(onBehalfOf);
        uint256 toRepay = amount > currentDebt ? currentDebt : amount;
        if (amount == type(uint256).max) toRepay = currentDebt;
        if (toRepay > 0) {
            debt.transferFrom(msg.sender, address(this), toRepay);
            variableDebtToken.burn(onBehalfOf, toRepay);
        }
        return toRepay;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(collateral), "Wrong asset");
        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 toWithdraw = amount == type(uint256).max ? balance : amount;
        if (toWithdraw > balance) toWithdraw = balance;
        aToken.burn(msg.sender, toWithdraw);
        collateral.transfer(to, toWithdraw);
        return toWithdraw;
    }

    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        require(asset == address(debt), "Wrong asset");
        uint256 premium = (amount * FLASHLOAN_PREMIUM_BPS) / 10000;

        // Mint flash loan amount to receiver
        debt.mint(receiver, amount);

        // Call executeOperation on receiver
        (bool success,) = receiver.call(
            abi.encodeWithSignature(
                "executeOperation(address,uint256,uint256,address,bytes)",
                asset,
                amount,
                premium,
                receiver,
                params
            )
        );
        require(success, "Flash loan callback failed");

        // Verify repayment: receiver should have approved pool for amount + premium
        uint256 repayment = amount + premium;
        debt.transferFrom(receiver, address(this), repayment);
    }
}

// ============ Mock Swapper ============

contract AaveMockSwapper is ISwapper {
    AaveMockCollateral public collateralToken;
    AaveMockDebt public debtToken;
    AaveMockOracle public collateralOracle;
    AaveMockOracle public debtOracle;

    constructor(
        address _collateral,
        address _debt,
        address _collateralOracle,
        address _debtOracle
    ) {
        collateralToken = AaveMockCollateral(_collateral);
        debtToken = AaveMockDebt(_debt);
        collateralOracle = AaveMockOracle(_collateralOracle);
        debtOracle = AaveMockOracle(_debtOracle);
    }

    function _collateralToDebt(uint256 collateralAmount) internal view returns (uint256) {
        // collateral (8 dec) at collateral price / debt price -> debt (6 dec)
        uint256 collateralPrice = uint256(collateralOracle.price());
        uint256 debtPrice = uint256(debtOracle.price());
        return (collateralAmount * collateralPrice * 1e6) / (debtPrice * 1e8);
    }

    function _debtToCollateral(uint256 debtAmount) internal view returns (uint256) {
        uint256 collateralPrice = uint256(collateralOracle.price());
        uint256 debtPrice = uint256(debtOracle.price());
        return (debtAmount * debtPrice * 1e8) / (collateralPrice * 1e6);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        return _debtToCollateral(debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        uint256 debtOut = _collateralToDebt(collateralAmount);
        // Collateral already transferred to us by the caller
        debtToken.mint(msg.sender, debtOut);
        return debtOut;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        uint256 collateralOut = _debtToCollateral(debtAmount);
        collateralToken.mint(msg.sender, collateralOut);
        return collateralOut;
    }
}

// ============ Handler ============

contract AaveLoanManagerHandler is Test {
    AaveLoanManager public lm;
    AaveMockCollateral public collateral;
    AaveMockDebt public debt;
    AaveMockAToken public aToken;
    AaveMockVariableDebtToken public variableDebtToken;
    AaveMockOracle public collateralOracle;
    address public vault;

    // Ghost variables
    bool public ghost_lastActionWasFullUnwind;
    // True if price changed at any point during the current loan's lifetime.
    // Only cleared on full unwind or fresh createLoan. This ensures health/LTV
    // invariants only fire when prices have been stable throughout.
    bool public ghost_priceChangedDuringLoan;

    // Call counters
    uint256 public calls_createLoan;
    uint256 public calls_addCollateral;
    uint256 public calls_borrowMore;
    uint256 public calls_repayDebt;
    uint256 public calls_removeCollateral;
    uint256 public calls_unwindPartial;
    uint256 public calls_unwindFull;
    uint256 public calls_changePrice;

    constructor(
        AaveLoanManager _lm,
        AaveMockCollateral _collateral,
        AaveMockDebt _debt,
        AaveMockAToken _aToken,
        AaveMockVariableDebtToken _variableDebtToken,
        AaveMockOracle _collateralOracle,
        address _vault
    ) {
        lm = _lm;
        collateral = _collateral;
        debt = _debt;
        aToken = _aToken;
        variableDebtToken = _variableDebtToken;
        collateralOracle = _collateralOracle;
        vault = _vault;
    }

    function createLoan(uint256 collateralAmount, uint256 debtAmount) external {
        if (lm.loanExists()) return; // Only create if no loan exists

        collateralAmount = bound(collateralAmount, 1e6, 10e8); // 0.01 - 10 BTC
        // Target ~30% LTV: debt = collateralValue * 0.3
        uint256 collateralValueUsdt = lm.getCollateralValue(collateralAmount);
        uint256 maxDebt = (collateralValueUsdt * 30) / 100;
        debtAmount = bound(debtAmount, 1, maxDebt > 0 ? maxDebt : 1);

        collateral.mint(address(lm), collateralAmount);
        vm.prank(vault);
        try lm.createLoan(collateralAmount, debtAmount, 0) {
            ghost_lastActionWasFullUnwind = false;
            ghost_priceChangedDuringLoan = false; // Fresh loan at current price
            calls_createLoan++;
        } catch { }
    }

    function addCollateral(uint256 amount) external {
        if (!lm.loanExists()) return;

        amount = bound(amount, 1e4, 5e8);
        collateral.mint(address(lm), amount);
        vm.prank(vault);
        try lm.addCollateral(amount) {
            ghost_lastActionWasFullUnwind = false;
            calls_addCollateral++;
        } catch { }
    }

    function borrowMore(uint256 collateralAmount, uint256 debtAmount) external {
        if (!lm.loanExists()) return;

        collateralAmount = bound(collateralAmount, 1e4, 2e8);
        // Keep total LTV below 50%
        uint256 totalCollateral = aToken.balanceOf(address(lm)) + collateralAmount;
        uint256 totalCollateralValue = lm.getCollateralValue(totalCollateral);
        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        uint256 maxNewDebt =
            totalCollateralValue > currentDebt * 2 ? (totalCollateralValue / 2) - currentDebt : 0;
        if (maxNewDebt == 0) return;
        debtAmount = bound(debtAmount, 1, maxNewDebt);

        collateral.mint(address(lm), collateralAmount);
        vm.prank(vault);
        try lm.borrowMore(collateralAmount, debtAmount) {
            ghost_lastActionWasFullUnwind = false;
            calls_borrowMore++;
        } catch { }
    }

    function repayDebt(uint256 amount) external {
        if (!lm.loanExists()) return;

        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        if (currentDebt == 0) return;

        amount = bound(amount, 1, currentDebt);
        debt.mint(address(lm), amount);
        vm.prank(vault);
        try lm.repayDebt(amount) {
            ghost_lastActionWasFullUnwind = false;
            calls_repayDebt++;
        } catch { }
    }

    function removeCollateral(uint256 amount) external {
        if (!lm.loanExists()) return;

        uint256 currentCollateral = aToken.balanceOf(address(lm));
        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        if (currentCollateral == 0) return;

        if (currentDebt > 0) {
            // Use healthCalculator to find max removable while keeping health >= MIN_HEALTH + buffer
            // Binary search would be ideal but keep it simple: cap removal to keep health >= 1.2e18
            int256 targetMinHealth = 1.2e18;
            // Estimate: remove up to 10% of collateral, check health
            uint256 maxRemovable = currentCollateral / 10;
            if (maxRemovable == 0) return;

            // Verify hypothetical health
            int256 hypotheticalHealth = lm.healthCalculator(-int256(maxRemovable), int256(0));
            if (hypotheticalHealth < targetMinHealth) return;

            amount = bound(amount, 1, maxRemovable);
        } else {
            amount = bound(amount, 1, currentCollateral);
        }

        vm.prank(vault);
        try lm.removeCollateral(amount) {
            ghost_lastActionWasFullUnwind = false;
            calls_removeCollateral++;
            // Transfer idle collateral to vault (simulating what vault does)
            uint256 idle = collateral.balanceOf(address(lm));
            if (idle > 0) {
                vm.prank(vault);
                lm.transferCollateral(vault, idle);
            }
        } catch { }
    }

    function unwindPartial(uint256 collateralNeeded) external {
        if (!lm.loanExists()) return;

        uint256 currentCollateral = aToken.balanceOf(address(lm));
        if (currentCollateral == 0) return;

        collateralNeeded = bound(collateralNeeded, 1, currentCollateral / 2 + 1);

        // Fund LM with proportional debt for repayment
        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        uint256 proportionalDebt =
            currentCollateral > 0 ? (currentDebt * collateralNeeded) / currentCollateral : 0;
        if (proportionalDebt > 0) {
            debt.mint(address(lm), proportionalDebt);
        }

        vm.prank(vault);
        try lm.unwindPosition(collateralNeeded) {
            ghost_lastActionWasFullUnwind = false;
            calls_unwindPartial++;
        } catch { }
    }

    function unwindFull() external {
        if (!lm.loanExists()) return;

        // Fund LM with all debt for full repayment
        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        if (currentDebt > 0) {
            debt.mint(address(lm), currentDebt);
        }

        vm.prank(vault);
        try lm.unwindPosition(type(uint256).max) {
            ghost_lastActionWasFullUnwind = true;
            ghost_priceChangedDuringLoan = false; // Loan fully closed
            calls_unwindFull++;
        } catch { }
    }

    function changePrice(uint256 newPrice) external {
        ghost_lastActionWasFullUnwind = false;
        ghost_priceChangedDuringLoan = true;
        // BTC price ±20%: 72000 - 108000
        newPrice = bound(newPrice, 72_000, 108_000);
        collateralOracle.setPrice(int256(newPrice * 1e8));
        calls_changePrice++;
    }
}

// ============ Invariant Test Contract ============

contract AaveLoanManagerInvariantTest is Test {
    address vault = makeAddr("vault");

    AaveMockCollateral collateral;
    AaveMockDebt debt;
    AaveMockAToken aToken;
    AaveMockVariableDebtToken variableDebtToken;
    AaveMockPool pool;
    AaveMockOracle collateralOracle;
    AaveMockOracle debtOracle;
    AaveMockSwapper swapper;
    AaveLoanManager lm;
    AaveLoanManagerHandler handler;

    function setUp() public {
        // Deploy mock tokens
        collateral = new AaveMockCollateral();
        debt = new AaveMockDebt();
        aToken = new AaveMockAToken();
        variableDebtToken = new AaveMockVariableDebtToken();

        // Deploy mock pool
        pool = new AaveMockPool(
            address(collateral), address(debt), address(aToken), address(variableDebtToken)
        );
        // Fund pool with collateral for withdrawals
        collateral.mint(address(pool), 1000e8);

        // Deploy mock oracles: BTC ~$90,000, USDT ~$1
        collateralOracle = new AaveMockOracle(90_000e8, 8);
        debtOracle = new AaveMockOracle(1e8, 8);

        // Deploy mock swapper
        swapper = new AaveMockSwapper(
            address(collateral), address(debt), address(collateralOracle), address(debtOracle)
        );

        // Deploy real AaveLoanManager
        lm = new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(variableDebtToken),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7100, // maxLtvBps (71%)
            7600, // liquidationThresholdBps (76%)
            vault
        );

        // Deploy handler
        handler = new AaveLoanManagerHandler(
            lm, collateral, debt, aToken, variableDebtToken, collateralOracle, vault
        );

        targetContract(address(handler));
    }

    // ============ INVARIANT 1: Loan state consistency ============

    function invariant_loanStateConsistency() public view {
        uint256 lmCollateral = lm.getCurrentCollateral();
        uint256 aTokenBal = aToken.balanceOf(address(lm));
        assertEq(lmCollateral, aTokenBal, "getCurrentCollateral != aToken.balanceOf(lm)");

        uint256 lmDebt = lm.getCurrentDebt();
        uint256 debtTokenBal = variableDebtToken.balanceOf(address(lm));
        assertEq(lmDebt, debtTokenBal, "getCurrentDebt != variableDebtToken.balanceOf(lm)");
    }

    // ============ INVARIANT 2: Health above minimum ============

    function invariant_healthAboveMinimum() public view {
        // Price changes can push health below minimum — that's what liquidations handle.
        // This invariant checks that LM operations never create an unhealthy position.
        if (handler.ghost_priceChangedDuringLoan()) return;

        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        if (currentDebt == 0) return;

        int256 health = lm.getHealth();
        assertGe(health, lm.MIN_HEALTH(), "Health factor below MIN_HEALTH after LM operation");
    }

    // ============ INVARIANT 3: loanExists consistency ============

    function invariant_loanExistsConsistency() public view {
        bool exists = lm.loanExists();
        bool hasAToken = aToken.balanceOf(address(lm)) > 0;
        bool hasDebt = variableDebtToken.balanceOf(address(lm)) > 0;

        assertEq(exists, hasAToken || hasDebt, "loanExists() inconsistent with token balances");
    }

    // ============ INVARIANT 4: Full unwind cleans up ============

    function invariant_fullUnwindCleansUp() public view {
        if (!handler.ghost_lastActionWasFullUnwind()) return;

        assertEq(variableDebtToken.balanceOf(address(lm)), 0, "Debt remains after full unwind");
        assertFalse(lm.loanExists(), "Loan still exists after full unwind");
    }

    // ============ INVARIANT 5: LTV within bounds ============

    function invariant_ltvWithinBounds() public view {
        // Price changes can push LTV above max — that's expected market behavior.
        if (handler.ghost_priceChangedDuringLoan()) return;

        uint256 currentDebt = variableDebtToken.balanceOf(address(lm));
        if (currentDebt == 0) return;

        uint256 ltv = lm.getCurrentLTV();
        // maxLtvBps = 7100 -> max LTV = 0.71e18
        uint256 maxLtv = lm.maxLtvBps() * 1e14;
        assertLe(ltv, maxLtv, "LTV exceeds protocol max after LM operation");
    }

    // ============ INVARIANT 6: Net collateral non-negative ============

    function invariant_netCollateralNonNegative() public view {
        // getNetCollateralValue returns 0 if debt > collateral, so this checks for reverts
        lm.getNetCollateralValue();
    }

    // ============ INVARIANT 7: No stuck collateral ============

    function invariant_noStuckCollateral() public view {
        if (lm.loanExists()) return;

        uint256 idleCollateral = collateral.balanceOf(address(lm));
        assertEq(idleCollateral, 0, "Collateral stuck in LM when no loan exists");
    }

    // ============ INVARIANT 8: Call summary ============

    function invariant_callSummary() public view {
        console.log("--- AaveLoanManager Invariant Call Summary ---");
        console.log("createLoan:       ", handler.calls_createLoan());
        console.log("addCollateral:    ", handler.calls_addCollateral());
        console.log("borrowMore:       ", handler.calls_borrowMore());
        console.log("repayDebt:        ", handler.calls_repayDebt());
        console.log("removeCollateral: ", handler.calls_removeCollateral());
        console.log("unwindPartial:    ", handler.calls_unwindPartial());
        console.log("unwindFull:       ", handler.calls_unwindFull());
        console.log("changePrice:      ", handler.calls_changePrice());
        console.log("aToken balance:   ", aToken.balanceOf(address(lm)));
        console.log("debtToken balance:", variableDebtToken.balanceOf(address(lm)));
    }
}
