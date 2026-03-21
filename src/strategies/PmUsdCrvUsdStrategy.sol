// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { BaseCurveRewardVaultStrategy } from "./BaseCurveRewardVaultStrategy.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IChainlinkOracle } from "../interfaces/IChainlinkOracle.sol";
import { IAccountant } from "../interfaces/IAccountant.sol";
import { ICrvSwapper } from "../interfaces/ICrvSwapper.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { ICurveStableSwapNG } from "../interfaces/ICurveStableSwapNG.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IStakeDaoRewardVault } from "../interfaces/IStakeDaoRewardVault.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { CurveUsdtSwapLib } from "../libraries/CurveUsdtSwapLib.sol";
import { TimelockLib } from "../libraries/TimelockLib.sol";

/// @title PmUsdCrvUsdStrategy
/// @notice USDT -> crvUSD -> pmUSD/crvUSD LP -> Stake DAO RewardVault
/// @dev Accepts USDT debt, swaps to crvUSD, provides single-sided liquidity to pmUSD/crvUSD pool,
///      stakes LP in Stake DAO reward vault, and harvests CRV rewards back into the strategy
contract PmUsdCrvUsdStrategy is BaseCurveRewardVaultStrategy {
    using SafeTransferLib for IERC20;

    error SwapFailed();
    // ============ Constants ============

    uint256 public constant DEFAULT_SLIPPAGE = 1e16; // 1% for stablecoin swaps
    uint256 public constant MAX_SLIPPAGE = 5e16; // 5% governance max
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17; // 10% emergency
    uint256 public constant LP_SLIPPAGE = 5e15; // 0.5% for LP ops (stable pairs)
    uint256 public constant MIN_HARVEST_THRESHOLD = 1e17; // 0.1 CRV minimum
    uint256 public constant MAX_ORACLE_STALENESS = 90000; // 25 hours
    uint256 public constant MAX_VP_DEVIATION = 5e15; // 0.5% max virtual_price deviation from cached

    // ============ Immutables ============

    IERC20 public immutable crvUSD;
    IERC20 public immutable crv;
    IERC20 public immutable pmUSD;
    ICurveStableSwap public immutable usdtCrvUsdPool;
    ICurveStableSwapNG public immutable lpPool;
    IChainlinkOracle public immutable crvUsdOracle;
    IChainlinkOracle public immutable usdtOracle;
    IChainlinkOracle public immutable crvOracle;
    ICrvSwapper public immutable crvSwapper;
    address public immutable gauge;

    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;
    int128 public immutable lpCrvUsdIndex;
    uint256 public immutable lpPmUsdIndex;

    // ============ State ============

    address public owner;
    address public pendingOwner;
    uint256 public ownerTimelockReady;
    uint256 public slippageTolerance = DEFAULT_SLIPPAGE;
    uint256 public cachedVirtualPrice;

    uint256 public constant OWNER_TIMELOCK_DELAY = 2 days;
    uint256 public constant OWNER_TIMELOCK_EXPIRY = 7 days;

    // ============ Events ============

    event OwnerTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnerTransferCancelled(address indexed cancelledOwner);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);
    event LiquidityAdded(uint256 crvUsdAmount, uint256 pmUsdAmount, uint256 lpReceived);
    event LiquidityRemoved(uint256 lpBurned, uint256 crvUsdReceived);
    event RewardsHarvested(uint256 crvAmount, uint256 crvUsdCompounded);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ============ Constructor ============

    /// @param _usdt USDT token address (debt asset)
    /// @param _crvUsd crvUSD token address
    /// @param _crv CRV token address
    /// @param _pmUsd pmUSD token address (extra reward token reinvested into LP)
    /// @param _vault Zenji vault address
    /// @param _usdtCrvUsdPool Curve USDT/crvUSD StableSwap pool
    /// @param _lpPool Curve pmUSD/crvUSD StableSwapNG pool
    /// @param _rewardVault Stake DAO ERC4626 reward vault
    /// @param _crvSwapper CRV -> crvUSD swapper address
    /// @param _gauge Curve gauge for pmUSD/crvUSD LP (for accountant claims)
    /// @param _usdtIndex USDT coin index in USDT/crvUSD pool
    /// @param _crvUsdIndex crvUSD coin index in USDT/crvUSD pool
    /// @param _lpCrvUsdIndex crvUSD coin index in pmUSD/crvUSD pool
    /// @param _crvUsdOracle Chainlink crvUSD/USD oracle
    /// @param _usdtOracle Chainlink USDT/USD oracle
    /// @param _crvOracle Chainlink CRV/USD oracle
    constructor(
        address _usdt,
        address _crvUsd,
        address _crv,
        address _pmUsd,
        address _vault,
        address _usdtCrvUsdPool,
        address _lpPool,
        address _rewardVault,
        address _crvSwapper,
        address _gauge,
        int128 _usdtIndex,
        int128 _crvUsdIndex,
        int128 _lpCrvUsdIndex,
        address _crvUsdOracle,
        address _usdtOracle,
        address _crvOracle
    ) BaseCurveRewardVaultStrategy(_usdt, _vault, _rewardVault) {
        if (_crvUsd == address(0) || _crv == address(0)) revert InvalidAddress();
        if (_pmUsd == address(0)) revert InvalidAddress();
        if (_usdtCrvUsdPool == address(0) || _lpPool == address(0)) revert InvalidAddress();
        if (_crvSwapper == address(0)) revert InvalidAddress();
        if (_gauge == address(0)) revert InvalidAddress();
        if (_crvUsdOracle == address(0) || _usdtOracle == address(0) || _crvOracle == address(0)) {
            revert InvalidAddress();
        }

        crvUSD = IERC20(_crvUsd);
        crv = IERC20(_crv);
        pmUSD = IERC20(_pmUsd);
        usdtCrvUsdPool = ICurveStableSwap(_usdtCrvUsdPool);
        lpPool = ICurveStableSwapNG(_lpPool);
        crvSwapper = ICrvSwapper(_crvSwapper);
        gauge = _gauge;
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
        lpCrvUsdIndex = _lpCrvUsdIndex;
        lpPmUsdIndex = _lpCrvUsdIndex == int128(0) ? 1 : 0;
        crvUsdOracle = IChainlinkOracle(_crvUsdOracle);
        usdtOracle = IChainlinkOracle(_usdtOracle);
        crvOracle = IChainlinkOracle(_crvOracle);
        cachedVirtualPrice = ICurveStableSwapNG(_lpPool).get_virtual_price();
        owner = msg.sender;
    }

    // ============ Admin ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Propose a new owner (starts timelock)
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        ownerTimelockReady = block.timestamp + OWNER_TIMELOCK_DELAY;
        emit OwnerTransferProposed(owner, newOwner);
    }

    /// @notice Accept ownership (called by pending owner after timelock)
    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        if (ownerTimelockReady == 0) revert Unauthorized();
        if (block.timestamp < ownerTimelockReady) revert Unauthorized();
        if (block.timestamp > ownerTimelockReady + OWNER_TIMELOCK_EXPIRY) revert Unauthorized();

        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
        ownerTimelockReady = 0;
    }

    /// @notice Cancel pending ownership transfer
    function cancelOwnerTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert InvalidAddress();
        emit OwnerTransferCancelled(pendingOwner);
        pendingOwner = address(0);
        ownerTimelockReady = 0;
    }

    /// @notice Updates strategy slippage tolerance.
    /// @dev Callable by vault (normal operations) or owner (manual recovery/ops).
    /// @param newSlippage New slippage in 1e18 precision.
    function setSlippage(uint256 newSlippage) external {
        if (msg.sender != vault && msg.sender != owner) revert Unauthorized();
        if (newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    /// @notice Rescue ERC20 tokens that are not core strategy assets
    /// @param token Token address to rescue
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (
            token == address(debtAsset) || token == address(lpToken) || token == address(crvUSD)
                || token == address(pmUSD) || token == address(crv)
        ) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IYieldStrategy
    function underlyingAsset() external view override returns (address) {
        return address(lpToken);
    }

    /// @inheritdoc IYieldStrategy
    function name() external pure override returns (string memory) {
        return "USDT -> pmUSD/crvUSD LP Strategy";
    }

    /// @inheritdoc IYieldStrategy
    function balanceOf() public view override returns (uint256) {
        uint256 lpTokens = _rewardVaultBalance();
        if (lpTokens < 1) return 0;

        // LP -> crvUSD value via cached virtual_price (manipulation-resistant)
        uint256 virtualPrice = _getSafeVirtualPrice();
        uint256 crvUsdValue = (lpTokens * virtualPrice) / 1e18;

        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdValue, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
    }

    /// @inheritdoc IYieldStrategy
    function pendingRewards() external view override returns (uint256) {
        address accountant = rewardVault.ACCOUNTANT();
        try IAccountant(accountant).getPendingRewards(address(rewardVault), address(this)) returns (
            uint256 pendingCrv
        ) {
            if (pendingCrv < 1) return 0;

            // CRV (18 dec) -> USDT (6 dec) using CRV/USD and USDT/USD Chainlink oracles
            (uint80 crvRoundId, int256 crvPrice,, uint256 crvUpdatedAt, uint80 crvAnswered) =
                crvOracle.latestRoundData();
            if (
                crvPrice <= 0 || crvAnswered < crvRoundId
                    || block.timestamp - crvUpdatedAt > MAX_ORACLE_STALENESS
            ) {
                return crvSwapper.quote(pendingCrv) / 1e12; // fallback: LP price, crvUSD≈USDT 1:1
            }

            (uint80 usdtRoundId, int256 usdtPrice,, uint256 usdtUpdatedAt, uint80 usdtAnswered) =
                usdtOracle.latestRoundData();
            if (
                usdtPrice <= 0 || usdtAnswered < usdtRoundId
                    || block.timestamp - usdtUpdatedAt > MAX_ORACLE_STALENESS
            ) {
                return crvSwapper.quote(pendingCrv) / 1e12; // fallback: LP price, crvUSD≈USDT 1:1
            }

            return (pendingCrv * uint256(crvPrice)) / (uint256(usdtPrice) * 1e12);
        } catch {
            return 0;
        }
    }

    // ============ Internal: Core Strategy ============

    function _deposit(uint256 usdtAmount) internal override returns (uint256 underlyingDeposited) {
        // Auto-compound any pending CRV rewards
        _claimAndCompound();

        // 1. Swap USDT -> crvUSD
        _swapUsdtToCrvUsd(usdtAmount, slippageTolerance);

        // 2. Add liquidity (all crvUSD + any pmUSD rewards in contract)
        uint256 lpReceived = _addLiquidity();

        // 3. Stake LP tokens in reward vault
        _depositToRewardVault(lpReceived);

        _updateCachedVirtualPrice();

        // Return value in USDT terms
        underlyingDeposited = lpReceived;
    }

    function _withdraw(uint256 usdtAmount) internal override returns (uint256 usdtReceived) {
        // Auto-compound any pending CRV rewards
        _claimAndCompound();

        uint256 currentValue = balanceOf();
        if (currentValue < 1) return 0;

        uint256 shares = rewardVault.balanceOf(address(this));
        if (shares < 1) return 0;

        // Calculate proportional shares to redeem
        uint256 sharesToRedeem = (shares * usdtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem < 1) return 0;

        // 1. Unstake from reward vault
        uint256 lpReceived = _redeemFromRewardVault(sharesToRedeem);

        // 2. Remove liquidity (single-sided crvUSD)
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);

        // 3. Swap crvUSD -> USDT
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }

        _updateCachedVirtualPrice();
    }

    function _withdrawAll() internal override returns (uint256 usdtReceived) {
        // 1. Unstake all LP tokens
        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        // 2. Remove all liquidity for crvUSD
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, slippageTolerance);

        // 3. Swap all crvUSD -> USDT
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }

        _updateCachedVirtualPrice();
    }

    function _harvest() internal override returns (uint256 rewardsValue) {
        uint256 crvUsdCompounded = _claimAndCompound();
        rewardsValue = CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdCompounded, crvUsdOracle, usdtOracle, MAX_ORACLE_STALENESS
        );
        _updateCachedVirtualPrice();
    }

    /// @notice Claim CRV from accountant, swap to crvUSD, and compound back into LP with any pmUSD rewards
    /// @return crvUsdCompounded Amount of crvUSD compounded (0 if nothing to harvest)
    function _claimAndCompound() internal returns (uint256 crvUsdCompounded) {
        _accountantClaim();

        uint256 crvBalance = crv.balanceOf(address(this));
        if (crvBalance >= MIN_HARVEST_THRESHOLD) {
            crv.safeTransfer(address(crvSwapper), crvBalance);
            crvUsdCompounded = _swapCrv(crvBalance);
            emit RewardsHarvested(crvBalance, crvUsdCompounded);
        }

        // Compound crvUSD + any pmUSD rewards into LP
        uint256 crvUsdBal = crvUSD.balanceOf(address(this));
        uint256 pmUsdBal = pmUSD.balanceOf(address(this));
        if (crvUsdBal < 1 && pmUsdBal < 1) return crvUsdCompounded;

        uint256 lpReceived = _addLiquidity();
        _depositToRewardVault(lpReceived);
    }

    function _swapCrv(uint256 amount) internal returns (uint256 crvUsdReceived) {
        try crvSwapper.swap(amount) returns (uint256 received) {
            crvUsdReceived = received;
        } catch {
            revert SwapFailed();
        }
    }

    function _accountantClaim() internal {
        address accountant = rewardVault.ACCOUNTANT();
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        bytes[] memory harvestData = new bytes[](1);
        harvestData[0] = bytes("");
        // NoPendingRewards is expected when nothing has accrued yet
        try IAccountant(accountant).claim(gauges, harvestData, address(this)) { } catch { }
    }

    function _emergencyWithdraw() internal override returns (uint256 usdtReceived) {
        // 1. Unstake all LP tokens
        uint256 lpReceived = _redeemAllFromRewardVault();
        if (lpReceived < 1) return 0;

        // 2. Remove all liquidity with emergency slippage
        uint256 crvUsdReceived = _removeLiquidity(lpReceived, EMERGENCY_SLIPPAGE);

        // 3. Swap all crvUSD -> USDT with emergency slippage
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, EMERGENCY_SLIPPAGE);
        }

        _updateCachedVirtualPrice();
    }

    // ============ Internal: Virtual Price Cache ============

    /// @notice Get manipulation-resistant virtual price, bounded by ±MAX_VP_DEVIATION from cache
    /// @dev Prevents same-block manipulation of get_virtual_price() from affecting share accounting or LP floors
    function _getSafeVirtualPrice() internal view returns (uint256) {
        uint256 cached = cachedVirtualPrice;
        uint256 current = lpPool.get_virtual_price();
        if (cached == 0) return current;

        uint256 maxDeviation = (cached * MAX_VP_DEVIATION) / PRECISION;
        uint256 upperBound = cached + maxDeviation;
        uint256 lowerBound = cached > maxDeviation ? cached - maxDeviation : 0;

        if (current > upperBound) return upperBound;
        if (current < lowerBound) return lowerBound;
        return current;
    }

    /// @notice Update cached virtual price using bounded value
    /// @dev Only moves cache by MAX_VP_DEVIATION per call, preventing manipulation from poisoning the cache
    function _updateCachedVirtualPrice() internal {
        cachedVirtualPrice = _getSafeVirtualPrice();
    }

    // ============ Internal: LP Operations ============

    /// @notice Add all crvUSD and pmUSD balances as liquidity to pmUSD/crvUSD pool
    function _addLiquidity() internal returns (uint256 lpReceived) {
        uint256 crvUsdAmount = crvUSD.balanceOf(address(this));
        uint256 pmUsdAmount = pmUSD.balanceOf(address(this));
        if (crvUsdAmount == 0 && pmUsdAmount == 0) return 0;

        if (crvUsdAmount > 0) _ensureApprove(address(crvUSD), address(lpPool), crvUsdAmount);
        if (pmUsdAmount > 0) _ensureApprove(address(pmUSD), address(lpPool), pmUsdAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(lpCrvUsdIndex))] = crvUsdAmount;
        amounts[lpPmUsdIndex] = pmUsdAmount;

        uint256 expectedLp = lpPool.calc_token_amount(amounts, true);
        uint256 minLp = (expectedLp * (PRECISION - LP_SLIPPAGE)) / PRECISION;

        // Oracle floor using cached VP (immune to same-block manipulation)
        // Both crvUSD and pmUSD are stablecoins (~$1 each, 18 decimals)
        uint256 safeVP = _getSafeVirtualPrice();
        uint256 totalValue = crvUsdAmount + pmUsdAmount;
        uint256 oracleMinLp =
            (totalValue * PRECISION * (PRECISION - LP_SLIPPAGE)) / (safeVP * PRECISION);
        if (oracleMinLp > minLp) minLp = oracleMinLp;

        lpReceived = lpPool.add_liquidity(amounts, minLp);
        emit LiquidityAdded(crvUsdAmount, pmUsdAmount, lpReceived);
    }

    /// @notice Remove single-sided crvUSD liquidity from pmUSD/crvUSD pool
    function _removeLiquidity(uint256 lpAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedOut = lpPool.calc_withdraw_one_coin(lpAmount, lpCrvUsdIndex);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        // Oracle floor using cached VP (immune to same-block manipulation)
        uint256 safeVP = _getSafeVirtualPrice();
        uint256 oracleMinOut =
            (lpAmount * safeVP * (PRECISION - slippage)) / (PRECISION * PRECISION);
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        _ensureApprove(address(lpToken), address(lpPool), lpAmount);
        crvUsdReceived = lpPool.remove_liquidity_one_coin(lpAmount, lpCrvUsdIndex, minOut);
        emit LiquidityRemoved(lpAmount, crvUsdReceived);
    }

    // ============ Internal: USDT/crvUSD Swaps ============

    function _swapUsdtToCrvUsd(uint256 usdtAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        _ensureApprove(address(debtAsset), address(usdtCrvUsdPool), usdtAmount);
        crvUsdReceived = CurveUsdtSwapLib.swapUsdtToCrvUsd(
            usdtCrvUsdPool,
            usdtIndex,
            crvUsdIndex,
            usdtAmount,
            slippage,
            usdtOracle,
            crvUsdOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    function _swapCrvUsdToUsdt(uint256 crvUsdAmount, uint256 slippage)
        internal
        returns (uint256 usdtReceived)
    {
        _ensureApprove(address(crvUSD), address(usdtCrvUsdPool), crvUsdAmount);
        usdtReceived = CurveUsdtSwapLib.swapCrvUsdToUsdt(
            usdtCrvUsdPool,
            crvUsdIndex,
            usdtIndex,
            crvUsdAmount,
            slippage,
            crvUsdOracle,
            usdtOracle,
            MAX_ORACLE_STALENESS
        );
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }
}
