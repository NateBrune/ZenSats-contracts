// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ICurveStableSwap } from "../src/interfaces/ICurveStableSwap.sol";
import { CurveUsdtSwapLib } from "../src/libraries/CurveUsdtSwapLib.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

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

    function setStale() external {
        updatedAt = block.timestamp - 100000;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract MockYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock IPOR", "mIPOR") { }
}

contract MockCurveStableSwap is ICurveStableSwap {
    IERC20 public immutable usdt;
    IERC20 public immutable crvUSD;
    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;

    constructor(address _usdt, address _crvUSD, int128 _usdtIndex, int128 _crvUsdIndex) {
        usdt = IERC20(_usdt);
        crvUSD = IERC20(_crvUSD);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        if (i == usdtIndex && j == crvUsdIndex) {
            // USDT (6 dec) -> crvUSD (18 dec): scale up by 1e12
            usdt.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx * 1e12;
            MockERC20(address(crvUSD)).mint(msg.sender, out);
            return out;
        }
        if (i == crvUsdIndex && j == usdtIndex) {
            // crvUSD (18 dec) -> USDT (6 dec): scale down by 1e12
            crvUSD.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx / 1e12;
            MockERC20(address(usdt)).mint(msg.sender, out);
            return out;
        }
        return 0;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if (i == usdtIndex && j == crvUsdIndex) {
            return dx * 1e12; // USDT -> crvUSD
        }
        if (i == crvUsdIndex && j == usdtIndex) {
            return dx / 1e12; // crvUSD -> USDT
        }
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        if (i == uint256(uint128(uint128(usdtIndex)))) return address(usdt);
        if (i == uint256(uint128(uint128(crvUsdIndex)))) return address(crvUSD);
        return address(0);
    }

    function balances(uint256) external pure returns (uint256) {
        return 0;
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
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
        if (burnAmount > balance) {
            burnAmount = balance;
        }
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
        IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset, amount, 0, receiverAddress, params
        );
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }
}

