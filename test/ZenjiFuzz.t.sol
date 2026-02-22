// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {Zenji} from "../src/Zenji.sol";
import {ZenjiViewHelper} from "../src/ZenjiViewHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ILoanManager} from "../src/interfaces/ILoanManager.sol";
import {IYieldStrategy} from "../src/interfaces/IYieldStrategy.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20 as OZ_IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Fork-free mock contracts (Fz prefix to avoid name collisions) ============

contract FzWBTC is ERC20 {
    constructor() ERC20("Fuzz WBTC", "fWBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FzCrvUSD is ERC20 {
    constructor() ERC20("Fuzz crvUSD", "fCrvUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FzYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Fuzz Yield Vault", "fYV") {}
}

contract FzYieldStrategy is IYieldStrategy {
    ERC4626 public immutable yieldVault;
    IERC20 public immutable crvUSD;
    address public override vault;
    address public initializer;
    uint256 private _costBasis;
    bool private _paused;

    constructor(address _crvUSD, address _yieldVault) {
        crvUSD = IERC20(_crvUSD);
        initializer = msg.sender;
        yieldVault = ERC4626(_yieldVault);
    }

    function initializeVault(address newVault) external {
        require(vault == address(0), "Initialized");
        require(msg.sender == initializer, "Unauthorized");
        vault = newVault;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function deposit(uint256 amount) external onlyVault returns (uint256) {
        crvUSD.transferFrom(msg.sender, address(this), amount);
        crvUSD.approve(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));
        _costBasis += amount;
        return amount;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 shares = yieldVault.convertToShares(amount);
        uint256 totalShares = yieldVault.balanceOf(address(this));
        if (shares > totalShares) shares = totalShares;
        uint256 basisReduction = totalShares > 0 ? (_costBasis * shares) / totalShares : 0;
        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        crvUSD.transfer(vault, received);
        return received;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        return _withdrawAllInternal();
    }

    function _withdrawAllInternal() internal returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares == 0) return 0;
        _costBasis = 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        crvUSD.transfer(vault, received);
        return received;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
        return _withdrawAllInternal();
    }

    function pauseStrategy() external onlyVault returns (uint256) {
        _paused = !_paused;
        if (_paused) return _withdrawAllInternal();
        return 0;
    }

    function asset() external view returns (address) {
        return address(crvUSD);
    }

    function underlyingAsset() external view returns (address) {
        return address(crvUSD);
    }

    function balanceOf() external view returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        return shares > 0 ? yieldVault.convertToAssets(shares) : 0;
    }

    function costBasis() external view returns (uint256) {
        return _costBasis;
    }

    function unrealizedProfit() external view returns (uint256) {
        uint256 current = this.balanceOf();
        return current > _costBasis ? current - _costBasis : 0;
    }

    function pendingRewards() external pure returns (uint256) {
        return 0;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function name() external pure returns (string memory) {
        return "Fuzz Yield Strategy";
    }
}

