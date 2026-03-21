// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { PmUsdCrvUsdStrategy } from "../../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IAavePool } from "../../src/interfaces/IAavePool.sol";
import { IFlashLoanSimpleReceiver } from "../../src/interfaces/IFlashLoanSimpleReceiver.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Minimal mocks for H4 test ============

contract MockERC20H4 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory sym_, uint8 dec_) ERC20(name_, sym_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burnFrom(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockOracleH4 {
    int256 public price;
    uint256 public updatedAt;

    constructor(int256 price_) { price = price_; updatedAt = block.timestamp; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

/// @notice Configurable virtual price -- key for H4
contract MockLpPoolH4 {
    MockERC20H4 public crvUSD;
    MockERC20H4 public pmUSD;
    MockERC20H4 public lpToken;
    int128 public immutable crvUsdIdx;
    uint256 public immutable pmUsdIdx;
    uint256 public virtualPrice; // mutable -- set by test

    constructor(address _crvUSD, address _pmUSD, address _lpToken, int128 _crvUsdIdx) {
        crvUSD = MockERC20H4(_crvUSD);
        pmUSD = MockERC20H4(_pmUSD);
        lpToken = MockERC20H4(_lpToken);
        crvUsdIdx = _crvUsdIdx;
        pmUsdIdx = _crvUsdIdx == int128(0) ? 1 : 0;
        virtualPrice = 1e18;
    }

    function setVirtualPrice(uint256 vp) external { virtualPrice = vp; }
    function get_virtual_price() external view returns (uint256) { return virtualPrice; }

    function add_liquidity(uint256[] calldata amounts, uint256) external returns (uint256) {
        uint256 c = amounts[uint256(uint128(crvUsdIdx))];
        uint256 p = amounts[pmUsdIdx];
        if (c > 0) crvUSD.transferFrom(msg.sender, address(this), c);
        if (p > 0) pmUSD.transferFrom(msg.sender, address(this), p);
        uint256 minted = c + p;
        if (minted > 0) lpToken.mint(msg.sender, minted);
        return minted;
    }

    function remove_liquidity_one_coin(uint256 burn_amount, int128, uint256)
        external returns (uint256)
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

    function coins(uint256) external pure returns (address) { return address(0); }
    function balances(uint256) external pure returns (uint256) { return 0; }
    function exchange(int128, int128, uint256, uint256) external pure returns (uint256) { return 0; }
    function get_dy(int128, int128, uint256) external pure returns (uint256) { return 0; }
}

contract MockUsdtCrvUsdPoolH4 {
    MockERC20H4 public usdt;
    MockERC20H4 public crvUSD;

    constructor(address _usdt, address _crvUSD) {
        usdt = MockERC20H4(_usdt);
        crvUSD = MockERC20H4(_crvUSD);
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        if (i == 0 && j == 1) { usdt.transferFrom(msg.sender, address(this), dx); uint256 out = dx * 1e12; crvUSD.mint(msg.sender, out); return out; }
        if (i == 1 && j == 0) { crvUSD.transferFrom(msg.sender, address(this), dx); uint256 out = dx / 1e12; usdt.mint(msg.sender, out); return out; }
        return 0;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external pure returns (uint256) {
        if (i == 0 && j == 1) return dx * 1e12;
        if (i == 1 && j == 0) return dx / 1e12;
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        if (i == 0) return address(usdt);
        if (i == 1) return address(crvUSD);
        return address(0);
    }

    function balances(uint256) external pure returns (uint256) { return 0; }
    function get_virtual_price() external pure returns (uint256) { return 1e18; }
}

contract MockAccountantH4 {
    function getPendingRewards(address, address) external pure returns (uint256) { return 0; }
    function claim(address[] calldata, bytes[] calldata, address) external { }
}

contract MockRewardVaultH4 is ERC4626 {
    address public immutable _accountant;

    constructor(address _lpToken, address accountant_)
        ERC4626(OZ_IERC20(_lpToken))
        ERC20("Mock Reward Vault H4", "mRVH4")
    {
        _accountant = accountant_;
    }

    function ACCOUNTANT() external view returns (address) { return _accountant; }
    function claim() external returns (uint256[] memory) { return new uint256[](0); }
}

contract MockCrvSwapperH4 {
    function swap(uint256) external pure returns (uint256) { return 0; }
    function quote(uint256) external pure returns (uint256) { return 0; }
}

// ============ H4 Verification Test ============

contract H4_VirtualPriceLagTest is Test {
    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_VP_DEVIATION = 5e15; // 0.5%

    MockERC20H4 usdt;
    MockERC20H4 crvUSD;
    MockERC20H4 crv;
    MockERC20H4 pmUSD;
    MockERC20H4 lpToken;

    MockOracleH4 crvUsdOracle;
    MockOracleH4 usdtOracle;
    MockOracleH4 crvOracle;

    MockUsdtCrvUsdPoolH4 usdtCrvUsdPool;
    MockLpPoolH4 lpPool;
    MockAccountantH4 accountant;
    MockRewardVaultH4 rewardVault;
    MockCrvSwapperH4 crvSwapper;

    PmUsdCrvUsdStrategy strategy;

    address vaultAddr;

    function setUp() public {
        usdt    = new MockERC20H4("USDT",  "USDT",  6);
        crvUSD  = new MockERC20H4("crvUSD","crvUSD",18);
        crv     = new MockERC20H4("CRV",   "CRV",   18);
        pmUSD   = new MockERC20H4("pmUSD", "pmUSD", 18);
        lpToken = new MockERC20H4("LP",    "LP",    18);

        crvUsdOracle = new MockOracleH4(1e8); // $1.00
        usdtOracle   = new MockOracleH4(1e8); // $1.00
        crvOracle    = new MockOracleH4(0.5e8);

        usdtCrvUsdPool = new MockUsdtCrvUsdPoolH4(address(usdt), address(crvUSD));
        lpPool = new MockLpPoolH4(address(crvUSD), address(pmUSD), address(lpToken), 1);
        accountant = new MockAccountantH4();
        rewardVault = new MockRewardVaultH4(address(lpToken), address(accountant));
        crvSwapper = new MockCrvSwapperH4();

        // Use address(this) as the vault for simplicity
        vaultAddr = address(this);

        strategy = new PmUsdCrvUsdStrategy(
            address(usdt),
            address(crvUSD),
            address(crv),
            address(pmUSD),
            vaultAddr,
            address(usdtCrvUsdPool),
            address(lpPool),
            address(rewardVault),
            address(crvSwapper),
            makeAddr("gauge"),
            0,   // usdtIndex
            1,   // crvUsdIndex
            1,   // lpCrvUsdIndex (crvUSD at index 1)
            address(crvUsdOracle),
            address(usdtOracle),
            address(crvOracle)
        );

        // Fund strategy with LP tokens already staked in reward vault
        // Simulate: strategy holds 1_000_000 USDT worth of LP @ virtual_price=1e18
        // 1 LP = 1 crvUSD = 1 USDT at virtual_price=1e18
        uint256 lpAmount = 1_000_000e18; // 1M LP tokens
        lpToken.mint(address(this), lpAmount);
        lpToken.approve(address(rewardVault), lpAmount);
        rewardVault.deposit(lpAmount, address(strategy));
    }

    /// @notice H4: Prove that when real virtual_price diverges 2% above cachedVirtualPrice,
    ///         balanceOf() understates NAV, and multiple update calls are needed to converge.
    function test_H4_cachedVirtualPriceLagUnderstatesNAV() public {
        // Step 1: Record initial state
        uint256 cachedVP_initial = strategy.cachedVirtualPrice();
        uint256 realVP_initial   = lpPool.get_virtual_price();
        uint256 navBefore        = strategy.balanceOf();

        assertEq(cachedVP_initial, realVP_initial, "Cache should equal real VP at deployment");
        emit log_named_uint("Initial cachedVP", cachedVP_initial);
        emit log_named_uint("Initial realVP",   realVP_initial);
        emit log_named_uint("Initial NAV (USDT 6-dec)", navBefore);

        // Step 2: Simulate real virtual_price jumping 2% (e.g., fee accumulation + external liquidity events)
        // In production: get_virtual_price() returns a higher value than cached
        uint256 realVP_2pct = (realVP_initial * 102) / 100; // 1.02e18
        lpPool.setVirtualPrice(realVP_2pct);

        // Step 3: Measure balanceOf() immediately -- cache has NOT been updated yet
        uint256 navAfterPriceJump = strategy.balanceOf();
        emit log_named_uint("Real VP after 2% jump", lpPool.get_virtual_price());
        emit log_named_uint("CachedVP (stale)", strategy.cachedVirtualPrice());
        emit log_named_uint("NAV immediately after price jump (USDT 6-dec)", navAfterPriceJump);

        // The safe VP used by balanceOf() should be capped at cached + 0.5% = 1.005e18
        // NOT the real 1.02e18
        uint256 expectedSafeVP = cachedVP_initial + (cachedVP_initial * MAX_VP_DEVIATION) / PRECISION;
        emit log_named_uint("Expected safe VP (cached + 0.5%)", expectedSafeVP);

        // balanceOf() uses safeVP = 1.005e18, but real is 1.02e18
        // So NAV is understated
        // With 1M LP: true NAV = 1M * 1.02 / 1e18 crvUSD -> USDT = 1,020,000 USDT
        // Reported NAV = 1M * 1.005e18 / 1e18 = 1,005,000 crvUSD -> USDT (still 1:1) = 1,005,000 USDT
        // Understatement = 15,000 USDT on 1M position

        // Verify the safe VP cap is working
        // navAfterPriceJump should be based on 1.005e18, not 1.02e18
        uint256 trueLpBal     = rewardVault.convertToAssets(rewardVault.balanceOf(address(strategy)));
        uint256 trueNavCrvUsd = (trueLpBal * realVP_2pct) / PRECISION;
        // Convert crvUSD (18 dec) to USDT (6 dec): divide by 1e12 (oracle prices equal at 1:1)
        uint256 trueNavUsdt   = trueNavCrvUsd / 1e12;

        uint256 understatedNavCrvUsd = (trueLpBal * expectedSafeVP) / PRECISION;
        uint256 understatedNavUsdt   = understatedNavCrvUsd / 1e12;

        emit log_named_uint("True NAV (USDT 6-dec)",        trueNavUsdt);
        emit log_named_uint("Understated NAV (USDT 6-dec)", understatedNavUsdt);
        emit log_named_uint("Understatement delta (USDT 6-dec)", trueNavUsdt - understatedNavUsdt);

        // ASSERTION 1: NAV is understated after 2% VP divergence
        // balanceOf() should equal understatedNavUsdt (uses capped VP), not trueNavUsdt
        assertEq(navAfterPriceJump, understatedNavUsdt,
            "H4: balanceOf() must use capped VP = understated NAV");

        // Confirm the understatement magnitude is ~1.48% (15,000 USDT on 1,020,000)
        uint256 understamentPct = ((trueNavUsdt - navAfterPriceJump) * 10000) / trueNavUsdt;
        emit log_named_uint("Understatement (BPS)", understamentPct);
        // Should be ~147 BPS (1.47%)
        assertGt(understamentPct, 100, "H4: Understatement must exceed 100 BPS (1%)");

        // Step 4: Verify convergence requires multiple calls
        // Each call to _updateCachedVirtualPrice() (triggered by deposit/withdraw/harvest) moves cache by 0.5%
        // We trigger it by calling deposit() which internally calls _updateCachedVirtualPrice()
        // But deposit() requires vault auth -- we ARE the vault (address(this))
        // Instead, count expected iterations analytically:

        // After call 1: cached = 1.005e18
        // After call 2: cached = 1.010025e18 (1.005 * 1.005)
        // After call 3: cached = 1.015075e18
        // After call 4: cached = 1.020150e18 > 1.02e18 -> returns real 1.02e18
        // So 4 updates required to fully converge

        // Simulate: trigger 4 deposit-cycle updates by depositing 1 USDT (minimal)
        // This exercises _deposit() -> _updateCachedVirtualPrice()
        uint256 smallDeposit = 1e6; // 1 USDT
        usdt.mint(address(this), smallDeposit * 4);
        usdt.approve(address(strategy), type(uint256).max);

        uint256 cacheAfter0 = strategy.cachedVirtualPrice();
        emit log_named_uint("Cache before any updates", cacheAfter0);

        // Update 1
        strategy.deposit(smallDeposit);
        uint256 cacheAfter1 = strategy.cachedVirtualPrice();
        emit log_named_uint("Cache after update 1", cacheAfter1);

        // Update 2
        strategy.deposit(smallDeposit);
        uint256 cacheAfter2 = strategy.cachedVirtualPrice();
        emit log_named_uint("Cache after update 2", cacheAfter2);

        // Update 3
        strategy.deposit(smallDeposit);
        uint256 cacheAfter3 = strategy.cachedVirtualPrice();
        emit log_named_uint("Cache after update 3", cacheAfter3);

        // Update 4
        strategy.deposit(smallDeposit);
        uint256 cacheAfter4 = strategy.cachedVirtualPrice();
        emit log_named_uint("Cache after update 4", cacheAfter4);

        // ASSERTION 2: After 4 calls, cache should have converged to real VP (1.02e18)
        assertEq(cacheAfter4, realVP_2pct,
            "H4: Cache must converge to real VP after 4 update calls");

        // ASSERTION 3: Confirm cache was NOT converged after only 1 update
        assertLt(cacheAfter1, realVP_2pct,
            "H4: Cache must still lag after only 1 update");

        // ASSERTION 4: Final balanceOf() after convergence must equal true NAV
        uint256 navAfterConvergence = strategy.balanceOf();
        emit log_named_uint("NAV after full convergence", navAfterConvergence);
        // After convergence, should reflect true VP
        // (Note: small deposits add tiny LP too, so we check approximate equality)
        assertGe(navAfterConvergence, trueNavUsdt,
            "H4: After convergence, NAV should reflect true VP");

        emit log("=== H4 CONFIRMED: cachedVirtualPrice lags real VP, causing NAV understatement ===");
        emit log_named_uint("Periods of understatement (N calls needed to converge)", 4);
        emit log_named_uint("Peak understatement BPS", understamentPct);
    }

    /// @notice H4 BOUNDARY: Show the exact boundary where the mechanism switches
    ///         At exactly MAX_VP_DEVIATION divergence (0.5%), safeVP = real VP (no understatement)
    ///         Above 0.5%, understatement begins
    function test_H4_boundaryAt05Percent() public {
        uint256 cached = strategy.cachedVirtualPrice();

        // Exactly 0.5% divergence: no clamping occurs, safeVP == realVP
        uint256 vp_exactly_05pct = cached + (cached * MAX_VP_DEVIATION) / PRECISION;
        lpPool.setVirtualPrice(vp_exactly_05pct);
        uint256 navAt05 = strategy.balanceOf();

        // 0.501% divergence: clamping kicks in, safeVP < realVP
        uint256 vp_above_05pct = vp_exactly_05pct + 1; // 1 wei above
        lpPool.setVirtualPrice(vp_above_05pct);
        uint256 navAbove05 = strategy.balanceOf();

        emit log_named_uint("NAV at exactly 0.5% VP divergence", navAt05);
        emit log_named_uint("NAV at 0.5%+1wei VP divergence",    navAbove05);

        // At exactly 0.5%, safeVP = realVP = vp_exactly_05pct -> navAt05 is accurate
        // At 0.5%+1wei, safeVP is clamped to vp_exactly_05pct -> navAbove05 < true NAV
        assertEq(navAt05, navAbove05,
            "H4-BOUNDARY: At 0.5% and 0.5%+1wei, safeVP is the same (boundary is inclusive)");

        emit log("H4-BOUNDARY: Clamping boundary confirmed at MAX_VP_DEVIATION");
    }
}
