// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Zenji } from "../Zenji.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Zenji vault implementation for WBTC/USDT using pmUSD/crvUSD strategy
contract ZenjiWbtcPmUsd is Zenji {
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    constructor(
        address _loanManager,
        address _yieldStrategy,
        address _swapper,
        address _owner,
        address _viewHelper
    ) Zenji(WBTC, USDT, _loanManager, _yieldStrategy, _swapper, _owner, _viewHelper) { }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Zen WBTC (pmUSD/crvUSD StakeDao) ";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "zenWBTC-pmUSDcrvUSDStake";
    }

    /// @notice 1e4 sat = 0.0001 BTC ≈ $10 dead capital (at $100K/BTC).
    /// Attack cost: ~$10. Dilution: ~10 bps at $10K TVL, ~1 bp at $100K TVL.
    function VIRTUAL_SHARE_OFFSET() public pure override returns (uint256) {
        return 1e4;
    }

    /// @notice 1e4 sat = 0.0001 BTC ≈ $10 at $100K/BTC.
    /// Must be >= VIRTUAL_SHARE_OFFSET to preserve inflation-attack economics.
    function MIN_DEPOSIT() public pure override returns (uint256) {
        return 1e4;
    }
}
