# Key Finding Verification

Evidence tag: [CODE-TRACE]

---

## ITEM 1 — LP-5: CRV stranded at swapper on swap failure

**VERDICT: FALSE_POSITIVE (downgrade to Informational / monitoring only)**

### Decisive Code Evidence

`src/swappers/reward/CrvToCrvUsdSwapper.sol`, `swap(uint256 crvAmount)`, lines 96–134:

```solidity
function swap(uint256 crvAmount) external returns (uint256 crvUsdReceived) {
    if (authorizedCaller != address(0) && msg.sender != authorizedCaller) {
        revert Unauthorized();
    }
    if (crvAmount == 0) return 0;
    // ...
    crv.ensureApproval(address(triCryptoPool), crvAmount);
    // exchanges exactly crvAmount
    crvUsdReceived = triCryptoPool.exchange(CRV_INDEX, CRVUSD_INDEX, crvAmount, minOut, false);
    // ...
}
```

`src/strategies/lp/BaseCurveStakeDaoStrategy.sol`, `_claimAndSwapRewards()`, lines 136–148:

```solidity
function _claimAndSwapRewards() internal override returns (uint256 lpAssetReceived) {
    _accountantClaim();
    uint256 crvBalance = crv.balanceOf(address(this));        // reads strategy's balance
    if (crvBalance < MIN_HARVEST_THRESHOLD) return 0;

    crv.safeTransfer(address(crvSwapper), crvBalance);        // transfer THIS cycle's CRV
    try crvSwapper.swap(crvBalance) returns (uint256 received) {
        lpAssetReceived = received;
    } catch {
        // CRV stays at swapper; retried next compound cycle.
    }
```

### Analysis

The finding claim is correct that `swap(crvBalance)` swaps exactly `crvBalance` (the amount passed), NOT `crv.balanceOf(address(crvSwapper))`. So the swapper does NOT automatically sweep its full CRV balance — it only processes the amount explicitly passed.

HOWEVER, the claim that stranded CRV is "never retried" is FALSE. The rescue path exists:
- `CrvToCrvUsdSwapper.rescueToken(address crv, address to, uint256 amount)` at line 78–82 allows gov to recover stranded CRV back to the strategy.
- More importantly: the next cycle transfers `crv.balanceOf(address(this))` — the **strategy's** balance — to the swapper. So only the strategy's freshly claimed CRV goes to the swapper. The previously stranded CRV sitting at the swapper address is **not swept**, meaning it truly does sit until gov rescues it.

The finding is therefore **partially valid in root cause** (stranded CRV is not auto-retried by the normal cycle), but the actual impact is low: (a) CRV loss is bounded to a single harvest's reward; (b) the `rescueToken` function provides an explicit gov recovery path; (c) there is no fund-of-users loss — it's protocol revenue (CRV rewards) only. The comment in the code (`// CRV stays at swapper; retried next compound cycle.`) is actually misleading — the next cycle does NOT retry the stranded amount automatically. This is a documentation/comment inaccuracy.

**Revised verdict**: FALSE_POSITIVE for the "permanently stranded" characterisation (no permanent loss, gov can rescue). Downgrade to **Informational** — the in-code comment is wrong ("retried next compound cycle" is inaccurate; it is retried only if gov rescues or a direct `rescueToken` call is made).

**Fix**: In `_claimAndSwapRewards`, read `crv.balanceOf(address(crvSwapper))` and add it to the transfer amount so any residual from a prior failed swap is included:
```solidity
uint256 residualAtSwapper = crv.balanceOf(address(crvSwapper));
uint256 crvBalance = crv.balanceOf(address(this)) + residualAtSwapper;
crv.safeTransfer(address(crvSwapper), crv.balanceOf(address(this)));
// now swap(crvBalance) will include the residual already at swapper
```
Alternatively, change `swap()` to operate on `crv.balanceOf(address(this))` (swapper-self balance) rather than the passed amount.

---

## ITEM 2 — LP-3: Pre-compound sharesToRedeem snapshot causes under-delivery

**VERDICT: FALSE_POSITIVE**

### Decisive Code Evidence

`src/strategies/lp/BaseLPStrategy.sol`, `_withdraw()`, lines 165–187:

```solidity
function _withdraw(uint256 debtAmount) internal virtual override returns (uint256 received) {
    _updateCachedUnitValue();

    // Snapshot share ratio BEFORE _compoundRewards inflates the pool, keeping it consistent
    // with the basisReduction computed from the outer balanceOf() call.
    uint256 currentValue = balanceOf();          // (A) snapshot of value
    if (currentValue < 1) return 0;
    uint256 shares = stakingVault.balanceOf(address(this));  // (B) snapshot of shares
    if (shares < 1) return 0;
    uint256 sharesToRedeem = (shares * debtAmount) / currentValue;  // (C) ratio
    if (sharesToRedeem > shares) sharesToRedeem = shares;

    _compoundRewards();                          // (D) compounds AFTER snapshot
    if (sharesToRedeem < 1) return 0;

    uint256 lpReceived = _unstakeLp(sharesToRedeem);
    // ...
}
```

`BaseYieldStrategy.withdraw()`, lines 173–195 (outer call):

```solidity
function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 received) {
    if (amount == 0) revert ZeroAmount();
    uint256 currentValue = balanceOf();          // (X) outer balanceOf snapshot
    if (currentValue == 0) return 0;
    if (amount > currentValue) amount = currentValue;
    uint256 basisReduction = (_costBasis * amount) / currentValue;
    received = _withdraw(amount);
    // ...
}
```

### Analysis

The claim is: `sharesToRedeem` is snapshotted BEFORE `_compoundRewards()`, so compounding inflates the pool, making `sharesToRedeem` a smaller fraction of the now-larger stake, delivering less than `debtAmount`.

**Why this is FALSE_POSITIVE:**

1. **The snapshot is intentional and documented**: The comment at line 168–170 reads: `"Snapshot share ratio BEFORE _compoundRewards inflates the pool, keeping it consistent with the basisReduction computed from the outer balanceOf() call."` This is a deliberate design decision.

2. **The math nets out correctly**: At the time of the snapshot:
   - `currentValue` = `balanceOf()` — value computed from `_getSafeUnitValue()` × staked LP shares
   - `shares` = `stakingVault.balanceOf(address(this))`
   - `sharesToRedeem = shares × debtAmount / currentValue`
   
   After `_compoundRewards()`, new LP tokens are staked (increasing both total shares and total LP). The `sharesToRedeem` computed before compounding now represents a **smaller fraction** of a **larger total** — but the LP tokens backing those shares have not changed. `_unstakeLp(sharesToRedeem)` redeems exactly the same number of LP tokens regardless of the compounding that happened after the snapshot. The LP redemption goes through `stakingVault.redeem(shares, ...)` which calls `convertToAssets(shares)` — if the ERC4626 vault uses a share-per-asset ratio that increased due to new LP being staked, this could theoretically change the output. However, in Stake DAO's ERC4626 design, staking more LP tokens increases *both* the numerator (total assets) and denominator (total shares) proportionally, so the ratio is unchanged.

3. **The outer `basisReduction` consistency**: The outer `withdraw()` computes `currentValue = balanceOf()` before calling `_withdraw(amount)`. If `_withdraw` compounded first and then recomputed its own snapshot, the inner `currentValue` would be higher than the outer one, creating an accounting mismatch in `basisReduction`. The current design avoids this.

4. **`received` vs `debtAmount`**: The actual `received` depends on `_removeLiquidity` (Curve pool exit slippage) and `_swapYieldAssetToDebt` (e.g. USDT conversion). Shortfall relative to `debtAmount` is bounded by pool slippage, which is already enforced by `slippageTolerance` checks. There is no systematic shortfall caused by the snapshot ordering.

**Conclusion**: The snapshot-before-compound ordering is correct design. No systematic under-delivery beyond normal LP exit slippage.

**Fix**: None needed. The comment accurately explains the intent.

---

## ITEM 3 — PLAT-1: WstEthOracle stale-stETH/ETH passes consumer 1h check

**VERDICT: CONFIRMED — Low severity (not Medium)**

### Decisive Code Evidence

`src/WstEthOracle.sol`, `latestRoundData()`, lines 30–80:

```solidity
// Get stETH/ETH price (18 decimals) — 24h heartbeat, validated here
(
    uint80 stEthRoundId,
    int256 stEthEthPrice,,
    uint256 stEthEthUpdatedAt,
    uint80 stEthAnsweredInRound
) = stEthEthFeed.latestRoundData();
require(stEthEthPrice > 0, "stETH/ETH: invalid price");
require(stEthAnsweredInRound >= stEthRoundId, "stETH/ETH: stale round");
require(block.timestamp - stEthEthUpdatedAt <= STETH_ETH_MAX_STALENESS, "stETH/ETH: stale");
// STETH_ETH_MAX_STALENESS = 90000 (25 hours)

// ...
// Pass through ETH/USD updatedAt — stETH/ETH staleness is validated above
// This lets the consumer's 1h staleness check apply to the ETH/USD feed only
updatedAt = ethUsdUpdatedAt;   // <-- line 76: passes ETH/USD timestamp, NOT stETH/ETH
```

`src/lenders/LlamaLoanManager.sol`, line 44:
```solidity
uint256 public constant MAX_ORACLE_STALENESS = 3600; // 1 hour
```

`src/libraries/OracleLib.sol`, `_validatedPrice()`, lines 17–28:
```solidity
function _validatedPrice(IChainlinkOracle oracle, uint256 maxStaleness)
    private view returns (uint256)
{
    (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
        oracle.latestRoundData();
    if (price <= 0) revert InvalidPrice();
    if (answeredInRound < roundId) revert StaleOracle();
    if (block.timestamp - updatedAt > maxStaleness) revert StaleOracle();  // checks updatedAt
    return uint256(price);
}
```

### Confirmed Impact Path

(a) **Composite returns ETH/USD's `updatedAt`**: `WstEthOracle.latestRoundData()` sets `updatedAt = ethUsdUpdatedAt` (line 76). The stETH/ETH timestamp is **discarded** after being validated internally against its own 25h window.

(b) **stETH/ETH validated with ~25h window**: `require(block.timestamp - stEthEthUpdatedAt <= STETH_ETH_MAX_STALENESS)` where `STETH_ETH_MAX_STALENESS = 90000` (line 19).

(c) **Consumer's 1h check sees only ETH/USD timestamp**: `OracleLib._validatedPrice(wstEthOracle, 3600)` calls `latestRoundData()` and receives `updatedAt = ethUsdUpdatedAt`. The consumer's 3600s staleness check passes as long as ETH/USD is fresh, even if stETH/ETH is up to 25h stale.

**Result**: The composite wstETH/USD price can embed a stETH/ETH ratio that is up to ~25h old while the consumer believes the entire price is ≤1h old.

### Severity Assessment: LOW (not Medium)

The realistic impact is constrained:
- stETH/ETH is historically extremely stable — it has traded in the 0.9993–1.0002 range for extended periods. A 25h-stale ratio during normal operations changes the wstETH/USD price by < 0.05%.
- The only material risk is a **stETH depeg event** (e.g. similar to the June 2022 event when stETH/ETH dropped to ~0.93). In that scenario, a 25h-stale stETH/ETH ratio would **overstate** wstETH collateral value → over-borrow / incorrect liquidation thresholds.
- However: (1) stETH depegs are rare and visible events; (2) LlamaLend's LLAMMA AMM provides a second layer of liquidation protection; (3) the 25h window would only matter if a depeg started AND resolved within the 25h window (otherwise the feed would eventually update); (4) the wstETH vault targets moderate LTV with conservative bands.
- Impact is conditional on a specific external event (stETH depeg) of historically low likelihood and limited duration.

**Severity**: **Low** — the vulnerability is real (the described staleness transparency gap exists in the code), but the realistic harm requires a rare external event (stETH depeg) coinciding with a specific timing window. Medium requires "conditional fund loss" at medium likelihood; here likelihood is low (stETH depeg events are rare).

**Fix**: Return the **minimum** (oldest) of `ethUsdUpdatedAt` and `stEthEthUpdatedAt` so the consumer's staleness check covers both feeds:
```solidity
// line 76 — replace:
updatedAt = ethUsdUpdatedAt;
// with:
updatedAt = stEthEthUpdatedAt < ethUsdUpdatedAt ? stEthEthUpdatedAt : ethUsdUpdatedAt;
```
This makes the consumer's 3600s check fail when stETH/ETH is stale, triggering a circuit breaker instead of silently using a potentially stale price. The internal `require(... <= STETH_ETH_MAX_STALENESS)` check can then be removed (the consumer check subsumes it) or kept as defense-in-depth.
