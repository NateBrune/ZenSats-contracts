# ZenSats Audit Plan

> **Audit Target**: ZenSats (Zenji) — ERC4626 Collateral Yield Vault  
> **Chain**: Ethereum Mainnet  
> **Auditor**: AI-assisted manual review  
> **Date**: 2026-04-27

---

## Protocol Overview

ZenSats is a conservative collateral yield vault that:
1. Accepts collateral (WBTC, wstETH, XAUT) from users
2. Borrows USDT against it on Aave V3 (or crvUSD on LlamaLend)
3. Deploys borrowed stablecoins into yield strategies (pmUSD/crvUSD LP + StakeDAO, IPOR, or Tokemak)
4. Returns the spread (yield - borrow cost) to vault shareholders

**Deployed Vaults**:
- WBTC → USDT debt → pmUSD/crvUSD LP (Aave)
- wstETH → USDT debt → pmUSD/crvUSD LP (Aave)
- XAUT → USDT debt → pmUSD/crvUSD LP (Aave)
- WBTC → crvUSD debt → pmUSD/crvUSD LP (LlamaLend)
- wstETH → crvUSD debt → pmUSD/crvUSD LP (LlamaLend)

---

## Audit Phases

### Phase 1: Find All Potential Bugs (Current Phase)
Systematic review of every contract surface for individual vulnerability patterns. Findings are stored in `./Audit/{high,medium,low,info}/` as markdown files.

### Phase 2: Compose Attack Chains
Try to chain individual findings from Phase 1 into multi-step exploits with greater impact. Documents stored alongside Phase 1 findings.

### Phase 3: Proof-of-Concept (PoC)
Write Foundry fork tests that demonstrate exploitability for the most impactful findings from Phase 1 + Phase 2.

### Phase 4: Admin Centralization & Key Management
Review governance model, role permissions, multisig/key assumptions, and recovery procedures.

---

## Contracts Under Audit

### Core Vault
| Contract | File | Description |
|----------|------|-------------|
| `Zenji` | `src/Zenji.sol` | Main ERC4626 vault (~1500 lines) |
| `ZenjiViewHelper` | `src/ZenjiViewHelper.sol` | External view helper contract |

### Loan Managers
| Contract | File | Description |
|----------|------|-------------|
| `AaveLoanManager` | `src/lenders/AaveLoanManager.sol` | Aave V3 loan management |
| `LlamaLoanManager` | `src/lenders/LlamaLoanManager.sol` | LlamaLend loan management |

### Yield Strategies
| Contract | File | Description |
|----------|------|-------------|
| `BaseYieldStrategy` | `src/strategies/BaseYieldStrategy.sol` | Abstract base |
| `BaseCurveRewardVaultStrategy` | `src/strategies/BaseCurveRewardVaultStrategy.sol` | StakeDAO reward vault base |
| `BasePmUsdCrvUsdStrategy` | `src/strategies/BasePmUsdCrvUsdStrategy.sol` | pmUSD/crvUSD LP base |
| `UsdtPmUsdCrvUsdStrategy` | `src/strategies/UsdtPmUsdCrvUsdStrategy.sol` | USDT variant (swaps USDT→crvUSD) |
| `PmUsdCrvUsdStrategy` | `src/strategies/PmUsdCrvUsdStrategy.sol` | crvUSD variant (native) |
| `UsdtIporYieldStrategy` | `src/strategies/UsdtIporYieldStrategy.sol` | USDT → IPOR PlasmaVault |
| `IporYieldStrategy` | `src/strategies/IporYieldStrategy.sol` | crvUSD → IPOR |
| `TokemakYieldStrategy` | `src/strategies/TokemakYieldStrategy.sol` | Tokemak Autopool |

### Swappers
| Contract | File | Description |
|----------|------|-------------|
| `BaseSwapper` | `src/swappers/base/BaseSwapper.sol` | Shared swapper governance |
| `UniversalRouterV3SingleHopSwapper` | `src/swappers/base/UniversalRouterV3SingleHopSwapper.sol` | Uniswap URv3 single-hop |
| `UniswapV3TwoHopSwapper` | `src/swappers/base/UniswapV3TwoHopSwapper.sol` | Uniswap V3 two-hop |
| `UniswapMixedCurveSwapper` | `src/swappers/base/UniswapMixedCurveSwapper.sol` | Uniswap + Curve mixed |
| `UniswapMixedTwoHopSwapper` | `src/swappers/base/UniswapMixedTwoHopSwapper.sol` | Two-hop mixed |
| `CurveTwoCryptoSwapper` | `src/swappers/base/CurveTwoCryptoSwapper.sol` | Curve TwoCrypto |
| `CurveThreeCryptoSwapper` | `src/swappers/base/CurveThreeCryptoSwapper.sol` | Curve ThreeCrypto |
| `CbBtcWbtcUsdtSwapper` | `src/swappers/base/CbBtcWbtcUsdtSwapper.sol` | cbBTC/WBTC/USDT |
| `CbBtcUniswapV3TwoHopSwapper` | `src/swappers/base/CbBtcUniswapV3TwoHopSwapper.sol` | cbBTC two-hop |
| `CrvToCrvUsdSwapper` | `src/swappers/reward/CrvToCrvUsdSwapper.sol` | CRV → crvUSD rewards |

