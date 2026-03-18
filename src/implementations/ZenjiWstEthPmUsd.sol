// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Zenji } from "../Zenji.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Zenji vault implementation for wstETH/USDT using pmUSD/crvUSD strategy
contract ZenjiWstEthPmUsd is Zenji {
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    constructor(
        address _loanManager,
        address _yieldStrategy,
        address _swapper,
        address _owner,
        address _viewHelper
    ) Zenji(WSTETH, USDT, _loanManager, _yieldStrategy, _swapper, _owner, _viewHelper) { }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Zen wstETH (pmUSD/crvUSD StakeDao)";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "zenWstETH-pmUSDcrvUSDStake";
    }

    /// @notice wstETH has 18 decimals — the base 1e5 provides zero protection.
    /// 3e16 = 0.03 wstETH ≈ $114 dead capital (at $3,800/wstETH).
    /// Matches WBTC's ~$100 dead capital. Dilution: ~11 bps at $100K TVL, ~1 bp at $1M TVL.
    function VIRTUAL_SHARE_OFFSET() public pure override returns (uint256) {
        return 3e16;
    }
}
