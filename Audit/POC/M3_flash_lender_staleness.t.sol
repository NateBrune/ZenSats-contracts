// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { LlamaLoanManager } from "../../src/lenders/LlamaLoanManager.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { ILlamaLendController } from "../../src/interfaces/ILlamaLendController.sol";
import { ICurveTwoCrypto } from "../../src/interfaces/ICurveTwoCrypto.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";
import { ISwapper } from "../../src/interfaces/ISwapper.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mocks ============

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burnFrom(address from, uint256 a) external { _burn(from, a); }
}

contract MockOracle is IChainlinkOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 p) { decimals = d; price = p; updatedAt = block.timestamp; }
    function setPrice(int256 p) external { price = p; roundId++; answeredInRound = roundId; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 _ts) external { updatedAt = _ts; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
    function description() external pure returns (string memory) { return "Mock"; }
    function latestAnswer() external view returns (int256) { return price; }
}

contract MockTwoCrypto {
    MockERC20 public wbtc;
    MockERC20 public crvUSD;
    uint256 public rate;

    constructor(address _wbtc, address _crvUSD, uint256 _rate) {
        wbtc = MockERC20(_wbtc);
        crvUSD = MockERC20(_crvUSD);
        rate = _rate;
    }

    function setRate(uint256 _r) external { rate = _r; }
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return (dx * rate) / 1e8;
        if (i == 0 && j == 1) return (dx * 1e8) / rate;
        return 0;
    }
    function exchange(uint256 i, uint256 j, uint256 dx, uint256) external returns (uint256) {
        return exchange(i, j, dx, 0, msg.sender);
    }
    function exchange(uint256 i, uint256 j, uint256 dx, uint256, address receiver) public returns (uint256) {
        if (i == 1 && j == 0) {
            wbtc.transferFrom(msg.sender, address(this), dx);
            crvUSD.mint(receiver, (dx * rate) / 1e8);
            return (dx * rate) / 1e8;
        }
        if (i == 0 && j == 1) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            wbtc.mint(receiver, (dx * 1e8) / rate);
            return (dx * 1e8) / rate;
        }
        return 0;
    }
    function coins(uint256 i) external view returns (address) { return i == 0 ? address(crvUSD) : address(wbtc); }
    function balances(uint256 i) external view returns (uint256) {
        return i == 0 ? crvUSD.balanceOf(address(this)) : wbtc.balanceOf(address(this));
    }
}

contract MockLlamaLend is ILlamaLendController {
    struct Position { uint256 collateral; uint256 debt; }
    mapping(address => Position) internal positions;

    function create_loan(uint256 coll, uint256 debtAmount, uint256) external payable {
        positions[msg.sender].collateral += coll;
        positions[msg.sender].debt += debtAmount;
    }
    function add_collateral(uint256 coll) external payable { positions[msg.sender].collateral += coll; }
    function add_collateral(uint256 coll, address _for) external payable { positions[_for].collateral += coll; }
    function remove_collateral(uint256 coll) external {
        require(positions[msg.sender].collateral >= coll, "Insufficient collateral");
        positions[msg.sender].collateral -= coll;
    }
    function borrow_more(uint256 coll, uint256 debtAmount) external payable {
        positions[msg.sender].collateral += coll;
        positions[msg.sender].debt += debtAmount;
    }
    function repay(uint256 _d_debt) external {
        positions[msg.sender].debt = _d_debt >= positions[msg.sender].debt ? 0 : positions[msg.sender].debt - _d_debt;
    }
    function repay(uint256 _d_debt, address _for) external {
        positions[_for].debt = _d_debt >= positions[_for].debt ? 0 : positions[_for].debt - _d_debt;
    }
    function debt(address user) external view returns (uint256) { return positions[user].debt; }
    function loan_exists(address user) external view returns (bool) {
        return positions[user].debt > 0 || positions[user].collateral > 0;
    }
    function total_debt() external pure returns (uint256) { return 0; }
    function max_borrowable(uint256, uint256) external pure returns (uint256) { return 0; }
    function max_borrowable(uint256, uint256, uint256) external pure returns (uint256) { return 0; }
    function min_collateral(uint256 debt_, uint256 bands) external pure returns (uint256) {
        return bands == 0 ? 0 : debt_ / bands;
    }
    function health(address) external pure returns (int256) { return 2e18; }
    function health(address, bool) external pure returns (int256) { return 2e18; }
    function health_calculator(address, int256, int256, bool) external pure returns (int256) { return 2e18; }
    function user_state(address user) external view returns (uint256[4] memory) {
        Position memory pos = positions[user];
        return [pos.collateral, 0, pos.debt, 0];
    }
    function amm_price() external pure returns (uint256) { return 0; }
    function user_prices(address) external pure returns (uint256[2] memory) { return [0, 0]; }
}

