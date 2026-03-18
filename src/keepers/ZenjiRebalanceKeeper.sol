// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { AutomationCompatibleInterface } from "../interfaces/AutomationCompatibleInterface.sol";
import { ILoanManager } from "../interfaces/ILoanManager.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

interface IZenjiKeeperTarget {
    function loanManager() external view returns (ILoanManager);
    function targetLtv() external view returns (uint256);
    function DEADBAND_SPREAD() external view returns (uint256);
    function idle() external view returns (bool);
    function emergencyMode() external view returns (bool);
    function rebalance() external;
}

/// @title ZenjiRebalanceKeeper
/// @notice Chainlink Automation receiver that triggers `Zenji.rebalance()` when LTV exits deadband
contract ZenjiRebalanceKeeper is AutomationCompatibleInterface {
    using SafeTransferLib for IERC20;

    IZenjiKeeperTarget public immutable vault;
    address public owner;

    error Unauthorized();
    error InvalidAddress();

    event UpkeepPerformed(uint256 currentLtv, uint256 lowerBand, uint256 upperBand);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ERC20Drained(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address vault_, address owner_) {
        if (vault_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        vault = IZenjiKeeperTarget(vault_);
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (upkeepNeeded, performData) = _shouldRebalance();
    }

    function performUpkeep(bytes calldata) external override {
        (bool needed, bytes memory data) = _shouldRebalance();
        if (!needed) return;

        (uint256 currentLtv, uint256 lowerBand, uint256 upperBand) =
            abi.decode(data, (uint256, uint256, uint256));

        vault.rebalance();
        emit UpkeepPerformed(currentLtv, lowerBand, upperBand);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function drainERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert InvalidAddress();

        IERC20(token).safeTransfer(to, amount);
        emit ERC20Drained(token, to, amount);
    }

    function _shouldRebalance()
        internal
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (vault.idle() || vault.emergencyMode()) return (false, bytes(""));

        ILoanManager loanManager_ = vault.loanManager();
        if (!loanManager_.loanExists()) return (false, bytes(""));

        try loanManager_.checkOracleFreshness() {
            uint256 currentLtv = loanManager_.getCurrentLTV();
            uint256 target = vault.targetLtv();
            uint256 spread = vault.DEADBAND_SPREAD();

            uint256 lowerBand = target > spread ? target - spread : 0;
            uint256 upperBand = target + spread;

            if (currentLtv < lowerBand || currentLtv > upperBand) {
                return (true, abi.encode(currentLtv, lowerBand, upperBand));
            }
            return (false, bytes(""));
        } catch {
            return (false, bytes(""));
        }
    }
}
