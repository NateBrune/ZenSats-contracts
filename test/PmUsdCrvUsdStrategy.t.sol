// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { NgCrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/NgCrvUsdLpStakeDaoStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
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
        updatedAt = 0; // epoch 0 — block.timestamp - 0 always exceeds any staleness threshold
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

/// @notice Mock Curve StableSwapNG pool (pmUSD/crvUSD) with LP token minting
contract MockCurveStableSwapNG {
    MockERC20 public immutable crvUSD;
    MockERC20 public pmUSD;
    MockERC20 public lpToken;
    int128 public immutable crvUsdIdx;
    uint256 public pmUsdIdx;
    uint256 private _virtualPrice = 1e18;

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

    function setVirtualPrice(uint256 vp) external {
        _virtualPrice = vp;
    }

    function add_liquidity(uint256[] calldata amounts, uint256) external returns (uint256) {
        uint256 crvUsdAmount = amounts[uint256(uint128(crvUsdIdx))];
        uint256 pmUsdAmount = amounts[pmUsdIdx];
        if (crvUsdAmount > 0) crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount);
        if (pmUsdAmount > 0 && address(pmUSD) != address(0)) {
            pmUSD.transferFrom(msg.sender, address(this), pmUsdAmount);
        }
        uint256 totalMinted = crvUsdAmount + pmUsdAmount;
        if (totalMinted > 0) lpToken.mint(msg.sender, totalMinted);
        return totalMinted;
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external
        returns (uint256)
    {
        lpToken.transferFrom(msg.sender, address(this), burn_amount);
        crvUSD.mint(msg.sender, burn_amount);
        return burn_amount;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIdx))] + amounts[pmUsdIdx];
    }

    function calc_withdraw_one_coin(uint256 burn_amount, int128) external pure returns (uint256) {
        return burn_amount;
    }

    function get_virtual_price() external view returns (uint256) {
        return _virtualPrice;
    }

    function N_COINS() external pure returns (uint256) {
        return 2;
    }

    function coins(uint256 i) external view returns (address) {
        return i == uint256(uint128(crvUsdIdx)) ? address(crvUSD) : address(pmUSD);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock Stake DAO Accountant
contract MockAccountant {
    MockERC20 public rewardToken;
    mapping(address => uint256) public rewards;

    constructor(address _rewardToken) {
        rewardToken = MockERC20(_rewardToken);
    }

    function setRewards(address account, uint256 amount) external {
        rewards[account] = amount;
    }

    function getPendingRewards(address, address account) external view returns (uint256) {
        return rewards[account];
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        uint256 pending = rewards[receiver];
        if (pending > 0) {
            rewards[receiver] = 0;
            rewardToken.mint(receiver, pending);
        }
    }
}

/// @notice Mock Stake DAO RewardVault (ERC4626)
contract MockRewardVault is ERC4626 {
    address public immutable _accountant;

    constructor(address _lpToken, address accountant_)
        ERC4626(OZ_IERC20(_lpToken))
        ERC20("Mock Reward Vault", "mRV")
    {
        _accountant = accountant_;
    }

    function ACCOUNTANT() external view returns (address) {
        return _accountant;
    }

    function claim() external returns (uint256[] memory amounts) {
        amounts = new uint256[](0);
    }
}

/// @notice Mock CRV -> crvUSD swapper (1:1)
contract MockCrvSwapper {
    MockERC20 public immutable crvUSD;

    constructor(address _crvUSD) {
        crvUSD = MockERC20(_crvUSD);
    }

    function swap(uint256 amount) external returns (uint256) {
        // CRV already at this address - mint equivalent crvUSD to caller
        crvUSD.mint(msg.sender, amount);
        return amount;
    }

    function quote(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function setSlippage(uint256) external {}
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

    function getUserEMode(address) external pure returns (uint256) {
        return 0;
    }
}

// ============ Test Contract ============

/// @notice Unit tests for crvUSD-native NgCrvUsdLpStakeDaoStrategy (no USDT swap layer)
contract PmUsdCrvUsdStrategyTest is Test {
    // Tokens
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MockERC20 crv;
    MockERC20 pmUsd;
    MockERC20 lpToken;
    MockERC20 aToken;
    MockERC20 debtToken; // mock aave crvUSD debt token

    // Infrastructure mocks
    MockAavePool aavePool;
    MockOracle collateralOracle; // BTC/USD
    MockOracle crvUsdOracle; // crvUSD/USD
    MockOracle crvOracle; // CRV/USD
    MockCurveStableSwapNG lpPool;
    MockAccountant accountant;
    MockRewardVault rewardVault;
    MockCrvSwapper crvSwapper;
    MockSwapper swapper;

    // Protocol contracts
    AaveLoanManager loanManager;
    NgCrvUsdLpStakeDaoStrategy strategy;
    Zenji vault;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address gauge = makeAddr("pmusdCrvUsdGauge");

    uint256 constant DEPOSIT_AMOUNT = 1000e18; // 1000 crvUSD

    function setUp() public {
        // Deploy tokens
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        // Strategy constants (CRVUSD, crv, pmUSD) reference hardcoded mainnet addresses.
        // Etch mock ERC20 code at those addresses so unit tests work without a fork.
        bytes memory erc20Code = address(new MockERC20("x", "x", 18)).code;
        vm.etch(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, erc20Code); // CRVUSD
        vm.etch(0xD533a949740bb3306d119CC777fa900bA034cd52, erc20Code); // crv
        vm.etch(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF, erc20Code); // pmUSD
        crvUSD = MockERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        crv = MockERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
        pmUsd = MockERC20(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF);
        lpToken = new MockERC20("pmUSD/crvUSD LP", "LP", 18);
        aToken = new MockERC20("aWBTC", "aWBTC", 8);
        debtToken = new MockERC20("varcrvUSD", "varcrvUSD", 18); // 18 dec for crvUSD

        // Deploy oracle mocks
        collateralOracle = new MockOracle(8, 100_000e8); // BTC $100k
        crvUsdOracle = new MockOracle(8, 1e8); // crvUSD $1.00
        crvOracle = new MockOracle(8, 0.50e8); // CRV $0.50

        // Deploy pool / vault mocks
        // crvUSD is at index 1 in pmUSD/crvUSD pool (pmUSD=0, crvUSD=1)
        lpPool = new MockCurveStableSwapNG(address(crvUSD), int128(1));
        lpPool.setLpToken(address(lpToken));
        lpPool.setPmUsd(address(pmUsd));

        accountant = new MockAccountant(address(crv));
        rewardVault = new MockRewardVault(address(lpToken), address(accountant));
        crvSwapper = new MockCrvSwapper(address(crvUSD));

        viewHelper = new ZenjiViewHelper();

        // Predict vault address
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 4);

        swapper = new MockSwapper(address(wbtc), address(crvUSD));

        // Use AaveLoanManager with crvUSD debt for simplicity (tests strategy, not loan manager)
        aavePool = new MockAavePool(
            address(wbtc), address(crvUSD), address(aToken), address(debtToken)
        );

        loanManager = new AaveLoanManager(
            address(wbtc),
            address(crvUSD),
            address(aToken),
            address(debtToken),
            address(aavePool),
            address(collateralOracle),
            address(crvUsdOracle),
            address(swapper),
            7500,
            8000,
            predictedVault,
            0,
            3600
        );

        strategy = new NgCrvUsdLpStakeDaoStrategy(
            address(crvUSD), // _crvUsd
            predictedVault, // _vault
            owner, // _owner
            address(lpPool), // _lpPool
            address(rewardVault), // _rewardVault
            address(crvSwapper), // _crvSwapper
            gauge, // _gauge
            int128(1), // _lpCrvUsdIndex (crvUSD at index 1)
            address(crvUsdOracle), // _crvUsdOracle
            address(crvOracle) // _crvOracle
        );

        vault = new Zenji(
            address(wbtc),
            address(crvUSD),
            address(loanManager),
            address(strategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        // Fund user with WBTC collateral
        wbtc.mint(user, 1e8); // 1 BTC
    }

    // ============ Basic Properties ============

    function test_name() public view {
        assertEq(strategy.name(), "crvUSD -> NG crvUSD/token LP Strategy");
    }

    function test_debtAsset_is_crvUsd() public view {
        assertEq(address(strategy.debtAsset()), address(crvUSD));
    }

    function test_lpCrvUsdIndex() public view {
        assertEq(strategy.lpCrvUsdIndex(), int128(1));
        assertEq(strategy.lpOtherIndex(), 0);
    }

    function test_owner_set() public view {
        assertEq(strategy.owner(), owner);
    }

    // ============ Deposit ============

    function test_deposit_full_flow() public {
        // Simulate vault sending crvUSD to strategy
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);

        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);

        vm.prank(address(vault));
        uint256 underlying = strategy.deposit(DEPOSIT_AMOUNT);

        // LP tokens equal to crvUSD sent (1:1 mock)
        assertEq(underlying, DEPOSIT_AMOUNT);
        // No crvUSD should remain in strategy
        assertEq(crvUSD.balanceOf(address(strategy)), 0);
        // Reward vault has shares
        assertGt(rewardVault.balanceOf(address(strategy)), 0);
    }

    function test_deposit_creates_lp_position() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        // Strategy balance should reflect crvUSD value via VP (1e18)
        uint256 bal = strategy.balanceOf();
        assertApproxEqRel(bal, DEPOSIT_AMOUNT, 0.01e18); // within 1%
    }

    function test_deposit_second_round_compounds_pending_crv() public {
        // First deposit
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        // Simulate CRV reward accumulation
        uint256 rewardAmount = 50e18;
        accountant.setRewards(address(strategy), rewardAmount);

        // Second deposit — triggers _claimAndCompound → harvests CRV
        uint256 deposit2 = 200e18;
        crvUSD.mint(address(vault), deposit2);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), deposit2);
        vm.prank(address(vault));
        strategy.deposit(deposit2);

        // Balance should exceed deposit1 + deposit2 due to compounded CRV rewards
        uint256 bal = strategy.balanceOf();
        assertGt(bal, DEPOSIT_AMOUNT + deposit2);
    }

    // ============ Withdraw ============

    function test_withdraw_partial() public {
        // Setup: deposit crvUSD
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        uint256 halfDeposit = DEPOSIT_AMOUNT / 2;
        vm.prank(address(vault));
        uint256 received = strategy.withdraw(halfDeposit);

        // Should receive approx half back (1:1 mock LP)
        assertGt(received, 0);
        assertApproxEqRel(received, halfDeposit, 0.02e18);
        // Vault gets crvUSD
        assertGt(crvUSD.balanceOf(address(vault)), 0);
    }

    function test_withdraw_all() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(address(vault));
        uint256 received = strategy.withdrawAll();

        assertGt(received, 0);
        // Strategy should have no more LP staked
        assertEq(rewardVault.balanceOf(address(strategy)), 0);
        // No crvUSD remains in strategy
        assertEq(crvUSD.balanceOf(address(strategy)), 0);
    }

    function test_withdraw_all_via_idle() public {
        // withdrawAll when nothing staked returns 0
        vm.prank(address(vault));
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0);
    }

    // ============ Emergency ============

    function test_emergency_withdraw() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(address(vault));
        uint256 received = strategy.emergencyWithdraw();

        assertGt(received, 0);
        assertEq(rewardVault.balanceOf(address(strategy)), 0);
    }

    // ============ Harvest ============

    function test_harvest_compounds_crv_rewards() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        uint256 balanceBefore = strategy.balanceOf();

        // Simulate CRV accumulation
        uint256 rewardCrv = 100e18; // 100 CRV = 50 crvUSD at $0.50
        accountant.setRewards(address(strategy), rewardCrv);

        vm.prank(address(vault));
        uint256 rewardsValue = strategy.harvest();

        assertGt(rewardsValue, 0);
        // Balance should increase after compounding
        assertGt(strategy.balanceOf(), balanceBefore);
    }

    // ============ Balance and Rewards ============

    function test_balance_of_empty_returns_zero() public view {
        assertEq(strategy.balanceOf(), 0);
    }

    function test_balance_of_after_deposit() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        assertGt(strategy.balanceOf(), 0);
    }

    function test_pending_rewards_oracle_price() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        // Set 200 CRV pending
        accountant.setRewards(address(strategy), 200e18);

        uint256 pending = strategy.pendingRewards();
        // 200 CRV × $0.50 / $1.00 = 100 crvUSD
        assertApproxEqRel(pending, 100e18, 0.01e18);
    }

    function test_pending_rewards_stale_oracle_falls_back_to_quote() public {
        crvUSD.mint(address(vault), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        crvUSD.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(address(vault));
        strategy.deposit(DEPOSIT_AMOUNT);

        accountant.setRewards(address(strategy), 100e18);
        crvOracle.setStale();

        // Falls back to crvSwapper.quote() which returns 1:1
        uint256 pending = strategy.pendingRewards();
        assertGt(pending, 0);
    }

    function test_pending_rewards_zero_when_no_crv() public view {
        assertEq(strategy.pendingRewards(), 0);
    }

    // ============ Slippage ============

    function test_set_slippage_by_owner() public {
        vm.prank(owner);
        strategy.setSlippage(2e16); // 2%
        assertEq(strategy.slippageTolerance(), 2e16);
    }

    function test_set_slippage_by_vault() public {
        vm.prank(address(vault));
        strategy.setSlippage(2e16);
        assertEq(strategy.slippageTolerance(), 2e16);
    }

    function test_set_slippage_reverts_unauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        strategy.setSlippage(2e16);
    }

    function test_set_slippage_reverts_below_min() public {
        vm.prank(owner);
        vm.expectRevert();
        strategy.setSlippage(1e14); // 0.01% — below min
    }

    function test_set_slippage_reverts_above_max() public {
        vm.prank(owner);
        vm.expectRevert();
        strategy.setSlippage(6e16); // 6% — above max
    }

    // ============ Virtual Price Cache ============

    function test_update_cached_virtual_price_permissionless() public {
        // Should not revert when called by anyone
        strategy.updateCachedVirtualPrice();
        assertEq(strategy.cachedVirtualPrice(), 1e18);
    }

    // ============ Constructor Validation ============

    function test_constructor_zero_owner_reverts() public {
        vm.expectRevert();
        new NgCrvUsdLpStakeDaoStrategy(
            address(crvUSD),
            address(lpPool),  // vault (any non-zero)
            address(0),       // owner = 0 → should revert
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            gauge,
            int128(1),
            address(crvUsdOracle),
            address(crvOracle)
        );
    }


    // ============ Access Control ============

    function test_deposit_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert();
        strategy.deposit(DEPOSIT_AMOUNT);
    }

    function test_withdraw_reverts_non_vault() public {
        vm.prank(user);
        vm.expectRevert();
        strategy.withdraw(DEPOSIT_AMOUNT);
    }

    function test_rescue_erc20_by_owner() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        random.mint(address(strategy), 100e18);

        vm.prank(owner);
        strategy.rescueERC20(address(random), owner, 100e18);

        assertEq(random.balanceOf(owner), 100e18);
    }

    function test_rescue_erc20_reverts_for_debt_asset() public {
        vm.prank(owner);
        vm.expectRevert();
        strategy.rescueERC20(address(crvUSD), owner, 1);
    }

    function test_rescue_erc20_reverts_non_owner() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        vm.prank(user);
        vm.expectRevert();
        strategy.rescueERC20(address(random), user, 1);
    }

    function test_transfer_owner_from_vault() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(address(vault));
        strategy.transferOwnerFromVault(newOwner);
        assertEq(strategy.owner(), newOwner);
    }

    function test_transfer_owner_reverts_non_vault() public {
        vm.prank(owner);
        vm.expectRevert();
        strategy.transferOwnerFromVault(makeAddr("x"));
    }
}
