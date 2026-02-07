// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ICurveStableSwap } from "../src/interfaces/ICurveStableSwap.sol";
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

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
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
            usdt.transferFrom(msg.sender, address(this), dx);
            MockERC20(address(crvUSD)).mint(msg.sender, dx);
            return dx;
        }
        if (i == crvUsdIndex && j == usdtIndex) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            MockERC20(address(usdt)).mint(msg.sender, dx);
            return dx;
        }
        return 0;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if ((i == usdtIndex && j == crvUsdIndex) || (i == crvUsdIndex && j == usdtIndex)) {
            return dx;
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
        usdt = new MockERC20("USDT", "USDT", 18);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        aToken = new MockERC20("aWBTC", "aWBTC", 8);
        debtToken = new MockERC20("vUSDT", "vUSDT", 18);

        pool = new MockAavePool(address(wbtc), address(usdt), address(aToken), address(debtToken));
        collateralOracle = new MockOracle(8, 1e8);
        debtOracle = new MockOracle(8, 1e8);
        iporVault = new MockYieldVault(address(crvUSD));
        curvePool = new MockCurveStableSwap(address(usdt), address(crvUSD), 0, 1);

        viewHelper = new ZenjiViewHelper();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);

        loanManager = new AaveLoanManager(
            address(wbtc),
            address(usdt),
            address(aToken),
            address(debtToken),
            address(pool),
            address(collateralOracle),
            address(debtOracle),
            address(0),
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
            1
        );

        vault = new Zenji(
            address(wbtc),
            address(usdt),
            address(loanManager),
            address(strategy),
            owner,
            address(viewHelper)
        );

        require(address(vault) == predictedVault, "Vault address mismatch");

        vm.prank(owner);
        vault.toggleYield(true);

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
        vault.emergencyRedeemYield();

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
}
