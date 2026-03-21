// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IChainlinkOracleH2 {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

// ─────────────────────────────────────────────────────────────────
//  Mock ERC4626 yield vault
// ─────────────────────────────────────────────────────────────────
contract MockYieldVaultH2 is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock Yield Vault H2", "mYVH2") {}
}

// ─────────────────────────────────────────────────────────────────
//  Harvest-aware mock strategy
//  harvest() simulates receiving external rewards by reinvesting
//  pre-funded crvUSD (simulates CRV -> crvUSD conversion profit).
//  The harvest reward amount is configured externally via setHarvestReward().
// ─────────────────────────────────────────────────────────────────
contract MockHarvestStrategy is IYieldStrategy {
    MockYieldVaultH2 public immutable yieldVault;
    IERC20 public immutable crvUSD;
    address public override vault;
    address public initializer;
    uint256 private _costBasis;

    // Amount of crvUSD to reinvest (simulate harvest reward) on next harvest() call
    uint256 public harvestRewardAmount;

    constructor(address _crvUSD, address _yieldVault) {
        crvUSD = IERC20(_crvUSD);
        initializer = msg.sender;
        yieldVault = MockYieldVaultH2(_yieldVault);
    }

    function initializeVault(address newVault) external {
        require(vault == address(0), "Initialized");
        require(newVault != address(0), "InvalidVault");
        require(msg.sender == initializer, "Unauthorized");
        vault = newVault;
        initializer = address(0);
    }

    /// @notice Configure the harvest reward that will be injected on next harvest() call
    function setHarvestReward(uint256 amount) external {
        harvestRewardAmount = amount;
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
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares == 0) return 0;
        _costBasis = 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        crvUSD.transfer(vault, received);
        return received;
    }

    /// @notice Simulates harvest: deposits the configured reward amount into
    ///         the yieldVault, increasing balanceOf() return.
    ///         In production this would be CRV -> crvUSD conversion profit reinvested.
    function harvest() external returns (uint256) {
        uint256 reward = harvestRewardAmount;
        harvestRewardAmount = 0; // consume once
        if (reward > 0) {
            // The reward crvUSD has been pre-funded to this contract by the test.
            // Deposit it into the yield vault to increase balanceOf().
            crvUSD.approve(address(yieldVault), reward);
            yieldVault.deposit(reward, address(this));
        }
        return reward;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
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

    function name() external pure returns (string memory) {
        return "Mock Harvest Strategy";
    }
}

// ─────────────────────────────────────────────────────────────────
//  Mock swapper (slightly overpays vs oracle to satisfy floors)
// ─────────────────────────────────────────────────────────────────
contract MockSwapperH2 is ISwapper {
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
            payout = (loanManager.getCollateralValue(collateralAmount) * 101) / 100;
        }
        debt.transfer(msg.sender, payout);
        return payout;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        uint256 payout = debtAmount;
        if (address(loanManager) != address(0)) {
            payout = (loanManager.getDebtValue(debtAmount) * 101) / 100;
        }
        collateral.transfer(msg.sender, payout);
        return payout;
    }
}

