// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";
import { IYieldVault } from "../interfaces/IYieldVault.sol";
import { ICurveStableSwap } from "../interfaces/ICurveStableSwap.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title UsdtIporYieldStrategy
/// @notice Swaps USDT to crvUSD and deposits into IPOR PlasmaVault
contract UsdtIporYieldStrategy is IYieldStrategy {
    using SafeTransferLib for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEFAULT_SLIPPAGE = 1e16;
    uint256 public constant MAX_SLIPPAGE = 5e16;
    uint256 public constant EMERGENCY_SLIPPAGE = 1e17;

    IERC20 public immutable usdt;
    IERC20 public immutable crvUSD;
    ICurveStableSwap public immutable curvePool;
    IYieldVault public immutable iporVault;
    address public override vault;
    address public initializer;

    int128 public immutable usdtIndex;
    int128 public immutable crvUsdIndex;

    uint256 public slippageTolerance = DEFAULT_SLIPPAGE;
    uint256 private _costBasis;
    bool public override paused;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event SwappedUsdtToCrvUsd(uint256 usdtAmount, uint256 crvUsdReceived);
    event SwappedCrvUsdToUsdt(uint256 crvUsdAmount, uint256 usdtReceived);
    event VaultInitialized(address indexed vault);

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert StrategyPaused();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Unauthorized();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(
        address _usdt,
        address _crvUSD,
        address _vault,
        address _curvePool,
        address _iporVault,
        int128 _usdtIndex,
        int128 _crvUsdIndex
    ) {
        if (
            _usdt == address(0) || _crvUSD == address(0) || _curvePool == address(0)
                || _iporVault == address(0)
        ) {
            revert InvalidAddress();
        }
        usdt = IERC20(_usdt);
        crvUSD = IERC20(_crvUSD);
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
        curvePool = ICurveStableSwap(_curvePool);
        iporVault = IYieldVault(_iporVault);
        usdtIndex = _usdtIndex;
        crvUsdIndex = _crvUsdIndex;
        _status = _NOT_ENTERED;
    }

    function initializeVault(address _vault) external {
        if (vault != address(0)) revert InvalidAddress();
        if (_vault == address(0)) revert InvalidAddress();
        if (msg.sender != initializer) revert Unauthorized();

        vault = _vault;
        initializer = address(0);
        emit VaultInitialized(_vault);
    }

    function setSlippage(uint256 newSlippage) external onlyVault {
        if (newSlippage > MAX_SLIPPAGE) revert SlippageExceeded();
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    // ============ Core Functions ============

    function deposit(uint256 usdtAmount)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 underlyingDeposited)
    {
        if (usdtAmount == 0) revert ZeroAmount();

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        _costBasis += usdtAmount;

        uint256 crvUsdReceived = _swapUsdtToCrvUsd(usdtAmount, slippageTolerance);
        _ensureApprove(address(crvUSD), address(iporVault), crvUsdReceived);
        iporVault.deposit(crvUsdReceived, address(this));

        underlyingDeposited = crvUsdReceived;
        emit Deposited(usdtAmount, underlyingDeposited);
    }

    function withdraw(uint256 usdtAmount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 usdtReceived)
    {
        if (usdtAmount == 0) revert ZeroAmount();

        uint256 currentValue = balanceOf();
        if (currentValue == 0) return 0;
        if (usdtAmount > currentValue) usdtAmount = currentValue;

        uint256 basisReduction = (_costBasis * usdtAmount) / currentValue;

        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        uint256 sharesToRedeem = (shares * usdtAmount) / currentValue;
        if (sharesToRedeem > shares) sharesToRedeem = shares;
        if (sharesToRedeem == 0) return 0;

        uint256 crvUsdReceived = iporVault.redeem(sharesToRedeem, address(this), address(this));
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }

        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;

        if (usdtReceived > 0) {
            usdt.safeTransfer(vault, usdtReceived);
        }

        emit Withdrawn(usdtAmount, usdtReceived);
    }

    function withdrawAll()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 usdtReceived)
    {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        uint256 crvUsdReceived = iporVault.redeem(shares, address(this), address(this));
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, slippageTolerance);
        }

        _costBasis = 0;
        if (usdtReceived > 0) {
            usdt.safeTransfer(vault, usdtReceived);
        }

        emit Withdrawn(type(uint256).max, usdtReceived);
    }

    function harvest()
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 rewardsValue)
    {
        emit Harvested(0);
        return 0;
    }

    function emergencyWithdraw()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 usdtReceived)
    {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;

        uint256 crvUsdReceived = iporVault.redeem(shares, address(this), address(this));
        if (crvUsdReceived > 0) {
            usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, EMERGENCY_SLIPPAGE);
        }

        _costBasis = 0;
        if (usdtReceived > 0) {
            usdt.safeTransfer(vault, usdtReceived);
        }

        emit EmergencyWithdrawn(usdtReceived);
    }

    function pauseStrategy()
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 usdtReceived)
    {
        paused = !paused;

        if (paused) {
            uint256 shares = iporVault.balanceOf(address(this));
            if (shares > 0) {
                uint256 crvUsdReceived = iporVault.redeem(shares, address(this), address(this));
                if (crvUsdReceived > 0) {
                    usdtReceived = _swapCrvUsdToUsdt(crvUsdReceived, EMERGENCY_SLIPPAGE);
                }
            }

            _costBasis = 0;
            if (usdtReceived > 0) {
                usdt.safeTransfer(vault, usdtReceived);
            }
        }

        emit StrategyPauseToggled(paused, usdtReceived);
    }

    // ============ View Functions ============

    function asset() external view override returns (address) {
        return address(usdt);
    }

    function underlyingAsset() external view override returns (address) {
        return address(crvUSD);
    }

    function balanceOf() public view override returns (uint256) {
        uint256 shares = iporVault.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 crvUsdValue = iporVault.convertToAssets(shares);
        if (crvUsdValue == 0) return 0;
        return curvePool.get_dy(crvUsdIndex, usdtIndex, crvUsdValue);
    }

    function costBasis() external view override returns (uint256) {
        return _costBasis;
    }

    function unrealizedProfit() external view override returns (uint256) {
        uint256 currentValue = balanceOf();
        return currentValue > _costBasis ? currentValue - _costBasis : 0;
    }

    function pendingRewards() external pure override returns (uint256) {
        return 0;
    }

    function name() external pure override returns (string memory) {
        return "USDT -> crvUSD IPOR Strategy";
    }

    // ============ Internal ============

    function _swapUsdtToCrvUsd(uint256 usdtAmount, uint256 slippage)
        internal
        returns (uint256 crvUsdReceived)
    {
        uint256 expectedOut = curvePool.get_dy(usdtIndex, crvUsdIndex, usdtAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        _ensureApprove(address(usdt), address(curvePool), usdtAmount);
        crvUsdReceived = _exchange(usdtIndex, crvUsdIndex, usdtAmount, minOut);
        emit SwappedUsdtToCrvUsd(usdtAmount, crvUsdReceived);
    }

    function _swapCrvUsdToUsdt(uint256 crvUsdAmount, uint256 slippage)
        internal
        returns (uint256 usdtReceived)
    {
        uint256 expectedOut = curvePool.get_dy(crvUsdIndex, usdtIndex, crvUsdAmount);
        uint256 minOut = (expectedOut * (PRECISION - slippage)) / PRECISION;

        _ensureApprove(address(crvUSD), address(curvePool), crvUsdAmount);
        usdtReceived = _exchange(crvUsdIndex, usdtIndex, crvUsdAmount, minOut);
        emit SwappedCrvUsdToUsdt(crvUsdAmount, usdtReceived);
    }

    function _exchange(int128 i, int128 j, uint256 dx, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        (bool ok, bytes memory data) = address(curvePool).call(
            abi.encodeWithSignature(
                "exchange(int128,int128,uint256,uint256,address)", i, j, dx, minOut, address(this)
            )
        );
        if (!ok) {
            (ok, data) = address(curvePool).call(
                abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", i, j, dx, minOut)
            );
        }
        if (!ok || data.length < 32) revert TransferFailed();
        amountOut = abi.decode(data, (uint256));
    }

    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).ensureApproval(spender, amount);
    }
}
