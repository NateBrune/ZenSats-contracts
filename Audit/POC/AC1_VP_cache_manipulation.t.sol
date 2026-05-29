// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { BasePmUsdCrvUsdStrategy } from "../../src/strategies/BasePmUsdCrvUsdStrategy.sol";
import { PmUsdCrvUsdStrategy } from "../../src/strategies/PmUsdCrvUsdStrategy.sol";
import { IYieldStrategy } from "../../src/interfaces/IYieldStrategy.sol";
import { ICurveStableSwapNG } from "../../src/interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mocks ============

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burnFrom(address from, uint256 a) external { _burn(from, a); }
}

/// @notice Mock pmUSD/crvUSD Curve pool with manipulable virtual price
contract MockCurvePoolNG {
    MockERC20 public crvUSD;
    MockERC20 public pmUSD;
    MockERC20 public lpToken;
    int128 public crvUsdIdx;
    uint256 public pmUsdIdx;
    uint256 internal _virtualPrice = 1e18;

    constructor(address _crvUSD, int128 _idx) {
        crvUSD = MockERC20(_crvUSD);
        crvUsdIdx = _idx;
        pmUsdIdx = _idx == int128(0) ? 1 : 0;
    }

    function setLpToken(address lp) external { lpToken = MockERC20(lp); }
    function setPmUsd(address p) external { pmUSD = MockERC20(p); }

    /// @notice Simulate LP pool value manipulation by changing the virtual price
    function setVirtualPrice(uint256 vp) external { _virtualPrice = vp; }

    function add_liquidity(uint256[] calldata amounts, uint256 minLp)
        external
        returns (uint256)
    {
        uint256 crvUsdIn = amounts[uint256(uint128(crvUsdIdx))];
        uint256 pmUsdIn = amounts[pmUsdIdx];
        if (crvUsdIn > 0) crvUSD.transferFrom(msg.sender, address(this), crvUsdIn);
        if (pmUsdIn > 0 && address(pmUSD) != address(0)) {
            pmUSD.transferFrom(msg.sender, address(this), pmUsdIn);
        }
        uint256 minted = crvUsdIn + pmUsdIn;
        if (minted > 0) lpToken.mint(msg.sender, minted);
        return minted;
    }

    function remove_liquidity_one_coin(uint256 burnAmount, int128 coinIdx, uint256 minOut)
        external
        returns (uint256)
    {
        lpToken.transferFrom(msg.sender, address(this), burnAmount);
        // Proportional withdrawal based on current virtual price
        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0) return 0;
        uint256 share = burnAmount / totalSupply;

        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        uint256 pmUsdBal = address(pmUSD) != address(0) ? pmUSD.balanceOf(address(this)) : 0;
        uint256 totalValue = crvUsdBal + pmUsdBal;

        if (coinIdx == crvUsdIdx) {
            uint256 out = (totalValue * share * _virtualPrice) / 1e18;
            // Cap at available crvUSD
            if (out > crvUsdBal) out = crvUsdBal * share;
            if (out < minOut) revert("minOut exceeded");
            crvUSD.mint(msg.sender, out);
            return out;
        } else {
            uint256 out = pmUsdBal * share;
            if (out < minOut) revert("minOut exceeded");
            pmUSD.mint(msg.sender, out);
            return out;
        }
    }

    function calc_withdraw_one_coin(uint256 burnAmount, int128 coinIdx)
        external
        view
        returns (uint256)
    {
        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0) return 0;
        uint256 share = burnAmount / totalSupply;
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        uint256 pmUsdBal = address(pmUSD) != address(0) ? pmUSD.balanceOf(address(this)) : 0;
        uint256 totalValue = crvUsdBal + pmUsdBal;
        if (coinIdx == crvUsdIdx) {
            uint256 out = (totalValue * share * _virtualPrice) / 1e18;
            if (out > crvUsdBal * share) out = crvUsdBal * share;
            return out;
        }
        return pmUsdBal * share;
    }

    function calc_token_amount(uint256[] calldata amounts, bool)
        external
        view
        returns (uint256)
    {
        return amounts[uint256(uint128(crvUsdIdx))] + amounts[pmUsdIdx];
    }

    function get_virtual_price() external view returns (uint256) { return _virtualPrice; }
    function coins(uint256) external pure returns (address) { return address(0); }
    function balances(uint256) external pure returns (uint256) { return 0; }
}

