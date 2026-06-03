// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { TimelockLib } from "./TimelockLib.sol";
import { IYieldStrategy } from "../interfaces/IYieldStrategy.sol";

interface ISwapperSlippage {
    function setSlippage(uint256 newSlippage) external;
}

/// @title ZenjiGovLib
/// @notice Cold-path gov parameter administration extracted from Zenji to reduce vault bytecode.
/// @dev All functions are `public` and run via DELEGATECALL from the vault, so `address(this)` is
///      the vault: storage pointers operate on the vault's storage, events are emitted from the
///      vault address, and external calls (setSlippage) carry the vault as msg.sender. The vault
///      resolves its virtual `MAX_TARGET_LTV()` and the loan manager's `maxLtvBps()` and passes
///      them in as values, since a library cannot call the vault's virtuals.
library ZenjiGovLib {
    using TimelockLib for TimelockLib.TimelockData;

    // ---- bounds (mirror Zenji constants) ----
    uint256 internal constant MAX_FEE_RATE = 2e17; // 20%
    uint256 internal constant MIN_TARGET_LTV = 15e16; // 15%
    uint256 internal constant MAX_REBALANCE_BOUNTY = 5e17; // 50%
    uint256 internal constant MAX_VAULT_SLIPPAGE = 5e16; // 5%
    /// @dev Must match BaseYieldStrategy.MIN_SLIPPAGE — the vault rejects sub-floor values
    ///      up front rather than letting the strategy's setSlippage revert the whole param change.
    uint256 internal constant MIN_VAULT_SLIPPAGE = 1e15; // 0.1%
    uint256 internal constant PARAM_TIMELOCK_DELAY = 1 weeks;

    /// @notice Snapshot of the five gov-settable scalar params, threaded in and back out.
    struct ParamState {
        uint256 feeRate;
        uint256 targetLtv;
        uint256 depositCap;
        uint256 rebalanceBountyRate;
        uint256 maxSlippage;
    }

    // ---- events (same signatures as Zenji; topics match on emit via delegatecall) ----
    event ParamUpdated(uint8 indexed param, uint256 oldValue, uint256 newValue);
    event FeeRateChangeProposed(uint256 currentFeeRate, uint256 newFeeRate, uint256 effectiveTime);
    event TargetLtvChangeProposed(uint256 currentLtv, uint256 newLtv, uint256 effectiveTime);
    event BountyRateChangeProposed(uint256 currentRate, uint256 newRate, uint256 effectiveTime);
    event DepositCapChangeProposed(uint256 currentCap, uint256 newCap, uint256 effectiveTime);
    event MaxSlippageChangeProposed(uint256 currentSlippage, uint256 newSlippage, uint256 effectiveTime);
    event FeeRateChangeCancelled(uint256 cancelledValue);
    event TargetLtvChangeCancelled(uint256 cancelledValue);
    event BountyRateChangeCancelled(uint256 cancelledValue);
    event DepositCapChangeCancelled(uint256 cancelledValue);
    event MaxSlippageChangeCancelled(uint256 cancelledValue);

    error InvalidFeeRate();
    error InvalidTargetLtv();
    error InvalidBountyRate();
    error InvalidSlippage();
    error InvalidParam();

    /// @notice setParam logic (see Zenji.setParam). Adverse changes timelock; favorable apply now.
    function setParam(
        TimelockLib.TimelockData storage feeT,
        TimelockLib.TimelockData storage ltvT,
        TimelockLib.TimelockData storage capT,
        TimelockLib.TimelockData storage bountyT,
        TimelockLib.TimelockData storage slipT,
        ParamState memory s,
        uint8 p,
        uint256 v,
        uint256 maxTargetLtv,
        uint256 lmMaxBps,
        address yieldStrategy,
        address swapper
    ) public returns (ParamState memory) {
        if (p == 0) {
            if (v > MAX_FEE_RATE) revert InvalidFeeRate();
            if (v > s.feeRate) {
                feeT.propose(v, PARAM_TIMELOCK_DELAY);
                emit FeeRateChangeProposed(s.feeRate, v, block.timestamp + PARAM_TIMELOCK_DELAY);
            } else {
                emit ParamUpdated(p, s.feeRate, v);
                s.feeRate = v;
            }
        } else if (p == 1) {
            if (v < MIN_TARGET_LTV || v > maxTargetLtv) revert InvalidTargetLtv();
            if (lmMaxBps != type(uint256).max && v > lmMaxBps * 1e14) revert InvalidTargetLtv();
            if (v > s.targetLtv) {
                ltvT.propose(v, PARAM_TIMELOCK_DELAY);
                emit TargetLtvChangeProposed(s.targetLtv, v, block.timestamp + PARAM_TIMELOCK_DELAY);
            } else {
                emit ParamUpdated(p, s.targetLtv, v);
                s.targetLtv = v;
            }
        } else if (p == 2) {
            if (v < s.depositCap) {
                capT.propose(v, PARAM_TIMELOCK_DELAY);
                emit DepositCapChangeProposed(s.depositCap, v, block.timestamp + PARAM_TIMELOCK_DELAY);
            } else {
                emit ParamUpdated(p, s.depositCap, v);
                s.depositCap = v;
            }
        } else if (p == 3) {
            if (v > MAX_REBALANCE_BOUNTY) revert InvalidBountyRate();
            if (v > s.rebalanceBountyRate) {
                bountyT.propose(v, PARAM_TIMELOCK_DELAY);
                emit BountyRateChangeProposed(
                    s.rebalanceBountyRate, v, block.timestamp + PARAM_TIMELOCK_DELAY
                );
            } else {
                emit ParamUpdated(p, s.rebalanceBountyRate, v);
                s.rebalanceBountyRate = v;
            }
        } else if (p == 4) {
            if (v < MIN_VAULT_SLIPPAGE || v > MAX_VAULT_SLIPPAGE) revert InvalidSlippage();
            if (v > s.maxSlippage) {
                slipT.propose(v, PARAM_TIMELOCK_DELAY);
                emit MaxSlippageChangeProposed(s.maxSlippage, v, block.timestamp + PARAM_TIMELOCK_DELAY);
            } else {
                emit ParamUpdated(p, s.maxSlippage, v);
                s.maxSlippage = v;
                IYieldStrategy(yieldStrategy).setSlippage(v);
                if (swapper != address(0)) ISwapperSlippage(swapper).setSlippage(v);
            }
        } else {
            revert InvalidParam();
        }
        return s;
    }

    /// @notice executeParamChange logic (see Zenji.executeParamChange). For p==0 the vault must
    ///         call _accrueYieldFees() at the OLD rate BEFORE invoking this (it cannot be done here).
    function executeParamChange(
        TimelockLib.TimelockData storage feeT,
        TimelockLib.TimelockData storage ltvT,
        TimelockLib.TimelockData storage capT,
        TimelockLib.TimelockData storage bountyT,
        TimelockLib.TimelockData storage slipT,
        ParamState memory s,
        uint8 p,
        uint256 maxTargetLtv,
        uint256 lmMaxBps,
        address yieldStrategy,
        address swapper
    ) public returns (ParamState memory) {
        if (p == 0) {
            uint256 newFee = feeT.execute();
            if (newFee > MAX_FEE_RATE) revert InvalidFeeRate();
            emit ParamUpdated(p, s.feeRate, newFee);
            s.feeRate = newFee;
        } else if (p == 1) {
            uint256 newLtv = ltvT.execute();
            if (newLtv < MIN_TARGET_LTV || newLtv > maxTargetLtv) revert InvalidTargetLtv();
            if (lmMaxBps != type(uint256).max && newLtv > lmMaxBps * 1e14) revert InvalidTargetLtv();
            emit ParamUpdated(p, s.targetLtv, newLtv);
            s.targetLtv = newLtv;
        } else if (p == 2) {
            uint256 newCap = capT.execute();
            emit ParamUpdated(p, s.depositCap, newCap);
            s.depositCap = newCap;
        } else if (p == 3) {
            uint256 newBounty = bountyT.execute();
            if (newBounty > MAX_REBALANCE_BOUNTY) revert InvalidBountyRate();
            emit ParamUpdated(p, s.rebalanceBountyRate, newBounty);
            s.rebalanceBountyRate = newBounty;
        } else if (p == 4) {
            uint256 newSlip = slipT.execute();
            if (newSlip < MIN_VAULT_SLIPPAGE || newSlip > MAX_VAULT_SLIPPAGE) revert InvalidSlippage();
            emit ParamUpdated(p, s.maxSlippage, newSlip);
            s.maxSlippage = newSlip;
            IYieldStrategy(yieldStrategy).setSlippage(newSlip);
            if (swapper != address(0)) ISwapperSlippage(swapper).setSlippage(newSlip);
        } else {
            revert InvalidParam();
        }
        return s;
    }

    /// @notice cancelParamChange logic (see Zenji.cancelParamChange).
    function cancelParamChange(
        TimelockLib.TimelockData storage feeT,
        TimelockLib.TimelockData storage ltvT,
        TimelockLib.TimelockData storage capT,
        TimelockLib.TimelockData storage bountyT,
        TimelockLib.TimelockData storage slipT,
        uint8 p
    ) public {
        if (p == 0) {
            emit FeeRateChangeCancelled(feeT.cancel());
        } else if (p == 1) {
            emit TargetLtvChangeCancelled(ltvT.cancel());
        } else if (p == 2) {
            emit DepositCapChangeCancelled(capT.cancel());
        } else if (p == 3) {
            emit BountyRateChangeCancelled(bountyT.cancel());
        } else if (p == 4) {
            emit MaxSlippageChangeCancelled(slipT.cancel());
        } else {
            revert InvalidParam();
        }
    }
}
