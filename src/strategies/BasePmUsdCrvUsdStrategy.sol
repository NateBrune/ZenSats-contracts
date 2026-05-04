// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveRewardVaultStrategy } from "./BaseCurveRewardVaultStrategy.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { IAccountant } from "../interfaces/IAccountant.sol";
import { ICrvSwapper } from "../interfaces/ICrvSwapper.sol";
import { ICurveStableSwapNG } from "../interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IStakeDaoRewardVault } from "../interfaces/IStakeDaoRewardVault.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @dev Minimal interface for propagating slippage to the CRV reward swapper.
interface ICrvSwapperWithSlippage {
    function setSlippage(uint256 newSlippage) external;
}

/// @title BasePmUsdCrvUsdStrategy
/// @notice Abstract base for pmUSD/crvUSD Curve LP + Stake DAO strategies.
/// @dev Provides all shared logic: LP operations, CRV harvesting, virtual price cache, admin
///      controls, and deposit/withdraw orchestration via lightweight virtual hooks.
///
///      Subclasses supply the debt-asset conversion layer via five hooks:
///
///      | Hook                        | Default (crvUSD variant) | Override (USDT variant)       |
///      |-----------------------------|--------------------------|-------------------------------|
///      | _crvUsdToken()              | —  (abstract)            | returns crvUSD immutable      |
///      | _convertCrvUsdValueToDebt() | return as-is (1:1)       | oracle crvUSD→USDT            |
///      | _swapCrvUsdToDebt()         | return as-is (no swap)   | Curve crvUSD→USDT swap        |
///      | _beforeDeposit()            | no-op                    | Curve USDT→crvUSD swap        |
///      | _crvToPendingRewards()      | —  (abstract)            | reads USDT oracle, /1e12      |
///      | _pendingRewardsFallback()   | quote(crv) in crvUSD     | quote(crv)/1e12 in USDT       |
///      | _isProtectedToken()         | standard set             | + crvUSD                      |
abstract contract BasePmUsdCrvUsdStrategy is BaseCurveRewardVaultStrategy {
    using SafeTransferLib for IERC20;

    // ============ Constants ============

    // crv, pmUSD, and CRVUSD are `constant` (not `immutable` constructor parameters) because
    // they are well-known mainnet singletons shared identically across all deployed strategy
    // instances. Baking them in saves 3 storage slots and makes misconfiguration impossible.
    // Unit tests without a mainnet fork must etch mock ERC20 bytecode at these addresses;
    // see the vm.etch pattern in UsdtPmUsdCrvUsdStrategy.t.sol.
    IERC20 public constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);

    uint256 public constant MIN_SLIPPAGE = 1e15; // 0.1% minimum
    uint256 public constant DEFAULT_SLIPPAGE = 1e16; // 1% default
    uint256 public constant MAX_SLIPPAGE = 5e16; // 5% governance max
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17; // 10% emergency
    uint256 public constant LP_SLIPPAGE = 5e15; // 0.5% for stable LP operations
    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV minimum to harvest
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours
    uint256 public constant MAX_VP_DEVIATION = 5e15; // 0.5% max virtual_price deviation from cache
    uint256 public constant MAX_VP_STALENESS = 1 days; // bypass clamp if cache is older than this
    uint256 public constant MAX_SINGLE_SIDED_EXIT_DISCOUNT = 2e16; // 2% vs safe VP value

    // ============ Immutables ============

    IERC20 public constant crv = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant pmUSD = IERC20(0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF);
    ICurveStableSwapNG public immutable lpPool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable crvOracle;
    ICrvSwapper public immutable crvSwapper;
    address public immutable gauge;

    int128 public immutable lpCrvUsdIndex;
    uint256 public immutable lpPmUsdIndex;

    // ============ State ============

    address public owner;
    uint256 public slippageTolerance = DEFAULT_SLIPPAGE;
    uint256 public cachedVirtualPrice;
    uint256 public lastVpUpdate;

    // ============ Events ============

    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event LiquidityAdded(uint256 crvUsdAmount, uint256 pmUsdAmount, uint256 lpReceived);
    event LiquidityRemoved(uint256 lpBurned, uint256 crvUsdReceived);
    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdCompounded);
    event CrvSwapDeferred(uint256 crvAmount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error SingleSidedExitTooDiscounted();

    // ============ Constructor ============

    /// @param _debtAsset Debt token accepted by the vault (crvUSD in native variant; USDT in USDT
    ///        variant). Passed straight through to BaseCurveRewardVaultStrategy → BaseYieldStrategy.
    constructor(
        address _debtAsset,
        address _vault,
        address _owner,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _crvOracle
    ) BaseCurveRewardVaultStrategy(_debtAsset, _vault, _rewardVault) {
        if (_owner == address(0)) revert InvalidAddress();
        if (_lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _crvOracle == address(0)) revert InvalidAddress();

        lpPool = ICurveStableSwapNG(_lpPool);
        crvSwapper = ICrvSwapper(_crvSwapper);
        gauge = _gauge;
        lpCrvUsdIndex = _lpCrvUsdIndex;
        lpPmUsdIndex = _lpCrvUsdIndex == int128(0) ? 1 : 0;
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        crvOracle = IChainlinkOracle(_crvOracle);
        cachedVirtualPrice = ICurveStableSwapNG(_lpPool).get_virtual_price();
        lastVpUpdate = block.timestamp;
        owner = _owner;
    }

    // ============ Admin ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Transfer strategy ownership to a new address.
    /// @dev Only callable by the vault. The vault enforces a 2-day timelock before any gov role
    ///      transfer completes (see Zenji.transferRole / acceptRole), so this function is
    ///      effectively timelocked at the vault level. `owner` is always the vault's current gov.
    function transferOwnerFromVault(address newOwner) external {
        if (msg.sender != vault) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Updates strategy slippage tolerance.
    /// @dev Callable by vault (normal operations) or owner (manual recovery/ops).
    ///      Propagates to the CRV reward swapper so its oracle floor stays in sync.
    function setSlippage(uint256 newSlippage) external {
        if (msg.sender != vault && msg.sender != owner) revert Unauthorized();
        if (newSlippage < MIN_SLIPPAGE || newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
        try ICrvSwapperWithSlippage(address(crvSwapper)).setSlippage(newSlippage) {} catch {}
    }

    /// @notice Rescue ERC20 tokens that are not core strategy assets.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (_isProtectedToken(token)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ============ View Functions ============

    function underlyingAsset() external view override returns (address) {
        return address(lpToken);
    }

    /// @dev LP value via cached virtual_price, then converted to debt asset units via hook.
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _rewardVaultBalance();
        if (lpTokens < 1) return 0;
        uint256 crvUsdValue = (lpTokens * _getSafeVirtualPrice()) / 1e18;
        return _convertCrvUsdValueToDebt(crvUsdValue);
    }

    /// @dev CRV oracle staleness check is shared. Second oracle and final conversion are
    ///      variant-specific via _crvToPendingRewards() and _pendingRewardsFallback().
    function pendingRewards() external view override returns (uint256) {
        address accountant = rewardVault.ACCOUNTANT();
        try IAccountant(accountant).getPendingRewards(address(rewardVault), address(this)) returns (
            uint256 pendingCrv
        ) {
            if (pendingCrv < 1) return 0;

            (uint80 crvRoundId, int256 crvPrice,, uint256 crvUpdatedAt, uint80 crvAnswered) =
                crvOracle.latestRoundData();
            if (
                crvPrice <= 0 || crvAnswered < crvRoundId
                    || block.timestamp - crvUpdatedAt > MAX_ORACLE_STALENESS
            ) {
                return _pendingRewardsFallback(pendingCrv);
            }

            return _crvToPendingRewards(pendingCrv, uint256(crvPrice));
        } catch {
            return 0;
        }
    }

    // ============ Virtual Hooks ============

    /// @notice Convert a crvUSD-denominated amount to the debt asset denomination.
    /// @dev Oracle-based, no token transfers. Used by balanceOf() and _harvest().
    ///      crvUSD variant default: 1:1 pass-through.
    ///      USDT variant overrides with Chainlink crvUSD/USD ÷ USDT/USD.
    function _convertCrvUsdValueToDebt(uint256 crvUsdAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        return crvUsdAmount;
    }

    /// @notice Swap crvUSD tokens to the debt asset (actual token movement).
    /// @dev Called on withdrawals. crvUSD variant default: no-op pass-through.
    ///      USDT variant overrides with Curve crvUSD→USDT swap.
    function _swapCrvUsdToDebt(uint256 crvUsdAmount, uint256 /*slippage*/)
        internal
        virtual
        returns (uint256)
    {
        return crvUsdAmount;
    }

    /// @notice Pre-deposit hook: convert debt asset to crvUSD before LP operations.
    /// @dev crvUSD variant default: no-op (debt is already crvUSD, already in contract).
    ///      USDT variant overrides to run the Curve USDT→crvUSD swap.
    function _beforeDeposit(uint256, /*amount*/ uint256 /*slippage*/) internal virtual {}

    /// @notice Fallback for pendingRewards() when the CRV oracle is stale.
    /// @dev crvUSD variant: returns crvSwapper.quote() in crvUSD (18 dec).
    ///      USDT variant overrides to divide by 1e12 for 6-decimal USDT.
    function _pendingRewardsFallback(uint256 pendingCrv) internal view virtual returns (uint256) {
        return crvSwapper.quote(pendingCrv);
    }

    /// @notice Convert a CRV amount to debt asset value using a valid CRV/USD price.
    /// @dev Abstract — each variant reads its own denominator oracle (crvUSD or USDT).
    function _crvToPendingRewards(uint256 pendingCrv, uint256 crvPrice)
        internal
        view
        virtual
        returns (uint256);

    /// @notice Returns true if a token must be blocked from recue.
    /// @dev Override (with super call) to add variant-specific protected tokens.
    function _isProtectedToken(address token) internal view virtual returns (bool) {
        return token == address(debtAsset) || token == address(lpToken)
            || token == address(pmUSD) || token == address(crv) || token == address(rewardVault);
    }

    // ============ Internal: Core Strategy ============

    /// @dev Deposit flow:
    ///   1. Compound existing CRV rewards (for crvUSD variant this also consumes the deposit).
    ///   2. _beforeDeposit hook (USDT variant: swap incoming USDT → crvUSD; no-op otherwise).
    ///   3. Add any residual crvUSD/pmUSD as LP and stake.
    ///   Return value is shares-delta (event-only; cost basis is updated from `amount` upstream).
    function _deposit(uint256 amount) internal override returns (uint256 underlyingDeposited) {
        _updateCachedVirtualPrice(); // ratchet before any LP math executes

        uint256 sharesBefore = rewardVault.balanceOf(address(this));

        // For crvUSD variant: deposit crvUSD is already in contract, gets consumed here.
        // For USDT variant: compound runs before the swap, so no deposit crvUSD is present yet.
        _claimAndCompound();

        // USDT variant: swap the incoming USDT → crvUSD now. crvUSD variant: no-op.
        _beforeDeposit(amount, slippageTolerance);

        // Stake any remaining crvUSD/pmUSD (covers USDT post-swap and crvUSD residuals).
        uint256 lpRemainder = _addLiquidity();
        if (lpRemainder > 0) _depositToRewardVault(lpRemainder);

        underlyingDeposited = rewardVault.balanceOf(address(this)) - sharesBefore;
    }

    /// @dev Withdrawals may transiently revert during extreme market conditions (high pool
    /// slippage or stale oracle on the USDT variant). No funds are permanently stuck — all
    /// state changes revert atomically. Users should retry when conditions normalise.
    function _withdraw(uint256 debtAmount) internal override returns (uint256 received) {
        _updateCachedVirtualPrice(); // ratchet before any LP math executes

        // Snapshot share ratio before _claimAndCompound inflates the pool, keeping it
        // consistent with the basisReduction computed from the outer balanceOf() call.
        uint256 currentValue = balanceOf(); // in debt asset units, using fresh VP from ratchet
        if (currentValue < 1) return 0;

        uint256 shares = rewardVault.balanceOf(address(this));
        if (shares < 1) return 0;

        uint256 sharesToRedeem = (shares * debtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;

        _claimAndCompound(); // reward shares accrue beyond the locked ratio above

        if (sharesToRedeem < 1) return 0;

        uint256 lpReceived = _redeemFromRewardVault(sharesToRedeem);
        uint256 crvUsdReceived;
        if (lpReceived > 0) {
            crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);
        }

        // USDT variant: swap crvUSD → USDT. crvUSD variant: no-op pass-through.
        received = _swapCrvUsdToDebt(crvUsdReceived, slippageTolerance);
    }

    function _withdrawAll() internal override returns (uint256 received) {
        _updateCachedVirtualPrice(); // ratchet before any LP math executes

        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        uint256 crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);
        received = _swapCrvUsdToDebt(crvUsdReceived, slippageTolerance);
    }

    function _harvest() internal override returns (uint256 rewardsValue) {
        _updateCachedVirtualPrice(); // ratchet before any LP math executes

        uint256 crvUsdCompounded = _claimAndCompound();
        // Oracle-based conversion (no token transfer) — just reports the value harvested.
        rewardsValue = _convertCrvUsdValueToDebt(crvUsdCompounded);
    }

    function _emergencyWithdraw() internal override returns (uint256 received) {
        _updateCachedVirtualPrice(); // ratchet before any LP math executes

        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        uint256 crvUsdReceived = _removeLiquidity(lpReceived, EMERGENCY_SLIPPAGE);
        received = _swapCrvUsdToDebt(crvUsdReceived, EMERGENCY_SLIPPAGE);
    }

    // ============ Internal: CRV Compounding ============

    /// @notice Claim CRV from accountant, swap to crvUSD, and compound into LP.
    /// @return crvUsdCompounded Amount of crvUSD produced by the CRV swap (0 if below threshold).
    function _claimAndCompound() internal returns (uint256 crvUsdCompounded) {
        _accountantClaim();

        uint256 crvBalance = crv.balanceOf(address(this));
        if (crvBalance >= MIN_HARVEST_THRESHOLD) {
            crv.safeTransfer(address(crvSwapper), crvBalance);
            uint256 swapped = _swapCrv(crvBalance);
            if (swapped > 0) {
                crvUsdCompounded = swapped;
                emit RewardsHarvested(crvBalance, crvUsdCompounded);
            } else {
                emit CrvSwapDeferred(crvBalance);
            }
        }

        // Add any crvUSD + pmUSD in the contract into the LP pool and stake.
        uint256 crvUsdBal = CRVUSD.balanceOf(address(this));
        uint256 pmUsdBal = pmUSD.balanceOf(address(this));
        if (crvUsdBal < 1 && pmUsdBal < 1) return crvUsdCompounded;

        uint256 lpReceived = _addLiquidity();
        _depositToRewardVault(lpReceived);
    }

    function _swapCrv(uint256 amount) internal returns (uint256 crvUsdReceived) {
        try crvSwapper.swap(amount) returns (uint256 received) {
            crvUsdReceived = received;
        } catch {
            // Swap failed (oracle floor, slippage, etc.) — CRV stays at swapper address
            // and will be retried on the next compound cycle.
        }
    }

    function _accountantClaim() internal {
        address accountant = rewardVault.ACCOUNTANT();
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        bytes[] memory harvestData = new bytes[](1);
        harvestData[0] = bytes("");
        // NoPendingRewards is expected when nothing has accrued yet.
        try IAccountant(accountant).claim(gauges, harvestData, address(this)) {} catch {}
    }

    // ============ Internal: Virtual Price Cache ============

    /// @notice Get manipulation-resistant virtual price, bounded by ±MAX_VP_DEVIATION from cache.
    /// @dev Bypasses the clamp when the cache is older than MAX_VP_STALENESS to avoid reporting
    ///      a stale bounded value after long periods of inactivity.
    function _getSafeVirtualPrice() internal view returns (uint256) {
        uint256 cached = cachedVirtualPrice;
        uint256 current = lpPool.get_virtual_price();
        if (cached == 0) return current;

        // Cache is stale: bypass clamp so balanceOf() reflects the true pool price.
        if (block.timestamp - lastVpUpdate > MAX_VP_STALENESS) return current;

        uint256 maxDeviation = (cached * MAX_VP_DEVIATION) / PRECISION;
        uint256 upperBound = cached + maxDeviation;
        uint256 lowerBound = cached > maxDeviation ? cached - maxDeviation : 0;

        if (current > upperBound) return upperBound;
        if (current < lowerBound) return lowerBound;
        return current;
    }

    /// @notice Advance the cached virtual price (permissionless keeper function).
    function updateCachedVirtualPrice() external override {
        _updateCachedVirtualPrice();
    }

    function _updateCachedVirtualPrice() internal {
        cachedVirtualPrice = _getSafeVirtualPrice();
        lastVpUpdate = block.timestamp;
    }

    // ============ Internal: LP Operations ============

    /// @notice Add all crvUSD and pmUSD balances as liquidity to the pmUSD/crvUSD pool.
    function _addLiquidity() internal returns (uint256 lpReceived) {
        uint256 crvUsdAmount = CRVUSD.balanceOf(address(this));
        uint256 pmUsdAmount = pmUSD.balanceOf(address(this));
        if (crvUsdAmount == 0 && pmUsdAmount == 0) return 0;

        if (crvUsdAmount > 0) _ensureApprove(address(CRVUSD), address(lpPool), crvUsdAmount);
        if (pmUsdAmount > 0) _ensureApprove(address(pmUSD), address(lpPool), pmUsdAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;
        amounts[lpPmUsdIndex] = pmUsdAmount;

        uint256 expectedLp = lpPool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        // Oracle floor via cached VP — immune to same-block manipulation.
        uint256 safeVP = _getSafeVirtualPrice();
        uint256 totalValue = crvUsdAmount + pmUsdAmount;
        uint256 oracleMinLp =
            (totalValue * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = lpPool.add_liquidity(amounts, minLp);
        emit LiquidityAdded(crvUsdAmount, pmUsdAmount, lpReceived);
    }

    /// @notice Remove single-sided crvUSD liquidity from the pmUSD/crvUSD pool.
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);

        uint256 safeVP = _getSafeVirtualPrice();
        uint256 vpValue = (lpAmount * safeVP) / PRECISION;
        uint256 minHealthyOut =
            (vpValue * (PRECISION - MAX_SINGLE_SIDED_EXIT_DISCOUNT)) / PRECISION;
        if (expectedOut < minHealthyOut) revert SingleSidedExitTooDiscounted();

        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        crvUsdReceived = lpPool.remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut);
        emit LiquidityRemoved(lpAmount, crvUsdReceived);
    }
}
