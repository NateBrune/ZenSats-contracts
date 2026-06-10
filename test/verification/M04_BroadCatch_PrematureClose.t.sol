// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title M-04: LlamaLend undiscriminated broad catch triggers premature full close
///
/// HYPOTHESIS (MEDIUM):
///   In LlamaLoanManager.unwindPosition() the *direct removal* path uses an UNDISCRIMINATED
///   broad catch around health_calculator()/remove_collateral():
///
///       try llamaLend.health_calculator(address(this), -int256(toRemove), 0, true)
///           returns (int256 projectedHealth) { ... }
///       catch { escalate = true; }          // <-- ANY revert escalates to a full close
///
///   The repay() partial path (a few lines above) correctly DISCRIMINATES: it only escalates
///   on LlamaLend's band-redistribution dust assertion ("Amount too low"); any other reason
///   reverts with PartialRepayFailed() and leaves the position intact:
///
///       catch Error(string memory reason) {
///           if (keccak256(bytes(reason)) != _DUST_REVERT_HASH) revert PartialRepayFailed();
///           ...escalate...
///       }
///       catch { revert PartialRepayFailed(); }   // non-string revert -> fail safe
///
///   CONSEQUENCE: if health_calculator() reverts for ANY reason that is NOT the dust assertion
///   (controller pause/transient fault, a Vyper Panic, an oracle hiccup inside the controller,
///   a transiently-unsafe projected state), a *partial* unwind is silently escalated to a
///   destructive FULL CLOSE — the entire LlamaLend position is unwound via flash loan, all
///   remaining depositors' collateral is liquidated and re-priced against now-idle collateral.
///   The defense parity that repay() has is missing here.
///
/// This is a unit test with a mock LlamaLend controller whose health_calculator() reverts with
/// a NON-dust error. We assert:
///   (1) the direct-removal catch escalates to full close (loan fully closed, flash path taken),
///   (2) the SAME error through the repay() partial path would instead revert PartialRepayFailed
///       (defense-parity contrast).

import { Test, console } from "forge-std/Test.sol";
import { LlamaLoanManager } from "../../src/lenders/LlamaLoanManager.sol";
import { ILoanManager } from "../../src/interfaces/ILoanManager.sol";
import { ILlamaLendController } from "../../src/interfaces/ILlamaLendController.sol";
import { ICurveTwoCrypto } from "../../src/interfaces/ICurveTwoCrypto.sol";
import { IChainlinkOracle } from "../../src/interfaces/IChainlinkOracle.sol";
import { ISwapper } from "../../src/interfaces/ISwapper.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function burnFrom(address from, uint256 a) external {
        _burn(from, a);
    }
}

contract MockOracle is IChainlinkOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;

    constructor(uint8 d, int256 p) {
        decimals = d;
        price = p;
        updatedAt = block.timestamp;
    }

    function refresh() external {
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, updatedAt, updatedAt, 1);
    }

    function description() external pure returns (string memory) {
        return "Mock";
    }

    function latestAnswer() external view returns (int256) {
        return price;
    }
}

contract MockTwoCrypto is ICurveTwoCrypto {
    MockERC20 public collat;
    MockERC20 public debt;
    uint256 public rate; // debt per 1e8 collat

    constructor(address _c, address _d, uint256 _rate) {
        collat = MockERC20(_c);
        debt = MockERC20(_d);
        rate = _rate;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return (dx * rate) / 1e8;
        if (i == 0 && j == 1) return (dx * 1e8) / rate;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256) external returns (uint256) {
        return exchange(i, j, dx, 0, msg.sender);
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256, address recv)
        public
        returns (uint256)
    {
        if (i == 1 && j == 0) {
            collat.transferFrom(msg.sender, address(this), dx);
            uint256 out = (dx * rate) / 1e8;
            debt.mint(recv, out);
            return out;
        }
        if (i == 0 && j == 1) {
            debt.transferFrom(msg.sender, address(this), dx);
            uint256 out = (dx * 1e8) / rate;
            collat.mint(recv, out);
            return out;
        }
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(debt) : address(collat);
    }

    function balances(uint256 i) external view returns (uint256) {
        return i == 0 ? debt.balanceOf(address(this)) : collat.balanceOf(address(this));
    }
}