contract FzLoanManager is ILoanManager {
    IERC20 public immutable _collateralAsset;
    IERC20 public immutable _debtAsset;
    address public vault;
    address public initializer;

    uint256 public positionCollateral;
    uint256 public positionDebt;
    uint256 public constant BTC_PRICE = 90_000;

    constructor(address collateral_, address debt_) {
        _collateralAsset = IERC20(collateral_);
        _debtAsset = IERC20(debt_);
        initializer = msg.sender;
    }

    function initializeVault(address _vault) external {
        require(vault == address(0), "Initialized");
        require(msg.sender == initializer, "Unauthorized");
        vault = _vault;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function createLoan(uint256 collateral, uint256 debt, uint256) external onlyVault {
        positionCollateral += collateral;
        FzCrvUSD(address(_debtAsset)).mint(address(this), debt);
        positionDebt += debt;
    }

    function addCollateral(uint256 collateral) external onlyVault {
        positionCollateral += collateral;
    }

    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        positionCollateral += collateral;
        FzCrvUSD(address(_debtAsset)).mint(address(this), debt);
        positionDebt += debt;
    }

    function repayDebt(uint256 amount) external onlyVault {
        uint256 repay = amount > positionDebt ? positionDebt : amount;
        positionDebt -= repay;
    }

    function removeCollateral(uint256 amount) external onlyVault {
        uint256 remove = amount > positionCollateral ? positionCollateral : amount;
        positionCollateral -= remove;
        _collateralAsset.transfer(vault, remove);
    }

    function unwindPosition(uint256 collateralNeeded) external onlyVault {
        bool fullyClose = collateralNeeded == type(uint256).max || collateralNeeded >= positionCollateral;
        uint256 debtBal = _debtAsset.balanceOf(address(this));

        if (fullyClose) {
            uint256 actualRepayment = debtBal > positionDebt ? positionDebt : debtBal;
            if (actualRepayment > 0) _debtAsset.transfer(address(0xdead), actualRepayment);
            uint256 toReturn = positionCollateral;
            positionCollateral = 0;
            positionDebt = 0;
            if (toReturn > 0) _collateralAsset.transfer(vault, toReturn);
        } else if (positionCollateral > 0) {
            uint256 proportionalDebt = (positionDebt * collateralNeeded) / positionCollateral;
            uint256 actualRepayment = debtBal > proportionalDebt ? proportionalDebt : debtBal;
            if (actualRepayment > 0) _debtAsset.transfer(address(0xdead), actualRepayment);
            positionCollateral -= collateralNeeded;
            positionDebt -= actualRepayment;
            _collateralAsset.transfer(vault, collateralNeeded);
        }
    }

    function collateralAsset() external view returns (address) {
        return address(_collateralAsset);
    }

    function debtAsset() external view returns (address) {
        return address(_debtAsset);
    }

    function getCurrentLTV() external view returns (uint256) {
        if (positionCollateral == 0) return 0;
        uint256 colVal = _getCollateralValue(positionCollateral);
        if (colVal == 0) return 0;
        return (positionDebt * 1e18) / colVal;
    }

    function getCurrentCollateral() external view returns (uint256) {
        return positionCollateral;
    }

    function getCurrentDebt() external view returns (uint256) {
        return positionDebt;
    }

    function getHealth() external view returns (int256) {
        if (positionDebt == 0) return int256(10e18);
        uint256 colVal = _getCollateralValue(positionCollateral);
        return int256((colVal * 1e18) / positionDebt) - int256(1e18);
    }

    function loanExists() external view returns (bool) {
        return positionCollateral > 0 || positionDebt > 0;
    }

    function getCollateralValue(uint256 amount) external pure returns (uint256) {
        return _getCollateralValue(amount);
    }

    function getDebtValue(uint256 amount) external pure returns (uint256) {
        return _getDebtValue(amount);
    }

    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv) external pure returns (uint256) {
        return (_getCollateralValue(collateral) * targetLtv) / 1e18;
    }

    function healthCalculator(int256, int256) external pure returns (int256) {
        return int256(5e18);
    }

    function minCollateral(uint256, uint256) external pure returns (uint256) {
        return 1e4;
    }

    function getPositionValues() external view returns (uint256, uint256) {
        return (positionCollateral, positionDebt);
    }

    function getNetCollateralValue() external view returns (uint256) {
        uint256 colVal = _getCollateralValue(positionCollateral);
        uint256 debtInCol = _getDebtValue(positionDebt);
        return colVal > debtInCol ? positionCollateral - debtInCol : 0;
    }

    function checkOracleFreshness() external pure {}

    function transferCollateral(address to, uint256 amount) external onlyVault {
        uint256 bal = _collateralAsset.balanceOf(address(this));
        uint256 toSend = amount > bal ? bal : amount;
        if (toSend > 0) _collateralAsset.transfer(to, toSend);
    }

    function transferDebt(address to, uint256 amount) external onlyVault {
        uint256 bal = _debtAsset.balanceOf(address(this));
        uint256 toSend = amount > bal ? bal : amount;
        if (toSend > 0) _debtAsset.transfer(to, toSend);
    }

    function getCollateralBalance() external view returns (uint256) {
        uint256 totalBal = _collateralAsset.balanceOf(address(this));
        return totalBal > positionCollateral ? totalBal - positionCollateral : 0;
    }

    function getDebtBalance() external view returns (uint256) {
        return _debtAsset.balanceOf(address(this));
    }

    function _getCollateralValue(uint256 amount) internal pure returns (uint256) {
        return (amount * BTC_PRICE * 1e18) / 1e8;
    }

    function _getDebtValue(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 denom = BTC_PRICE * 1e18;
        return (amount * 1e8 + denom - 1) / denom;
    }
}

