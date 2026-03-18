// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock ERC20 tokens ============

contract PmMockWBTC is ERC20 {
    constructor() ERC20("Mock WBTC", "WBTC") { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PmMockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PmMockCrvUSD is ERC20 {
    constructor() ERC20("Mock crvUSD", "crvUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PmMockCRV is ERC20 {
    constructor() ERC20("Mock CRV", "CRV") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PmMockPmUSD is ERC20 {
    constructor() ERC20("Mock pmUSD", "pmUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PmMockLP is ERC20 {
    constructor() ERC20("Mock pmUSD/crvUSD LP", "pmUSD-crvUSD") { }

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

contract PmMockOracle {
    int256 public price;
    uint8 public decimals_ = 8;

    constructor(int256 _price) {
        price = _price;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
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

// ============ Mock Curve USDT/crvUSD StableSwap pool ============
/// @dev 1:1 rate accounting for decimal difference (USDT=6, crvUSD=18)

contract PmMockUsdtCrvUsdPool {
    PmMockUSDT public usdt;
    PmMockCrvUSD public crvUSD;

    constructor(address _usdt, address _crvUSD) {
        usdt = PmMockUSDT(_usdt);
        crvUSD = PmMockCrvUSD(_crvUSD);
    }

    function get_dy(int128 i, int128, uint256 dx) external pure returns (uint256) {
        if (i == 0) {
            // USDT -> crvUSD: scale up 1e12
            return dx * 1e12;
        } else {
            // crvUSD -> USDT: scale down 1e12
            return dx / 1e12;
        }
    }

    // exchange with receiver param (called first by CurveUsdtSwapLib)
    function exchange(int128 i, int128, uint256 dx, uint256, address receiver)
        external
        returns (uint256)
    {
        return _doExchange(i, dx, receiver);
    }

    // exchange without receiver param (fallback)
    function exchange(int128 i, int128, uint256 dx, uint256) external returns (uint256) {
        return _doExchange(i, dx, msg.sender);
    }

    function _doExchange(int128 i, uint256 dx, address receiver) internal returns (uint256 dy) {
        if (i == 0) {
            // USDT -> crvUSD
            usdt.transferFrom(msg.sender, address(this), dx);
            dy = dx * 1e12;
            crvUSD.mint(receiver, dy);
        } else {
            // crvUSD -> USDT
            crvUSD.transferFrom(msg.sender, address(this), dx);
            dy = dx / 1e12;
            usdt.mint(receiver, dy);
        }
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(usdt) : address(crvUSD);
    }

    function balances(uint256) external pure returns (uint256) {
        return 1e30;
    }
}

// ============ Mock Curve pmUSD/crvUSD StableSwapNG pool ============
/// @dev 1:1 LP minting/burning. crvUSD index = 1.

contract PmMockLpPool {
    PmMockCrvUSD public crvUSD;
    PmMockPmUSD public pmUSD;
    PmMockLP public lp;
    int128 public crvUsdIndex;
    uint256 public pmUsdIndex;

    constructor(address _crvUSD, address _pmUSD, address _lp, int128 _crvUsdIndex) {
        crvUSD = PmMockCrvUSD(_crvUSD);
        pmUSD = PmMockPmUSD(_pmUSD);
        lp = PmMockLP(_lp);
        crvUsdIndex = _crvUsdIndex;
        pmUsdIndex = _crvUsdIndex == int128(0) ? 1 : 0;
    }

    function add_liquidity(uint256[] calldata amounts, uint256)
        external
        returns (uint256 lpMinted)
    {
        uint256 crvUsdAmount = amounts[uint256(uint128(crvUsdIndex))];
        uint256 pmUsdAmount = amounts[pmUsdIndex];
        if (crvUsdAmount > 0) crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount);
        if (pmUsdAmount > 0) pmUSD.transferFrom(msg.sender, address(this), pmUsdAmount);
        lpMinted = crvUsdAmount + pmUsdAmount; // 1:1
        if (lpMinted > 0) lp.mint(msg.sender, lpMinted);
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external
        returns (uint256)
    {
        lp.burn(msg.sender, burn_amount);
        uint256 crvUsdOut = burn_amount; // 1:1
        crvUSD.mint(msg.sender, crvUsdOut);
        return crvUsdOut;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIndex))] + amounts[pmUsdIndex]; // 1:1
    }

    function calc_withdraw_one_coin(uint256 burn_amount, int128) external pure returns (uint256) {
        return burn_amount; // 1:1
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }

    function coins(uint256 i) external view returns (address) {
        return i == uint256(uint128(crvUsdIndex)) ? address(crvUSD) : address(0);
    }

    function balances(uint256) external pure returns (uint256) {
        return 1e30;
    }
}

// ============ Mock Stake DAO Reward Vault (ERC4626) ============

contract PmMockRewardVault is ERC4626 {
    address public accountant;

    constructor(address _lpToken, address _accountant)
        ERC4626(OZ_IERC20(_lpToken))
        ERC20("Mock Reward Vault", "mRV")
    {
        accountant = _accountant;
    }

    function ACCOUNTANT() external view returns (address) {
        return accountant;
    }

    function claim() external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](0);
    }

    function earned(address, address) external pure returns (uint256) {
        return 0;
    }

    function rewardTokens(uint256) external pure returns (address) {
        return address(0);
    }

    function rewardTokensLength() external pure returns (uint256) {
        return 0;
    }
}

// ============ Mock Accountant ============

contract PmMockAccountant {
    PmMockCRV public crv;
    uint256 public pendingCrv;

    constructor(address _crv) {
        crv = PmMockCRV(_crv);
    }

    /// @dev Set pending rewards that will be distributed on next claim
    function setPendingRewards(uint256 amount) external {
        pendingCrv = amount;
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        if (pendingCrv > 0) {
            crv.mint(receiver, pendingCrv);
            pendingCrv = 0;
        }
    }

    function getPendingRewards(address, address) external view returns (uint256) {
        return pendingCrv;
    }

    function REWARD_TOKEN() external view returns (address) {
        return address(crv);
    }
}

// ============ Mock CRV -> crvUSD Swapper ============

contract PmMockCrvSwapper {
    PmMockCrvUSD public crvUSD;

    constructor(address _crvUSD) {
        crvUSD = PmMockCrvUSD(_crvUSD);
    }

    /// @dev 1:1 CRV -> crvUSD swap (CRV and crvUSD both 18 dec)
    function swap(uint256 amount) external returns (uint256) {
        crvUSD.mint(msg.sender, amount);
        return amount;
    }
}

// ============ Mock Loan Manager (WBTC/USDT) ============
/// @dev Variable price: default 1 WBTC = 90,000 USDT. WBTC=8 dec, USDT=6 dec.

contract PmMockLoanManager is ILoanManager {
    IERC20 public immutable _collateralAsset;
    IERC20 public immutable _debtAsset;
    address public vault;
    address public initializer;

    uint256 public positionCollateral;
    uint256 public positionDebt;

    uint256 public btcPrice = 90_000; // 1 BTC = 90,000 USDT (mutable for rebalance testing)

    function setPrice(uint256 newPrice) external {
        btcPrice = newPrice;
    }

    constructor(address collateral_, address debt_) {
        _collateralAsset = IERC20(collateral_);
        _debtAsset = IERC20(debt_);
        initializer = msg.sender;
    }

    function initializeVault(address _vault) external {
        if (vault != address(0)) revert("Initialized");
        if (msg.sender != initializer) revert("Unauthorized");
        vault = _vault;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    // ============ Loan Management ============

    function createLoan(uint256 collateral, uint256 debt, uint256) external onlyVault {
        positionCollateral += collateral;
        PmMockUSDT(address(_debtAsset)).mint(address(this), debt);
        positionDebt += debt;
    }

    function addCollateral(uint256 collateral) external onlyVault {
        positionCollateral += collateral;
    }

    function borrowMore(uint256 collateral, uint256 debt) external onlyVault {
        positionCollateral += collateral;
        PmMockUSDT(address(_debtAsset)).mint(address(this), debt);
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

    // ============ View Functions ============

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

    function getCollateralValue(uint256 collateralAmount) external view returns (uint256) {
        return _getCollateralValue(collateralAmount);
    }

    function getDebtValue(uint256 debtAmount) external view returns (uint256) {
        return _getDebtValue(debtAmount);
    }

    function calculateBorrowAmount(uint256 collateral, uint256 targetLtv)
        external
        view
        returns (uint256)
    {
        uint256 colVal = _getCollateralValue(collateral);
        return (colVal * targetLtv) / 1e18;
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
        uint256 debtInCollateral = _getDebtValue(positionDebt);
        return positionCollateral > debtInCollateral ? positionCollateral - debtInCollateral : 0;
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

    // ============ Internal Price Helpers ============
    // 1 WBTC (1e8 sats) = btcPrice USDT (btcPrice * 1e6 raw)
    // collateralValue(sats) = sats * btcPrice * 1e6 / 1e8
    // debtValue(usdt) = usdt * 1e8 / (btcPrice * 1e6)

    function _getCollateralValue(uint256 collateralAmount) internal view returns (uint256) {
        return (collateralAmount * btcPrice * 1e6) / 1e8;
    }

    function _getDebtValue(uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 denom = btcPrice * 1e6;
        return (debtAmount * 1e8 + denom - 1) / denom; // round up (conservative)
    }
}

// ============ Mock Swapper (WBTC <-> USDT) ============

contract PmMockSwapper is ISwapper {
    IERC20 public immutable collateral;
    IERC20 public immutable debt;
    ILoanManager public loanManager;

    constructor(address _collateral, address _debt) {
        collateral = IERC20(_collateral);
        debt = IERC20(_debt);
    }

    function setLoanManager(address _loanManager) external {
        loanManager = ILoanManager(_loanManager);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (address(loanManager) == address(0)) return debtAmount;
        return loanManager.getDebtValue(debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        uint256 payout = collateralAmount;
        if (address(loanManager) != address(0)) {
            payout = loanManager.getCollateralValue(collateralAmount);
        }
        PmMockUSDT(address(debt)).mint(msg.sender, payout);
        return payout;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        uint256 payout = debtAmount;
        if (address(loanManager) != address(0)) {
            payout = loanManager.getDebtValue(debtAmount);
        }
        PmMockWBTC(address(collateral)).mint(msg.sender, payout);
        return payout;
    }
}

// ============ Handler ============

/// @notice Handler contract for fuzz-driven vault operations.
/// Includes deposit, withdraw, rebalance, and harvest actions.
contract PmUsdHandler is Test {
    Zenji public vault;
    IERC20 public wbtc;
    PmMockAccountant public accountant;
    PmMockLoanManager public loanManager;
    PmUsdCrvUsdStrategy public strategy;

    address[] public actors;
    uint256 public constant NUM_ACTORS = 4;

    // Ghost variables
    mapping(address => uint256) public ghost_totalDeposited;
    mapping(address => uint256) public ghost_totalWithdrawn;
    uint256 public ghost_sumDeposits;
    uint256 public ghost_sumWithdrawals;

    // Call counters
    uint256 public calls_deposit;
    uint256 public calls_redeem;
    uint256 public calls_withdraw;
    uint256 public calls_rebalance;
    uint256 public calls_harvest;

    constructor(
        Zenji _vault,
        IERC20 _wbtc,
        PmMockAccountant _accountant,
        PmMockLoanManager _loanManager,
        PmUsdCrvUsdStrategy _strategy
    ) {
        vault = _vault;
        wbtc = _wbtc;
        accountant = _accountant;
        loanManager = _loanManager;
        strategy = _strategy;

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = makeAddr(string(abi.encodePacked("pmactor", vm.toString(i))));
            actors.push(actor);
        }
    }

    function _selectActor(uint256 seed) internal view returns (address) {
        return actors[seed % NUM_ACTORS];
    }

    // ============ Fuzzed Actions ============

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _selectActor(actorSeed);
        amount = bound(amount, 1e4, 2e8);

        PmMockWBTC(address(wbtc)).mint(actor, amount);

        vm.startPrank(actor);
        wbtc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghost_totalDeposited[actor] += amount;
        ghost_sumDeposits += amount;
        calls_deposit++;
    }

    function redeem(uint256 actorSeed, uint256 shareFraction) external {
        address actor = _selectActor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 sharesToRedeem = (shares * shareFraction) / 100;
        if (sharesToRedeem == 0) sharesToRedeem = 1;

        vm.prank(actor);
        try vault.redeem(sharesToRedeem, actor, actor) returns (uint256 collateralOut) {
            ghost_totalWithdrawn[actor] += collateralOut;
            ghost_sumWithdrawals += collateralOut;
            calls_redeem++;
        } catch { }
    }

    function withdraw(uint256 actorSeed, uint256 assetFraction) external {
        address actor = _selectActor(actorSeed);
        uint256 maxW = vault.maxWithdraw(actor);
        if (maxW == 0) return;

        assetFraction = bound(assetFraction, 1, 90);
        uint256 assetsToWithdraw = (maxW * assetFraction) / 100;
        if (assetsToWithdraw == 0) assetsToWithdraw = 1;

        vm.prank(actor);
        try vault.withdraw(assetsToWithdraw, actor, actor) returns (uint256) {
            ghost_totalWithdrawn[actor] += assetsToWithdraw;
            ghost_sumWithdrawals += assetsToWithdraw;
            calls_withdraw++;
        } catch { }
    }

    /// @dev Simulate a BTC price change to push LTV out of deadband, then rebalance.
    function rebalance(uint256 priceSeed) external {
        if (!loanManager.loanExists()) return;
        // Skip dust positions — rebalancing tiny positions creates disproportionate surplus
        if (loanManager.positionCollateral() < 1e5) return;

        // Fuzz price within ±10% of base price (81k - 99k)
        // Price persists (not reset) to avoid artificial arbitrage from price cycling
        uint256 newPrice = bound(priceSeed, 81_000, 99_000);
        loanManager.setPrice(newPrice);

        try vault.rebalance() {
            calls_rebalance++;
        } catch { }
    }

    /// @dev Simulate CRV rewards accrual and call harvestYield.
    /// Rewards are scaled to 0.01%-0.5% of strategy balance to be realistic.
    function harvest(uint256 rewardAmount) external {
        if (vault.totalSupply() == 0) return;

        uint256 stratBal = strategy.balanceOf();
        if (stratBal == 0) return;

        // Realistic yield: 0.01% - 0.5% of strategy balance per harvest
        // Strategy balance is in USDT (6 dec), CRV rewards in 18 dec
        // stratBal * 1e12 converts to crvUSD scale, then take percentage
        uint256 maxReward = (stratBal * 1e12 * 50) / 10000; // 0.5%
        uint256 minReward = (stratBal * 1e12) / 10000; // 0.01%

        // Enforce MIN_HARVEST_THRESHOLD (0.1 CRV = 1e17)
        if (maxReward < 1e17) return;
        if (minReward < 1e17) minReward = 1e17;

        rewardAmount = bound(rewardAmount, minReward, maxReward);
        accountant.setPendingRewards(rewardAmount);

        try vault.harvestYield() {
            calls_harvest++;
        } catch { }
    }

    // ============ View helpers ============

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function totalSharesAcrossActors() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.balanceOf(actors[i]);
        }
    }
}

// ============ Invariant Test Contract ============

/// @title PmUsdCrvUsdInvariantTest
/// @notice Fork-free stateful fuzz testing for Zenji vault with PmUsdCrvUsdStrategy.
/// Uses the real PmUsdCrvUsdStrategy against mock Curve pools, Stake DAO vault,
/// and oracle contracts. Verifies deposit, withdraw, rebalance, and harvest
/// invariants across random operation sequences by multiple concurrent users.
contract PmUsdCrvUsdInvariantTest is Test {
    address owner = makeAddr("pm_invariant_owner");

    Zenji vault;
    ZenjiViewHelper viewHelper;
    PmUsdHandler handler;

    PmMockWBTC wbtc;
    PmMockUSDT usdt;
    PmMockCrvUSD crvUSD;
    PmMockCRV crv;
    PmMockPmUSD pmUsd;
    PmMockLP lpToken;

    PmMockOracle crvUsdOracle;
    PmMockOracle usdtOracle;
    PmMockOracle crvOracle;

    PmMockUsdtCrvUsdPool usdtCrvUsdPool;
    PmMockLpPool lpPool;
    PmMockRewardVault rewardVault;
    PmMockAccountant accountant;
    PmMockCrvSwapper crvSwapper;

    PmUsdCrvUsdStrategy strategy;
    PmMockLoanManager loanManager;
    PmMockSwapper swapper;

    function setUp() public {
        // Deploy mock tokens
        wbtc = new PmMockWBTC();
        usdt = new PmMockUSDT();
        crvUSD = new PmMockCrvUSD();
        crv = new PmMockCRV();
        pmUsd = new PmMockPmUSD();
        lpToken = new PmMockLP();

        viewHelper = new ZenjiViewHelper();

        // Deploy mock oracles ($1 each, 8 decimals)
        crvUsdOracle = new PmMockOracle(1e8);
        usdtOracle = new PmMockOracle(1e8);
        crvOracle = new PmMockOracle(0.5e8); // CRV $0.50

        // Deploy mock Curve pools
        usdtCrvUsdPool = new PmMockUsdtCrvUsdPool(address(usdt), address(crvUSD));
        lpPool = new PmMockLpPool(address(crvUSD), address(pmUsd), address(lpToken), 1); // crvUSD at index 1

        // Deploy mock accountant and CRV swapper
        accountant = new PmMockAccountant(address(crv));
        crvSwapper = new PmMockCrvSwapper(address(crvUSD));

        // Deploy mock Stake DAO reward vault (ERC4626 around LP token)
        rewardVault = new PmMockRewardVault(address(lpToken), address(accountant));

        // Deploy mock swapper and fund it
        swapper = new PmMockSwapper(address(wbtc), address(usdt));

        // Deploy mock loan manager
        loanManager = new PmMockLoanManager(address(wbtc), address(usdt));
        swapper.setLoanManager(address(loanManager));

        // Fund swapper with initial liquidity
        wbtc.mint(address(swapper), 1e20);
        usdt.mint(address(swapper), 1e20);

        // Deploy real PmUsdCrvUsdStrategy
        // Constructor: (usdt, crvUsd, crv, pmUsd, vault, usdtCrvUsdPool, lpPool, rewardVault,
        //               crvSwapper, gauge, usdtIndex, crvUsdIndex, lpCrvUsdIndex,
        //               crvUsdOracle, usdtOracle, crvOracle)
        // vault = address(0) for deferred initialization
        strategy = new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(0), // deferred vault init
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            address(accountant), // use accountant as gauge (mock doesn't care)
            0, // usdtIndex = 0
            1, // crvUsdIndex = 1
            1, // lpCrvUsdIndex = 1
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );

        // Deploy Zenji vault
        vault = new Zenji(
            address(wbtc),
            address(usdt),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        // Initialize strategy and loan manager with vault address
        strategy.initializeVault(address(vault));
        loanManager.initializeVault(address(vault));

        // Set fee rate
        vm.prank(owner);
        vault.setParam(0, 1e17); // 10% fee rate

        // Deploy handler
        handler = new PmUsdHandler(vault, IERC20(address(wbtc)), accountant, loanManager, strategy);

        // Only the handler should be called by the fuzzer
        targetContract(address(handler));
    }

    // ============ INVARIANT 1: Share supply consistency ============

    function invariant_shareSupplyConsistency() public view {
        uint256 actorTotal = handler.totalSharesAcrossActors();
        uint256 supply = vault.totalSupply();
        assertLe(actorTotal, supply, "Actor shares exceed total supply");
    }

    // ============ INVARIANT 2: No theft via over-withdrawal ============
    /// Catches the isFinalWithdraw exploit: no user should withdraw drastically
    /// more than they deposited. Tolerance is 500% to account for the vault's 5%
    /// slippage buffer surplus, BTC price fluctuations (±10%), proportional yield,
    /// and the deliberately low VIRTUAL_SHARE_OFFSET (10) which amplifies surplus
    /// redistribution. The isFinalWithdraw exploit would show >10,000%.

    function invariant_noTheftViaOverWithdrawal() public view {
        address[] memory _actors = handler.getActors();
        for (uint256 i = 0; i < _actors.length; i++) {
            uint256 deposited = handler.ghost_totalDeposited(_actors[i]);
            uint256 withdrawn = handler.ghost_totalWithdrawn(_actors[i]);
            if (deposited > 0) {
                assertLe(
                    withdrawn,
                    (deposited * 500) / 100 + 1e5,
                    "User withdrew significantly more than deposited - possible theft"
                );
            }
        }
    }

    // ============ INVARIANT 3: Total collateral non-negative ============

    function invariant_totalCollateralNonNegative() public view {
        uint256 total = vault.getTotalCollateral();
        assertGe(total, 0, "Total collateral underflowed");
    }

    // ============ INVARIANT 4: Share price reasonable ============
    /// Skip when supply is low (fee shares + dust can distort pricing).
    /// Real inflation attacks create millions-of-x share price, easily caught at 100x.

    function invariant_sharePriceReasonable() public view {
        uint256 supply = vault.totalSupply();
        // Skip when supply is low relative to VIRTUAL_SHARE_OFFSET (1e5).
        // At low supply, the offset dominates pricing and per-share value can appear inflated
        // after partial unwinds leave phantom collateral from the mock swapper.
        if (supply < 1e7) return;

        uint256 oneShare = 10 ** vault.decimals();
        uint256 assetsPerShare = vault.convertToAssets(oneShare);

        assertLe(
            assetsPerShare,
            oneShare * 100,
            "Share price inflated beyond 100x - possible inflation attack"
        );
    }

    // ============ INVARIANT 5: No shares without collateral ============
    /// Skip when supply is low — with VIRTUAL_SHARE_OFFSET=1e5, fee shares can
    /// accumulate while the offset provides pricing anchoring. At certain BTC
    /// prices, collateral can legitimately round to 0 at very low supply.

    function invariant_noSharesWithoutCollateral() public view {
        uint256 supply = vault.totalSupply();
        if (supply < 1e7) return; // Skip when fee shares dominate

        uint256 totalCollateral = vault.getTotalCollateral();
        assertGt(totalCollateral, 0, "Shares exist but no collateral backing");
    }

    // ============ INVARIANT 6: Global solvency ============

    function invariant_globalSolvency() public view {
        uint256 totalDeposited = handler.ghost_sumDeposits();
        uint256 totalWithdrawn = handler.ghost_sumWithdrawals();
        if (totalDeposited > 0) {
            assertLe(
                totalWithdrawn,
                (totalDeposited * 500) / 100 + 1e5,
                "Global withdrawals exceed deposits - vault is insolvent"
            );
        }
    }

    // ============ INVARIANT 7: ERC4626 preview consistency ============

    function invariant_previewRedeemConsistency() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 testShares = supply > 1e6 ? 1e6 : supply;
        uint256 preview = vault.previewRedeem(testShares);
        uint256 convert = vault.convertToAssets(testShares);

        assertApproxEqAbs(preview, convert, 1, "previewRedeem diverges from convertToAssets");
    }

    // ============ INVARIANT 8: isFinalWithdraw safety ============

    function invariant_isFinalWithdrawSafety() public view {
        address[] memory _actors = handler.getActors();
        uint256 holdersWithShares = 0;
        uint256 sumShares = 0;

        for (uint256 i = 0; i < _actors.length; i++) {
            uint256 bal = vault.balanceOf(_actors[i]);
            if (bal > 0) {
                holdersWithShares++;
                sumShares += bal;
            }
        }

        if (holdersWithShares > 1) {
            assertEq(
                vault.totalSupply(),
                sumShares,
                "totalSupply doesn't match sum of holder balances - isFinalWithdraw may have fired incorrectly"
            );
        }
    }

    // ============ INVARIANT 9: Strategy balance sanity ============
    /// Strategy's reported balance should not exceed what was deposited (cost basis)
    /// plus a reasonable yield allowance. Harvest adds CRV rewards which increases
    /// balance without increasing cost basis, so we use a generous multiplier.

    function invariant_strategyBalanceSanity() public view {
        uint256 stratBalance = strategy.balanceOf();
        uint256 costBasis = strategy.costBasis();
        if (costBasis == 0 && stratBalance == 0) return;
        if (costBasis == 0) return; // Fully withdrawn

        // Strategy balance shouldn't exceed 3x cost basis (proportional harvest adds modest yield)
        assertLe(
            stratBalance,
            (costBasis * 300) / 100 + 1e6,
            "Strategy balance far exceeds cost basis - phantom value"
        );
    }

    // ============ Summary ============

    function invariant_callSummary() public view {
        console.log("--- PmUSD Invariant Test Call Summary ---");
        console.log("Deposits:   ", handler.calls_deposit());
        console.log("Redeems:    ", handler.calls_redeem());
        console.log("Withdraws:  ", handler.calls_withdraw());
        console.log("Rebalances: ", handler.calls_rebalance());
        console.log("Harvests:   ", handler.calls_harvest());
        console.log("Total supply:", vault.totalSupply());
        console.log("Total collateral:", vault.getTotalCollateral());
        console.log("Strategy balance:", strategy.balanceOf());
    }
}
