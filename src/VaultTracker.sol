// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IVault {
    function getTotalCollateral() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title VaultTracker
/// @notice Tracks APR and performance metrics for Zenji
/// @dev Separate contract to keep main vault under size limit
contract VaultTracker {
    // ============ Constants ============

    /// @notice Minimum time between snapshots (1 day)
    uint256 public constant SNAPSHOT_INTERVAL = 1 days;

    /// @notice Maximum number of snapshots to retain (2 years of daily snapshots)
    uint256 public constant MAX_SNAPSHOTS = 730;

    // ============ Immutables ============

    IVault public immutable vault;

    // ============ State ============

    /// @notice Snapshot of vault state for APR calculation
    struct Snapshot {
        uint256 timestamp;
        uint256 sharePrice;
        uint256 totalShares;
        uint256 totalValue;
    }

    /// @notice Historical snapshots for APR calculation
    Snapshot[] public snapshots;

    /// @notice Cumulative profit in WBTC
    uint256 public cumulativeProfit;

    /// @notice Cumulative loss in WBTC
    uint256 public cumulativeLoss;

    /// @notice Last recorded total value for profit tracking
    uint256 public lastRecordedValue;

    // ============ Events ============

    event SnapshotTaken(
        uint256 indexed index, uint256 timestamp, uint256 sharePrice, uint256 totalValue
    );
    event ProfitRecorded(uint256 profit, uint256 newCumulativeProfit);
    event LossRecorded(uint256 loss, uint256 newCumulativeLoss);

    // ============ Errors ============

    error SnapshotTooSoon();

    // ============ Constructor ============

    constructor(address _vault) {
        vault = IVault(_vault);
    }

    // ============ View Functions ============

    /// @notice Get current price per share (WBTC per share, 8 decimals)
    function sharePrice() public view returns (uint256) {
        uint256 totalShares = vault.totalSupply();
        if (totalShares == 0) return 1e8;
        return (vault.getTotalCollateral() * 1e8) / totalShares;
    }

    /// @notice Get the number of snapshots
    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    /// @notice Get snapshot at index
    function getSnapshot(uint256 index) external view returns (Snapshot memory) {
        return snapshots[index];
    }

    /// @notice Calculate APR based on share price growth over a period
    /// @param periodDays Number of days to calculate APR over
    /// @return apr Annual percentage rate in basis points (10000 = 100%)
    function calculateAPR(uint256 periodDays) external view returns (uint256 apr) {
        if (snapshots.length < 2) return 0;

        uint256 targetTime = block.timestamp - (periodDays * 1 days);

        uint256 oldIndex = 0;
        for (uint256 i = 0; i < snapshots.length; i++) {
            if (snapshots[i].timestamp <= targetTime) {
                oldIndex = i;
            } else {
                break;
            }
        }

        Snapshot memory oldSnapshot = snapshots[oldIndex];
        Snapshot memory newSnapshot = snapshots[snapshots.length - 1];

        if (newSnapshot.timestamp <= oldSnapshot.timestamp) return 0;

        uint256 timeDelta = newSnapshot.timestamp - oldSnapshot.timestamp;
        if (timeDelta == 0) return 0;

        if (newSnapshot.sharePrice <= oldSnapshot.sharePrice) return 0;

        uint256 priceGrowth = newSnapshot.sharePrice - oldSnapshot.sharePrice;
        apr = (priceGrowth * 365 days * 10000) / (oldSnapshot.sharePrice * timeDelta);
    }

    /// @notice Get current and historical performance metrics
    function getPerformanceMetrics()
        external
        view
        returns (
            uint256 currentSharePrice,
            uint256 totalProfitWbtc,
            uint256 totalLossWbtc,
            int256 netProfitWbtc,
            uint256 snapshotsCount
        )
    {
        currentSharePrice = sharePrice();
        totalProfitWbtc = cumulativeProfit;
        totalLossWbtc = cumulativeLoss;
        netProfitWbtc = int256(cumulativeProfit) - int256(cumulativeLoss);
        snapshotsCount = snapshots.length;
    }

    // ============ External Functions ============

    /// @notice Take a snapshot of current vault state
    /// @dev Can be called by anyone, rate-limited to once per day
    function takeSnapshot() external {
        if (snapshots.length > 0) {
            if (block.timestamp < snapshots[snapshots.length - 1].timestamp + SNAPSHOT_INTERVAL) {
                revert SnapshotTooSoon();
            }
        }

        uint256 currentSharePrice = sharePrice();
        uint256 currentTotalValue = vault.getTotalCollateral();

        _pushSnapshot(currentSharePrice, currentTotalValue);
    }

    /// @notice Record profit/loss since last recording
    /// @dev Can be called by anyone, typically after harvest
    function recordProfitLoss() external {
        uint256 currentValue = vault.getTotalCollateral();

        if (lastRecordedValue == 0) {
            lastRecordedValue = currentValue;
            return;
        }

        if (currentValue > lastRecordedValue) {
            uint256 profit = currentValue - lastRecordedValue;
            cumulativeProfit += profit;
            emit ProfitRecorded(profit, cumulativeProfit);
        } else if (currentValue < lastRecordedValue) {
            uint256 loss = lastRecordedValue - currentValue;
            cumulativeLoss += loss;
            emit LossRecorded(loss, cumulativeLoss);
        }

        lastRecordedValue = currentValue;
    }

    /// @notice Take snapshot and record profit/loss in one call
    function update() external {
        // Record profit/loss
        uint256 currentValue = vault.getTotalCollateral();

        if (lastRecordedValue == 0) {
            lastRecordedValue = currentValue;
        } else if (currentValue > lastRecordedValue) {
            uint256 profit = currentValue - lastRecordedValue;
            cumulativeProfit += profit;
            emit ProfitRecorded(profit, cumulativeProfit);
        } else if (currentValue < lastRecordedValue) {
            uint256 loss = lastRecordedValue - currentValue;
            cumulativeLoss += loss;
            emit LossRecorded(loss, cumulativeLoss);
        }
        lastRecordedValue = currentValue;

        // Take snapshot if enough time passed
        if (
            snapshots.length == 0
                || block.timestamp >= snapshots[snapshots.length - 1].timestamp + SNAPSHOT_INTERVAL
        ) {
            uint256 currentSharePrice = sharePrice();
            _pushSnapshot(currentSharePrice, currentValue);
        }
    }

    // ============ Internal Functions ============

    /// @notice Push a snapshot, removing the oldest if at capacity
    function _pushSnapshot(uint256 currentSharePrice, uint256 currentTotalValue) internal {
        if (snapshots.length >= MAX_SNAPSHOTS) {
            // Shift array left by 1 to drop oldest entry
            for (uint256 i = 0; i < snapshots.length - 1; i++) {
                snapshots[i] = snapshots[i + 1];
            }
            snapshots.pop();
        }

        snapshots.push(
            Snapshot({
                timestamp: block.timestamp,
                sharePrice: currentSharePrice,
                totalShares: vault.totalSupply(),
                totalValue: currentTotalValue
            })
        );

        emit SnapshotTaken(
            snapshots.length - 1, block.timestamp, currentSharePrice, currentTotalValue
        );
    }
}