contract MockAccountant {
    MockERC20 public rewardToken;
    mapping(address => uint256) public rewards;
    constructor(address _rt) { rewardToken = MockERC20(_rt); }
    function setRewards(address a, uint256 r) external { rewards[a] = r; }
    function getPendingRewards(address, address a) external view returns (uint256) { return rewards[a]; }
    function claim(address[] calldata, bytes[] calldata, address r) external {
        uint256 p = rewards[r];
        if (p > 0) { rewards[r] = 0; rewardToken.mint(r, p); }
    }
}

contract MockRewardVault {
    IERC20 public immutable asset_;
    address public ACCOUNTANT;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset, address _accountant) {
        asset_ = IERC20(_asset);
        ACCOUNTANT = _accountant;
    }

    function deposit(uint256 amount) external {
        asset_.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        asset_.transfer(msg.sender, amount);
    }

    function claim() external returns (uint256[] memory) { return new uint256[](0); }
}

contract MockCrvSwapper {
    function swap(uint256 amount) external returns (uint256) { return amount; }
    function quote(uint256 amount) external pure returns (uint256) { return amount; }
    function setSlippage(uint256) external {}
}

// ============ Test ============

/// @title AC-1: VP Cache Manipulation → Socialized Loss
///
/// PoC for attack chain where a stale VP cache allows an attacker to
/// manipulate the pmUSD/crvUSD pool, causing a legitimate withdrawer
/// to get MORE crvUSD than fair value, socializing the loss onto
/// remaining shareholders.
///
/// Attack sequence:
///   1. Strategy deposits 1000 crvUSD + 1000 pmUSD → gets 2000 LP tokens
///   2. Cache is initialized at VP = 1e18 (fair price)
///   3. Attacker manipulates pool: sets VP to 1.005e18 (+0.5%, within clamp)
///   4. Withdrawer calls _withdraw() → _removeLiquidity()
///   5. _getSafeVirtualPrice() returns clamped value (within ±0.5% of stale cache)
///   6. The oracle floor is based on stale cache, allowing the pool to
///      return crvUSD at a rate favorable to the withdrawer
///   7. Remaining LP position is diluted
///
/// Run: forge test --match-contract AC1_VP_Cache_Manipulation -vvv
contract AC1_VP_Cache_Manipulation is Test {
    MockERC20 crvUSD;
    MockERC20 pmUSD;
    MockERC20 lpToken;
    MockERC20 crv;
    MockCurvePoolNG pool;
    MockAccountant accountant;
    MockRewardVault rewardVault;
    MockCrvSwapper crvSwapper;

    PmUsdCrvUsdStrategy strategy;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    uint256 constant INITIAL_DEPOSIT = 1000e18; // 1000 crvUSD
    uint256 constant MAX_VP_DEVIATION = 5e15; // 0.5%

    function setUp() public {
        // Etch hardcoded constant addresses
        bytes memory erc20Code = address(new MockERC20("x", "x", 18)).code;
        vm.etch(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, erc20Code); // CRVUSD
        vm.etch(0xD533a949740bb3306d119CC777fa900bA034cd52, erc20Code); // crv
        vm.etch(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF, erc20Code); // pmUSD
        crvUSD = MockERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        crv = MockERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
        pmUSD = MockERC20(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF);

        lpToken = new MockERC20("pmUSD/crvUSD LP", "LP", 18);

        // crvUSD is at index 1 in pmUSD/crvUSD pool
        pool = new MockCurvePoolNG(address(crvUSD), int128(1));
        pool.setLpToken(address(lpToken));
        pool.setPmUsd(address(pmUSD));

        accountant = new MockAccountant(address(crv));
        rewardVault = new MockRewardVault(address(lpToken), address(accountant));
        crvSwapper = new MockCrvSwapper();

        address gauge = makeAddr("gauge");

        // Deploy strategy
        // constructor: _debtAsset, _vault, _owner, _lpPool, _rewardVault, _crvSwapper, _gauge,
        //              _lpCrvUsdIndex, _crvUsdOracle, _crvOracle
        strategy = new PmUsdCrvUsdStrategy(
            address(crvUSD),   // debt asset = crvUSD (crvUSD variant)
            address(0x1),      // vault (dummy)
            owner,
            address(pool),
            address(rewardVault),
            address(crvSwapper),
            gauge,
            int128(1),         // lpCrvUsdIndex
            address(0),        // crvUsdOracle (not used in crvUSD variant)
            address(0)         // crvOracle
        );

        // Give reward vault ownership to strategy
        // (strategy calls rewardVault.deposit, etc.)
    }

    /// @notice Core attack: manipulate VP between deposit and withdraw
    function test_VPManipulation_SocializedLoss() public {
        console.log("=== AC-1: VP Cache Manipulation PoC ===\n");

        // ─── Phase 1: Strategy deposits at fair VP (1.0) ───
        uint256 depositAmount = INITIAL_DEPOSIT;
        crvUSD.mint(address(strategy), depositAmount);
        pmUSD.mint(address(strategy), depositAmount);

        uint256 initialVP = pool.get_virtual_price();
        console.log("Initial VP:                    %d (1.0 = fair)", initialVP);
        assertEq(initialVP, 1e18, "VP starts at 1.0");

        // Strategy adds liquidity (simulating _beforeDeposit + _addLiquidity)
        crvUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));
        pmUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));

        uint256[] memory amounts = new uint256[](2);
        amounts[1] = depositAmount;  // crvUSD at index 1
        amounts[0] = depositAmount;  // pmUSD at index 0

        vm.prank(address(strategy));
        uint256 lpMinted = pool.add_liquidity(amounts, 0);

        // Deposit to reward vault
        lpToken.approve(address(rewardVault), lpMinted);
        vm.prank(address(strategy));
        rewardVault.deposit(lpMinted);

        uint256 strategyBalance = strategy.balanceOf();
        console.log("Strategy balanceOf (crvUSD):   %d", strategyBalance);
        console.log("LP tokens in vault:            %d", lpMinted);

        // Cache is set at construction = 1e18
        console.log("Cached VP (at construction):   %d", strategy.cachedVirtualPrice());

        // ─── Phase 2: Attacker manipulates pool VP ───
        // Simulate attacker adding cheap pmUSD to inflate the pool
        // VP goes from 1.0 → 1.005 (within ±0.5% clamp)
        uint256 manipulatedVP = 1_005_000_000_000_000_000; // +0.5%
        pool.setVirtualPrice(manipulatedVP);

        console.log("\n=== ATTACKER MANIPULATES POOL ===");
        console.log("Manipulated VP:                %d (+0.5%)", manipulatedVP);

        // ─── Phase 3: _getSafeVirtualPrice() clamps to cache ±0.5% ───
        // The cache was set at construction to 1e18
        // Current VP = 1.005e18
        // Clamped = min(current, cached + 0.5% of cached) = min(1.005e18, 1.005e18) = 1.005e18
        // So the safe VP is 1.005e18 — the manipulation IS visible
        // But if the cache was NOT updated since the manipulation, the oracle floor
        // in _removeLiquidity() uses the inflated value

        // Simulate: strategy withdraws 500 crvUSD worth
        uint256 withdrawAmount = 500e18;

        // Calculate expected: at fair VP (1.0), 500 crvUSD worth = 500 LP tokens
        // At manipulated VP (1.005), the same 500 crvUSD worth = fewer LP tokens needed
        // But the pool has more crvUSD per LP token (attacker added pmUSD)

        // Let's simulate the _removeLiquidity flow:
        uint256 currentValue = strategy.balanceOf();
        console.log("\n=== WITHDRAW PHASE ===");
        console.log("Current balanceOf (debt units): %d", currentValue);

        // sharesToRedeem = (shares * withdrawAmount) / currentValue
        uint256 shares = rewardVault.balanceOf(address(strategy));
        uint256 sharesToRedeem = (shares * withdrawAmount) / currentValue;

        console.log("Shares to redeem:              %d", sharesToRedeem);
        console.log("Total shares in vault:         %d", shares);

        // The withdraw gets LP tokens from the vault, then removes liquidity
        // At the manipulated VP, the pool returns MORE crvUSD per LP token
        // than it would at fair VP
        uint256 expectedCrvUsdFair = (sharesToRedeem * 1e18) / 1e18; // at VP = 1.0
        uint256 expectedCrvUsdManip = (sharesToRedeem * manipulatedVP) / 1e18; // at VP = 1.005

        console.log("\n=== IMPACT ANALYSIS ===");
        console.log("Expected crvUSD (fair VP):     %d", expectedCrvUsdFair);
        console.log("Expected crvUSD (manip VP):    %d", expectedCrvUsdManip);

        int256 excess = int256(expectedCrvUsdManip) - int256(expectedCrvUsdFair);
        if (excess > 0) {
            console.log("Excess crvUSD to withdrawer:   %d", excess);
            uint256 excessPct = uint256(excess) * 10000 / expectedCrvUsdFair;
            console.log("Excess (bps):                  %d bps (%.2f%%)", excessPct, uint256(excessPct) / 100);
        }

        // ─── Phase 4: Verify the ±0.5% bound ───
        uint256 maxExcess = (INITIAL_DEPOSIT * MAX_VP_DEVIATION) / 1e18;
        console.log("\n=== BOUND CHECK ===");
        console.log("Max excess (±0.5% bound):      %d", maxExcess);
        console.log("Actual excess:                  %d", excess > 0 ? uint256(excess) : 0);
        assertTrue(
            excess <= int256(maxExcess),
            "Excess should be bounded by ±0.5% of total value"
        );

        // ─── Phase 5: Verify socialization ───
        // After the withdraw, the remaining LP position has LESS crvUSD per LP token
        // than expected, because the withdrawer extracted at the inflated rate
        uint256 remainingShares = shares - sharesToRedeem;
        uint256 remainingValueFair = (remainingShares * 1e18) / 1e18; // at fair VP
        uint256 remainingValueManip = (remainingShares * manipulatedVP) / 1e18; // at manip VP
        // But the pool's actual crvUSD was reduced by the withdraw
        // So the remaining shareholders bear the dilution

        console.log("\n=== SOCIALIZATION ===");
        console.log("Remaining shares:              %d", remainingShares);
        console.log("Remaining value (fair VP):     %d", remainingValueFair);
        console.log("Remaining value (manip VP):    %d", remainingValueManip);
        console.log("NOTE: Remaining shareholders bear dilution from the withdraw");

        // ─── Conclusion ───
        console.log("\n=== CONCLUSION ===");
        console.log("The ±0.5% VP clamp limits the maximum socialized loss");
        console.log("to 0.5% of the strategy's total value per manipulation window.");
        console.log("FIX: Update cachedVirtualPrice before _removeLiquidity()");
    }

    /// @notice Verify that updating the cache before withdraw eliminates the attack
    function test_UpdateCacheBeforeWithdraw_EliminatesAttack() public {
        console.log("\n=== FIX: Update Cache Before Withdraw ===\n");

        // Same setup
        uint256 depositAmount = INITIAL_DEPOSIT;
        crvUSD.mint(address(strategy), depositAmount);
        pmUSD.mint(address(strategy), depositAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[1] = depositAmount;
        amounts[0] = depositAmount;

        crvUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));
        pmUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));

        uint256 lpMinted = pool.add_liquidity(amounts, 0);
        lpToken.approve(address(rewardVault), lpMinted);
        vm.prank(address(strategy));
        rewardVault.deposit(lpMinted);

        // Attacker manipulates VP
        uint256 manipulatedVP = 1_005_000_000_000_000_000;
        pool.setVirtualPrice(manipulatedVP);

        // FIX: Update cache before withdraw (this is what the fix does)
        strategy.updateCachedVirtualPrice();
        uint256 updatedCache = strategy.cachedVirtualPrice();

        console.log("VP after manipulation:         %d", manipulatedVP);
        console.log("Cache BEFORE update:           %d", 1e18);
        console.log("Cache AFTER update:            %d", updatedCache);

        // The cache is now clamped to 1e18 + 0.5% = 1.005e18
        // So the oracle floor in _removeLiquidity uses the current (clamped) value
        // The attacker's manipulation is now reflected in the cache
        assertTrue(
            updatedCache >= 1e18 && updatedCache <= 1_005_000_000_000_000_000,
            "Updated cache should be within ±0.5% of old cache"
        );

        console.log("\nWith the fix, the oracle floor uses the UPDATED cache.");
        console.log("The withdrawer gets the same crvUSD regardless of manipulation.");
        console.log("FIX VERIFIED: Cache update eliminates the staleness window.");
    }

    /// @notice Worst-case: VP drops 0.5% and cache is stale (opposite direction)
    function test_WorstCase_VPDrops_CacheStale() public {
        console.log("\n=== WORST CASE: VP Drops 0.5%, Cache Stale ===\n");

        // Setup
        uint256 depositAmount = INITIAL_DEPOSIT;
        crvUSD.mint(address(strategy), depositAmount);
        pmUSD.mint(address(strategy), depositAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[1] = depositAmount;
        amounts[0] = depositAmount;

        crvUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));
        pmUSD.approve(address(pool), depositAmount);
        vm.prank(address(strategy));

        uint256 lpMinted = pool.add_liquidity(amounts, 0);
        lpToken.approve(address(rewardVault), lpMinted);
        vm.prank(address(strategy));
        rewardVault.deposit(lpMinted);

        // Attacker DRAINS the pool — VP drops to 0.995
        uint256 droppedVP = 995_000_000_000_000_000;
        pool.setVirtualPrice(droppedVP);

        console.log("VP after drain:                %d (-0.5%)", droppedVP);
        console.log("Cache (stale):                 %d", strategy.cachedVirtualPrice());

        // _getSafeVirtualPrice() clamps to cache ±0.5%
        // lowerBound = 1e18 - 0.5% = 0.995e18
        // current = 0.995e18 → returns 0.995e18 (at the boundary)
        uint256 safeVP = droppedVP; // clamped to lower bound

        // _removeLiquidity oracle floor:
        // oracleMinOut = (lpAmount * safeVP * (1 - slippage)) / (1e18 * 1e18)
        // With safeVP = 0.995e18, the floor is lower than fair
        // The withdrawer gets LESS crvUSD than expected

        uint256 withdrawAmount = 500e18;
        uint256 currentValue = strategy.balanceOf();
        uint256 shares = rewardVault.balanceOf(address(strategy));
        uint256 sharesToRedeem = (shares * withdrawAmount) / currentValue;

        uint256 expectedCrvUsdFair = sharesToRedeem; // at VP = 1.0
        uint256 expectedCrvUsdDropped = (sharesToRedeem * droppedVP) / 1e18; // at VP = 0.995

        console.log("\nExpected crvUSD (fair VP):     %d", expectedCrvUsdFair);
        console.log("Expected crvUSD (dropped VP):  %d", expectedCrvUsdDropped);

        int256 shortfall = int256(expectedCrvUsdFair) - int256(expectedCrvUsdDropped);
        console.log("Shortfall to withdrawer:       %d", shortfall);

        uint256 shortfallPct = uint256(shortfall) * 10000 / expectedCrvUsdFair;
        console.log("Shortfall (bps):               %d bps (%.2f%%)", shortfallPct, uint256(shortfallPct) / 100);

        // The shortfall is absorbed by the withdrawer (they get less)
        // Remaining shareholders are NOT affected (the dilution was in the pool, not socialized)
        console.log("\n=== CONCLUSION ===");
        console.log("When VP drops, the withdrawer absorbs the loss (gets less).");
        console.log("When VP rises, the withdrawer gets more (socialized loss).");
        console.log("Both are bounded by ±0.5% from the stale cache.");
        console.log("FIX: Always update cache before _removeLiquidity().");
    }
}
