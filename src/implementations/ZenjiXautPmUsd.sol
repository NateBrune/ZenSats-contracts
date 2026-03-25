// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Zenji } from "../Zenji.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Zenji vault implementation for XAUT/USDT using pmUSD/crvUSD strategy
/// @dev XAUT (Tether Gold) has 6 decimals. eMode category 43 ("XAUt USDC USDT GHO") on Aave V3
///      enables 70% LTV when borrowing USDT against XAUT.
contract ZenjiXautPmUsd is Zenji {
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    constructor(
        address _loanManager,
        address _yieldStrategy,
        address _swapper,
        address _owner,
        address _viewHelper
    ) Zenji(XAUT, USDT, _loanManager, _yieldStrategy, _swapper, _owner, _viewHelper) { }

    /// @notice XAUT loan manager maxLtvBps = 6000 (60%); cap targetLtv to match.
    function MAX_TARGET_LTV() public pure override returns (uint256) {
        return 60e16; // 60% — matches AaveLoanManager maxLtvBps for XAUT eMode 43
    }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Zen XAUT (pmUSD/crvUSD StakeDao)";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "zenXAUT-pmUSDcrvUSDStake";
    }

    /// @notice 1e3 = 0.001 XAUT ≈ $4.50 dead capital (at $4500/oz).
    /// Attack cost: ~$4.50. Dilution: ~1 bp at $45K TVL.
    function VIRTUAL_SHARE_OFFSET() public pure override returns (uint256) {
        return 1e3;
    }

    /// @notice 2000 units = 0.002 XAUT ≈ $9 at $4500/oz.
    /// Must be >= VIRTUAL_SHARE_OFFSET to preserve inflation-attack economics.
    function MIN_DEPOSIT() public pure override returns (uint256) {
        return 2000;
    }
}
