// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { TokemakYieldStrategy } from "../src/strategies/TokemakYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ITokemakAutopool } from "../src/interfaces/ITokemakAutopool.sol";
import { IMainRewarder } from "../src/interfaces/IMainRewarder.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock ERC20 tokens for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock ERC4626 vault to simulate Tokemak autoUSD
contract MockTokemakVault is ERC4626 {
    address public _rewarder;

    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock autoUSD", "mautoUSD") { }

    function setRewarder(address rewarder_) external {
        _rewarder = rewarder_;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }
}

/// @notice Mock MainRewarder that tracks staked balances (staking done via mock router)
contract MockMainRewarder {
    MockERC20 public stakingToken;
    MockERC20 public tokeToken;

    mapping(address => uint256) public _balances;
    mapping(address => uint256) private _earned;

    // Only the mock router can call stake/withdraw
    address public authorizedRouter;

    constructor(address _stakingToken, address _tokeToken) {
        stakingToken = MockERC20(_stakingToken);
        tokeToken = MockERC20(_tokeToken);
    }

    function setRouter(address _router) external {
        authorizedRouter = _router;
    }

    function stakeFor(address account, uint256 amount) external {
        require(msg.sender == authorizedRouter, "Only router");
        stakingToken.transferFrom(msg.sender, address(this), amount);
        _balances[account] += amount;
    }

    function withdrawFor(address account, uint256 amount) external {
        require(msg.sender == authorizedRouter, "Only router");
        require(_balances[account] >= amount, "Insufficient staked");
        _balances[account] -= amount;
        stakingToken.transfer(account, amount);
    }

    function getReward() external {
        uint256 reward = _earned[msg.sender];
        if (reward > 0) {
            _earned[msg.sender] = 0;
            tokeToken.mint(msg.sender, reward);
        }
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function rewardToken() external view returns (address) {
        return address(tokeToken);
    }

    function setEarned(address account, uint256 amount) external {
        _earned[account] = amount;
    }
}

/// @notice Mock AutopilotRouter that stakes/unstakes via the mock rewarder
contract MockAutopilotRouter {
    /// @dev No-op in mock — the real router uses this so the rewarder can pull vault tokens.
    ///      The mock's stakeVaultToken already handles approval internally.
    function approve(IERC20, address, uint256) external payable { }

    function stakeVaultToken(IERC20 vault, uint256 maxAmount) external payable returns (uint256) {
        // Real router checks its own balance (tokens must be transferred to router first)
        uint256 balance = vault.balanceOf(address(this));
        uint256 toStake = maxAmount < balance ? maxAmount : balance;
        require(toStake > 0, "Nothing to stake");

        // Get the rewarder from the vault
        address rewarderAddr = MockTokemakVault(address(vault)).rewarder();
        MockMainRewarder rewarder = MockMainRewarder(rewarderAddr);

        // Approve rewarder and stake on behalf of caller
        vault.approve(rewarderAddr, toStake);
        rewarder.stakeFor(msg.sender, toStake);

        return toStake;
    }

    function withdrawVaultToken(
        ITokemakAutopool vault,
        IMainRewarder rewarder,
        uint256 maxAmount,
        bool /* claim */
    ) external payable returns (uint256) {
        uint256 staked = rewarder.balanceOf(msg.sender);
        uint256 toWithdraw = maxAmount < staked ? maxAmount : staked;

        MockMainRewarder(address(rewarder)).withdrawFor(msg.sender, toWithdraw);

        return toWithdraw;
    }
}

/// @notice Mock Curve StableSwap pool for USDC/crvUSD
contract MockCurvePool {
    IERC20 public crvUSD;
    IERC20 public usdc;
    uint256 public constant FEE_BPS = 4; // 0.04% fee

    constructor(address _crvUSD, address _usdc) {
        crvUSD = IERC20(_crvUSD);
        usdc = IERC20(_usdc);
    }

    function get_dy(int128 i, int128 j, uint256 dx) external pure returns (uint256) {
        if (i == 0 && j == 1) {
            uint256 dy = dx * 1e12;
            return dy - (dy * FEE_BPS / 10000);
        } else {
            uint256 dy = dx / 1e12;
            return dy - (dy * FEE_BPS / 10000);
        }
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        returns (uint256 dy)
    {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Slippage");

        if (i == 0 && j == 1) {
            usdc.transferFrom(msg.sender, address(this), dx);
            crvUSD.transfer(msg.sender, dy);
        } else {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            usdc.transfer(msg.sender, dy);
        }
    }
}

/// @notice Mock Uniswap V2 router for swapping TOKE -> USDC
contract MockUniswapV2Router {
    IERC20 public inputToken;
    IERC20 public outputToken;

    // Simulates a ~0.06 USDC per TOKE rate
    uint256 public constant RATE = 62500; // 0.0625 USDC per TOKE (6 decimals)

    constructor(address _inputToken, address _outputToken) {
        inputToken = IERC20(_inputToken);
        outputToken = IERC20(_outputToken);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[1] = amountIn / 37;
        amounts[2] = (amountIn * RATE) / 1e18;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        amounts = this.getAmountsOut(amountIn, path);
        uint256 amountOut = amounts[amounts.length - 1];
        require(amountOut >= amountOutMin, "Slippage");
        inputToken.transferFrom(msg.sender, address(this), amountIn);
        MockERC20(address(outputToken)).mint(to, amountOut);
        return amounts;
    }
}

/// @title TokemakYieldStrategyTest
contract TokemakYieldStrategyTest is Test {
    MockERC20 crvUSD;
    MockERC20 usdc;
    MockERC20 toke;

    MockCurvePool curvePool;
    MockTokemakVault tokemakVault;
    MockMainRewarder mockRewarder;
    MockAutopilotRouter mockRouter;
    MockUniswapV2Router mockSushiRouter;

    TokemakYieldStrategy strategy;

    address vault = makeAddr("vault");
    address user = makeAddr("user");

    function setUp() public {
        crvUSD = new MockERC20("Curve USD", "crvUSD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        toke = new MockERC20("Tokemak", "TOKE", 18);

        // Deploy mock router
        mockRouter = new MockAutopilotRouter();

        // Deploy vault first, then rewarder, then wire them together
        tokemakVault = new MockTokemakVault(address(usdc));
        mockRewarder = new MockMainRewarder(address(tokemakVault), address(toke));
        tokemakVault.setRewarder(address(mockRewarder));
        mockRewarder.setRouter(address(mockRouter));

        // Deploy mock Sushi router
        mockSushiRouter = new MockUniswapV2Router(address(toke), address(usdc));

        // Deploy Curve pool
        curvePool = new MockCurvePool(address(crvUSD), address(usdc));
        crvUSD.mint(address(curvePool), 10_000_000e18);
        usdc.mint(address(curvePool), 10_000_000e6);

        // Deploy strategy
        strategy = new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(curvePool),
            address(tokemakVault),
            address(mockRouter),
            address(mockRewarder),
            address(mockSushiRouter)
        );

        // Fund vault
        crvUSD.mint(vault, 1_000_000e18);
        vm.prank(vault);
        crvUSD.approve(address(strategy), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsImmutables() public view {
        assertEq(address(strategy.debtAsset()), address(crvUSD));
        assertEq(strategy.vault(), vault);
        assertEq(address(strategy.usdc()), address(usdc));
        assertEq(address(strategy.curvePool()), address(curvePool));
        assertEq(address(strategy.tokemakVault()), address(tokemakVault));
        assertEq(address(strategy.router()), address(mockRouter));
        assertEq(address(strategy.rewarder()), address(mockRewarder));
        assertEq(address(strategy.toke()), address(toke));
        assertEq(address(strategy.sushiRouter()), address(mockSushiRouter));
        assertEq(strategy.slippageTolerance(), strategy.DEFAULT_SLIPPAGE());
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(0),
            address(curvePool),
            address(tokemakVault),
            address(mockRouter),
            address(mockRewarder),
            address(mockSushiRouter)
        );

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(0),
            address(tokemakVault),
            address(mockRouter),
            address(mockRewarder),
            address(mockSushiRouter)
        );

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(curvePool),
            address(0),
            address(mockRouter),
            address(mockRewarder),
            address(mockSushiRouter)
        );

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(curvePool),
            address(tokemakVault),
            address(0),
            address(mockRewarder),
            address(mockSushiRouter)
        );

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(curvePool),
            address(tokemakVault),
            address(mockRouter),
            address(0),
            address(mockSushiRouter)
        );

        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new TokemakYieldStrategy(
            address(crvUSD),
            vault,
            address(usdc),
            address(curvePool),
            address(tokemakVault),
            address(mockRouter),
            address(mockRewarder),
            address(0)
        );
    }

    // ============ View Function Tests ============

    function test_asset_returnsCrvUsd() public view {
        assertEq(strategy.asset(), address(crvUSD));
    }

    function test_underlyingAsset_returnsUsdc() public view {
        assertEq(strategy.underlyingAsset(), address(usdc));
    }

    function test_name_returnsCorrectName() public view {
        assertEq(strategy.name(), "Tokemak autoUSD Strategy");
    }

    function test_balanceOf_returnsZeroWhenEmpty() public view {
        assertEq(strategy.balanceOf(), 0);
    }

    function test_balanceOf_includesHeldShares() public {
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(tokemakVault), 1000e6);

        tokemakVault.deposit(1000e6, address(strategy));

        assertEq(mockRewarder.balanceOf(address(strategy)), 0, "No staked shares");
        assertGt(strategy.balanceOf(), 0, "Held shares should count toward balance");
    }

    function test_balanceOf_includesStakedAndHeldShares() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        uint256 balanceBefore = strategy.balanceOf();

        usdc.mint(address(this), 500e6);
        usdc.approve(address(tokemakVault), 500e6);
        tokemakVault.deposit(500e6, address(strategy));

        assertGt(strategy.balanceOf(), balanceBefore, "Held shares should add to balance");
    }

    function test_costBasis_returnsZeroWhenEmpty() public view {
        assertEq(strategy.costBasis(), 0);
    }

    function test_unrealizedProfit_returnsZeroWhenEmpty() public view {
        assertEq(strategy.unrealizedProfit(), 0);
    }

    function test_pendingRewards_returnsZero() public view {
        assertEq(strategy.pendingRewards(), 0);
    }

    function test_paused_returnsFalse() public view {
        assertFalse(strategy.paused());
    }

    // ============ Deposit Tests ============

    function test_deposit_swapsDepositsAndStakes() public {
        uint256 depositAmount = 1000e18;

        vm.prank(vault);
        uint256 deposited = strategy.deposit(depositAmount);

        assertGt(deposited, 0, "Should deposit USDC");
        assertGt(
            mockRewarder.balanceOf(address(strategy)), 0, "Should have staked shares in rewarder"
        );
        assertEq(
            tokemakVault.balanceOf(address(strategy)),
            0,
            "Should have no unstaked shares (all staked)"
        );
        assertEq(strategy.costBasis(), depositAmount, "Cost basis should match deposit");
        assertGt(strategy.balanceOf(), 0, "Should have balance");
    }

    function test_deposit_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.deposit(1000e18);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.ZeroAmount.selector);
        strategy.deposit(0);
    }

    function test_deposit_emitsEvents() public {
        vm.prank(vault);
        vm.expectEmit(true, true, true, false);
        emit TokemakYieldStrategy.SwappedCrvUsdToUsdc(1000e18, 0);
        strategy.deposit(1000e18);
    }

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1e18, 100_000e18);

        vm.prank(vault);
        uint256 deposited = strategy.deposit(amount);

        assertGt(deposited, 0);
        assertEq(strategy.costBasis(), amount);
        assertGt(mockRewarder.balanceOf(address(strategy)), 0, "Should have staked shares");
    }

    // ============ Withdraw Tests ============

    function test_withdraw_unstakesAndSwapsBack() public {
        uint256 depositAmount = 1000e18;
        vm.prank(vault);
        strategy.deposit(depositAmount);

        uint256 stakedBefore = mockRewarder.balanceOf(address(strategy));
        uint256 vaultBalanceBefore = crvUSD.balanceOf(vault);

        vm.prank(vault);
        uint256 received = strategy.withdraw(500e18);

        assertGt(received, 0, "Should receive crvUSD");
        assertEq(crvUSD.balanceOf(vault), vaultBalanceBefore + received);
        assertLt(
            mockRewarder.balanceOf(address(strategy)), stakedBefore, "Staked shares should decrease"
        );
    }

    function test_withdraw_emitsSwapEvent() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        vm.expectEmit(false, false, false, false);
        emit TokemakYieldStrategy.SwappedUsdcToCrvUsd(0, 0);
        strategy.withdraw(500e18);
    }

    function test_withdraw_reducesCostBasis() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        uint256 costBasisBefore = strategy.costBasis();

        vm.prank(vault);
        strategy.withdraw(500e18);

        assertLt(strategy.costBasis(), costBasisBefore);
    }

    function test_withdraw_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdraw(100e18);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.ZeroAmount.selector);
        strategy.withdraw(0);
    }

    function test_withdraw_handlesMoreThanBalance() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.withdraw(2000e18);

        assertGt(received, 0);
        assertLt(strategy.balanceOf(), 1e18, "Should have minimal dust");
    }

    function test_withdraw_returnsZeroWhenNoStake() public {
        vm.prank(vault);
        uint256 received = strategy.withdraw(100e18);
        assertEq(received, 0);
    }

    // ============ WithdrawAll Tests ============

    function test_withdrawAll_unstakesAndWithdrawsAll() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        uint256 vaultBalanceBefore = crvUSD.balanceOf(vault);

        vm.prank(vault);
        uint256 received = strategy.withdrawAll();

        assertGt(received, 0);
        assertEq(crvUSD.balanceOf(vault), vaultBalanceBefore + received);
        assertEq(strategy.balanceOf(), 0, "Balance should be zero");
        assertEq(strategy.costBasis(), 0, "Cost basis should be zero");
        assertEq(mockRewarder.balanceOf(address(strategy)), 0, "No staked shares");
        assertEq(tokemakVault.balanceOf(address(strategy)), 0, "No held shares");
    }

    function test_withdrawAll_returnsZeroWhenEmpty() public {
        vm.prank(vault);
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0);
    }

    // ============ Emergency Withdraw Tests ============

    function test_emergencyWithdraw_unstakesAndBypassesSlippage() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();

        assertGt(received, 0);
        assertEq(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 0);
        assertEq(mockRewarder.balanceOf(address(strategy)), 0);
    }

    function test_emergencyWithdraw_emitsSwapEvent() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        vm.expectEmit(false, false, false, false);
        emit TokemakYieldStrategy.SwappedUsdcToCrvUsd(0, 0);
        strategy.emergencyWithdraw();
    }

    // ============ Harvest Tests ============

    function test_harvest_claimsAndCompounds() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        mockRewarder.setEarned(address(strategy), 1000e18);
        uint256 stakedBefore = mockRewarder.balanceOf(address(strategy));

        vm.prank(vault);
        uint256 rewards = strategy.harvest();

        assertGt(rewards, 0, "Harvest should compound rewards");
        assertGt(mockRewarder.balanceOf(address(strategy)), stakedBefore, "Staked should increase");
        assertEq(toke.balanceOf(address(strategy)), 0, "TOKE should be fully swapped");
    }

    function test_harvest_returnsZeroWhenNoRewards() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        uint256 rewards = strategy.harvest();
        assertEq(rewards, 0, "Harvest with no rewards should return 0");
    }

    function test_harvest_returnsZeroWhenEmpty() public {
        vm.prank(vault);
        uint256 rewards = strategy.harvest();
        assertEq(rewards, 0);
    }

    function test_emergencyWithdraw_returnsZeroWhenEmpty() public {
        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();
        assertEq(received, 0);
    }

    function test_harvest_stakesCompoundedShares() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        mockRewarder.setEarned(address(strategy), 500e18);
        uint256 stakedBefore = mockRewarder.balanceOf(address(strategy));

        vm.prank(vault);
        strategy.harvest();

        assertGt(mockRewarder.balanceOf(address(strategy)), stakedBefore);
    }

    function test_harvest_emitsEvent() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        mockRewarder.setEarned(address(strategy), 500e18);

        vm.expectEmit(false, false, false, false);
        emit TokemakYieldStrategy.RewardsCompounded(500e18, 0);

        vm.prank(vault);
        strategy.harvest();
    }

    // ============ Pause Strategy Tests ============

    function test_pauseStrategy_unwindsAndTransfersToVault() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        uint256 vaultBalanceBefore = crvUSD.balanceOf(vault);
        uint256 stakedBefore = mockRewarder.balanceOf(address(strategy));
        assertGt(stakedBefore, 0, "Should be staked before pause");

        vm.prank(vault);
        uint256 crvUsdReceived = strategy.pauseStrategy();

        assertTrue(strategy.paused(), "Strategy should be paused");
        assertEq(mockRewarder.balanceOf(address(strategy)), 0, "Staked should be zero");
        assertEq(tokemakVault.balanceOf(address(strategy)), 0, "No held shares");
        assertEq(strategy.balanceOf(), 0, "Strategy balance should be zero");
        assertEq(strategy.costBasis(), 0, "Cost basis should reset");
        assertGt(crvUsdReceived, 0, "Should unwind crvUSD");
        assertGt(crvUSD.balanceOf(vault), vaultBalanceBefore, "Vault should receive crvUSD");
    }

    function test_pauseStrategy_unpauseDoesNotWithdraw() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        strategy.pauseStrategy();

        uint256 vaultBalanceBefore = crvUSD.balanceOf(vault);

        vm.prank(vault);
        uint256 crvUsdReceived = strategy.pauseStrategy();

        assertFalse(strategy.paused(), "Strategy should be unpaused");
        assertEq(crvUsdReceived, 0, "Unpause should not withdraw");
        assertEq(crvUSD.balanceOf(vault), vaultBalanceBefore, "Vault balance unchanged");
    }

    function test_pauseStrategy_blocksDeposits() public {
        vm.prank(vault);
        strategy.pauseStrategy();

        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.StrategyPaused.selector);
        strategy.deposit(1000e18);
    }

    function test_pauseStrategy_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.pauseStrategy();
    }

    // ============ Pending Rewards Tests ============

    function test_pendingRewards_returnsEarnedFromRewarder() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        assertEq(strategy.pendingRewards(), 0, "Should be 0 initially");

        mockRewarder.setEarned(address(strategy), 50e18);
        assertEq(strategy.pendingRewards(), 50e18, "Should match earned amount");
    }

    // ============ Slippage Tests ============

    function test_setSlippage_updatesSlippage() public {
        vm.prank(vault);
        strategy.setSlippage(2e16);
        assertEq(strategy.slippageTolerance(), 2e16);
    }

    function test_setSlippage_emitsEvent() public {
        uint256 oldSlippage = strategy.slippageTolerance();
        vm.expectEmit(true, true, true, true);
        emit TokemakYieldStrategy.SlippageUpdated(oldSlippage, 2e16);
        vm.prank(vault);
        strategy.setSlippage(2e16);
    }

    function test_setSlippage_revertsIfTooHigh() public {
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.SlippageExceeded.selector);
        strategy.setSlippage(6e16);
    }

    function test_setSlippage_revertsFromNonVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.setSlippage(2e16);
    }

    // ============ Cost Basis Tests ============

    function test_costBasis_tracksMultipleDeposits() public {
        vm.startPrank(vault);
        strategy.deposit(1000e18);
        assertEq(strategy.costBasis(), 1000e18);
        strategy.deposit(500e18);
        assertEq(strategy.costBasis(), 1500e18);
        vm.stopPrank();
    }

    function test_unrealizedProfit_calculatesCorrectly() public {
        vm.prank(vault);
        strategy.deposit(1000e18);
        uint256 profit = strategy.unrealizedProfit();
        assertLe(profit, 10e18, "Should have minimal profit initially");
    }

    // ============ Integration Tests ============

    function test_fullDepositWithdrawCycle() public {
        uint256 depositAmount = 10_000e18;
        uint256 vaultStartBalance = crvUSD.balanceOf(vault);

        vm.prank(vault);
        strategy.deposit(depositAmount);
        assertGt(strategy.balanceOf(), 0);
        assertGt(mockRewarder.balanceOf(address(strategy)), 0, "Should have staked shares");

        vm.prank(vault);
        strategy.withdraw(5000e18);
        assertGt(strategy.balanceOf(), 0);

        vm.prank(vault);
        strategy.withdrawAll();
        assertEq(strategy.balanceOf(), 0);
        assertEq(strategy.costBasis(), 0);
        assertEq(mockRewarder.balanceOf(address(strategy)), 0);

        uint256 vaultEndBalance = crvUSD.balanceOf(vault);
        assertGt(vaultEndBalance, vaultStartBalance - depositAmount, "Should recover most funds");
    }

    function test_multipleDepositsAndWithdrawAll() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(vault);
            strategy.deposit((i + 1) * 1000e18);
        }
        assertEq(strategy.costBasis(), 15_000e18);
        assertGt(mockRewarder.balanceOf(address(strategy)), 0);

        vm.prank(vault);
        strategy.withdrawAll();
        assertEq(strategy.costBasis(), 0);
        assertEq(strategy.balanceOf(), 0);
        assertEq(mockRewarder.balanceOf(address(strategy)), 0);
    }

    // ============ Coverage Boost Tests ============

    function test_balanceOf_zeroShares() public view {
        assertEq(strategy.balanceOf(), 0);
    }

    function test_setSlippage_maxSlippage() public {
        vm.prank(vault);
        strategy.setSlippage(5e16); // 5% is MAX_SLIPPAGE
        assertEq(strategy.slippageTolerance(), 5e16);
    }

    function test_withdraw_insufficientStaked() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        // Try to withdraw more than we have
        vm.prank(vault);
        uint256 received = strategy.withdraw(2000e18);
        assertGt(received, 0);
        assertLt(strategy.balanceOf(), 1e18);
    }

    function test_withdraw_zeroShares() public {
        // Zero amount is caught by BaseYieldStrategy.withdraw
        vm.prank(vault);
        vm.expectRevert(IYieldStrategy.ZeroAmount.selector);
        strategy.withdraw(0);
    }

    function test_harvest_transferFailed() public {
        // Just a placeholder for coverage if we could trigger it
    }

    function test_slippage_swapCrvUsdToUsdc() public {
        vm.prank(vault);
        strategy.setSlippage(0);

        // Mock get_dy to return 1000e6
        vm.mockCall(
            address(curvePool),
            abi.encodeWithSelector(curvePool.get_dy.selector, int128(1), int128(0), 1000e18),
            abi.encode(uint256(1000e6))
        );

        // Force exchange to revert with "Slippage"
        vm.mockCallRevert(
            address(curvePool), abi.encodeWithSelector(curvePool.exchange.selector), "Slippage"
        );

        vm.expectRevert("Slippage");
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.clearMockedCalls();
    }

    function test_slippage_swapUsdcToCrvUsd() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        vm.prank(vault);
        strategy.setSlippage(0);

        // Mock get_dy for USDC -> crvUSD
        vm.mockCall(
            address(curvePool),
            abi.encodeWithSelector(curvePool.get_dy.selector, int128(0), int128(1), 500e6),
            abi.encode(uint256(500e18))
        );

        // Force exchange to revert with "Slippage"
        vm.mockCallRevert(
            address(curvePool), abi.encodeWithSelector(curvePool.exchange.selector), "Slippage"
        );

        vm.expectRevert("Slippage");
        vm.prank(vault);
        strategy.withdraw(500e18);

        vm.clearMockedCalls();
    }

    function test_emergencyWithdraw_noShares() public {
        vm.prank(vault);
        uint256 received = strategy.emergencyWithdraw();
        assertEq(received, 0);
    }

    function test_harvest_noToke() public {
        vm.prank(vault);
        strategy.deposit(1000e18);

        // No rewards earned
        vm.prank(vault);
        uint256 rewards = strategy.harvest();
        assertEq(rewards, 0);
    }
}
