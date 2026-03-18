// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock ERC20 tokens ============

contract StratMockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StratMockCrvUSD is ERC20 {
    constructor() ERC20("Mock crvUSD", "crvUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StratMockCRV is ERC20 {
    constructor() ERC20("Mock CRV", "CRV") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StratMockPmUSD is ERC20 {
    constructor() ERC20("Mock pmUSD", "pmUSD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StratMockLP is ERC20 {
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

contract StratMockOracle {
    int256 public price;

    constructor(int256 _price) {
        price = _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
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

contract StratMockUsdtCrvUsdPool {
    StratMockUSDT public usdt;
    StratMockCrvUSD public crvUSD;

    constructor(address _usdt, address _crvUSD) {
        usdt = StratMockUSDT(_usdt);
        crvUSD = StratMockCrvUSD(_crvUSD);
    }

    function get_dy(int128 i, int128, uint256 dx) external pure returns (uint256) {
        if (i == 0) return dx * 1e12;
        else return dx / 1e12;
    }

    function exchange(int128 i, int128, uint256 dx, uint256, address receiver)
        external
        returns (uint256)
    {
        return _doExchange(i, dx, receiver);
    }

    function exchange(int128 i, int128, uint256 dx, uint256) external returns (uint256) {
        return _doExchange(i, dx, msg.sender);
    }

    function _doExchange(int128 i, uint256 dx, address receiver) internal returns (uint256 dy) {
        if (i == 0) {
            usdt.transferFrom(msg.sender, address(this), dx);
            dy = dx * 1e12;
            crvUSD.mint(receiver, dy);
        } else {
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

contract StratMockLpPool {
    StratMockCrvUSD public crvUSD;
    StratMockPmUSD public pmUSD;
    StratMockLP public lp;
    int128 public crvUsdIndex;
    uint256 public pmUsdIndex;

    constructor(address _crvUSD, address _pmUSD, address _lp, int128 _crvUsdIndex) {
        crvUSD = StratMockCrvUSD(_crvUSD);
        pmUSD = StratMockPmUSD(_pmUSD);
        lp = StratMockLP(_lp);
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
        lpMinted = crvUsdAmount + pmUsdAmount;
        if (lpMinted > 0) lp.mint(msg.sender, lpMinted);
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external
        returns (uint256)
    {
        lp.burn(msg.sender, burn_amount);
        uint256 crvUsdOut = burn_amount;
        crvUSD.mint(msg.sender, crvUsdOut);
        return crvUsdOut;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIndex))] + amounts[pmUsdIndex];
    }

    function calc_withdraw_one_coin(uint256 burn_amount, int128) external pure returns (uint256) {
        return burn_amount;
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

contract StratMockRewardVault is ERC4626 {
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

contract StratMockAccountant {
    StratMockCRV public crv;
    uint256 public pendingCrv;

    constructor(address _crv) {
        crv = StratMockCRV(_crv);
    }

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

contract StratMockCrvSwapper {
    StratMockCrvUSD public crvUSD;

    constructor(address _crvUSD) {
        crvUSD = StratMockCrvUSD(_crvUSD);
    }

    function swap(uint256 amount) external returns (uint256) {
        crvUSD.mint(msg.sender, amount);
        return amount;
    }
}

// ============ Handler ============

contract PmUsdStrategyHandler is Test {
    PmUsdCrvUsdStrategy public strategy;
    StratMockUSDT public usdt;
    StratMockAccountant public accountant;
    StratMockRewardVault public rewardVault;
    address public mockVault;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    bool public ghost_lastActionWasWithdrawAll;
    uint256 public ghost_balanceBeforeHarvest;
    uint256 public ghost_balanceAfterHarvest;
    bool public ghost_harvestOccurred;

    // Call counters
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_withdrawAll;
    uint256 public calls_harvest;
    uint256 public calls_setSlippage;

    constructor(
        PmUsdCrvUsdStrategy _strategy,
        StratMockUSDT _usdt,
        StratMockAccountant _accountant,
        StratMockRewardVault _rewardVault,
        address _mockVault
    ) {
        strategy = _strategy;
        usdt = _usdt;
        accountant = _accountant;
        rewardVault = _rewardVault;
        mockVault = _mockVault;
    }

    function deposit(uint256 amount) external {
        ghost_lastActionWasWithdrawAll = false;
        ghost_harvestOccurred = false;

        amount = bound(amount, 1e6, 100_000e6); // 1 USDT to 100k USDT

        usdt.mint(mockVault, amount);
        vm.startPrank(mockVault);
        usdt.approve(address(strategy), amount);
        try strategy.deposit(amount) {
            ghost_totalDeposited += amount;
            calls_deposit++;
        } catch { }
        vm.stopPrank();
    }

    function withdraw(uint256 amount) external {
        ghost_lastActionWasWithdrawAll = false;
        ghost_harvestOccurred = false;

        uint256 balance = strategy.balanceOf();
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(mockVault);
        try strategy.withdraw(amount) returns (uint256 received) {
            ghost_totalWithdrawn += received;
            calls_withdraw++;
        } catch { }
    }

    function withdrawAll() external {
        ghost_harvestOccurred = false;
        uint256 balance = strategy.balanceOf();
        if (balance == 0) return;

        vm.prank(mockVault);
        try strategy.withdrawAll() returns (uint256 received) {
            ghost_totalWithdrawn += received;
            ghost_lastActionWasWithdrawAll = true;
            calls_withdrawAll++;
        } catch { }
    }

    function harvest(uint256 rewardAmount) external {
        ghost_lastActionWasWithdrawAll = false;

        uint256 stratBal = strategy.balanceOf();
        if (stratBal == 0) return;

        // Realistic yield: 0.01% - 0.5% of strategy balance per harvest
        // Strategy balance is in USDT (6 dec), CRV rewards in 18 dec
        uint256 maxReward = (stratBal * 1e12 * 50) / 10000; // 0.5%
        uint256 minReward = (stratBal * 1e12) / 10000; // 0.01%

        // Enforce MIN_HARVEST_THRESHOLD (0.1 CRV = 1e17)
        if (maxReward < 1e17) return;
        if (minReward < 1e17) minReward = 1e17;

        rewardAmount = bound(rewardAmount, minReward, maxReward);
        accountant.setPendingRewards(rewardAmount);

        ghost_balanceBeforeHarvest = strategy.balanceOf();

        vm.prank(mockVault);
        try strategy.harvest() {
            ghost_balanceAfterHarvest = strategy.balanceOf();
            ghost_harvestOccurred = true;
            calls_harvest++;
        } catch { }
    }

    function setSlippage(uint256 newSlippage) external {
        ghost_lastActionWasWithdrawAll = false;
        ghost_harvestOccurred = false;

        // 0.1% - 5%
        newSlippage = bound(newSlippage, 1e15, 5e16);

        vm.prank(mockVault);
        try strategy.setSlippage(newSlippage) {
            calls_setSlippage++;
        } catch { }
    }
}

// ============ Invariant Test Contract ============

contract PmUsdCrvUsdStrategyInvariantTest is Test {
    address mockVault = makeAddr("mockVault");

    StratMockUSDT usdt;
    StratMockCrvUSD crvUSD;
    StratMockCRV crv;
    StratMockPmUSD pmUsd;
    StratMockLP lpToken;

    StratMockOracle crvUsdOracle;
    StratMockOracle usdtOracle;
    StratMockOracle crvOracle;

    StratMockUsdtCrvUsdPool usdtCrvUsdPool;
    StratMockLpPool lpPool;
    StratMockRewardVault rewardVault;
    StratMockAccountant accountant;
    StratMockCrvSwapper crvSwapper;

    PmUsdCrvUsdStrategy strategy;
    PmUsdStrategyHandler handler;

    function setUp() public {
        // Deploy mock tokens
        usdt = new StratMockUSDT();
        crvUSD = new StratMockCrvUSD();
        crv = new StratMockCRV();
        pmUsd = new StratMockPmUSD();
        lpToken = new StratMockLP();

        // Deploy mock oracles ($1 each, 8 decimals)
        crvUsdOracle = new StratMockOracle(1e8);
        usdtOracle = new StratMockOracle(1e8);
        crvOracle = new StratMockOracle(0.5e8); // CRV $0.50

        // Deploy mock Curve pools
        usdtCrvUsdPool = new StratMockUsdtCrvUsdPool(address(usdt), address(crvUSD));
        lpPool = new StratMockLpPool(address(crvUSD), address(pmUsd), address(lpToken), 1);

        // Deploy mock accountant and CRV swapper
        accountant = new StratMockAccountant(address(crv));
        crvSwapper = new StratMockCrvSwapper(address(crvUSD));

        // Deploy mock Stake DAO reward vault
        rewardVault = new StratMockRewardVault(address(lpToken), address(accountant));

        // Deploy real PmUsdCrvUsdStrategy with mockVault as vault
        strategy = new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            mockVault,
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            address(accountant), // gauge = accountant (mock doesn't care)
            0, // usdtIndex
            1, // crvUsdIndex
            1, // lpCrvUsdIndex
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );

        // Deploy handler
        handler = new PmUsdStrategyHandler(strategy, usdt, accountant, rewardVault, mockVault);

        targetContract(address(handler));
    }

    // ============ INVARIANT 1: Cost basis tracking ============

    function invariant_costBasisTracking() public view {
        uint256 costBasis = strategy.costBasis();
        uint256 totalDeposited = handler.ghost_totalDeposited();
        assertLe(costBasis, totalDeposited, "Cost basis exceeds total deposits");
    }

    // ============ INVARIANT 2: Cost basis zero after withdrawAll ============

    function invariant_costBasisZeroAfterWithdrawAll() public view {
        if (!handler.ghost_lastActionWasWithdrawAll()) return;

        assertEq(strategy.costBasis(), 0, "Cost basis non-zero after withdrawAll");
    }

    // ============ INVARIANT 3: balanceOf non-negative (no reverts) ============

    function invariant_balanceOfNonNegative() public view {
        // For uint this is trivially true, but catches reverts in the balanceOf calculation
        strategy.balanceOf();
    }

    // ============ INVARIANT 4: Reward vault consistency ============

    function invariant_rewardVaultConsistency() public view {
        uint256 costBasis = strategy.costBasis();
        uint256 rvBalance = rewardVault.balanceOf(address(strategy));

        if (costBasis > 0) {
            assertGt(rvBalance, 0, "Cost basis > 0 but no LP tokens in reward vault");
        }
        if (rvBalance == 0) {
            // If no LP in reward vault, cost basis should be 0
            // (unless a deposit just failed)
            if (handler.calls_deposit() > 0 || handler.calls_withdrawAll() > 0) {
                assertEq(costBasis, 0, "LP tokens gone but cost basis remains");
            }
        }
    }

    // ============ INVARIANT 5: No stuck tokens ============

    function invariant_noStuckTokens() public view {
        uint256 usdtBal = usdt.balanceOf(address(strategy));
        uint256 crvUsdBal = crvUSD.balanceOf(address(strategy));
        assertEq(usdtBal, 0, "USDT stuck in strategy");
        assertEq(crvUsdBal, 0, "crvUSD stuck in strategy");
    }

    // ============ INVARIANT 6: Virtual price bounded ============

    function invariant_virtualPriceBounded() public view {
        uint256 cached = strategy.cachedVirtualPrice();
        if (cached == 0) return; // Not yet initialized

        uint256 actual = lpPool.get_virtual_price(); // Mock returns 1e18
        uint256 maxDeviation = (cached * 5e15) / 1e18; // 0.5%
        uint256 upperBound = cached + maxDeviation;
        uint256 lowerBound = cached > maxDeviation ? cached - maxDeviation : 0;

        assertLe(cached, upperBound, "Cached VP above upper bound");
        assertGe(cached, lowerBound, "Cached VP below lower bound");

        // Cached should be close to actual (mock always returns 1e18)
        assertApproxEqRel(cached, actual, 1e16, "Cached VP diverged >1% from actual");
    }

    // ============ INVARIANT 7: Harvest never decreases balance ============

    function invariant_harvestNeverDecreasesBalance() public view {
        if (!handler.ghost_harvestOccurred()) return;

        assertGe(
            handler.ghost_balanceAfterHarvest(),
            handler.ghost_balanceBeforeHarvest(),
            "Harvest decreased strategy balance"
        );
    }

    // ============ INVARIANT 8: Call summary ============

    function invariant_callSummary() public view {
        console.log("--- PmUsdCrvUsd Strategy Invariant Call Summary ---");
        console.log("Deposits:    ", handler.calls_deposit());
        console.log("Withdraws:   ", handler.calls_withdraw());
        console.log("WithdrawAlls:", handler.calls_withdrawAll());
        console.log("Harvests:    ", handler.calls_harvest());
        console.log("SetSlippage: ", handler.calls_setSlippage());
        console.log("Balance:     ", strategy.balanceOf());
        console.log("Cost basis:  ", strategy.costBasis());
    }
}