/// @notice Controller whose health_calculator() reverts with a configurable, NON-dust error.
contract MockLlamaController is ILlamaLendController {
    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address => Position) public positions;

    // Toggle: when true, health_calculator() reverts with a non-dust custom error.
    bool public revertHealthCalc;

    error ControllerPaused(); // a NON-"Amount too low" revert (a custom error => empty-string catch)

    function setRevertHealthCalc(bool v) external {
        revertHealthCalc = v;
    }

    function create_loan(uint256 c, uint256 d, uint256) external payable {
        positions[msg.sender].collateral += c;
        positions[msg.sender].debt += d;
    }

    function add_collateral(uint256 c) external payable {
        positions[msg.sender].collateral += c;
    }

    function add_collateral(uint256 c, address f) external payable {
        positions[f].collateral += c;
    }

    function remove_collateral(uint256 c) external {
        Position storage p = positions[msg.sender];
        require(p.collateral >= c, "Insufficient collateral");
        p.collateral -= c;
    }

    function borrow_more(uint256 c, uint256 d) external payable {
        positions[msg.sender].collateral += c;
        positions[msg.sender].debt += d;
    }

    function repay(uint256 d) external {
        Position storage p = positions[msg.sender];
        p.debt = d >= p.debt ? 0 : p.debt - d;
    }

    function repay(uint256 d, address f) external {
        Position storage p = positions[f];
        p.debt = d >= p.debt ? 0 : p.debt - d;
    }

    function debt(address u) external view returns (uint256) {
        return positions[u].debt;
    }

    function loan_exists(address u) external view returns (bool) {
        Position memory p = positions[u];
        return p.debt > 0 || p.collateral > 0;
    }

    function total_debt() external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function min_collateral(uint256 d, uint256 b) external pure returns (uint256) {
        return b == 0 ? 0 : d / b;
    }

    function health(address) external pure returns (int256) {
        return 2e18;
    }

    function health(address, bool) external pure returns (int256) {
        return 2e18;
    }

    function health_calculator(address, int256, int256, bool) external view returns (int256) {
        if (revertHealthCalc) revert ControllerPaused();
        return 2e18;
    }

    function user_state(address u) external view returns (uint256[4] memory) {
        Position memory p = positions[u];
        return [p.collateral, 0, p.debt, 0];
    }

    function amm_price() external pure returns (uint256) {
        return 0;
    }

    function user_prices(address) external pure returns (uint256[2] memory) {
        return [uint256(0), uint256(0)];
    }

    function collateral_token() external pure returns (address) {
        return address(0);
    }

    function amm() external pure returns (address) {
        return address(0);
    }

    function liquidation_discounts(address) external pure returns (uint256) {
        return 0;
    }

    function liquidation_discount() external pure returns (uint256) {
        return 0;
    }

    function loan_discount() external pure returns (uint256) {
        return 0;
    }
}

contract MockSwapper is ISwapper {
    MockERC20 public c;
    MockERC20 public d;
    MockTwoCrypto public pool;

    constructor(address _c, address _d, address _pool) {
        c = MockERC20(_c);
        d = MockERC20(_d);
        pool = MockTwoCrypto(_pool);
    }

    function quoteCollateralForDebt(uint256 a) external view returns (uint256) {
        return a == 0 ? 0 : pool.get_dy(0, 1, a);
    }

    function swapCollateralForDebt(uint256 a) external returns (uint256) {
        if (a == 0) return 0;
        c.approve(address(pool), a);
        uint256 r = pool.exchange(1, 0, a, 0);
        d.transfer(msg.sender, r);
        return r;
    }

    function swapDebtForCollateral(uint256 a) external returns (uint256) {
        if (a == 0) return 0;
        d.approve(address(pool), a);
        uint256 r = pool.exchange(0, 1, a, 0);
        c.transfer(msg.sender, r);
        return r;
    }
}