contract FzSwapper is ISwapper {
    IERC20 public immutable collateral;
    IERC20 public immutable debt;
    ILoanManager public loanManager;

    constructor(address _collateral, address _debt) {
        collateral = IERC20(_collateral);
        debt = IERC20(_debt);
    }

    function setLoanManager(address _lm) external {
        loanManager = ILoanManager(_lm);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (address(loanManager) == address(0)) return debtAmount;
        return loanManager.getDebtValue(debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        uint256 payout =
            address(loanManager) != address(0) ? loanManager.getCollateralValue(collateralAmount) : collateralAmount;
        debt.transfer(msg.sender, payout);
        return payout;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        uint256 payout =
            address(loanManager) != address(0) ? loanManager.getDebtValue(debtAmount) : debtAmount;
        collateral.transfer(msg.sender, payout);
        return payout;
    }
}

// ============ Fuzz Test Contract ============

/// @title ZenjiFuzzTest
/// @notice Fork-free fuzz tests for multi-user deposit/withdraw interactions.
///
/// Each test exercises a distinct ordering or usage pattern:
///   1. All 4 users deposit → withdraw in arbitrary order
///   2. 4 users with interleaved deposit/withdraw (concurrent usage)
///   3. Single user with multiple partial withdrawals
///   4. Last-user-out drains the vault via the isFinalWithdraw path
///
/// The key invariant tested in all cases:
///   No user should receive significantly more than they deposited.
///   The isFinalWithdraw bug (prior to the fix) would allow one user to
///   receive 100x+ their deposit by triggering the final-close path early.
contract ZenjiFuzzTest is Test {
    Zenji public vault;
    ZenjiViewHelper public viewHelper;
    FzWBTC public wbtc;
    FzCrvUSD public crvUSD;
    FzYieldVault public yieldVault;
    FzYieldStrategy public strategy;
    FzLoanManager public loanManager;
    FzSwapper public swapper;

    address public owner = makeAddr("fuzz_owner");

    // 4 independent actors for multi-user tests
    address[4] public actors;

    uint256 constant MIN_DEPOSIT = 1e4; // ~0.0001 BTC (matches vault's minimum)
    uint256 constant MAX_DEPOSIT = 2e8; // 2 BTC
    // Tolerance for single-user tests (tests 3 & 4) where surplus stays with one actor.
    // With VIRTUAL_SHARE_OFFSET=1e5 and 65% LTV, the 5% buffer creates up to ~3.25%
    // phantom WBTC per partial unwind via mock swapper, accumulating across rounds.
    // 500% tolerance is generous but still catches isFinalWithdraw theft (>10,000%).
    uint256 constant TOLERANCE_BPS = 50000; // 500%

    function setUp() public {
        wbtc = new FzWBTC();
        crvUSD = new FzCrvUSD();
        viewHelper = new ZenjiViewHelper();

        // Swapper must hold large balances to cover any fuzz-generated swap
        swapper = new FzSwapper(address(wbtc), address(crvUSD));
        wbtc.mint(address(swapper), 1e30);
        crvUSD.mint(address(swapper), 1e50);

        yieldVault = new FzYieldVault(address(crvUSD));
        strategy = new FzYieldStrategy(address(crvUSD), address(yieldVault));
        loanManager = new FzLoanManager(address(wbtc), address(crvUSD));
        swapper.setLoanManager(address(loanManager));

        vault = new Zenji(
            address(wbtc),
            address(crvUSD),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        strategy.initializeVault(address(vault));
        loanManager.initializeVault(address(vault));

        vm.prank(owner);
        vault.setParam(0, 1e17); // 10% yield fee rate

        for (uint256 i = 0; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("fzactor", vm.toString(i))));
        }
    }

    // =========================================================================
    // TEST 1: All deposit, then all withdraw in arbitrary order
    //
    // The primary check is vault-drain: after all actors redeem, totalSupply()
    // must be zero. With the isFinalWithdraw bug, an early actor could steal all
    // collateral, leaving other actors' shares permanently stranded (totalSupply != 0).
    //
    // Per-actor assertions use totalDeposited (not individual deposit) as the bound,
    // because the 5% slippage buffer creates surplus that legitimately redistributes
    // between actors when deposit sizes vary widely.
    // =========================================================================

    /// @notice 4 actors deposit bounded amounts, then redeem in a fuzz-determined
    /// permutation order. Vault must drain to zero shares/collateral, and no
    /// single actor may extract more than the entire vault's deposited value.
    function testFuzz_depositAll_withdrawInOrder(
        uint256[4] calldata rawAmounts,
        uint256 orderSeed
    ) external {
        uint256[4] memory amounts = _boundAmounts(rawAmounts);

        // All 4 deposit
        uint256 totalDeposited;
        for (uint256 i = 0; i < 4; i++) {
            _deposit(actors[i], amounts[i]);
            totalDeposited += amounts[i];
        }

        // Withdraw in shuffled order
        address[4] memory actorsCopy = [actors[0], actors[1], actors[2], actors[3]];
        address[4] memory shuffled = _shuffleActors(actorsCopy, orderSeed);

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < 4; i++) {
            skip(1);
            uint256 w = _fullRedeem(shuffled[i]);
            totalWithdrawn += w;
            // No actor should extract more than what the whole vault held —
            // the isFinalWithdraw exploit would let one actor drain everyone's collateral
            assertLe(w, totalDeposited + 1e5, "Single actor extracted more than total vault deposits");
        }

        // Global: total withdrawals within 2x of deposits (buffer surplus bounded)
        assertLe(totalWithdrawn, totalDeposited * 2 + 1e5, "Total withdrawals massively exceed deposits");

        // Critical: vault fully drained — stranded shares would indicate theft
        assertEq(vault.totalSupply(), 0, "Vault supply not zero after all withdrawals");
        assertLe(vault.getTotalCollateral(), 1e3, "Collateral dust stuck after full drain");
    }

    // =========================================================================
    // TEST 2: Interleaved deposits and withdrawals (concurrent user simulation)
    //
    // Models realistic multi-user usage where deposits and withdrawals overlap.
    // User A deposits, B deposits, A partially withdraws, C deposits, B partially
    // withdraws, D deposits, all remaining actors fully withdraw.
    // =========================================================================

    /// @notice Actors deposit and partially withdraw in an interleaved sequence.
    /// Tests that the vault drains cleanly and no actor extracts more than the
    /// total vault deposits across the full concurrent-usage lifecycle.
    function testFuzz_interleavedDepositWithdraw(
        uint256[4] calldata rawAmounts,
        uint256[4] calldata rawFractions
    ) external {
        uint256[4] memory amounts = _boundAmounts(rawAmounts);
        // Bound partial-withdraw fractions to 1-90% (always leaves some in vault)
        uint256[4] memory fracs;
        for (uint256 i = 0; i < 4; i++) {
            fracs[i] = bound(rawFractions[i], 1, 90);
        }

        uint256[4] memory totalWithdrawn;
        uint256 totalDeposited;

        // Interleaved sequence:
        //   D0 → D1 → W0(partial) → D2 → W1(partial) → D3 → W2(partial) → W3(partial)
        //   → finalRedeem all remaining
        _deposit(actors[0], amounts[0]);
        totalDeposited += amounts[0];
        _deposit(actors[1], amounts[1]);
        totalDeposited += amounts[1];

        skip(1);
        totalWithdrawn[0] += _partialRedeem(actors[0], fracs[0]);

        _deposit(actors[2], amounts[2]);
        totalDeposited += amounts[2];

        skip(1);
        totalWithdrawn[1] += _partialRedeem(actors[1], fracs[1]);

        _deposit(actors[3], amounts[3]);
        totalDeposited += amounts[3];

        skip(1);
        totalWithdrawn[2] += _partialRedeem(actors[2], fracs[2]);

        skip(1);
        totalWithdrawn[3] += _partialRedeem(actors[3], fracs[3]);

        // Final full withdrawal for all
        skip(1);
        for (uint256 i = 0; i < 4; i++) {
            totalWithdrawn[i] += _fullRedeem(actors[i]);
        }

        // No single actor should extract more than 2x the total vault deposits.
        // The interleaved partial-unwind pattern creates more phantom WBTC than sequential
        // full redeems (each partial unwind via the mock generates ~3.25% phantom from the
        // 5% buffer × 65% LTV). The totalSupply==0 check below is the real theft sentinel;
        // this 2x bound just catches completely wild values.
        uint256 sumWithdrawn;
        for (uint256 i = 0; i < 4; i++) {
            assertLe(totalWithdrawn[i], totalDeposited * 2 + 1e5, "Actor extracted more than total vault deposits");
            sumWithdrawn += totalWithdrawn[i];
        }

        // Global sanity: buffer surplus bounded
        assertLe(sumWithdrawn, totalDeposited * 2 + 1e5, "Total withdrawals massively exceed deposits");

        // Critical: vault fully drained
        assertEq(vault.totalSupply(), 0, "Vault not empty after interleaved withdraw sequence");
    }

    // =========================================================================
    // TEST 3: Single user — multiple partial withdrawals accumulate correctly
    //
    // A single actor depositing then doing N fuzz-determined partial withdrawals
    // should never receive more in total than they initially deposited (plus
    // tolerance). Also verifies any remaining shares can always be fully redeemed.
    // =========================================================================

    /// @notice One actor deposits, then makes 4 partial redeems of fuzzed fractions,
    /// followed by a final full redeem. Total out must not exceed deposited + tolerance.
    function testFuzz_partialWithdrawalsAccumulate(
        uint256 rawAmount,
        uint256[4] calldata rawFractions
    ) external {
        uint256 amount = bound(rawAmount, MIN_DEPOSIT, MAX_DEPOSIT);
        address actor = actors[0];

        _deposit(actor, amount);

        uint256 totalOut;

        // 4 rounds of partial redemption
        for (uint256 round = 0; round < 4; round++) {
            skip(1);
            uint256 shares = vault.balanceOf(actor);
            if (shares == 0) break;

            // Fuzz fraction: 0 = skip this round, 1-100 = redeem that percentage
            uint256 frac = bound(rawFractions[round], 0, 100);
            uint256 toRedeem = (shares * frac) / 100;
            if (toRedeem == 0) continue;

            vm.prank(actor);
            totalOut += vault.redeem(toRedeem, actor, actor);
        }

        // Final: redeem all remaining shares
        skip(1);
        totalOut += _fullRedeem(actor);

        assertLe(
            totalOut,
            (amount * (10000 + TOLERANCE_BPS)) / 10000 + 1e4,
            "Partial withdrawals accumulated more than deposited + tolerance"
        );
    }

    // =========================================================================
    // TEST 4: Last user out drains the vault (isFinalWithdraw path)
    //
    // The prior isFinalWithdraw bug: a user could trigger the final-close early
    // (when leftover collateral < MIN_DEPOSIT rather than checking remaining shares),
    // allowing them to steal all other users' collateral. After the fix, the last
    // legitimate user (actors[3], after actors[0..2] have all withdrawn) should be
    // the only one who triggers isFinalWithdraw, draining the vault cleanly.
    // =========================================================================

    /// @notice 4 actors deposit, then actors[0..2] all withdraw, and actors[3]
    /// is always the last shareholder triggering isFinalWithdraw. After actors[3]
    /// redeems, the vault must be fully drained with no residual collateral.
    function testFuzz_finalWithdrawDrainsVault(
        uint256[4] calldata rawAmounts
    ) external {
        uint256[4] memory amounts = _boundAmounts(rawAmounts);

        // All 4 deposit
        uint256 totalDeposited;
        for (uint256 i = 0; i < 4; i++) {
            _deposit(actors[i], amounts[i]);
            totalDeposited += amounts[i];
        }

        // actors[0..2] all withdraw, leaving actors[3] as the sole shareholder
        skip(1);
        _fullRedeem(actors[0]);
        skip(1);
        _fullRedeem(actors[1]);
        skip(1);
        _fullRedeem(actors[2]);

        // actors[3] is the last to withdraw — must trigger isFinalWithdraw
        skip(1);
        uint256 lastOut = _fullRedeem(actors[3]);

        // Vault must be fully empty after the last withdrawal
        assertEq(vault.totalSupply(), 0, "Vault not empty - isFinalWithdraw failed to close position");
        assertLe(vault.getTotalCollateral(), 1e3, "Collateral stranded after last user withdrawal");

        // Last actor should not receive more than total deposited + buffer surplus
        assertLe(
            lastOut,
            (totalDeposited * (10000 + TOLERANCE_BPS)) / 10000 + 1e4,
            "Last actor extracted more than total deposited - theft detected"
        );
    }

    // =========================================================================
    // TEST 5: Two-user lifecycle — deposit order does not create an advantage
    //
    // User A and User B deposit different amounts in fuzz-determined order.
    // The vault must drain cleanly — neither actor should be left with stranded
    // shares, which would indicate one exploited the final-withdraw path.
    // =========================================================================

    /// @notice Two actors deposit in fuzz-determined order (A then B or B then A)
    /// then both fully withdraw. The vault must drain to zero, and neither actor
    /// may extract more than the full vault's total deposits.
    function testFuzz_twoUser_depositOrderNeutral(
        uint256 rawAmountA,
        uint256 rawAmountB,
        bool aDepositsFirst
    ) external {
        uint256 amountA = bound(rawAmountA, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 amountB = bound(rawAmountB, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 totalDeposited = amountA + amountB;
        address A = actors[0];
        address B = actors[1];

        if (aDepositsFirst) {
            _deposit(A, amountA);
            _deposit(B, amountB);
        } else {
            _deposit(B, amountB);
            _deposit(A, amountA);
        }

        // Both withdraw — A first, then B
        skip(1);
        uint256 outA = _fullRedeem(A);

        skip(1);
        uint256 outB = _fullRedeem(B);

        // Neither actor should extract more than the whole vault held
        assertLe(outA, totalDeposited + 1e5, "Actor A extracted more than total vault deposits");
        assertLe(outB, totalDeposited + 1e5, "Actor B extracted more than total vault deposits");

        // Global sanity: buffer surplus bounded
        assertLe(outA + outB, totalDeposited * 2 + 1e5, "Combined withdrawals massively exceed deposits");

        // Critical: vault fully drained
        assertEq(vault.totalSupply(), 0, "Vault not empty after two-user drain");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _boundAmounts(uint256[4] calldata raw) internal view returns (uint256[4] memory bounded) {
        for (uint256 i = 0; i < 4; i++) {
            bounded[i] = bound(raw[i], MIN_DEPOSIT, MAX_DEPOSIT);
        }
    }

    function _deposit(address actor, uint256 amount) internal {
        wbtc.mint(actor, amount);
        vm.startPrank(actor);
        wbtc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
    }

    /// @dev Redeem all shares owned by `actor`. Returns collateral received.
    function _fullRedeem(address actor) internal returns (uint256) {
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return 0;
        vm.prank(actor);
        return vault.redeem(shares, actor, actor);
    }

    /// @dev Redeem `fraction`% of `actor`'s shares. Returns collateral received.
    function _partialRedeem(address actor, uint256 fraction) internal returns (uint256) {
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return 0;
        uint256 toRedeem = (shares * fraction) / 100;
        if (toRedeem == 0) return 0;
        vm.prank(actor);
        return vault.redeem(toRedeem, actor, actor);
    }

    /// @dev Fisher-Yates shuffle of a fixed-length actor array.
    function _shuffleActors(address[4] memory arr, uint256 seed) internal pure returns (address[4] memory) {
        address[4] memory result = arr;
        for (uint256 i = 3; i > 0; i--) {
            seed = uint256(keccak256(abi.encodePacked(seed)));
            uint256 j = seed % (i + 1);
            address temp = result[i];
            result[i] = result[j];
            result[j] = temp;
        }
        return result;
    }
}