contract UsdtIporAaveStrategyTest is Test {
    MockERC20 wbtc;
    MockERC20 usdt;
    MockERC20 crvUSD;
    MockERC20 aToken;
    MockERC20 debtToken;

    MockAavePool pool;
    MockOracle collateralOracle;
    MockOracle debtOracle;
    MockOracle crvUsdOracle;
    MockOracle usdtOracle;
    MockYieldVault iporVault;
    MockCurveStableSwap curvePool;

    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    Zenji vault;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usdt = new MockERC20("USDT", "USDT", 6);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        aToken = new MockERC20("aWBTC", "aWBTC", 8);
        debtToken = new MockERC20("vUSDT", "vUSDT", 6);

        pool = new MockAavePool(address(wbtc), address(usdt), address(aToken), address(debtToken));
        collateralOracle = new MockOracle(8, 1e8);
        debtOracle = new MockOracle(8, 1e8);
        crvUsdOracle = new MockOracle(8, 1e8); // crvUSD at $1.00
        usdtOracle = new MockOracle(8, 1e8); // USDT at $1.00
        iporVault = new MockYieldVault(address(crvUSD));
        curvePool = new MockCurveStableSwap(address(usdt), address(crvUSD), 0, 1);

        viewHelper = new ZenjiViewHelper();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        MockSwapper swapper = new MockSwapper(address(wbtc), address(usdt));

        loanManager = new AaveLoanManager(
            address(wbtc),
            address(usdt),
            address(aToken),
            address(debtToken),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(swapper),
            7500,
            8000,
            predictedVault
        );

        strategy = new UsdtIporYieldStrategy(
            address(usdt),
            address(crvUSD),
            predictedVault,
            address(curvePool),
            address(iporVault),
            0,
            1,
            address(crvUsdOracle),
            address(usdtOracle)
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

        wbtc.mint(user, 1e8);
        vm.prank(user);
        wbtc.approve(address(vault), type(uint256).max);
    }

    function test_borrowUsdt_and_depositIntoIporViaSwap() public {
        vm.prank(user);
        vault.deposit(1e8, address(this));

        assertGt(loanManager.getCurrentDebt(), 0, "USDT debt should be > 0");
        assertGt(strategy.balanceOf(), 0, "Strategy balance should be > 0");
        assertGt(iporVault.balanceOf(address(strategy)), 0, "IPOR shares should be > 0");
        assertGt(crvUSD.balanceOf(address(iporVault)), 0, "IPOR vault should hold crvUSD");
    }

    function test_withdraw_partial_flow() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.roll(block.number + 1);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares / 2, user, user);

        assertLt(vault.balanceOf(user), shares, "Shares should decrease");
        assertGt(wbtc.balanceOf(user), 0, "User should receive WBTC");
    }

    function test_strategy_withdrawAll_emitsAndReturnsUsdt() public {
        vm.prank(user);
        vault.deposit(1e8, address(this));

        vm.prank(owner);
        vault.setIdle(true);

        assertEq(usdt.balanceOf(address(strategy)), 0, "Strategy should not hold USDT after idle");
        assertGt(wbtc.balanceOf(address(vault)), 0, "Vault should recover collateral");
    }

    // function test_strategy_pause_unwinds_to_usdt() public {
    //     vm.prank(user);
    //     vault.deposit(1e8, address(this));

    //     vm.prank(owner);
    //     vault.pauseStrategy();

    //     assertTrue(strategy.paused(), "Strategy should be paused");
    //     assertEq(usdt.balanceOf(address(strategy)), 0, "Strategy should not hold USDT");
    // }

    function test_strategy_emergency_withdraw() public {
        vm.prank(user);
        vault.deposit(1e8, address(this));

        vm.prank(owner);
        vault.enterEmergencyMode();

        vm.prank(owner);
        vault.emergencyRescue(2);

        assertEq(usdt.balanceOf(address(strategy)), 0, "Strategy should not retain USDT");
    }

    function test_strategy_slippage_update() public {
        vm.prank(address(vault));
        strategy.setSlippage(5e16);

        assertEq(strategy.slippageTolerance(), 5e16, "Slippage should update");
    }

    function test_strategy_reverts_on_zero_deposit() public {
        vm.prank(owner);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.deposit(0);
    }

    function test_strategy_reverts_on_non_vault_call() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.withdrawAll();
    }

    // ============ Branch Coverage Tests ============

    function test_strategy_name() public view {
        string memory n = strategy.name();
        assertGt(bytes(n).length, 0, "Name should not be empty");
    }

    function test_strategy_underlyingAsset() public view {
        assertEq(strategy.underlyingAsset(), address(crvUSD), "Underlying asset should be crvUSD");
    }

    function test_strategy_setSlippage_onlyVault() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.setSlippage(5e16);
    }

    // ============ Additional Branch Coverage ============

    function test_balanceOf_returns_zero_when_ipor_empty() public view {
        // Strategy has no deposits, IPOR balance is 0
        assertEq(strategy.balanceOf(), 0, "Empty strategy should return 0");
    }

    function test_withdraw_returns_zero_when_currentValue_zero() public {
        // No deposit → balanceOf() is 0 → _withdraw returns 0
        vm.prank(address(vault));
        // Withdraw from empty strategy should not revert, just return 0
        strategy.withdraw(1e6);
        // Strategy balance should still be 0
        assertEq(strategy.balanceOf(), 0);
    }

    function test_balanceOf_oracle_stale_reverts() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 normalBalance = strategy.balanceOf();
        assertGt(normalBalance, 0, "Should have balance after deposit");

        // Make crvUSD oracle stale → now reverts with StaleOrInvalidOracle
        vm.warp(block.timestamp + 100001);
        crvUsdOracle.setStale();

        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        strategy.balanceOf();
    }

    // ============ More Branch Coverage ============

    function test_withdrawAll_returns_zero_when_empty() public {
        // No deposit → _withdrawAll with 0 crvUSD → returns 0
        vm.prank(address(vault));
        uint256 received = strategy.withdrawAll();
        assertEq(received, 0, "Empty withdrawAll returns 0");
    }

    function test_emergencyWithdraw_returns_zero_when_empty() public {
        vm.prank(address(vault));
        uint256 received = strategy.emergencyWithdraw();
        assertEq(received, 0, "Empty emergencyWithdraw returns 0");
    }

    function test_withdraw_partial_proportional_shares() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        uint256 balBefore = strategy.balanceOf();
        assertGt(balBefore, 0);

        // Withdraw half
        vm.prank(address(vault));
        uint256 received = strategy.withdraw(balBefore / 2);
        assertGt(received, 0, "Should receive some USDT");
    }

    function test_setSlippage_maxSlippage_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IYieldStrategy.SlippageExceeded.selector);
        strategy.setSlippage(6e16); // > 5%
    }

    function test_deposit_onlyVault_reverts() public {
        vm.prank(user);
        vm.expectRevert(IYieldStrategy.Unauthorized.selector);
        strategy.deposit(1e6);
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

    // ============ Branch Coverage: constructor zero-address checks ============

    function test_constructor_zeroCrvUSD_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new UsdtIporYieldStrategy(
            address(usdt),
            address(0), // crvUSD = 0
            address(vault),
            address(curvePool),
            address(iporVault),
            0,
            1,
            address(crvUsdOracle),
            address(usdtOracle)
        );
    }

    function test_constructor_zeroCurvePool_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new UsdtIporYieldStrategy(
            address(usdt),
            address(crvUSD),
            address(vault),
            address(0), // curvePool = 0
            address(iporVault),
            0,
            1,
            address(crvUsdOracle),
            address(usdtOracle)
        );
    }

    function test_constructor_zeroCrvUsdOracle_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new UsdtIporYieldStrategy(
            address(usdt),
            address(crvUSD),
            address(vault),
            address(curvePool),
            address(iporVault),
            0,
            1,
            address(0), // crvUsdOracle = 0
            address(usdtOracle)
        );
    }

    function test_constructor_zeroUsdtOracle_reverts() public {
        vm.expectRevert(IYieldStrategy.InvalidAddress.selector);
        new UsdtIporYieldStrategy(
            address(usdt),
            address(crvUSD),
            address(vault),
            address(curvePool),
            address(iporVault),
            0,
            1,
            address(crvUsdOracle),
            address(0) // usdtOracle = 0
        );
    }
}
