// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Zenji } from "../../Zenji.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Zenji vault implementation for wstETH/crvUSD using LlamaLend and USDT/crvUSD strategy
contract ZenjiWstEthLlamaUsdtStakeDao is Zenji {
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    constructor(
        address _loanManager,
        address _yieldStrategy,
        address _swapper,
        address _owner,
        address _viewHelper
    ) Zenji(WSTETH, CRVUSD, _loanManager, _yieldStrategy, _swapper, _owner, _viewHelper) { }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Zen wstETH (USDT/crvUSD LlamaLend)";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "zenWstETH-LL-USDT";
    }

    /// @notice wstETH has 18 decimals — the base 1e5 provides zero protection.
    /// 3e15 = 0.003 wstETH ≈ $11.4 dead capital (at $3,800/wstETH).
    /// Matches WBTC's ~$10 dead capital. Dilution: ~11 bps at $10K TVL, ~1 bp at $100K TVL.
    function VIRTUAL_SHARE_OFFSET() public pure override returns (uint256) {
        return 3e15;
    }

    /// @notice 3e15 = 0.003 wstETH ≈ $11.4 at $3,800/wstETH.
    /// Must be >= VIRTUAL_SHARE_OFFSET to preserve inflation-attack economics.
    function MIN_DEPOSIT() public pure override returns (uint256) {
        return 3e15;
    }
}
