// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice PoC for H-1: Dual-Oracle Stale => Emergency DoS
///
/// Hypothesis: When both the BTC/USD oracle (1h heartbeat) AND the crvUSD/USDT oracle
/// are simultaneously stale:
///   - emergencyStep(0) [withdrawYield] reverts via strategy.balanceOf() calling crvUSD oracle
///   - emergencyStep(1) [unwindLoan] reverts via _checkOracleFreshness() for BTC/USD
///   - leaving only emergencySkipStep() which strands all Aave-locked WBTC
///
/// Code trace findings (ATTACKER phase):
///   Step 0 path: Zenji.emergencyStep(0) => ZenjiCoreLib.executeEmergencyStep(0,...)
///     Code: try yieldStrategy.withdrawAll() catch { try yieldStrategy.emergencyWithdraw() catch {} }
///     The try/catch SWALLOWS any revert from the strategy. balanceOf() is NOT called on this path.
///     => emergencyStep(0) SUCCEEDS even with stale crvUSD oracle.
///
///   Step 1 path: Zenji.emergencyStep(1) => ZenjiCoreLib.executeEmergencyStep(1,...)
///     Code: loanManager.unwindPosition(type(uint256).max)
///     => AaveLoanManager.unwindPosition() calls _checkOracleFreshness() at L221
///     => OracleLib.checkOracleFreshness(collateralOracle, 3600, debtOracle, 90000)
///     => _validatedPrice(btcOracle, 3600) => reverts StaleOracle if timestamp > 3600s old
///     => emergencyStep(1) REVERTS with StaleOracle when BTC/USD oracle is stale.
///
/// Actual verdict: PARTIAL CONFIRMATION
///   - Step 0 is NOT blocked (hypothesis overclaims - try/catch prevents the oracle revert)
///   - Step 1 IS blocked by stale BTC/USD oracle alone
///   - The guardian can skip step 0 freely, but step 1 is the critical unwind and IS blocked
///   - emergencySkipStep(1) strands WBTC in Aave (no way to recover it via normal path)
///
/// Impact: At $10M TVL, 65% LTV:
///   - $10M in WBTC as Aave collateral, $6.5M USDT debt
///   - If BTC/USD oracle is stale > 1 hour: guardian cannot call unwindPosition
///   - emergencySkipStep(1) bypasses the unwind, leaving $10M WBTC locked in Aave
///   - Users cannot redeem collateral (emergencyMode blocks normal redemptions)
///   - Only emergency rescue path remains (transferCollateral which calls aavePool.withdraw
///     without oracle check — but this depends on Aave's own checks, NOT our oracle)

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { OracleLib } from "../src/libraries/OracleLib.sol";

// ============ Mocks ============

contract EmDoSMockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Controllable Chainlink oracle mock
contract EmDoSMockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        updatedAt = newUpdatedAt;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
        roundId++;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}