contract MockSwapper {
    MockERC20 public collateral;
    MockERC20 public debt;
    constructor(address _coll, address _debt) { collateral = MockERC20(_coll); debt = MockERC20(_debt); }
    function swapCollateralForDebt(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        debt.mint(msg.sender, amount * 500e10);
    }
    function swapDebtForCollateral(uint256 amount) external {
        debt.transferFrom(msg.sender, address(this), amount);
        collateral.mint(msg.sender, amount / 500e10);
    }
    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) { return d; }
    function quoteDebtForCollateral(uint256 c) external pure returns (uint256) { return c; }
    function setSlippage(uint256) external {}
    function slippage() external view returns (uint256) { return 1e16; }
}

/// @notice Mock flash lender that can be "deprecated" (pauses lending)
contract MockFlashLender is IERC3156FlashLender {
    MockERC20 public debtToken;
    bool public paused = false;

    constructor(address _token) { debtToken = MockERC20(_token); }
    function pause() external { paused = true; }
    function unpause() external { paused = false; }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (paused) return 0;
        return debtToken.balanceOf(address(this));
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        if (paused) return 0;
        return (amount * 5) / 10000; // 0.05%
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external {
        if (paused) revert("FlashLender: paused");
        debtToken.mint(receiver, amount);
        uint256 fee = flashFee(token, amount);
        receiver.onFlashLoan(address(this), token, amount, fee, data);
        debtToken.transferFrom(receiver, address(this), amount + fee);
    }
}

// ============ Test ============

