# P4-2: Sequential role transfers allow full takeover in ~5 weeks
**Severity**: MEDIUM
**Contract(s)**: Zenji.sol
**Function(s)**: `transferRole()`, `acceptRole()`
**Category**: Admin Centralization / Role Transfer

## Description

A compromised gov can sequentially transfer all three roles with the following timeline:

| Step | Action | Delay | Cumulative |
|------|--------|-------|------------|
| 1 | Gov initiates `transferRole(1, attacker)` (gov transfer) | 4 weeks | Week 4 |
| 2 | Attacker accepts gov role | 0 | Week 4 |
| 3 | Attacker initiates `transferRole(0, attacker)` (strategist) | 1 week | Week 5 |
| 4 | Attacker initiates `transferRole(2, attacker)` (guardian) | 4 weeks | Week 8 |

### Worst Case: Full Takeover in 8 Weeks

After the initial gov compromise, the attacker becomes gov at week 4, then strategist at week 5, and guardian at week 8. At week 8, the attacker controls all roles:
- **Strategist**: `setIdle()`, `withdrawFees()`
- **Gov**: `proposeSwapper()`, `setParam()`, `transferRole()`, `cancelEmergencyMode()`
- **Guardian**: `enterEmergencyMode()`, `emergencyStep()`, `rescueAssets()`

### Fastest Case: 5 Weeks (if guardian doesn't veto)

If the guardian doesn't actively monitor or veto, the attacker can complete all transfers in 5 weeks (4 weeks for gov + 1 week for strategist, since guardian transfer can happen in parallel after gov acceptance).

### Defender Window

The guardian can veto any transfer at any time via `guardianCancelRole(role)`. This requires:
1. Guardian is NOT compromised
2. Guardian is actively monitoring
3. Guardian acts within the delay window

### Impact

- **Full protocol control**: After 8 weeks, attacker controls all roles
- **Strategist transfer is fast**: Only 1 week — attacker can immediately drain fees or set idle
- **Swapper change is fast**: 1-week timelock + gov-only → attacker can change swapper at week 5
- **Param changes**: Adverse changes (fee increase, LTV increase) have 1-week timelock

## Proof of Concept / Steps to Reproduce

```
Week 0:   Compromised gov calls transferRole(1, attacker)
Week 4:   Attacker calls acceptRole(1) — now gov
Week 4:   Attacker calls transferRole(0, attacker) and transferRole(2, attacker)
Week 5:   Attacker calls acceptRole(0) — now also strategist
Week 8:   Attacker calls acceptRole(2) — now also guardian
Week 8:   Attacker controls all roles
```

## Recommendation

1. **Increase strategist transfer delay**: Consider 4 weeks for strategist too, matching gov/guardian. The strategist has immediate access to fees and idle mode.
2. **Add a "freeze" mechanism**: Guardian can freeze all role transfers (not just cancel) for an extended period.
3. **Document the takeover timeline**: Add a `MAX_TAKEOVER_TIME` constant or documentation in the vault.

## Notes

- The 4-week gov/guardian delay was designed so a compromised gov can't short-circuit the guardian veto window
- The 1-week strategist delay was considered sufficient since strategist has limited power
- In practice, the 1-week delay means an attacker can drain fees before the guardian notices