### Libraries
| Contract | File | Description |
|----------|------|-------------|
| `SafeTransferLib` | `src/libraries/SafeTransferLib.sol` | USDT-safe transfers |
| `TimelockLib` | `src/libraries/TimelockLib.sol` | Timelock state management |
| `ZenjiCoreLib` | `src/libraries/ZenjiCoreLib.sol` | Emergency/rebalance library (DELEGATECALL) |
| `OracleLib` | `src/libraries/OracleLib.sol` | Chainlink oracle helpers |
| `CurveUsdtSwapLib` | `src/libraries/CurveUsdtSwapLib.sol` | USDT↔crvUSD swap logic |

### Implementations
| Contract | File | Description |
|----------|------|-------------|
| `ZenjiWbtcPmUsd` | `src/implementations/ZenjiWbtcPmUsd.sol` | WBTC vault impl |
| `ZenjiWstEthPmUsd` | `src/implementations/ZenjiWstEthPmUsd.sol` | wstETH vault impl |
| `ZenjiXautPmUsd` | `src/implementations/ZenjiXautPmUsd.sol` | XAUT vault impl |
| `ZenjiWbtc` | `src/implementations/ZenjiWbtc.sol` | WBTC (legacy, IPOR strategy) |
| `ZenjiWstEth` | `src/implementations/ZenjiWstEth.sol` | wstETH (legacy, IPOR strategy) |
| `ZenjiCbBtc` | `src/implementations/ZenjiCbBtc.sol` | cbBTC vault impl |
| `ZenjiWbtcCrvUsdPmUsd` | `src/implementations/ZenjiWbtcCrvUsdPmUsd.sol` | WBTC Llama impl |
| `ZenjiWstEthCrvUsdPmUsd` | `src/implementations/ZenjiWstEthCrvUsdPmUsd.sol` | wstETH Llama impl |

### Supporting
| Contract | File | Description |
|----------|------|-------------|
| `WstEthOracle` | `src/WstEthOracle.sol` | Custom wstETH/USD oracle |
| `ZenjiRebalanceKeeper` | `src/keepers/ZenjiRebalanceKeeper.sol` | Chainlink Automation keeper |

---

## Phase 1: Systematic Review Checklist

Each finding is documented as a markdown file in `./Audit/<severity>/ID-title.md` with the following template:

```markdown
# [ID] Short Title
**Severity**: HIGH | MEDIUM | LOW | INFO
**Contract(s)**: ContractName.sol
**Function(s)**: functionName()
**Category**: <Access Control | Reentrancy | Oracle Manipulation | Arithmetic | ERC4626 | Logic | Flash Loan | Gas | Centralization>

## Description
What is the issue?

## Impact
Who/what is affected and how?

## Proof of Concept / Steps to Reproduce
How can this be triggered?

## Recommendation
How to fix it?
```

### 1A. Access Control Review
- [ ] All role-gated functions (strategist, gov, guardian, vault)
- [ ] Role transfer flow (two-step acceptance pattern)
- [ ] Pending role override races
- [ ] Governor/Guardian cancel interactions
- [ ] Strategy `transferOwnerFromVault` and `setSlippage` access
- [ ] Swapper governance access
- [ ] `rescueAssets` / `rescueERC20` / `rescueToken` paths
- [ ] `authorizedCaller` on CrvToCrvUsdSwapper
- [ ] `initializer` single-use pattern on loan managers and strategies
- [ ] Keeper `transferOwnership` (no timelock)

### 1B. Reentrancy Review
- [ ] All external entry points with `nonReentrant` guards
- [ ] Cross-contract reentrancy (Vault → Strategy → Vault)
- [ ] Flash loan callback reentrancy (AaveLoanManager.executeOperation)
- [ ] LlamaLend flashloan callback reentrancy (onFlashLoan)
- [ ] Swapper reentrancy (no explicit guards on swap functions)
- [ ] DELEGATECALL reentrancy via ZenjiCoreLib

### 1C. Oracle Manipulation Review
- [ ] Staleness checks on all oracles
- [ ] Price manipulation via Curve pool imbalance
- [ ] `get_dy` manipulation in swap minOut calculations
- [ ] Virtual price cache manipulation (MAX_VP_DEVIATION bounds)
- [ ] Oracle price divergence between vault and loan manager
- [ ] WstEthOracle multi-feed staleness handling
- [ ] Single-block oracle flash attacks
- [ ] USDT/crvUSD stablecoin depeg scenarios