contract M04_BroadCatch_PrematureCloseTest is Test {
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MockOracle btcOracle;
    MockOracle crvUsdOracle;
    MockTwoCrypto pool;
    MockLlamaController llama;
    MockSwapper swapper;
    LlamaLoanManager mgr;

    address vault = makeAddr("vault");

    // crvUSD flash lender hardcoded in LlamaLoanManager
    address constant FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;

    function setUp() public {
        vm.warp(1_710_000_000);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        btcOracle = new MockOracle(8, 60_000e8);
        crvUsdOracle = new MockOracle(8, 1e8);
        pool = new MockTwoCrypto(address(wbtc), address(crvUSD), 60_000e18);
        llama = new MockLlamaController();
        swapper = new MockSwapper(address(wbtc), address(crvUSD), address(pool));

        mgr = new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(llama),
            address(pool),
            address(btcOracle),
            address(crvUsdOracle),
            address(swapper),
            vault,
            3600
        );
    }

    /// @notice FIX VERIFICATION: a NON-dust health_calculator revert now surfaces as
    ///         PartialUnwindFailed(), leaving the position intact rather than silently escalating.
    function test_M04_nonDustHealthCalcRevert_escalatesToFullClose() public {
        // Create a position with collateral + debt.
        vm.prank(vault);
        mgr.createLoan(2e8, 10_000e18);

        // Fund the manager with enough crvUSD to do a partial repay but NOT the full debt,
        // so we reach the direct-removal branch, then hit health_calculator() inside remove path.
        crvUSD.mint(address(mgr), 1_000e18);

        // Sanity: loan exists with full collateral before unwind.
        assertTrue(llama.loan_exists(address(mgr)), "precondition: loan exists");
        (uint256 collBefore, uint256 debtBefore) = mgr.getPositionValues();
        assertEq(collBefore, 2e8, "precondition collateral");
        assertEq(debtBefore, 10_000e18, "precondition debt");

        // Arm the NON-dust revert in health_calculator (e.g. controller paused / transient fault).
        // The MockLlamaController reverts with ControllerPaused() — a custom error (empty-string catch).
        llama.setRevertHealthCalc(true);

        // FIX: non-dust revert from health_calculator now surfaces as PartialUnwindFailed(),
        // leaving the position intact rather than silently escalating to a full close.
        vm.prank(vault);
        vm.expectRevert(LlamaLoanManager.PartialUnwindFailed.selector);
        mgr.unwindPosition(0.5e8);

        // Position is INTACT — the fix fails safe.
        assertTrue(llama.loan_exists(address(mgr)), "FIX: position intact after non-dust revert");
        (uint256 collAfter, uint256 debtAfter) = mgr.getPositionValues();
        assertEq(collAfter, collBefore, "FIX: collateral unchanged");
        assertEq(debtAfter, debtBefore, "FIX: debt unchanged");

        console.log("[M04 FIX VERIFIED] non-dust health_calculator revert => PartialUnwindFailed, position intact");
    }

    /// @notice DEFENSE PARITY CONTRAST: the SAME class of non-dust revert, when surfaced through
    ///         the repay() partial path, is handled SAFELY (reverts PartialRepayFailed, position
    ///         intact). This proves the two paths handle identical errors DIFFERENTLY.
    ///
    ///         We demonstrate the discriminator directly: the repay() partial path only escalates
    ///         on keccak("Amount too low"); any other Error(string) reverts PartialRepayFailed,
    ///         and any non-string (custom error / panic) revert ALSO reverts PartialRepayFailed.
    function test_M04_defenseParity_repayPathFailsSafeOnNonDust() public {
        // Use a controller whose repay() reverts with a NON-dust string on partial repay,
        // forcing the repay() catch path. Reaching that branch requires repayNow > 0,
        // not fullyClose, and repayNow != currentDebt.
        RepayRevertController rc = new RepayRevertController();
        LlamaLoanManager mgr2 = new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(rc),
            address(pool),
            address(btcOracle),
            address(crvUsdOracle),
            address(swapper),
            vault,
            3600
        );

        vm.prank(vault);
        mgr2.createLoan(2e8, 10_000e18);
        // Fund a partial repay amount (< full debt) so the partial branch with try/catch runs.
        crvUSD.mint(address(mgr2), 1_000e18);

        rc.setRevertReason("Controller paused"); // NON-dust Error(string)

        // The repay() partial path discriminates: non-dust string => PartialRepayFailed, position intact.
        vm.prank(vault);
        vm.expectRevert(LlamaLoanManager.PartialRepayFailed.selector);
        mgr2.unwindPosition(0.5e8);

        // Position is INTACT — defense fails safe.
        assertTrue(rc.loan_exists(address(mgr2)), "repay path: position intact after non-dust revert");
        console.log("[M04 PARITY] repay() partial path fails SAFE (PartialRepayFailed) on non-dust");
        console.log("            health_calculator path ESCALATES on the same class of error.");
    }
}

