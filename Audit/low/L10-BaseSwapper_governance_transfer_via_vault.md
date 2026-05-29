# L10: BaseSwapper transferGovFromVault bypasses two-step
**Severity**: LOW
**Contract(s)**: BaseSwapper.sol
**Function(s)**: transferGovFromVault
**Category**: Governance / Transfer

## Description
transferGovFromVault allows the registered vault to directly transfer governance without the two-step acceptGovernance pattern. The vault address is set once via setVault during deployment. If a new vault is deployed, the old vault's address is still the registered one.

## Impact
Low. The vault is immutable per deployment. The vault can only transfer gov to a new address during its own lifetime.

## Recommendation
Consider adding a setVault(address) function callable by the current gov to allow updating the vault address for migrations.
