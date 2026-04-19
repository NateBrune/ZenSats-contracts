// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title VerifyH7_CrvOracleDoS
 *
 * BUG: When the CRV/USD Chainlink oracle becomes stale (>90000s since last update),
 *      deposits and PARTIAL withdrawals from the pmUSD/crvUSD strategy revert.
 *      This happens because _deposit()/_withdraw() unconditionally call _claimAndCompound(),
 *      which calls _swapCrv() when CRV balance >= MIN_HARVEST_THRESHOLD (0.1 CRV), which
 *      calls crvSwapper.swap(), which calls OracleLib._validatedPrice() that reverts
 *      StaleOracle(). The catch block in _swapCrv() re-reverts as SwapFailed().
 *
 * EXPECTED: Stale CRV oracle should not block user deposit/withdraw flows.
 * ACTUAL:   Stale CRV oracle blocks deposits AND partial withdrawals when CRV has accumulated.
 *
 * SCOPE REFINEMENT (discovered during verification):
 *   - FULL withdrawals (when redeeming 100% of total supply) call _withdrawAll() which
 *     bypasses _claimAndCompound() — so full exits are unblocked.
 *   - PARTIAL withdrawals call _withdraw() → _claimAndCompound() → blocked.
 *   - ALL deposits call _deposit() → _claimAndCompound() → blocked.
 *   - This means new depositors are always blocked, and existing depositors can only
 *     exit if they are the LAST depositor (which requires all others to exit first,
 *     but those others face the partial-withdrawal DoS).
 *
 * KEY QUESTION (defender): Is there a try/catch in _swapCrv that silences the revert?
 * ANSWER: No. _swapCrv() has:
 *   try crvSwapper.swap(amount) returns (uint256 received) {
 *       crvUsdReceived = received;
 *   } catch {
 *       revert SwapFailed();   <-- re-raises, does NOT silence
 *   }
 *
 * CONDITION GATE: The DoS is conditional on crvBalance >= MIN_HARVEST_THRESHOLD (0.1 CRV).
 * If CRV balance is zero, deposits/withdrawals proceed normally despite stale oracle.
 */

import { Test } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { PmUsdCrvUsdStrategy } from "../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IAavePool } from "../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock Contracts ============

contract H7MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burnFrom(address from, uint256 amount) external { _burn(from, amount); }
}

/// @notice Oracle with controllable freshness.
contract H7MockOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 dec_, int256 price_) {
        decimals = dec_;
        price = price_;
        updatedAt = block.timestamp;
    }

    /// @notice Force stale: sets updatedAt to block.timestamp - MAX_ORACLE_STALENESS - 1.
    ///         Requires block.timestamp to be large enough (setUp warps to 1_700_000_000).
    function makeStaleNow() external {
        updatedAt = block.timestamp - 90001;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, block.timestamp, updatedAt, roundId);
    }
}

