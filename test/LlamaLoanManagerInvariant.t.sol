// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IERC3156FlashBorrower
} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

// ============ Mock ERC20 tokens ============

contract LlamaMockCollateral is ERC20 {
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

contract LlamaMockDebt is ERC20 {
    constructor() ERC20("Mock crvUSD", "crvUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

// ============ Mock Chainlink Oracle ============

contract LlamaMockOracle {
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

// ============ Mock LlamaLend Controller ============

contract LlamaMockLlamaLend {
    LlamaMockCollateral public collateralToken;
    LlamaMockDebt public debtToken;

    mapping(address => uint256) public userCollateral;
    mapping(address => uint256) public userDebt;
    mapping(address => bool) public hasLoan;

    // Simple price: 1 collateral unit (1e8) = priceInDebt debt units
    uint256 public priceInDebt = 90_000e18; // 1 BTC = 90,000 crvUSD

    constructor(address _collateral, address _debt) {
        collateralToken = LlamaMockCollateral(_collateral);
        debtToken = LlamaMockDebt(_debt);
    }

    function setPrice(uint256 _price) external {
        priceInDebt = _price;
    }

    function create_loan(uint256 collateral, uint256 debtAmount, uint256) external payable {
        collateralToken.transferFrom(msg.sender, address(this), collateral);
        debtToken.mint(msg.sender, debtAmount);
        userCollateral[msg.sender] += collateral;
        userDebt[msg.sender] += debtAmount;
        hasLoan[msg.sender] = true;
    }

    function add_collateral(uint256 collateral) external payable {
        collateralToken.transferFrom(msg.sender, address(this), collateral);
        userCollateral[msg.sender] += collateral;
    }

    function borrow_more(uint256 collateral, uint256 debtAmount) external payable {
        if (collateral > 0) {
            collateralToken.transferFrom(msg.sender, address(this), collateral);
            userCollateral[msg.sender] += collateral;
        }
        if (debtAmount > 0) {
            debtToken.mint(msg.sender, debtAmount);
            userDebt[msg.sender] += debtAmount;
        }
    }

    function repay(uint256 amount) external {
        uint256 currentDebt = userDebt[msg.sender];
        uint256 toRepay = amount > currentDebt ? currentDebt : amount;
        if (toRepay > 0) {
            debtToken.transferFrom(msg.sender, address(this), toRepay);
            userDebt[msg.sender] -= toRepay;
        }
        if (userDebt[msg.sender] == 0 && userCollateral[msg.sender] == 0) {
            hasLoan[msg.sender] = false;
        }
    }

    function remove_collateral(uint256 collateral) external {
        uint256 current = userCollateral[msg.sender];
        uint256 toRemove = collateral > current ? current : collateral;
        userCollateral[msg.sender] -= toRemove;
        collateralToken.transfer(msg.sender, toRemove);
        if (userDebt[msg.sender] == 0 && userCollateral[msg.sender] == 0) {
            hasLoan[msg.sender] = false;
        }
    }

    function loan_exists(address user) external view returns (bool) {
        return hasLoan[user];
    }

    function debt(address user) external view returns (uint256) {
        return userDebt[user];
    }

    function user_state(address user) external view returns (uint256[4] memory state) {
        state[0] = userCollateral[user];
        state[1] = 0; // stablecoin in AMM
        state[2] = userDebt[user];
        state[3] = 4; // bands
    }

    function health(address user, bool) external view returns (int256) {
        uint256 coll = userCollateral[user];
        uint256 d = userDebt[user];
        if (d == 0) return type(int256).max;
        // health = collateralValue / debt - 1 (simplified)
        uint256 collValue = (coll * priceInDebt) / 1e8;
        if (collValue >= d) {
            return int256((collValue * 1e18) / d) - int256(1e18);
        } else {
            return -int256(((d - collValue) * 1e18) / d);
        }
    }

    function health_calculator(address user, int256 dCollateral, int256 dDebt, bool)
        external
        view
        returns (int256)
    {
        uint256 coll = userCollateral[user];
        uint256 d = userDebt[user];

        if (dCollateral < 0) {
            coll -= uint256(-dCollateral);
        } else {
            coll += uint256(dCollateral);
        }
        if (dDebt < 0) {
            d -= uint256(-dDebt);
        } else {
            d += uint256(dDebt);
        }

        if (d == 0) return type(int256).max;
        uint256 collValue = (coll * priceInDebt) / 1e8;
        if (collValue >= d) {
            return int256((collValue * 1e18) / d) - int256(1e18);
        } else {
            return -int256(((d - collValue) * 1e18) / d);
        }
    }

    function min_collateral(uint256 debt_, uint256) external view returns (uint256) {
        if (debt_ == 0) return 0;
        return (debt_ * 1e8 + priceInDebt - 1) / priceInDebt;
    }

    function amm_price() external pure returns (uint256) {
        return 1e18;
    }

    function collateral_token() external view returns (address) {
        return address(collateralToken);
    }
}

// ============ Mock Curve TwoCrypto (stub — not called in invariant paths) ============

contract LlamaMockCurveTwoCrypto {
    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        return dx;
    }
}

// ============ Mock ERC3156 Flash Lender ============

contract LlamaMockFlashLender {
    LlamaMockDebt public debtToken;
    uint256 public constant FEE_BPS = 5; // 0.05%

    // Ghost: total fees collected
    uint256 public totalFeesCollected;

    constructor(address _debtToken) {
        debtToken = LlamaMockDebt(_debtToken);
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != address(debtToken)) return 0;
        return type(uint256).max;
    }

    function flashFee(address, uint256 amount) external pure returns (uint256) {
        return (amount * FEE_BPS) / 10000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(token == address(debtToken), "Wrong token");
        uint256 fee = (amount * FEE_BPS) / 10000;

        // Mint flash loan to borrower
        debtToken.mint(address(receiver), amount);

        // Call onFlashLoan
        bytes32 result = receiver.onFlashLoan(address(receiver), token, amount, fee, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "Bad callback return");

        // Verify repayment (borrower must have transferred amount + fee to us)
        uint256 repayment = amount + fee;
        uint256 balance = debtToken.balanceOf(address(this));
        require(balance >= repayment, "Flash loan not repaid");

        totalFeesCollected += fee;
        return true;
    }
}

// ============ Mock Swapper ============

contract LlamaMockSwapper is ISwapper {
    LlamaMockCollateral public collateralToken;
    LlamaMockDebt public debtToken;
    LlamaMockOracle public collateralOracle;
    LlamaMockOracle public debtOracle;

    constructor(
        address _collateral,
        address _debt,
        address _collateralOracle,
        address _debtOracle
    ) {
        collateralToken = LlamaMockCollateral(_collateral);
        debtToken = LlamaMockDebt(_debt);
        collateralOracle = LlamaMockOracle(_collateralOracle);
        debtOracle = LlamaMockOracle(_debtOracle);
    }

    function _collateralToDebt(uint256 collateralAmount) internal view returns (uint256) {
        // collateral (8 dec) -> debt (18 dec) at oracle prices
        uint256 collateralPrice = uint256(collateralOracle.price());
        uint256 debtPrice = uint256(debtOracle.price());
        return (collateralAmount * collateralPrice * 1e18) / (debtPrice * 1e8);
    }

    function _debtToCollateral(uint256 debtAmount) internal view returns (uint256) {
        uint256 collateralPrice = uint256(collateralOracle.price());
        uint256 debtPrice = uint256(debtOracle.price());
        return (debtAmount * debtPrice * 1e8) / (collateralPrice * 1e18);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        return _debtToCollateral(debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        uint256 debtOut = _collateralToDebt(collateralAmount);
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

contract LlamaLoanManagerHandler is Test {
    LlamaLoanManager public lm;
    LlamaMockCollateral public collateral;
    LlamaMockDebt public debt;
    LlamaMockLlamaLend public llamaLend;
    LlamaMockOracle public collateralOracle;
    LlamaMockFlashLender public flashLender;
    address public vault;

    // Ghost variables
    bool public ghost_lastActionWasFullUnwind;
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
        LlamaLoanManager _lm,
        LlamaMockCollateral _collateral,
        LlamaMockDebt _debt,
        LlamaMockLlamaLend _llamaLend,
        LlamaMockOracle _collateralOracle,
        LlamaMockFlashLender _flashLender,
        address _vault
    ) {
        lm = _lm;
        collateral = _collateral;
        debt = _debt;
        llamaLend = _llamaLend;
        collateralOracle = _collateralOracle;
        flashLender = _flashLender;
        vault = _vault;
    }

    function createLoan(uint256 collateralAmount, uint256 debtAmount) external {
        if (lm.loanExists()) return;

        collateralAmount = bound(collateralAmount, 1e6, 10e8);
        // Target ~30% LTV
        uint256 collateralValueDebt = lm.getCollateralValue(collateralAmount);
        uint256 maxDebt = (collateralValueDebt * 30) / 100;
        debtAmount = bound(debtAmount, 1e18, maxDebt > 1e18 ? maxDebt : 1e18);

        collateral.mint(address(lm), collateralAmount);
        vm.prank(vault);
        try lm.createLoan(collateralAmount, debtAmount, 4) {
            ghost_lastActionWasFullUnwind = false;
            ghost_priceChangedDuringLoan = false;
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
        uint256[4] memory state = llamaLend.user_state(address(lm));
        uint256 totalCollateral = state[0] + collateralAmount;
        uint256 totalCollateralValue = lm.getCollateralValue(totalCollateral);
        uint256 currentDebt = llamaLend.debt(address(lm));
        uint256 maxNewDebt =
            totalCollateralValue > currentDebt * 2 ? (totalCollateralValue / 2) - currentDebt : 0;
        if (maxNewDebt < 1e18) return;
        debtAmount = bound(debtAmount, 1e18, maxNewDebt);

        collateral.mint(address(lm), collateralAmount);
        vm.prank(vault);
        try lm.borrowMore(collateralAmount, debtAmount) {
            ghost_lastActionWasFullUnwind = false;
            calls_borrowMore++;
        } catch { }
    }

    function repayDebt(uint256 amount) external {
        if (!lm.loanExists()) return;

        uint256 currentDebt = llamaLend.debt(address(lm));
        if (currentDebt == 0) return;

        amount = bound(amount, 1e18, currentDebt);
        debt.mint(address(lm), amount);
        vm.prank(vault);
        try lm.repayDebt(amount) {
            ghost_lastActionWasFullUnwind = false;
            calls_repayDebt++;
        } catch { }
    }

    function removeCollateral(uint256 amount) external {
        if (!lm.loanExists()) return;

        uint256[4] memory state = llamaLend.user_state(address(lm));
        uint256 currentCollateral = state[0];
        uint256 currentDebt = llamaLend.debt(address(lm));
        if (currentCollateral == 0) return;

        if (currentDebt > 0) {
            // Only remove up to 10% and verify health stays above 0.2e18
            uint256 maxRemovable = currentCollateral / 10;
            if (maxRemovable == 0) return;

            int256 hypotheticalHealth =
                llamaLend.health_calculator(address(lm), -int256(maxRemovable), 0, true);
            if (hypotheticalHealth < 0.2e18) return;

            amount = bound(amount, 1, maxRemovable);
        } else {
            amount = bound(amount, 1, currentCollateral);
        }

        vm.prank(vault);
        try lm.removeCollateral(amount) {
            ghost_lastActionWasFullUnwind = false;
            calls_removeCollateral++;
            // Transfer idle collateral to vault
            uint256 idle = collateral.balanceOf(address(lm));
            if (idle > 0) {
                vm.prank(vault);
                lm.transferCollateral(vault, idle);
            }
        } catch { }
    }

    function unwindPartial(uint256 collateralNeeded) external {
        if (!lm.loanExists()) return;

        uint256[4] memory state = llamaLend.user_state(address(lm));
        uint256 currentCollateral = state[0];
        if (currentCollateral == 0) return;

        collateralNeeded = bound(collateralNeeded, 1, currentCollateral / 2 + 1);

        // Fund LM with proportional debt for repayment
        uint256 currentDebt = llamaLend.debt(address(lm));
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
        uint256 currentDebt = llamaLend.debt(address(lm));
        if (currentDebt > 0) {
            debt.mint(address(lm), currentDebt);
        }

        vm.prank(vault);
        try lm.unwindPosition(type(uint256).max) {
            ghost_lastActionWasFullUnwind = true;
            ghost_priceChangedDuringLoan = false;
            calls_unwindFull++;
        } catch { }
    }

    function changePrice(uint256 newPrice) external {
        ghost_lastActionWasFullUnwind = false;
        ghost_priceChangedDuringLoan = true;
        // BTC price ±20%: 72000 - 108000
        newPrice = bound(newPrice, 72_000, 108_000);
        collateralOracle.setPrice(int256(newPrice * 1e8));
        // Also update mock LlamaLend's internal price to match
        llamaLend.setPrice(newPrice * 1e18);
        calls_changePrice++;
    }
}

// ============ Invariant Test Contract ============

contract LlamaLoanManagerInvariantTest is Test {
    address vault = makeAddr("vault");

    LlamaMockCollateral collateral;
    LlamaMockDebt debt;
    LlamaMockLlamaLend llamaLend;
    LlamaMockCurveTwoCrypto curveTwoCrypto;
    LlamaMockOracle collateralOracle;
    LlamaMockOracle debtOracle;
    LlamaMockSwapper swapper;
    LlamaMockFlashLender flashLender;
    LlamaLoanManager lm;
    LlamaLoanManagerHandler handler;

    function setUp() public {
        // Deploy mock tokens
        collateral = new LlamaMockCollateral();
        debt = new LlamaMockDebt();

        // Deploy mock LlamaLend controller
        llamaLend = new LlamaMockLlamaLend(address(collateral), address(debt));

        // Deploy mock Curve TwoCrypto (stub)
        curveTwoCrypto = new LlamaMockCurveTwoCrypto();

        // Deploy mock oracles: BTC ~$90,000, crvUSD ~$1
        collateralOracle = new LlamaMockOracle(90_000e8, 8);
        debtOracle = new LlamaMockOracle(1e8, 8);

        // Deploy mock swapper
        swapper = new LlamaMockSwapper(
            address(collateral), address(debt), address(collateralOracle), address(debtOracle)
        );

        // Deploy mock flash lender and etch at the hardcoded address
        LlamaMockFlashLender flashLenderImpl = new LlamaMockFlashLender(address(debt));
        bytes memory flashLenderCode = address(flashLenderImpl).code;
        address DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
        vm.etch(DEBT_FLASH_LENDER, flashLenderCode);

        // We need to initialize the storage of the etched contract
        // Store the debt token address at slot 0 (first state variable)
        vm.store(DEBT_FLASH_LENDER, bytes32(uint256(0)), bytes32(uint256(uint160(address(debt)))));
        flashLender = LlamaMockFlashLender(DEBT_FLASH_LENDER);

        // Deploy real LlamaLoanManager
        lm = new LlamaLoanManager(
            address(collateral),
            address(debt),
            address(llamaLend),
            address(curveTwoCrypto),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            vault
        );

        // Deploy handler
        handler = new LlamaLoanManagerHandler(
            lm, collateral, debt, llamaLend, collateralOracle, flashLender, vault
        );

        targetContract(address(handler));
    }

    // ============ INVARIANT 1: Loan state consistency ============

    function invariant_loanStateConsistency() public view {
        uint256 lmCollateral = lm.getCurrentCollateral();
        uint256 mockCollateral = llamaLend.userCollateral(address(lm));
        assertEq(
            lmCollateral, mockCollateral, "getCurrentCollateral != llamaLend tracked collateral"
        );

        uint256 lmDebt = lm.getCurrentDebt();
        uint256 mockDebt = llamaLend.debt(address(lm));
        assertEq(lmDebt, mockDebt, "getCurrentDebt != llamaLend.debt()");
    }

    // ============ INVARIANT 2: Health above minimum ============

    function invariant_healthAboveMinimum() public view {
        if (handler.ghost_priceChangedDuringLoan()) return;
        if (!lm.loanExists()) return;

        uint256 currentDebt = llamaLend.debt(address(lm));
        if (currentDebt == 0) return;

        int256 health = lm.getHealth();
        assertGe(health, lm.MIN_HEALTH(), "Health factor below MIN_HEALTH after LM operation");
    }

    // ============ INVARIANT 3: loanExists consistency ============

    function invariant_loanExistsConsistency() public view {
        bool lmExists = lm.loanExists();
        bool mockExists = llamaLend.loan_exists(address(lm));
        assertEq(lmExists, mockExists, "loanExists() inconsistent with llamaLend.loan_exists()");
    }

    // ============ INVARIANT 4: Full unwind cleans up ============

    function invariant_fullUnwindCleansUp() public view {
        if (!handler.ghost_lastActionWasFullUnwind()) return;

        assertFalse(llamaLend.loan_exists(address(lm)), "Loan still exists after full unwind");
        assertFalse(lm.loanExists(), "LM reports loan exists after full unwind");
    }

    // ============ INVARIANT 5: Net collateral non-negative ============

    function invariant_netCollateralNonNegative() public view {
        // getNetCollateralValue returns 0 if debt > collateral, so this checks for reverts
        lm.getNetCollateralValue();
    }

    // ============ INVARIANT 6: No stuck collateral ============

    function invariant_noStuckCollateral() public view {
        if (lm.loanExists()) return;

        uint256 idleCollateral = collateral.balanceOf(address(lm));
        assertEq(idleCollateral, 0, "Collateral stuck in LM when no loan exists");
    }

    // ============ INVARIANT 7: Flash loan repayment complete ============

    function invariant_flashloanRepaymentComplete() public view {
        // The flash lender should never have outstanding unreturned loans.
        // After any flashloan path, the lender's balance should be >= fees collected.
        // (In our mock, the lender receives repayments directly as transfers)
        uint256 lenderBalance = debt.balanceOf(address(flashLender));
        uint256 feesCollected = flashLender.totalFeesCollected();
        assertGe(lenderBalance, feesCollected, "Flash lender missing repayment");
    }

    // ============ INVARIANT 8: Call summary ============

    function invariant_callSummary() public view {
        console.log("--- LlamaLoanManager Invariant Call Summary ---");
        console.log("createLoan:       ", handler.calls_createLoan());
        console.log("addCollateral:    ", handler.calls_addCollateral());
        console.log("borrowMore:       ", handler.calls_borrowMore());
        console.log("repayDebt:        ", handler.calls_repayDebt());
        console.log("removeCollateral: ", handler.calls_removeCollateral());
        console.log("unwindPartial:    ", handler.calls_unwindPartial());
        console.log("unwindFull:       ", handler.calls_unwindFull());
        console.log("changePrice:      ", handler.calls_changePrice());
        console.log("Loan exists:      ", lm.loanExists());
    }
}