### 1D. ERC4626 Compliance Review
- [ ] `convertToShares` / `convertToAssets` symmetry
- [ ] `previewDeposit` / `previewMint` / `previewWithdraw` / `previewRedeem` accuracy
- [ ] `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` correctness
- [ ] VIRTUAL_SHARE_OFFSET usage and edge cases
- [ ] Rounding behavior (round-up vs round-down per spec)
- [ ] `totalAssets()` accuracy during strategy operations
- [ ] Fee accrual interaction with share pricing
- [ ] Post-liquidation pro-rata distribution math
- [ ] Allowance handling in `_redeemStandard`

### 1E. Flash Loan Review
- [ ] Aave flashloan callback (executeOperation) access control
- [ ] Flashloan repayment assurance
- [ ] Partial unwind flashloan escalation logic
- [ ] LlamaLend flashloan (DEBT_FLASH_LENDER hardcoded)
- [ ] Flashloan-based liquidation in Aave
- [ ] Rebalance flash loan attack vectors

### 1F. Arithmetic & Precision Review
- [ ] Decimal mismatch (WBTC 8-dec, USDT 6-dec, crvUSD 18-dec)
- [ ] Overflow/underflow in multiplications
- [ ] Division rounding direction
- [ ] `PRECISION = 1e18` vs Aave BPS math
- [ ] Cost basis tracking in strategies
- [ ] Fee calculation precision

### 1G. Logic Bugs Review
- [ ] Emergency mode flow (one-way latch, step ordering)
- [ ] `emergencySkipStep` two-call pattern with delay
- [ ] `cancelEmergencyMode` guard conditions
- [ ] Idle mode enter/exit flow
- [ ] `_deployCapital` and `_unwindPosition` paths
- [ ] `_accrueYieldFees` checkpoint logic
- [ ] `rebalance()` LTV + coverage trigger logic
- [ ] Rebalance bounty calculation
- [ ] `_swapRemainingDebtToCollateral` floor checks
- [ ] `_computeEffectiveSlippage` logic
- [ ] COOLDOWN_BLOCKS / `_cooling` mechanism
- [ ] `lastInBlock` dust grief vector
- [ ] `setParam` adverse vs favorable timelock branching
- [ ] `executeParamChange` re-validation
- [ ] Strategy debt coverage rebalance (rebalanceCoverageUp/Down)

### 1H. State Invariant Review
- [ ] `liquidationComplete` can only be set true
- [ ] `emergencyMode` one-way latch
- [ ] `lastStrategyBalance` consistency after strategy ops
- [ ] `accumulatedFees` capping to strategy balance
- `feesAtLastRebalance` tracking
- [ ] `emergencyStepsCompleted` bitmask logic
- [ ] Pending skip timestamps consistency

### 1I. Cross-Contract Interaction Review
- [ ] Vault → AaveLoanManager → Aave Pool
- [ ] Vault → LlamaLoanManager → LlamaLend Controller
- [ ] Vault → YieldStrategy → Curve LP → StakeDAO
- [ ] Vault → Swapper → Uniswap Universal Router
- [ ] Strategy → CrvToCrvUsdSwapper → Curve TriCrypto
- [ ] ZenjiCoreLib DELEGATECALL return value handling
- [ ] ViewHelper read-only guarantees
- [ ] RebalanceKeeper → Vault.rebalance()

### 1J. Gas & Edge Cases
- [ ] USDT transfer without return value
- [ ] SafeTransferLib handling of non-standard ERC20
- [ ] Zero-amount edge cases
- [ ] `type(uint256).max` as "fully close" sentinel
- [ ] `safeApprove` zero-then-set pattern for USDT
- [ ] Timelock expiry windows
- [ ] `ensureApproval` max approval pattern

### 1K. Deployment & Configuration
- [ ] Constructor validation completeness
- [ ] Immutable configuration correctness
- [ ] Default parameter safety
- [ ] Virtual function overrides in implementations
- [ ] `MAX_TARGET_LTV()` override per vault

---

## Phase 2: Attack Chain Composition

After Phase 1 is complete, revisit all findings and attempt to combine them:

### Completed Attack Chains

| # | Chain | Tests | Status | Notes |
|---|-------|-------|--------|-------|
| AC1 | VP Cache + LP Manipulation | 1 | ✅ PASS | Manipulate pmUSD/crvUSD pool → VP spikes → inflated withdraw |
| AC3 | Stale Oracle → Full Freeze | 4 | ✅ PASS | Oracle stale → balanceOf reverts → all ops frozen, emergency also broken |
| AC6 | Swapper Reentrancy | 1 | ✅ PASS | Malicious swapper in Aave flashloan callback |