/// @notice Minimal ERC3156 flash lender stub used at the hardcoded DEBT_FLASH_LENDER address.
///         flashLoan() mints `amount` debt to the borrower, calls onFlashLoan, then pulls repayment.
contract FlashLenderStub {
    address public immutable token;

    constructor(address _token) {
        token = _token;
    }

    function flashLoan(address borrower, address _token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        MockERC20(_token).mint(borrower, amount);
        bytes32 ret = IERC3156Borrower(borrower).onFlashLoan(borrower, _token, amount, 0, data);
        require(ret == keccak256("ERC3156FlashBorrower.onFlashLoan"), "bad callback");
        // pull repayment (amount + 0 fee); borrower already approved? It uses safeTransfer to msg.sender.
        return true;
    }
}

interface IERC3156Borrower {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32);
}

/// @notice Controller whose partial repay() reverts with a configurable NON-dust string.
contract RepayRevertController is ILlamaLendController {
    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address => Position) public positions;
    string public revertReason;
    bool private _armed;

    function setRevertReason(string calldata r) external {
        revertReason = r;
        _armed = true;
    }

    function create_loan(uint256 c, uint256 d, uint256) external payable {
        positions[msg.sender].collateral += c;
        positions[msg.sender].debt += d;
    }

    function add_collateral(uint256 c) external payable {
        positions[msg.sender].collateral += c;
    }

    function add_collateral(uint256 c, address f) external payable {
        positions[f].collateral += c;
    }

    function remove_collateral(uint256 c) external {
        Position storage p = positions[msg.sender];
        require(p.collateral >= c, "Insufficient collateral");
        p.collateral -= c;
    }

    function borrow_more(uint256 c, uint256 d) external payable {
        positions[msg.sender].collateral += c;
        positions[msg.sender].debt += d;
    }

    function repay(uint256 d) external {
        // Partial repay (d < debt) triggers the configured non-dust revert.
        Position storage p = positions[msg.sender];
        if (_armed && d < p.debt) {
            require(false, revertReason);
        }
        p.debt = d >= p.debt ? 0 : p.debt - d;
    }

    function repay(uint256 d, address f) external {
        Position storage p = positions[f];
        p.debt = d >= p.debt ? 0 : p.debt - d;
    }

    function debt(address u) external view returns (uint256) {
        return positions[u].debt;
    }

    function loan_exists(address u) external view returns (bool) {
        Position memory p = positions[u];
        return p.debt > 0 || p.collateral > 0;
    }

    function total_debt() external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function min_collateral(uint256 d, uint256 b) external pure returns (uint256) {
        return b == 0 ? 0 : d / b;
    }

    function health(address) external pure returns (int256) {
        return 2e18;
    }

    function health(address, bool) external pure returns (int256) {
        return 2e18;
    }

    function health_calculator(address, int256, int256, bool) external pure returns (int256) {
        return 2e18;
    }

    function user_state(address u) external view returns (uint256[4] memory) {
        Position memory p = positions[u];
        return [p.collateral, 0, p.debt, 0];
    }

    function amm_price() external pure returns (uint256) {
        return 0;
    }

    function user_prices(address) external pure returns (uint256[2] memory) {
        return [uint256(0), uint256(0)];
    }

    function collateral_token() external pure returns (address) {
        return address(0);
    }

    function amm() external pure returns (address) {
        return address(0);
    }

    function liquidation_discounts(address) external pure returns (uint256) {
        return 0;
    }

    function liquidation_discount() external pure returns (uint256) {
        return 0;
    }

    function loan_discount() external pure returns (uint256) {
        return 0;
    }
}