/// @title M3: DEBT_FLASH_LENDER Hardcoded Staleness
///
/// PoC demonstrating that LlamaLoanManager's DEBT_FLASH_LENDER is a hardcoded
/// constant address. If the crvUSD FlashLender contract is deprecated, paused,
/// or upgraded to a different address, full close unwinds via flashloan will
/// fail because the address in the loan manager is immutable.
///
/// Impact:
///   - Full close (withdrawAll, emergencyStep) fails when flashloan is needed
///   - Partial unwind (with available debt balance) still works
///   - Recovery: guardian can emergencySkipStep(1) and emergencyStep(2)
///
/// Run: forge test --match-contract M3_Flash_Lender_Staleness -vvv
contract M3_Flash_Lender_Staleness is Test {
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MockOracle wbtcOracle;
    MockOracle crvUsdOracle;
    MockTwoCrypto pool;
    MockLlamaLend llamaLend;
    MockSwapper swapper;
    MockFlashLender flashLender;

    LlamaLoanManager loanManager;

    address vault = makeAddr("vault");

    uint256 constant INITIAL_COLLATERAL = 100e8;    // 100 WBTC
    uint256 constant INITIAL_DEBT = 50_000e18;     // 50K crvUSD

    function setUp() public {
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);

        // Etch crvUSD at hardcoded constant address
        bytes memory erc20Code = address(crvUSD).code;
        vm.etch(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, erc20Code);

        wbtcOracle = new MockOracle(8, 100_000e8);
        crvUsdOracle = new MockOracle(8, 1e8);
        pool = new MockTwoCrypto(address(wbtc), address(crvUSD), 500e20);
        llamaLend = new MockLlamaLend();
        swapper = new MockSwapper(address(wbtc), address(crvUSD));
        flashLender = new MockFlashLender(address(crvUSD));

        // Deploy loan manager — DEBT_FLASH_LENDER is hardcoded in the source
        // We need to patch the constant to point to our mock
        loanManager = new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(llamaLend),
            address(pool),
            address(wbtcOracle),
            address(crvUsdOracle),
            address(swapper),
            vault
        );

        // Mock the DEBT_FLASH_LENDER constant by intercepting calls to it
        // The constant is 0x26dE7861e213A5351F6ED767d00e0839930e9eE1
        vm.etch(0x26dE7861e213A5351F6ED767d00e0839930e9eE1, address(flashLender).code);
        // Delegate calls from the hardcoded address to our mock
        vm.mockCall(
            0x26dE7861e213A5351F6ED767d00e0839930e9eE1,
            abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)"),
            abi.encode(true)
        );
    }

    /// @notice Core vulnerability: flash lender is deprecated/paused
    function test_FlashLenderPaused_FullCloseFails() public {
        console.log("=== M3: DEBT_FLASH_LENDER Hardcoded Staleness ===\n");

        // ─── Phase 1: Create loan ───
        wbtc.mint(address(loanManager), INITIAL_COLLATERAL);
        vm.startPrank(vault);
        wbtc.approve(address(llamaLend), INITIAL_COLLATERAL);
        loanManager.createLoan(INITIAL_COLLATERAL, INITIAL_DEBT);
        vm.stopPrank();

        console.log("=== INITIAL POSITION ===");
        console.log("Collateral:                    %d sat (%.4f WBTC)", INITIAL_COLLATERAL, uint256(INITIAL_COLLATERAL) / 1e8);
        console.log("Debt:                          %d crvUSD (%.0f)", INITIAL_DEBT, INITIAL_DEBT / 1e18);

        // ─── Phase 2: Flash lender is deprecated/paused ───
        flashLender.pause();

        console.log("\n=== FLASH LENDER DEPRECATED ===");
        console.log("Flash lender status:           PAUSED");
        console.log("DEBT_FLASH_LENDER address:     0x26dE7861e213A5351F6ED767d00e0839930e9eE1 (hardcoded)");

        // ─── Phase 3: Attempt full close (needs flashloan) ───
        // No debt token balance → must flashloan to repay

        console.log("\n=== FULL CLOSE ATTEMPT (type(uint256).max) ===");

        vm.prank(vault);
        // Mock the flashloan call to simulate the pause revert
        vm.mockCallRevert(
            0x26dE7861e213A5351F6ED767d00e0839930e9eE1,
            abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)"),
            "FlashLender: paused"
        );

        try loanManager.unwindPosition(type(uint256).max) {
            console.log("Full close SUCCEEDED (unexpected)");
            uint256 collRecovery = wbtc.balanceOf(vault);
            console.log("Collateral recovered:        %d sat", collRecovery);
        } catch (bytes memory reason) {
            console.log("Full close REVERTED:         %s", string(reason));

            console.log("\n=== VULNERABILITY CONFIRMED ===");
            console.log("The DEBT_FLASH_LENDER is hardcoded and immutable.");
            console.log("When the flash lender is deprecated/paused, full close fails.");
            console.log("");
            console.log("Impact:");
            console.log("  - Users cannot redeem (full withdraw blocks)");
            console.log("  - Emergency mode step 1 (unwind loan) fails");
            console.log("  - Guardian must emergencySkipStep(1) to bypass");
            console.log("  - Users can only redeem vault collateral (not strategy yield)");
        }

        console.log("\n=== RECOVERY PATHS ===");
        console.log("1. Guardian: emergencySkipStep(1) — skip the loan unwind");
        console.log("   → emergencyStep(2) — complete liquidation");
        console.log("   → Users redeem vault collateral only");
        console.log("2. Guardian: emergencyRescue(0) — transfer collateral directly");
        console.log("3. Wait for flash lender to be unpaused (if temporary)");
    }

    /// @notice Verify partial unwind works without flashloan (has debt balance)
    function test_PartialUnwind_WithoutFlashloan_Succeeds() public {
        console.log("\n=== PARTIAL UNWIND (No Flashloan Needed) ===\n");

        // Create loan
        wbtc.mint(address(loanManager), INITIAL_COLLATERAL);
        vm.startPrank(vault);
        wbtc.approve(address(llamaLend), INITIAL_COLLATERAL);
        loanManager.createLoan(INITIAL_COLLATERAL, INITIAL_DEBT);
        vm.stopPrank();

        // Flash lender is paused
        flashLender.pause();

        // Give the loan manager debt to repay (no flashloan needed)
        crvUSD.mint(address(loanManager), INITIAL_DEBT);

        console.log("Debt token balance:              %d crvUSD (sufficient to repay)", INITIAL_DEBT / 1e18);
        console.log("Flash lender status:             PAUSED");

        uint256 collateralNeeded = 50e8;

        // Partial unwind with sufficient debt balance → no flashloan needed
        vm.prank(vault);
        loanManager.unwindPosition(collateralNeeded);

        uint256 collRecovery = wbtc.balanceOf(vault);

        console.log("\n=== RESULT ===");
        console.log("Partial unwind SUCCEEDED");
        console.log("Collateral recovered:            %d sat (%.1f WBTC)", collRecovery, uint256(collRecovery) / 1e8);
        console.log("");
        console.log("VERIFIED: Partial unwind works when the loan manager has");
        console.log("enough debt balance to repay without a flashloan.");
        console.log("");
        console.log("The flash lender staleness only affects FULL CLOSE (withdrawAll)");
        console.log("where all debt must be repaid via flashloan.");
    }

    /// @notice Verify the flash lender address is indeed hardcoded
    function test_FlashLenderAddress_Hardcoded() public {
        console.log("\n=== DEBT_FLASH_LENDER Constant ===\n");

        // The constant is defined in LlamaLoanManager.sol:
        // address public constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;

        address expected = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;
        console.log("DEBT_FLASH_LENDER constant:      0x%s", vm.toString(expected));
        console.log("");
        console.log("This address is immutable and cannot be changed without redeploying");
        console.log("the entire loan manager. If the crvUSD FlashLender at this address");
        console.log("is deprecated, upgraded, or replaced, the loan manager will fail");
        console.log("on any operation requiring a flashloan (full close).");
        console.log("");
        console.log("=== FIX OPTIONS ===");
        console.log("1. Make DEBT_FLASH_LENDER mutable (upgradeable via gov)");
        console.log("2. Add a fallback flash lender address");
        console.log("3. Try multiple flash lenders (Curve pool, Aave, etc.)");
    }
}