// ─────────────────────────────────────────────────────────────────
//  Verification test: H-2 regression guard — harvestYield() must
//  accrue fees on both organic profit and harvest reward
// ─────────────────────────────────────────────────────────────────
contract VerifyH2 is Test {
    address constant WBTC              = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD            = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant LLAMALEND_WBTC    = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL  = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant BTC_USD_ORACLE    = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant WBTC_WHALE        = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

    address owner  = makeAddr("owner");
    address user1  = makeAddr("user1");
    address caller = makeAddr("caller"); // permissionless harvestYield caller

    Zenji vault;
    ZenjiViewHelper viewHelper;
    MockHarvestStrategy mockStrategy;
    IERC20 wbtc;
    IERC20 crvUSD;
    uint256 lastBtcPrice;

    function mockOracle(uint256 price) internal {
        lastBtcPrice = price;
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracleH2.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            CRVUSD_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracleH2.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function warpAndMock(uint256 t) internal {
        vm.warp(t);
        vm.roll(block.number + 1);
        mockOracle(lastBtcPrice);
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        }

        (, , uint256 btcUpdate, ,) = IChainlinkOracleH2(BTC_USD_ORACLE).latestRoundData();
        (, int256 btcPrice, , ,)   = IChainlinkOracleH2(BTC_USD_ORACLE).latestRoundData();
        lastBtcPrice = uint256(btcPrice);
        if (btcUpdate + 1 > block.timestamp) vm.warp(btcUpdate + 1);
        mockOracle(lastBtcPrice);

        wbtc   = IERC20(WBTC);
        crvUSD = IERC20(CRVUSD);

        viewHelper = new ZenjiViewHelper();

        MockYieldVaultH2 yieldVault = new MockYieldVaultH2(CRVUSD);
        mockStrategy = new MockHarvestStrategy(CRVUSD, address(yieldVault));

        MockSwapperH2 swapper = new MockSwapperH2(WBTC, CRVUSD);
        deal(WBTC,   address(swapper), 1e50);
        deal(CRVUSD, address(swapper), 1e50);

        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0)
        );
        swapper.setLoanManager(address(loanManager));

        vault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(mockStrategy),
            address(swapper),
            owner,
            address(viewHelper)
        );

        mockStrategy.initializeVault(address(vault));
        loanManager.initializeVault(address(vault));

        vm.startPrank(WBTC_WHALE);
        wbtc.transfer(user1, 5e8);
        vm.stopPrank();

        vm.prank(user1);
        wbtc.approve(address(vault), type(uint256).max);

        // Set feeRate = 10%
        vm.prank(owner);
        vault.setParam(0, 1e17);
    }

    // ─────────────────────────────────────────────────────────────
    //  test_H2_harvestRewardFeeCharged
    //
    //  Scenario:
    //  1. User deposits; capital is deployed (strategy receives crvUSD).
    //  2. Strategy balance grows organically by P = 1000 crvUSD.
    //     _accrueYieldFees() charges feeRate * P when harvestYield() calls it.
    //  3. Harvest reward H = 500 crvUSD pre-funded to strategy, ready for reinvestment.
    //  4. harvestYield() is called by permissionless caller.
    //
    //  Expected (correct): fees = 10% * (P + H) = 150 crvUSD
    // ─────────────────────────────────────────────────────────────
    function test_H2_harvestRewardFeeCharged() public {
        // Step 1: deposit
        vm.prank(user1);
        vault.deposit(1e8, user1);
        warpAndMock(block.timestamp + 2);

        // Step 2: simulate organic yield growth P = 1000 crvUSD
        // by dealing extra crvUSD directly into the MockYieldVaultH2 (inflates share value)
        uint256 P = 1000e18;
        address yieldVaultAddr = address(mockStrategy.yieldVault());
        deal(CRVUSD, yieldVaultAddr, IERC20(CRVUSD).balanceOf(yieldVaultAddr) + P);

        uint256 stratBalBefore    = mockStrategy.balanceOf();
        uint256 lastStratBefore   = vault.lastStrategyBalance();
        uint256 accFeesBefore     = vault.accumulatedFees();

        console.log("--- Before harvestYield() ---");
        console.log("strategy.balanceOf():", stratBalBefore);
        console.log("lastStrategyBalance :", lastStratBefore);
        console.log("accumulatedFees     :", accFeesBefore);

        // Step 3: pre-fund harvest reward H = 500 crvUSD into the strategy contract
        uint256 H = 500e18;
        deal(CRVUSD, address(mockStrategy), H);
        mockStrategy.setHarvestReward(H);

        console.log("organic profit P    :", P);
        console.log("harvest reward H    :", H);

        // Step 4: permissionless caller triggers harvestYield()
        vm.prank(caller);
        vault.harvestYield();

        uint256 stratBalAfter  = mockStrategy.balanceOf();
        uint256 lastStratAfter = vault.lastStrategyBalance();
        uint256 accFeesAfter   = vault.accumulatedFees();

        console.log("--- After harvestYield() ---");
        console.log("strategy.balanceOf():", stratBalAfter);
        console.log("lastStrategyBalance :", lastStratAfter);
        console.log("accumulatedFees     :", accFeesAfter);

        uint256 PRECISION        = 1e18;
        uint256 feeRate          = vault.feeRate(); // 10%
        uint256 feesOnP          = (P * feeRate) / PRECISION; // 100 crvUSD
        uint256 feesOnH_expected = (H * feeRate) / PRECISION; // 50 crvUSD
        uint256 totalExpected    = feesOnP + feesOnH_expected; // 150 crvUSD
        uint256 actualAccrued    = accFeesAfter - accFeesBefore;

        console.log("--- Fee Analysis ---");
        console.log("feeRate                 :", feeRate);
        console.log("fees on P (expected)    :", feesOnP);
        console.log("fees on H (expected)    :", feesOnH_expected);
        console.log("total fees expected     :", totalExpected);
        console.log("actual fees accrued     :", actualAccrued);
        console.log("fees on harvest H expected:", feesOnH_expected);

        // Core assertion: actual fees include both P and H
        assertApproxEqAbs(actualAccrued, totalExpected, 1, "Fees should include organic profit and harvest reward");

        // Derived assertion: incremental fees from H are present
        assertTrue(actualAccrued > feesOnP, "Harvest reward should contribute to accrued fees");

        // Structural assertion: lastStrategyBalance advanced past H without fee collection
        assertEq(
            lastStratAfter,
            stratBalAfter,
            "lastStrategyBalance should equal post-harvest strategy balance"
        );

        // Checkpoint assertion: immediate second accrual should be zero
        uint256 feesBefore2 = vault.accumulatedFees();
        vault.accrueYieldFees();
        uint256 feesAfter2 = vault.accumulatedFees();
        assertEq(
            feesAfter2,
            feesBefore2,
            "Second accrual should be zero after balances are checkpointed"
        );

        console.log("CONFIRMED: harvest reward H is fee-charged");
        console.log("Protocol revenue captured from H:", feesOnH_expected);
    }

    // ─────────────────────────────────────────────────────────────
    //  Control test: normal accrual correctly charges fees on P.
    //  Proves the bug is specific to the harvestYield path.
    // ─────────────────────────────────────────────────────────────
    function test_H2_normalAccrualChargesCorrectly() public {
        vm.prank(user1);
        vault.deposit(1e8, user1);
        warpAndMock(block.timestamp + 2);

        uint256 P = 1000e18;
        address yieldVaultAddr = address(mockStrategy.yieldVault());
        deal(CRVUSD, yieldVaultAddr, IERC20(CRVUSD).balanceOf(yieldVaultAddr) + P);

        uint256 accFeesBefore = vault.accumulatedFees();
        vault.accrueYieldFees();
        uint256 actualAccrued = vault.accumulatedFees() - accFeesBefore;

        uint256 PRECISION    = 1e18;
        uint256 feeRate      = vault.feeRate();
        uint256 expectedFees = (P * feeRate) / PRECISION;

        console.log("Control: normal accrual expected fees:", expectedFees);
        console.log("Control: normal accrual actual fees  :", actualAccrued);

        // 1 wei rounding tolerance
        assertApproxEqAbs(
            actualAccrued,
            expectedFees,
            1,
            "Normal fee accrual should correctly charge feeRate * profit"
        );
    }
}
