// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { CurveUsdtSwapLib } from "../src/libraries/CurveUsdtSwapLib.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock Contracts ============

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 price_) external {
        price = price_;
        updatedAt = block.timestamp;
    }

    function setStale() external {
        updatedAt = block.timestamp - 100000; // > 25 hours ago
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

/// @notice Mock Curve StableSwap pool (USDT/crvUSD) - 1:1 at 6/18 decimal scaling
contract MockCurveStableSwap {
    MockERC20 public immutable usdt;
    MockERC20 public immutable crvUSD;
    int128 public immutable usdtIdx;
    int128 public immutable crvUsdIdx;

    constructor(address _usdt, address _crvUSD, int128 _usdtIdx, int128 _crvUsdIdx) {
        usdt = MockERC20(_usdt);
        crvUSD = MockERC20(_crvUSD);
        usdtIdx = _usdtIdx;
        crvUsdIdx = _crvUsdIdx;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        if (i == usdtIdx && j == crvUsdIdx) {
            usdt.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx * 1e12; // 6→18 dec
            crvUSD.mint(msg.sender, out);
            return out;
        }
        if (i == crvUsdIdx && j == usdtIdx) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx / 1e12; // 18→6 dec
            usdt.mint(msg.sender, out);
            return out;
        }
        return 0;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if (i == usdtIdx && j == crvUsdIdx) return dx * 1e12;
        if (i == crvUsdIdx && j == usdtIdx) return dx / 1e12;
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        if (i == uint256(uint128(usdtIdx))) return address(usdt);
        if (i == uint256(uint128(crvUsdIdx))) return address(crvUSD);
        return address(0);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice Mock Curve StableSwapNG pool (pmUSD/crvUSD) with LP token minting
contract MockCurveStableSwapNG {
    MockERC20 public immutable crvUSD;
    MockERC20 public pmUSD;
    MockERC20 public lpToken;
    int128 public immutable crvUsdIdx;
    uint256 public pmUsdIdx;

    constructor(address _crvUSD, int128 _crvUsdIdx) {
        crvUSD = MockERC20(_crvUSD);
        crvUsdIdx = _crvUsdIdx;
        pmUsdIdx = _crvUsdIdx == int128(0) ? 1 : 0;
    }

    function setLpToken(address _lpToken) external {
        lpToken = MockERC20(_lpToken);
    }

    function setPmUsd(address _pmUSD) external {
        pmUSD = MockERC20(_pmUSD);
    }

    function add_liquidity(uint256[] calldata amounts, uint256) external returns (uint256) {
        uint256 crvUsdAmount = amounts[uint256(uint128(crvUsdIdx))];
        uint256 pmUsdAmount = amounts[pmUsdIdx];
        if (crvUsdAmount > 0) crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount);
        if (pmUsdAmount > 0 && address(pmUSD) != address(0)) {
            pmUSD.transferFrom(msg.sender, address(this), pmUsdAmount);
        }
        // 1:1 LP minting for simplicity
        uint256 totalMinted = crvUsdAmount + pmUsdAmount;
        if (totalMinted > 0) lpToken.mint(msg.sender, totalMinted);
        return totalMinted;
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external
        returns (uint256)
    {
        lpToken.transferFrom(msg.sender, address(this), burn_amount);
        // 1:1 LP burning for simplicity
        crvUSD.mint(msg.sender, burn_amount);
        return burn_amount;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIdx))] + amounts[pmUsdIdx]; // 1:1
    }

    function calc_withdraw_one_coin(uint256 burn_amount, int128) external pure returns (uint256) {
        return burn_amount; // 1:1
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }

    function coins(uint256) external pure returns (address) {
        return address(0);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }

    function exchange(int128, int128, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function get_dy(int128, int128, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock Stake DAO Accountant
contract MockAccountant {
    MockERC20 public rewardToken;
    mapping(address => mapping(address => uint256)) public rewards; // vault => account => amount

    constructor(address _rewardToken) {
        rewardToken = MockERC20(_rewardToken);
    }

    function setRewards(address account, uint256 amount) external {
        rewards[address(0)][account] = amount;
    }

    function getPendingRewards(address, address account) external view returns (uint256) {
        return rewards[address(0)][account];
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        uint256 pending = rewards[address(0)][receiver];
        if (pending > 0) {
            rewards[address(0)][receiver] = 0;
            rewardToken.mint(receiver, pending);
        }
    }
}

/// @notice Mock Stake DAO RewardVault (ERC4626 + rewards)
contract MockRewardVault is ERC4626 {
    MockERC20 public rewardToken;
    address public immutable _accountant;
    mapping(address => uint256) public pendingRewards;

    constructor(address _lpToken, address _rewardToken, address accountant_)
        ERC4626(OZ_IERC20(_lpToken))
        ERC20("Mock Reward Vault", "mRV")
    {
        rewardToken = MockERC20(_rewardToken);
        _accountant = accountant_;
    }

    function ACCOUNTANT() external view returns (address) {
        return _accountant;
    }

    function addRewards(address account, uint256 amount) external {
        pendingRewards[account] += amount;
        // Also set on the accountant so getPendingRewards and claim work
        MockAccountant(_accountant).setRewards(account, pendingRewards[account]);
    }

    function claim() external returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        uint256 pending = pendingRewards[msg.sender];
        if (pending > 0) {
            pendingRewards[msg.sender] = 0;
            rewardToken.mint(msg.sender, pending);
            amounts[0] = pending;
        }
    }

    function earned(address account, address) external view returns (uint256) {
        return pendingRewards[account];
    }

    function rewardTokens(uint256) external view returns (address) {
        return address(rewardToken);
    }

    function rewardTokensLength() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Mock CRV swapper (1:1 CRV→crvUSD)
contract MockCrvSwapper {
    MockERC20 public immutable crv;
    MockERC20 public immutable crvUSD;

    constructor(address _crv, address _crvUSD) {
        crv = MockERC20(_crv);
        crvUSD = MockERC20(_crvUSD);
    }

    function swap(uint256 amount) external returns (uint256) {
        // CRV already transferred to us by strategy
        // Mint equivalent crvUSD to caller
        crvUSD.mint(msg.sender, amount);
        return amount;
    }
}

contract MockSwapper {
    MockERC20 public immutable collateral;
    MockERC20 public immutable debt;

    constructor(address _collateral, address _debt) {
        collateral = MockERC20(_collateral);
        debt = MockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount;
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        debt.mint(msg.sender, collateralAmount);
        return collateralAmount;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        collateral.mint(msg.sender, debtAmount);
        return debtAmount;
    }

    function setSlippage(uint256) external {}
}

contract MockAavePool is IAavePool {
    IERC20 public immutable collateral;
    IERC20 public immutable debtAsset;
    MockERC20 public immutable aToken;
    MockERC20 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        collateral = IERC20(_collateral);
        debtAsset = IERC20(_debtAsset);
        aToken = MockERC20(_aToken);
        variableDebtToken = MockERC20(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        variableDebtToken.burnFrom(onBehalfOf, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 burnAmount = amount;
        uint256 balance = aToken.balanceOf(msg.sender);
        if (burnAmount > balance) burnAmount = balance;
        aToken.burnFrom(msg.sender, burnAmount);
        IERC20(asset).transfer(to, burnAmount);
        return burnAmount;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        MockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }
    function setUserEMode(uint8) external {}
    function getUserEMode(address) external pure returns (uint256) { return 0; }
}

// ============ Test Contract ============

contract PmUsdCrvUsdStrategyTest is Test {
    MockERC20 wbtc;
    MockERC20 usdt;
    MockERC20 crvUSD;
    MockERC20 crv;
    MockERC20 pmUsd;
    MockERC20 lpToken;
    MockERC20 aToken;
    MockERC20 debtToken;

    MockAavePool aavePool;
    MockOracle collateralOracle;
    MockOracle debtOracle;
    MockOracle crvUsdOracle;
    MockOracle usdtOracle;
    MockOracle crvOracle;
    MockCurveStableSwap usdtCrvUsdPool;
    MockCurveStableSwapNG lpPool;
    MockAccountant accountant;
    MockRewardVault rewardVault;
    MockCrvSwapper crvSwapper;

    AaveLoanManager loanManager;
    PmUsdCrvUsdStrategy strategy;
    Zenji vault;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        // Deploy tokens
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usdt = new MockERC20("USDT", "USDT", 6);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        crv = new MockERC20("CRV", "CRV", 18);
        pmUsd = new MockERC20("pmUSD", "pmUSD", 18);
        lpToken = new MockERC20("pmUSD/crvUSD LP", "LP", 18);
        aToken = new MockERC20("aWBTC", "aWBTC", 8);
        debtToken = new MockERC20("vUSDT", "vUSDT", 6);

        // Deploy mocks
        aavePool =
            new MockAavePool(address(wbtc), address(usdt), address(aToken), address(debtToken));
        collateralOracle = new MockOracle(8, 1e8); // $1 for simplicity
        debtOracle = new MockOracle(8, 1e8);
        crvUsdOracle = new MockOracle(8, 1e8); // crvUSD $1.00
        usdtOracle = new MockOracle(8, 1e8); // USDT $1.00
        crvOracle = new MockOracle(8, 0.5e8); // CRV $0.50

        usdtCrvUsdPool = new MockCurveStableSwap(address(usdt), address(crvUSD), 0, 1);
        lpPool = new MockCurveStableSwapNG(address(crvUSD), 1);
        lpPool.setLpToken(address(lpToken));
        lpPool.setPmUsd(address(pmUsd));
        accountant = new MockAccountant(address(crv));
        rewardVault = new MockRewardVault(address(lpToken), address(crv), address(accountant));
        crvSwapper = new MockCrvSwapper(address(crv), address(crvUSD));
        address gauge = makeAddr("pmusdGauge");

        viewHelper = new ZenjiViewHelper();

        // Compute predicted vault address
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        MockSwapper swapper = new MockSwapper(address(wbtc), address(usdt));

        loanManager = new AaveLoanManager(
            address(wbtc),
            address(usdt),
            address(aToken),
            address(debtToken),
            address(aavePool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            predictedVault,
            0, // eMode: disabled
            3600
        );

        strategy = new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            predictedVault,
            owner,
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            gauge,
            0, // usdtIndex
            1, // crvUsdIndex
            1, // lpCrvUsdIndex (crvUSD at index 1 in pmUSD/crvUSD pool)
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );

        vault = new Zenji(
            address(wbtc),
            address(usdt),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        require(address(vault) == predictedVault, "Vault address mismatch");

        // Fund user
        wbtc.mint(user, 10e8); // 10 WBTC
        vm.prank(user);
        wbtc.approve(address(vault), type(uint256).max);
    }

    // ============ Deposit Tests ============

    function test_deposit_full_flow() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        assertGt(loanManager.getCurrentDebt(), 0, "Should have USDT debt");
        assertGt(strategy.balanceOf(), 0, "Strategy should have balance");
        assertGt(rewardVault.balanceOf(address(strategy)), 0, "Should have reward vault shares");
    }

    function test_deposit_creates_lp_position() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // Reward vault shares should exist
        uint256 shares = rewardVault.balanceOf(address(strategy));
        assertGt(shares, 0, "Should hold reward vault shares");

        // LP value should be accessible
        uint256 lpBalance = rewardVault.convertToAssets(shares);
        assertGt(lpBalance, 0, "LP balance should be > 0");
    }

    // ============ Withdrawal Tests ============

    function test_withdraw_partial() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.roll(block.number + 1);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares / 2, user, user);

        assertLt(vault.balanceOf(user), shares, "Shares should decrease");
        assertGt(wbtc.balanceOf(user), 9e8, "User should receive some WBTC back");
    }

    function test_withdraw_all_via_idle() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.prank(owner);
        vault.setIdle(true);

        assertEq(usdt.balanceOf(address(strategy)), 0, "Strategy should not hold USDT after idle");
    }

    // ============ Emergency Tests ============

    function test_emergency_withdraw() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.prank(owner);
        vault.emergencyRescue(2);

        assertEq(usdt.balanceOf(address(strategy)), 0, "Strategy should not retain USDT");
    }

    // ============ Harvest Tests ============

    function test_harvest_with_crv_rewards() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 balanceBefore = strategy.balanceOf();

        // Simulate CRV rewards
        rewardVault.addRewards(address(strategy), 1e18); // 1 CRV

        vm.prank(owner);
        vault.harvestYield();

        uint256 balanceAfter = strategy.balanceOf();
        assertGt(balanceAfter, balanceBefore, "Balance should increase after harvest");
    }

    function test_harvest_skips_below_threshold() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 balanceBefore = strategy.balanceOf();

        // Add rewards below threshold (< 0.1 CRV)
        rewardVault.addRewards(address(strategy), 5e16); // 0.05 CRV

        vm.prank(owner);
        vault.harvestYield();

        // Balance should be essentially unchanged (no compound)
        uint256 balanceAfter = strategy.balanceOf();
        assertEq(balanceAfter, balanceBefore, "Balance should not change below threshold");
    }

    function test_harvest_with_zero_rewards() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.prank(owner);
        vault.harvestYield(); // Should not revert
    }

    // ============ Balance / Oracle Tests ============

    function test_balanceOf_with_fresh_oracles() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 balance = strategy.balanceOf();
        assertGt(balance, 0, "Balance should be > 0");
    }

    function test_balanceOf_reverts_when_oracle_stale() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // Make oracle stale
        vm.warp(block.timestamp + 100001);
        crvUsdOracle.setStale();

        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        strategy.balanceOf();
    }

    function test_setParam4_slippage_forwardedByOwner() public {
        vm.prank(owner);
        vault.setParam(4, 3e16);
        assertEq(strategy.slippageTolerance(), 3e16);
    }

    function test_setParam4_slippage_reverts_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(Zenji.Unauthorized.selector);
        vault.setParam(4, 3e16);
    }

    function test_balanceOf_zero_when_empty() public view {
        assertEq(strategy.balanceOf(), 0, "Empty strategy should return 0");
    }

    // ============ View Function Tests ============

    function test_name() public view {
        assertEq(strategy.name(), "USDT -> pmUSD/crvUSD LP Strategy");
    }

    function test_underlyingAsset() public view {
        assertEq(strategy.underlyingAsset(), address(lpToken));
    }

    function test_asset() public view {
        assertEq(strategy.asset(), address(usdt));
    }

    function test_pendingRewards_returns_zero_initially() public view {
        assertEq(strategy.pendingRewards(), 0);
    }

    function test_pendingRewards_with_earned() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        rewardVault.addRewards(address(strategy), 2e18); // 2 CRV
        uint256 pending = strategy.pendingRewards();
        assertGt(pending, 0, "Should show pending rewards");
    }

    // ============ Access Control Tests ============

    function test_deposit_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.deposit(1e6);
    }

    function test_withdraw_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdraw(1e6);
    }

    function test_withdrawAll_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdrawAll();
    }

    function test_harvest_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.harvest();
    }

    function test_rescueERC20_reverts_for_crv_rewards() public {
        crv.mint(address(strategy), 1e18);

        vm.prank(owner);
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        strategy.rescueERC20(address(crv), user, 1e18);
    }

    function test_emergencyWithdraw_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.emergencyWithdraw();
    }

    // ============ Slippage Tests ============

    function test_setSlippage() public {
        vm.prank(address(vault));
        strategy.setSlippage(3e16); // 3%
        assertEq(strategy.slippageTolerance(), 3e16);
    }

    function test_setSlippage_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.setSlippage(3e16);
    }

    function test_setSlippage_reverts_over_max() public {
        vm.prank(address(vault));
        vm.expectRevert(IYieldStrategy.SlippageExceeded.selector);
        strategy.setSlippage(6e16); // > 5%
    }

    // ============ Cost Basis Tests ============

    function test_costBasis_tracks_deposits() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        assertGt(strategy.costBasis(), 0, "Cost basis should be > 0 after deposit");
    }

    function test_unrealizedProfit_zero_initially() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // With 1:1 mocks, unrealized profit should be ~0
        uint256 profit = strategy.unrealizedProfit();
        // May be slightly off due to decimal conversions
        assertLe(profit, strategy.costBasis() / 100, "Profit should be minimal with 1:1 mocks");
    }

    // ============ Branch Coverage: pendingRewards revert fallback ============

    function test_pendingRewards_returns_zero_when_accountant_reverts() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // Make accountant's getPendingRewards revert by replacing with a contract that always reverts
        address accountantAddr = rewardVault.ACCOUNTANT();
        vm.etch(accountantAddr, type(RevertingAccountant).runtimeCode);

        uint256 pending = strategy.pendingRewards();
        assertEq(pending, 0, "Should return 0 when accountant reverts");
    }

    // ============ Branch Coverage: _claimAndCompound SwapFailed ============

    function test_harvest_reverts_when_crv_swap_fails() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // Add CRV rewards above threshold
        rewardVault.addRewards(address(strategy), 1e18);

        // Replace crvSwapper with a reverting one
        address crvSwapperAddr = address(strategy.crvSwapper());
        vm.etch(crvSwapperAddr, type(RevertingCrvSwapper).runtimeCode);

        vm.prank(owner);
        vm.expectRevert(PmUsdCrvUsdStrategy.SwapFailed.selector);
        vault.harvestYield();
    }

    function test_emergencyRescue2_clears_accumulatedFees() public {
        vm.prank(owner);
        vault.setParam(0, 1e17); // 10% fee rate

        vm.prank(user);
        vault.deposit(1e8, user);

        rewardVault.addRewards(address(strategy), 1e18);

        vm.prank(owner);
        vault.harvestYield();

        assertGt(vault.accumulatedFees(), 0, "Harvest should accrue fees before emergency rescue");

        vm.startPrank(owner);
        vault.enterEmergencyMode();
        vault.emergencyRescue(2);
        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 0, "Emergency rescue step 2 should clear accumulated fees");
        assertEq(vault.lastStrategyBalance(), 0, "Emergency rescue step 2 should clear strategy checkpoint");
    }

    // ============ More Branch Coverage ============

    function test_withdrawAll_returns_zero_when_empty() public {
        vm.prank(address(vault));
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0, "Empty withdrawAll returns 0");
    }

    function test_emergencyWithdraw_returns_zero_when_empty() public {
        vm.prank(address(vault));
        uint256 received = strategy.emergencyWithdraw();
        assertEq(received, 0, "Empty emergencyWithdraw returns 0");
    }

    function test_withdraw_returns_zero_when_empty() public {
        vm.prank(address(vault));
        strategy.withdraw(1e6);
        assertEq(strategy.balanceOf(), 0);
    }

    function test_withdraw_partial_proportional() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 bal = strategy.balanceOf();
        assertGt(bal, 0);

        vm.prank(address(vault));
        uint256 received = strategy.withdraw(bal / 2);
        assertGt(received, 0, "Should receive USDT");
    }

    function test_harvest_no_rewards_no_compound() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 balBefore = strategy.balanceOf();
        vm.prank(owner);
        vault.harvestYield();
        uint256 balAfter = strategy.balanceOf();

        // No rewards → no compound → balance unchanged
        assertEq(balAfter, balBefore, "No rewards -> no change");
    }

    // ============ Branch Coverage: _withdraw sharesToRedeem < 1 ============

    function test_withdraw_moreThanBalance_capsToShares() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 bal = strategy.balanceOf();
        assertGt(bal, 0);

        // Withdraw much more than balance — sharesToRedeem > shares, gets capped
        vm.prank(address(vault));
        uint256 received = strategy.withdraw(bal * 10);
        assertGt(received, 0, "Should receive some USDT");
    }

    // ============ Branch Coverage: _withdrawAll with lpReceived < 1 ============

    function test_withdrawAll_zeroLP_returnsZero() public {
        // Strategy has no LP deposits, _redeemAllFromRewardVault returns 0 → _withdrawAll returns 0
        vm.prank(address(vault));
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0, "WithdrawAll with no LP should return 0");
    }

    // ============ Branch Coverage: constructor zero-address checks ============

    function test_constructor_zeroCrvSwapper_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(0), // crvSwapper = 0
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroCrvUsd_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(0), // crvUSD = 0
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroCrv_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(0), // crv = 0
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroUsdtCrvUsdPool_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(0), // usdtCrvUsdPool = 0
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroLpPool_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(0), // lpPool = 0
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroGauge_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            address(0), // gauge = 0
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroCrvUsdOracle_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(0), // crvUsdOracle = 0
            address(usdtOracle),
            address(crvOracle)
        );
    }

    function test_constructor_zeroUsdtOracle_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(0), // usdtOracle = 0
            address(crvOracle)
        );
    }

    function test_constructor_zeroCrvOracle_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUsd),
            address(vault),
            makeAddr("owner"),
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,
            1,
            1,
            address(crvUsdOracle),
            address(usdtOracle),
            address(0) // crvOracle = 0
        );
    }
}

/// @notice Accountant mock that always reverts on getPendingRewards
contract RevertingAccountant {
    function getPendingRewards(address, address) external pure {
        revert("always reverts");
    }

    function claim(address[] calldata, bytes[] calldata, address) external pure {
        revert("always reverts");
    }
}

/// @notice CRV swapper mock that always reverts
contract RevertingCrvSwapper {
    function swap(uint256) external pure returns (uint256) {
        revert("swap failed");
    }
}