contract H7MockCurveStableSwap {
    H7MockERC20 public immutable usdt;
    H7MockERC20 public immutable crvUSD;
    int128 public immutable usdtIdx;
    int128 public immutable crvUsdIdx;

    constructor(address _usdt, address _crvUSD, int128 _usdtIdx, int128 _crvUsdIdx) {
        usdt = H7MockERC20(_usdt);
        crvUSD = H7MockERC20(_crvUSD);
        usdtIdx = _usdtIdx;
        crvUsdIdx = _crvUsdIdx;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        if (i == usdtIdx && j == crvUsdIdx) {
            usdt.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx * 1e12;
            crvUSD.mint(msg.sender, out);
            return out;
        }
        if (i == crvUsdIdx && j == usdtIdx) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            uint256 out = dx / 1e12;
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

    function balances(uint256) external pure returns (uint256) { return 0; }
    function get_virtual_price() external pure returns (uint256) { return 1e18; }
}

contract H7MockCurveStableSwapNG {
    H7MockERC20 public immutable crvUSD;
    H7MockERC20 public pmUSD;
    H7MockERC20 public lpToken;
    int128 public immutable crvUsdIdx;
    uint256 public pmUsdIdx;

    constructor(address _crvUSD, int128 _crvUsdIdx) {
        crvUSD = H7MockERC20(_crvUSD);
        crvUsdIdx = _crvUsdIdx;
        pmUsdIdx = _crvUsdIdx == int128(0) ? 1 : 0;
    }

    function setLpToken(address _lp) external { lpToken = H7MockERC20(_lp); }
    function setPmUsd(address _pm) external { pmUSD = H7MockERC20(_pm); }

    function add_liquidity(uint256[] calldata amounts, uint256) external returns (uint256) {
        uint256 c = amounts[uint256(uint128(crvUsdIdx))];
        uint256 p = amounts[pmUsdIdx];
        if (c > 0) crvUSD.transferFrom(msg.sender, address(this), c);
        if (p > 0 && address(pmUSD) != address(0)) pmUSD.transferFrom(msg.sender, address(this), p);
        uint256 total = c + p;
        if (total > 0) lpToken.mint(msg.sender, total);
        return total;
    }

    function remove_liquidity_one_coin(uint256 burn, int128, uint256) external returns (uint256) {
        lpToken.transferFrom(msg.sender, address(this), burn);
        crvUSD.mint(msg.sender, burn);
        return burn;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        return amounts[uint256(uint128(crvUsdIdx))] + amounts[pmUsdIdx];
    }

    function calc_withdraw_one_coin(uint256 burn, int128) external pure returns (uint256) {
        return burn;
    }

    function get_virtual_price() external pure returns (uint256) { return 1e18; }
    function coins(uint256) external pure returns (address) { return address(0); }
    function balances(uint256) external pure returns (uint256) { return 0; }
    function exchange(int128, int128, uint256, uint256) external pure returns (uint256) { return 0; }
    function get_dy(int128, int128, uint256) external pure returns (uint256) { return 0; }
}

contract H7MockAccountant {
    H7MockERC20 public rewardToken;
    mapping(address => uint256) public rewards;

    constructor(address _rt) { rewardToken = H7MockERC20(_rt); }

    function setRewards(address account, uint256 amount) external { rewards[account] = amount; }
    function getPendingRewards(address, address account) external view returns (uint256) {
        return rewards[account];
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        uint256 p = rewards[receiver];
        if (p > 0) {
            rewards[receiver] = 0;
            rewardToken.mint(receiver, p);
        }
    }
}

contract H7MockRewardVault is ERC4626 {
    H7MockERC20 public rewardToken;
    address public immutable _accountant;
    mapping(address => uint256) public pendingRewards;

    constructor(address _lp, address _rt, address acct_)
        ERC4626(OZ_IERC20(_lp))
        ERC20("Mock Reward Vault", "mRV")
    {
        rewardToken = H7MockERC20(_rt);
        _accountant = acct_;
    }

    function ACCOUNTANT() external view returns (address) { return _accountant; }

    function addRewards(address account, uint256 amount) external {
        pendingRewards[account] += amount;
        H7MockAccountant(_accountant).setRewards(account, pendingRewards[account]);
    }

    function earned(address account, address) external view returns (uint256) {
        return pendingRewards[account];
    }

    function rewardTokens(uint256) external view returns (address) { return address(rewardToken); }
    function rewardTokensLength() external pure returns (uint256) { return 1; }
}

/**
 * @notice Realistic CRV swapper that reproduces the oracle floor check from CrvToCrvUsdSwapper.
 *         The real swap() calls OracleLib.getCollateralValue() which calls _validatedPrice()
 *         for both CRV and crvUSD oracles, reverting StaleOracle() if either is stale.
 */
contract H7RealisticCrvSwapper {
    H7MockERC20 public immutable crv;
    H7MockERC20 public immutable crvUSD;
    H7MockOracle public immutable crvOracle;
    H7MockOracle public immutable crvUsdOracle;

    uint256 public constant MAX_STALENESS = 90000;

    error StaleOracle();
    error InvalidPrice();

    constructor(address _crv, address _crvUSD, address _crvOracle, address _crvUsdOracle) {
        crv = H7MockERC20(_crv);
        crvUSD = H7MockERC20(_crvUSD);
        crvOracle = H7MockOracle(_crvOracle);
        crvUsdOracle = H7MockOracle(_crvUsdOracle);
    }

    function _validatedPrice(H7MockOracle oracle) internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StaleOracle();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StaleOracle();
        return uint256(price);
    }

    function swap(uint256 crvAmount) external returns (uint256) {
        if (crvAmount == 0) return 0;
        _validatedPrice(crvOracle);
        _validatedPrice(crvUsdOracle);
        crvUSD.mint(msg.sender, crvAmount);
        return crvAmount;
    }

    function quote(uint256 crvAmount) external pure returns (uint256) { return crvAmount; }
}