### Pending Attack Chains

1. **Oracle Manipulation + Reentrancy**: Can oracle manipulation be combined with reentrancy to extract value?
2. **Flash Loan + Emergency Mode**: Can flash loans be used during emergency mode to front-run liquidation?
3. **Fee Timing + Withdrawal**: Can fee accrual timing be exploited during large withdrawals?
4. **Role Transfer + Parameter Change**: Can pending role transfers be combined with adverse parameter changes?
5. **Cooldown Bypass**: Can the 1-block cooldown be bypassed via allowances or approvals?
6. **Strategy Debt Coverage + LTV**: Can coverage imbalance be exploited to force unfavorable rebalances?

### Additional Attack Chain Candidates

- **Multi-hop Slippage + Partial Unwind**: CbBtc multi-hop with 1% slippage → 2% effective → partial withdraw absorbs slippage
- **Cost Basis + Withdraw**: VP drops → balanceOf underestimates → withdraw reduces cost basis too much

---

## Phase 3: Proof-of-Concept Development

For each HIGH and MEDIUM finding, write a Foundry fork test:

```solidity
// test/Audit/ID-title.fork.t.sol
contract AuditIdTest is ForkTest {
    function testExploit() public {
        // Setup, exploit, verify impact
    }
}
```

### Completed PoCs

| Finding | Tests | Status | Notes |
|---------|-------|--------|-------|
| M1: Llama partial unwind | 3 | ✅ PASS | Fixed Accountant.claim mock mismatch |
| M2: USDT stuck crvUSD | 2 | ⚠️ DISMISSED | EVM revert undoes all state changes |
| M3: DEBT_FLASH_LENDER staleness | 5 | ✅ PASS | Oracle staleness during flash loan |
| M4: VP cache staleness | 3 | ✅ PASS | Cached virtual price manipulation |
| M6: balanceOf stale oracle | 5 | ✅ PASS | Stale oracle + balanceOf manipulation |
| M9: SafeTransferLib USDT zero-reset | 6 | ✅ PASS | USDT transfer zero-reset behavior |
| M11: CbBtc multi-hop slippage | 2 | ✅ PASS | Per-hop slippage compounds to ~2x |

---

## Phase 4: Admin Centralization & Key Management

1. **Role Distribution**: Are gov, strategist, guardian on separate multisigs?
2. **Key Management**: What multisig/signer setup is used?
3. **Timelock Effectiveness**: Are all timelock windows meaningful?
4. **Emergency Response**: Can guardian act independently?
5. **Recovery Procedures**: What happens if all roles are compromised?
6. **Swapper Timelock**: 1-week window adequacy for infrastructure changes?
7. **Strategy Owner Propagation**: Does `transferOwnerFromVault` keep in sync?

---

## Known Risk Factors (from protocol docs)

- Multi-protocol smart contract risk (Aave, Curve, StakeDAO, LlamaLend)
- Stablecoin depeg risk (crvUSD, pmUSD, USDT)
- Pool liquidity and withdrawal risk
- Liquidation risk during extreme market moves
- Oracle manipulation during low-liquidity periods

---

## Audit Folder Structure

```
Audit/
├── AUDIT_PLAN.md          (this file)
├── high/                  (critical/high severity findings)
├── medium/                (medium severity findings)
├── low/                   (low severity findings)
└── info/                  (informational findings, gas optimizations)
```

---

## Progress Tracker

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Bug Finding | ✅ Complete | 43 findings documented (0 HIGH, 13 MEDIUM, 25 LOW, 5 INFO). Verified and downgraded after code review. See Audit/summary.md |
| Phase 2: Attack Chains | ⏳ In Progress | 3 PoCs written (AC1, AC3, AC6). 4 candidates pending. See Audit/summary.md |
| Phase 3: PoC | ✅ Complete | M1✅ (3/3), M2⚠️ dismissed (EVM revert undoes transfers), M3✅ (5/5), M4✅ (3/3), M6✅ (5/5), M9✅ (6/6), M11✅ (2/2). 6/7 findings demonstrated. |
| Phase 4: Centralization | ✅ Complete | 11 findings (2M, 9L). See Audit/summary.md |
| Phase 2: Attack Chains | ⏳ In Progress | 3 PoCs completed (AC1, AC3, AC6). See Audit/phase2-attack-chains.md |

## Next Steps

1. **Phase 2** (Attack Chains) — Write PoCs for 4 remaining attack chain candidates
2. **Phase 1** (Bug Finding) — Complete remaining checklist items (see 1A-1K below)
3. **Remediation** — Address HIGH/MEDIUM findings in code
4. **Retest** — Verify fixes with fork tests
5. **Final Report** — Compose executive summary and full audit report