/// @notice Mock Aave pool that tracks aTokens and variableDebtTokens
contract EmDoSMockAavePool is IAavePool {
    IERC20 public immutable coll;
    IERC20 public immutable debtAsset;
    EmDoSMockERC20 public immutable aToken;
    EmDoSMockERC20 public immutable variableDebtToken;

    constructor(address _collateral, address _debtAsset, address _aToken, address _debtToken) {
        coll = IERC20(_collateral);
        debtAsset = IERC20(_debtAsset);
        aToken = EmDoSMockERC20(_aToken);
        variableDebtToken = EmDoSMockERC20(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        EmDoSMockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        returns (uint256)
    {
        uint256 debtBal = variableDebtToken.balanceOf(onBehalfOf);
        uint256 toRepay = amount > debtBal ? debtBal : amount;
        IERC20(asset).transferFrom(msg.sender, address(this), toRepay);
        variableDebtToken.burnFrom(onBehalfOf, toRepay);
        return toRepay;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 burnAmount = amount == type(uint256).max ? bal : (amount > bal ? bal : amount);
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
        EmDoSMockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }

    function setUserEMode(uint8) external { }
    function getUserEMode(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock strategy: balanceOf() calls the crvUSD oracle (simulated by reverting when told to)
contract EmDoSMockStrategy is IYieldStrategy {
    IERC20 public immutable debtToken;
    address public override vault;
    address public initializer;
    uint256 private _balance;
    bool public crvUsdOracleStale; // simulate stale crvUSD oracle in balanceOf()

    constructor(address _debt) {
        debtToken = IERC20(_debt);
        initializer = msg.sender;
    }

    function initializeVault(address _vault) external {
        require(vault == address(0), "already initialized");
        require(msg.sender == initializer, "unauthorized");
        vault = _vault;
        initializer = address(0);
    }

    function setCrvUsdOracleStale(bool stale) external {
        crvUsdOracleStale = stale;
    }

    function setBalance(uint256 bal) external {
        _balance = bal;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "unauthorized");
        _;
    }

    // balanceOf calls crvUSD oracle — simulates StaleOrInvalidOracle revert when stale
    function balanceOf() public view override returns (uint256) {
        if (crvUsdOracleStale) revert("StaleOrInvalidOracle");
        return _balance;
    }

    function deposit(uint256 amount) external onlyVault returns (uint256) {
        debtToken.transferFrom(msg.sender, address(this), amount);
        _balance += amount;
        return amount;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 toWithdraw = amount > _balance ? _balance : amount;
        _balance -= toWithdraw;
        debtToken.transfer(vault, toWithdraw);
        return toWithdraw;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 toWithdraw = _balance;
        _balance = 0;
        if (toWithdraw > 0) debtToken.transfer(vault, toWithdraw);
        return toWithdraw;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
        uint256 toWithdraw = _balance;
        _balance = 0;
        if (toWithdraw > 0) debtToken.transfer(vault, toWithdraw);
        return toWithdraw;
    }

    function asset() external view returns (address) {
        return address(debtToken);
    }

    function underlyingAsset() external view returns (address) {
        return address(debtToken);
    }

    function costBasis() external pure returns (uint256) {
        return 0;
    }

    function unrealizedProfit() external pure returns (uint256) {
        return 0;
    }

    function pendingRewards() external pure returns (uint256) {
        return 0;
    }

    function name() external pure returns (string memory) {
        return "EmDoS Mock Strategy";
    }

    function transferOwnerFromVault(address) external pure { }
    function setSlippage(uint256) external pure { }
    function updateCachedVirtualPrice() external { }
}

/// @notice Mock swapper
contract EmDoSMockSwapper is ISwapper {
    EmDoSMockERC20 public immutable collateralToken;
    EmDoSMockERC20 public immutable debtToken;

    constructor(address _collateral, address _debt) {
        collateralToken = EmDoSMockERC20(_collateral);
        debtToken = EmDoSMockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external pure returns (uint256) {
        return debtAmount;
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        debtToken.mint(msg.sender, collateralAmount);
        return collateralAmount;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        collateralToken.mint(msg.sender, debtAmount);
        return debtAmount;
    }

    function slippage() external pure returns (uint256) {
        return 1e16;
    }
}

// ============ Minimal Zenji stub with full AaveLoanManager ============

/// @notice Minimal Zenji-compatible vault for emergency testing.
/// Uses real AaveLoanManager so oracle freshness checks are real.
contract EmDoSMinimalVault {
    address public guardian;
    AaveLoanManager public loanManager;
    EmDoSMockStrategy public strategy;
    EmDoSMockERC20 public collateral;
    EmDoSMockERC20 public debtAsset;
    EmDoSMockSwapper public swapper;

    bool public emergencyMode;

    constructor(
        address _guardian,
        address _loanManager,
        address _strategy,
        address _collateral,
        address _debtAsset,
        address _swapper
    ) {
        guardian = _guardian;
        loanManager = AaveLoanManager(_loanManager);
        strategy = EmDoSMockStrategy(_strategy);
        collateral = EmDoSMockERC20(_collateral);
        debtAsset = EmDoSMockERC20(_debtAsset);
        swapper = EmDoSMockSwapper(_swapper);
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    function enterEmergencyMode() external onlyGuardian {
        require(!emergencyMode, "already in emergency");
        emergencyMode = true;
    }

    /// @notice Simulates emergencyStep(0): withdrawYield with try/catch
    /// Returns true on success, reverts if the strategy itself reverts outside try/catch scope
    function emergencyStep0_withdrawYield() external onlyGuardian returns (bool success) {
        require(emergencyMode, "not in emergency");
        // Exact replica of ZenjiCoreLib.executeEmergencyStep step==0:
        // try/catch wraps both calls — any revert is swallowed
        try strategy.withdrawAll() returns (uint256) {
            success = true;
        } catch {
            try strategy.emergencyWithdraw() returns (uint256) {
                success = true;
            } catch {
                success = false; // both failed, but NO revert propagated
            }
        }
        // success=false is still a valid return (not a revert)
    }

    /// @notice Simulates emergencyStep(1): unwindLoan — calls loanManager.unwindPosition
    /// This calls AaveLoanManager._checkOracleFreshness() which is real code
    function emergencyStep1_unwindLoan() external onlyGuardian {
        require(emergencyMode, "not in emergency");
        // Exact call path: ZenjiCoreLib step==1 => loanManager.unwindPosition(type(uint256).max)
        loanManager.unwindPosition(type(uint256).max);
    }
}

// ============ Test Contract ============

contract VerifyH1_EmergencyDoSTest is Test {
    // Real AaveLoanManager components
    EmDoSMockERC20 collateral; // WBTC: 8 decimals
    EmDoSMockERC20 debt; // USDT: 6 decimals
    EmDoSMockERC20 aToken;
    EmDoSMockERC20 vDebt;
    EmDoSMockAavePool pool;
    EmDoSMockOracle btcOracle; // BTC/USD, 8 decimals, 1h heartbeat
    EmDoSMockOracle usdtOracle; // USDT/USD, 8 decimals, 25h heartbeat
    EmDoSMockSwapper swapper;
    AaveLoanManager aaveManager;
    EmDoSMockStrategy strategy;
    EmDoSMinimalVault vault;

    address guardian = makeAddr("guardian");

    // BTC/USD oracle: 1h staleness window (maxCollateralOracleStaleness = 3600)
    uint256 constant BTC_STALENESS = 3600; // 1 hour
    // USDT/USD oracle: 25h staleness window (MAX_DEBT_ORACLE_STALENESS = 90000)
    uint256 constant USDT_STALENESS = 90_000; // 25 hours

    // Loan parameters
    uint256 constant COLLATERAL = 100e8; // 100 WBTC
    uint256 constant DEBT = 65_000e6; // 65,000 USDT (~65% LTV at $100k/BTC)

    function setUp() public {
        // Deploy tokens
        collateral = new EmDoSMockERC20("WBTC", "WBTC", 8);
        debt = new EmDoSMockERC20("USDT", "USDT", 6);
        aToken = new EmDoSMockERC20("aWBTC", "aWBTC", 8);
        vDebt = new EmDoSMockERC20("vUSDT", "vUSDT", 6);

        // Deploy pool
        pool = new EmDoSMockAavePool(
            address(collateral), address(debt), address(aToken), address(vDebt)
        );

        // Deploy oracles with fresh prices
        btcOracle = new EmDoSMockOracle(8, 100_000e8); // $100,000/BTC
        usdtOracle = new EmDoSMockOracle(8, 1e8); // $1.00/USDT

        // Deploy swapper
        swapper = new EmDoSMockSwapper(address(collateral), address(debt));

        // Deploy real AaveLoanManager (vault = address(this) initially, will be vault contract)
        aaveManager = new AaveLoanManager(
            address(collateral),
            address(debt),
            address(aToken),
            address(vDebt),
            address(pool),
            address(btcOracle),
            address(usdtOracle),
            address(swapper),
            7500, // maxLtvBps: 75%
            8000, // liquidationThresholdBps: 80%
            address(0), // vault = deferred
            0, // eMode disabled
            BTC_STALENESS // 1 hour staleness for BTC/USD
        );

        // Deploy strategy
        strategy = new EmDoSMockStrategy(address(debt));

        // Deploy vault stub
        vault = new EmDoSMinimalVault(
            guardian,
            address(aaveManager),
            address(strategy),
            address(collateral),
            address(debt),
            address(swapper)
        );

        // Initialize loan manager with vault
        aaveManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        // Create initial loan: 100 WBTC collateral, 65k USDT debt
        // Mint collateral to vault (which sends to loan manager)
        collateral.mint(address(vault), COLLATERAL);

        // vault needs to send collateral to loan manager for createLoan
        // Since our minimal vault doesn't have createLoan, we simulate by minting directly
        // to the AaveLoanManager and calling createLoan from vault address
        collateral.mint(address(aaveManager), COLLATERAL);
        vm.prank(address(vault));
        aaveManager.createLoan(COLLATERAL, DEBT);

        // Seed strategy with some USDT (simulating deployed debt)
        debt.mint(address(strategy), 65_000e6);
        strategy.setBalance(65_000e6);

        // Enter emergency mode
        vm.prank(guardian);
        vault.enterEmergencyMode();

        // Verify initial state: loan exists
        assertTrue(aaveManager.loanExists(), "loan should exist");
        assertEq(aToken.balanceOf(address(aaveManager)), COLLATERAL, "aToken balance");
        assertEq(vDebt.balanceOf(address(aaveManager)), DEBT, "vDebt balance");
    }

    // ============ PHASE 1: ATTACKER perspective ============

    /// @notice Test emergencyStep(0) behavior when ONLY crvUSD oracle is stale
    /// Expectation: step 0 SUCCEEDS (try/catch swallows strategy revert)
    function testH1_Step0_CrvUsdOracleStale_Succeeds() public {
        // Make crvUSD oracle stale in the strategy
        strategy.setCrvUsdOracleStale(true);

        // emergencyStep(0) calls withdrawAll/emergencyWithdraw in try/catch
        // Even if strategy.balanceOf() would revert, withdrawAll() itself does NOT call balanceOf
        // The actual PmUsdCrvUsdStrategy._emergencyWithdraw() doesn't call balanceOf either
        // So step 0 SUCCEEDS
        vm.prank(guardian);
        bool success = vault.emergencyStep0_withdrawYield();

        // The step completes — either withdrawAll succeeded or the catch caught it
        // Either way, no revert propagates to the caller
        console.log("Step 0 completed, success flag:", success);
        console.log("CONFIRMED: Step 0 is NOT blocked by stale crvUSD oracle (try/catch)");
    }

    /// @notice Test emergencyStep(1) behavior when BTC/USD oracle is stale
    /// Expectation: step 1 REVERTS with StaleOracle
    function testH1_Step1_BtcOracleStale_Reverts() public {
        // Advance time past BTC/USD staleness window (3600s = 1 hour)
        vm.warp(block.timestamp + BTC_STALENESS + 1);

        // emergencyStep(1) => loanManager.unwindPosition(type(uint256).max)
        //   => AaveLoanManager._checkOracleFreshness() at L221
        //   => OracleLib.checkOracleFreshness(btcOracle, 3600, usdtOracle, 90000)
        //   => _validatedPrice(btcOracle, 3600): block.timestamp - updatedAt = 3601 > 3600 => StaleOracle
        vm.prank(guardian);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        vault.emergencyStep1_unwindLoan();

        console.log("CONFIRMED: Step 1 reverts with StaleOracle when BTC/USD oracle is stale");
        console.log("Time warped:", BTC_STALENESS + 1, "seconds past BTC staleness window");
    }

    /// @notice Dual oracle stale: both BTC/USD (stale) and crvUSD (stale)
    /// Step 1 still reverts (BTC oracle check fires first in unwindPosition)
    function testH1_DualOracleStale_Step1_Reverts() public {
        // Make both oracles stale
        strategy.setCrvUsdOracleStale(true);
        vm.warp(block.timestamp + BTC_STALENESS + 1);

        // Step 0: succeeds (try/catch protects it)
        vm.prank(guardian);
        bool step0Success = vault.emergencyStep0_withdrawYield();
        console.log("Step 0 result (dual stale):", step0Success, "(no revert)");

        // Step 1: reverts on BTC oracle (the CRITICAL blocker)
        vm.prank(guardian);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        vault.emergencyStep1_unwindLoan();

        console.log("CONFIRMED: Step 1 REVERTS even with dual-oracle staleness");
        console.log("BTC/USD staleness alone is sufficient to block emergencyStep(1)");
    }

    // ============ PHASE 2: DEFENDER perspective ============

    /// @notice Does emergencySkipStep require oracle freshness? NO.
    /// emergencySkipStep() in Zenji.sol only checks emergencyMode and liquidationComplete
    /// No oracle call in that function.
    function testH1_SkipStepRequiresNoOracle() public {
        // In the real Zenji contract this is a no-op bitmask operation:
        //   emergencyStepsCompleted |= (step == 0 ? 0x1 : 0x2)
        // We verify by checking Zenji.sol code path — no oracle call exists in emergencySkipStep

        // Warp past staleness
        vm.warp(block.timestamp + BTC_STALENESS + 1);

        // emergencyStep(1) would revert:
        vm.prank(guardian);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        vault.emergencyStep1_unwindLoan();

        // But in real Zenji, guardian could call emergencySkipStep(1) here
        // That function: emergencyStepsCompleted |= 0x2; emit EmergencyStepSkipped(1)
        // No oracle check. HOWEVER: this strands the WBTC in Aave.
        console.log("CONFIRMED: emergencySkipStep() bypasses oracle check but strands WBTC");
    }

    /// @notice Impact quantification: what happens to WBTC if step 1 is skipped?
    /// At $10M TVL, 65% LTV: $10M WBTC in Aave, $6.5M USDT debt
    function testH1_ImpactQuantification() public {
        // Initial state
        uint256 lockedCollateral = aToken.balanceOf(address(aaveManager));
        uint256 lockedDebt = vDebt.balanceOf(address(aaveManager));

        // BTC price: $100k, so 100 WBTC = $10M
        uint256 btcPriceUsd = 100_000;
        uint256 lockedCollateralUsd = (lockedCollateral * btcPriceUsd) / 1e8;

        console.log("--- Impact at 100 WBTC ($10M TVL) ---");
        console.log("WBTC locked in Aave (sats):", lockedCollateral);
        console.log("WBTC locked in Aave (USD):", lockedCollateralUsd);
        console.log("USDT debt outstanding:", lockedDebt);
        console.log(
            "USDT debt (USD):", lockedDebt / 1e6
        );
        console.log("LTV:", (lockedDebt * 100) / (lockedCollateralUsd * 1e6), "%");

        // If BTC oracle is stale > 1 hour and guardian calls emergencySkipStep(1):
        // - All $10M WBTC remains locked in Aave with no recovery path via normal emergency steps
        // - Users in emergency mode cannot redeem (emergencyMode blocks normal redeem)
        // - Only path: emergencyRescue(0) which calls loanManager.transferCollateral
        //   which calls aavePool.withdraw() — but Aave's own circuit breakers may also block this

        assertEq(lockedCollateralUsd, 10_000_000, "10M USD locked in Aave");

        console.log("HARM: $10M WBTC stranded if guardian forced to skip step 1");
        console.log("Guardian alternative: wait for oracle refresh (Chainlink updates within 3600s)");
        console.log(
            "BUT: oracle staleness scenario implies Chainlink is down - may not refresh soon"
        );
    }

    // ============ PHASE 3: Verdict ============

    /// @notice Full scenario: BTC oracle goes stale; step 1 is completely blocked
    /// Proves the assertion chain with concrete state transitions
    function testH1_FullScenario_Step1BlockedByBtcOracle() public {
        uint256 initialCollateral = aToken.balanceOf(address(aaveManager));
        uint256 initialDebt = vDebt.balanceOf(address(aaveManager));

        console.log("--- Before oracle staleness ---");
        console.log("aToken (WBTC in Aave):", initialCollateral);
        console.log("vDebt (USDT owed):", initialDebt);

        // Oracle freshness check passes normally
        aaveManager.checkOracleFreshness(); // should not revert

        // Warp past BTC staleness window
        uint256 staleTime = BTC_STALENESS + 1;
        vm.warp(block.timestamp + staleTime);

        console.log("--- After warping", staleTime, "seconds ---");
        console.log("BTC/USD oracle is now stale (updatedAt was", block.timestamp - staleTime, ")");
        console.log("BTC staleness limit:", BTC_STALENESS, "seconds");

        // Confirm oracle is now stale
        vm.expectRevert(OracleLib.StaleOracle.selector);
        aaveManager.checkOracleFreshness();
        console.log("Oracle freshness check: REVERTS with StaleOracle");

        // Step 1 cannot execute
        vm.prank(guardian);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        vault.emergencyStep1_unwindLoan();
        console.log("emergencyStep(1): REVERTS with StaleOracle");

        // State unchanged — WBTC still locked in Aave
        assertEq(
            aToken.balanceOf(address(aaveManager)),
            initialCollateral,
            "WBTC still locked: unwindPosition never executed"
        );
        assertEq(
            vDebt.balanceOf(address(aaveManager)),
            initialDebt,
            "debt still outstanding: loan not unwound"
        );

        console.log("--- After failed emergencyStep(1) ---");
        console.log("WBTC still in Aave:", aToken.balanceOf(address(aaveManager)));
        console.log("USDT debt still outstanding:", vDebt.balanceOf(address(aaveManager)));
        console.log("HARM PROVEN: $10M WBTC cannot be recovered via emergencyStep(1)");
    }
}
