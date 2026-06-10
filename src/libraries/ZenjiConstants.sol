// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ZenjiConstants
/// @notice Single source of truth for the governance/validation constants shared by the vault
///         core (Zenji), its admin facet (ZenjiAdmin), and the gov param library (ZenjiGovLib).
/// @dev I-01: previously these values were re-declared in all three places, creating a silent
///      divergence risk. They now live here once. ZenjiStorage re-exports the public-ABI ones as
///      `public constant X = ZenjiConstants.X` (inherited by Zenji and ZenjiAdmin, preserving the
///      `vault.X()` getters), and ZenjiGovLib aliases the ones it uses. All references are
///      compile-time, so there is no runtime cost and the values cannot drift.
library ZenjiConstants {
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant DEADBAND_SPREAD = 3e16; // 3%
    uint256 internal constant MIN_TARGET_LTV = 15e16; // 15%
    uint256 internal constant MAX_FEE_RATE = 2e17; // 20%
    uint256 internal constant COOLDOWN_BLOCKS = 1;
    uint256 internal constant MAX_REBALANCE_BOUNTY = 5e17; // 50%
    uint256 internal constant TIMELOCK_DELAY = 1 weeks;
    uint256 internal constant MAX_VAULT_SLIPPAGE = 5e16; // 5% cap
    uint256 internal constant ROLE_TRANSFER_DELAY = 1 weeks;
    uint256 internal constant GOV_GUARDIAN_TRANSFER_DELAY = 4 weeks;
    uint256 internal constant PARAM_TIMELOCK_DELAY = 1 weeks;
    uint256 internal constant EMERGENCY_SKIP_DELAY = 3 days;
    /// @dev M-06 break-glass: delay before a gov-proposed emergency-mode entry takes effect.
    ///      Short enough to cut the guardian-key-loss blackout from 4 weeks to 2 days; long
    ///      enough for the guardian (if alive) or social response to veto a compromised gov.
    uint256 internal constant GOV_EMERGENCY_DELAY = 48 hours;
    uint256 internal constant MAX_USER_SLIPPAGE = 2e17; // 20%
    /// @dev Must match BaseYieldStrategy.MIN_SLIPPAGE (used only by ZenjiGovLib).
    uint256 internal constant MIN_VAULT_SLIPPAGE = 1e15; // 0.1%
}
