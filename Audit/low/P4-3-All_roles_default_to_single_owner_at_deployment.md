# P4-3: All roles default to single owner at deployment
**Severity**: LOW
**Contract(s)**: Zenji.sol
**Function(s)**: `constructor()`
**Category**: Admin Centralization / Deployment

## Description

All three roles (strategist, gov, guardian) are initialized to the same `_owner` address at deployment:

```solidity
strategist = _owner;
gov = _owner;
guardian = _owner;
```

This is passed through the implementation constructor as a single `_owner` parameter. There is no enforced separation of roles — a single address controls all administrative functions from day one.

### Implications

- **Single point of failure**: Compromise of the owner address = full protocol control
- **No defense-in-depth**: No role separation means no independent veto capability at deployment
- **Operational simplicity**: Easy to manage for early-stage protocol

### Role Permissions Summary

| Role | Powers |
|------|--------|
| **Strategist** | `setIdle()`, `withdrawFees()`, calls `setSlippage()` via vault |
| **Gov** | `proposeSwapper()`, `setParam()`, `transferRole()`, `executeParamChange()`, `cancelEmergencyMode()`, `cancelSwapper()`, `cancelRole()` |
| **Guardian** | `enterEmergencyMode()`, `emergencyStep()`, `emergencySkipStep()`, `rescueAssets()`, `emergencyRescue()`, `guardianCancelRole()`, `guardianCancelSwapper()` |

## Impact

- **Full control from single key**: Any single key compromise gives full admin access
- **Fee drain**: Strategist can withdraw all accumulated fees immediately
- **Emergency exit**: Guardian can liquidate and capture strategy assets
- **Swapper change**: Gov can swap to malicious swapper (1-week timelock)

## Recommendation

1. **Document expected role separation**: Add deployment documentation showing recommended multisig separation
2. **Add a `distributeRoles()` utility**: One-call function to set all three roles at once
3. **Consider a "roles distributed" flag**: Once all three roles are different, lock the initial single-owner state

## Notes

- This is a common pattern in DeFi vaults (e.g., Yearn, Convex)
- The protocol's defense mechanisms (timelocks, guardian veto) compensate for initial centralization
- The 4-week gov/guardian transfer delay provides a safety net even from a single compromised owner