contract H7MockSwapper {
    H7MockERC20 public immutable collateral;
    H7MockERC20 public immutable debt;

    constructor(address _col, address _debt) {
        collateral = H7MockERC20(_col);
        debt = H7MockERC20(_debt);
    }

    function quoteCollateralForDebt(uint256 d) external pure returns (uint256) { return d; }
    function swapCollateralForDebt(uint256 c) external returns (uint256) {
        debt.mint(msg.sender, c);
        return c;
    }
    function swapDebtForCollateral(uint256 d) external returns (uint256) {
        collateral.mint(msg.sender, d);
        return d;
    }
    function setSlippage(uint256) external {}
}

contract H7MockAavePool is IAavePool {
    IERC20 public immutable collateral;
    IERC20 public immutable debtAsset;
    H7MockERC20 public immutable aToken;
    H7MockERC20 public immutable variableDebtToken;

    constructor(address _col, address _debt, address _aToken, address _debtToken) {
        collateral = IERC20(_col);
        debtAsset = IERC20(_debt);
        aToken = H7MockERC20(_aToken);
        variableDebtToken = H7MockERC20(_debtToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        H7MockERC20(asset).mint(onBehalfOf, amount);
        variableDebtToken.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external returns (uint256)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        variableDebtToken.burnFrom(onBehalfOf, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 burn = amount > bal ? bal : amount;
        aToken.burnFrom(msg.sender, burn);
        IERC20(asset).transfer(to, burn);
        return burn;
    }

    function flashLoanSimple(
        address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16
    ) external {
        H7MockERC20(asset).mint(receiverAddress, amount);
        IFlashLoanSimpleReceiver(receiverAddress)
            .executeOperation(asset, amount, 0, receiverAddress, params);
        IERC20(asset).transferFrom(receiverAddress, address(this), amount);
    }

    function setUserEMode(uint8) external {}
    function getUserEMode(address) external pure returns (uint256) { return 0; }
}

// ============ Test Contract ============

contract VerifyH7_CrvOracleDoS is Test {
    H7MockERC20 wbtc;
    H7MockERC20 usdt;
    H7MockERC20 crvUSD;
    H7MockERC20 crv;
    H7MockERC20 pmUsd;
    H7MockERC20 lpToken;
    H7MockERC20 aToken;
    H7MockERC20 debtToken;

    H7MockOracle collateralOracle;
    H7MockOracle debtOracle;
    H7MockOracle crvUsdOracle;
    H7MockOracle usdtOracle;
    H7MockOracle crvOracle;

    H7MockCurveStableSwap usdtCrvUsdPool;
    H7MockCurveStableSwapNG lpPool;
    H7MockAccountant accountant;
    H7MockRewardVault rewardVault;
    H7RealisticCrvSwapper crvSwapper;
    H7MockAavePool aavePool;

    AaveLoanManager loanManager;
    PmUsdCrvUsdStrategy strategy;
    Zenji vault;
    ZenjiViewHelper viewHelper;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address gauge = makeAddr("pmusdGauge");

    function setUp() public {
        // Start at a realistic timestamp so staleness math never underflows
        vm.warp(1_700_000_000);

        wbtc  = new H7MockERC20("WBTC",  "WBTC",  8);
        usdt  = new H7MockERC20("USDT",  "USDT",  6);
        crvUSD = new H7MockERC20("crvUSD","crvUSD",18);
        crv   = new H7MockERC20("CRV",   "CRV",  18);
        pmUsd = new H7MockERC20("pmUSD", "pmUSD",18);
        lpToken = new H7MockERC20("LP",  "LP",   18);
        aToken  = new H7MockERC20("aWBTC","aWBTC",8);
        debtToken = new H7MockERC20("vUSDT","vUSDT",6);

        collateralOracle = new H7MockOracle(8, 1e8);
        debtOracle       = new H7MockOracle(8, 1e8);
        crvUsdOracle     = new H7MockOracle(8, 1e8);
        usdtOracle       = new H7MockOracle(8, 1e8);
        crvOracle        = new H7MockOracle(8, 50000000);

        aavePool = new H7MockAavePool(
            address(wbtc), address(usdt), address(aToken), address(debtToken)
        );
        wbtc.mint(address(aavePool), 100e8);

        usdtCrvUsdPool = new H7MockCurveStableSwap(address(usdt), address(crvUSD), 0, 1);
        lpPool = new H7MockCurveStableSwapNG(address(crvUSD), 1);
        lpPool.setLpToken(address(lpToken));
        lpPool.setPmUsd(address(pmUsd));

        accountant  = new H7MockAccountant(address(crv));
        rewardVault = new H7MockRewardVault(address(lpToken), address(crv), address(accountant));

        crvSwapper = new H7RealisticCrvSwapper(
            address(crv), address(crvUSD), address(crvOracle), address(crvUsdOracle)
        );

        viewHelper = new ZenjiViewHelper();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);

        H7MockSwapper swapper = new H7MockSwapper(address(wbtc), address(usdt));

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
            0,
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
            0, 1, 1,
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

        wbtc.mint(user, 10e8);
        vm.prank(user);
        wbtc.approve(address(vault), type(uint256).max);

        wbtc.mint(user2, 10e8);
        vm.prank(user2);
        wbtc.approve(address(vault), type(uint256).max);
    }

    // ============ PROOF 1: Deposit blocked when CRV accumulated + oracle stale ============
    /**
     * HARM ASSERTION: user's deposit call reverts; user cannot deploy capital.
     *
     * CALL CHAIN:
     * vault.deposit() → strategy._deposit() → _claimAndCompound()
     * → _accountantClaim() mints 1 CRV to strategy
     * → crvBalance (1e18) >= MIN_HARVEST_THRESHOLD (1e17) → TRUE
     * → _swapCrv(1e18) → try crvSwapper.swap(1e18)
     * → _validatedPrice(stale crvOracle): block.timestamp - updatedAt > 90000 → StaleOracle()
     * → catch { revert SwapFailed() }
     */
    function test_H7_deposit_blocked_by_stale_crv_oracle_with_accumulated_crv() public {
        // STEP 1: Initial deposit — oracle fresh, no CRV yet, succeeds
        vm.prank(user);
        vault.deposit(1e8, user);
        assertGt(vault.balanceOf(user), 0, "Initial deposit must succeed");

        // STEP 2: CRV rewards accumulate (1 CRV > MIN_HARVEST_THRESHOLD of 0.1 CRV)
        rewardVault.addRewards(address(strategy), 1e18);

        // STEP 3: CRV oracle goes stale
        crvOracle.makeStaleNow();

        // STEP 4: PROVE — new deposit reverts with SwapFailed
        address newDepositor = makeAddr("newDepositor");
        wbtc.mint(newDepositor, 10e8);
        vm.prank(newDepositor);
        wbtc.approve(address(vault), type(uint256).max);

        vm.expectRevert(PmUsdCrvUsdStrategy.SwapFailed.selector);
        vm.prank(newDepositor);
        vault.deposit(1e8, newDepositor);
    }

    // ============ PROOF 2: Partial withdrawal blocked — funds partially locked ============
    /**
     * HARM ASSERTION: depositor cannot partially exit while other depositors remain.
     * With 2 depositors, user1's redemption is a PARTIAL withdrawal (< total supply),
     * triggering _withdraw() → _claimAndCompound() → stale oracle → SwapFailed().
     *
     * Note: Full withdrawal (redeeming 100% of supply when only 1 depositor) uses
     * _withdrawAll() which bypasses the oracle check — a design asymmetry.
     * The DoS specifically locks depositors who cannot be the last to exit.
     */
    function test_H7_partial_withdrawal_blocked_stale_crv_oracle() public {
        // Both users deposit to ensure partial (non-final) withdrawal path
        vm.prank(user);
        vault.deposit(1e8, user);
        vm.roll(block.number + 1); // advance past COOLDOWN_BLOCKS for user

        vm.prank(user2);
        vault.deposit(1e8, user2);

        uint256 sharesUser1 = vault.balanceOf(user);
        uint256 totalShares = vault.totalSupply();
        assertLt(sharesUser1, totalShares, "User1 should hold partial shares");
        vm.roll(block.number + 1); // advance past COOLDOWN_BLOCKS for user2

        // CRV rewards accumulate, oracle goes stale
        rewardVault.addRewards(address(strategy), 1e18);
        crvOracle.makeStaleNow();

        // PROVE: user1 PARTIAL redemption reverts (isFinalWithdraw=false → _withdraw() path)
        vm.expectRevert(PmUsdCrvUsdStrategy.SwapFailed.selector);
        vm.prank(user);
        vault.redeem(sharesUser1, user, user);
    }

    // ============ PROOF 3: Control — zero CRV, stale oracle, NO DoS ============
    /**
     * Validates the conditional: DoS ONLY triggers when crvBalance >= MIN_HARVEST_THRESHOLD.
     * Without accumulated CRV, stale oracle has zero effect on deposits.
     */
    function test_H7_control_stale_oracle_no_effect_when_crv_zero() public {
        vm.prank(user);
        vault.deposit(1e8, user);

        // Stale oracle but NO CRV rewards
        crvOracle.makeStaleNow();

        // New deposit: _claimAndCompound sees crvBalance=0, skips swap — no revert
        address newDepositor = makeAddr("controlDepositor");
        wbtc.mint(newDepositor, 10e8);
        vm.prank(newDepositor);
        wbtc.approve(address(vault), type(uint256).max);

        vm.prank(newDepositor);
        vault.deposit(1e8, newDepositor);

        assertGt(vault.balanceOf(newDepositor), 0, "Deposit must succeed when CRV balance is zero");
    }

    // ============ PROOF 4: _withdrawAll() bypasses CRV oracle DoS ============
    /**
     * Full (final) withdrawal takes _withdrawAll() path, bypassing _claimAndCompound().
     * Only users who are the last depositor (or emergency mode) can exit during oracle downtime.
     * Combined with PROOF 2, this creates a coordination game: nobody can do a partial
     * exit because partial → _withdraw() → blocked; full exit works but requires being last.
     */
    function test_H7_full_withdrawal_bypasses_crv_oracle_via_withdrawAll() public {
        // Single depositor — their redeem will be a full (final) withdrawal
        vm.prank(user);
        vault.deposit(1e8, user);

        vm.roll(block.number + 1);

        rewardVault.addRewards(address(strategy), 1e18);
        crvOracle.makeStaleNow();

        uint256 shares = vault.balanceOf(user);
        assertTrue(shares == vault.totalSupply(), "User holds 100% of shares");

        // Full withdrawal (isFinalWithdraw=true) → _withdrawAll() → no _claimAndCompound
        // This should NOT revert — confirming _withdrawAll() bypasses the DoS
        vm.prank(user);
        vault.redeem(shares, user, user); // Must NOT revert

        assertEq(vault.totalSupply(), 0, "All shares burned - full exit succeeded");
    }
}
