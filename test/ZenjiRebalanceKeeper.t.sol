// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ZenjiRebalanceKeeper } from "../src/keepers/ZenjiRebalanceKeeper.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";

contract MockKeeperToken is ERC20 {
    constructor() ERC20("Mock Keeper Token", "MKT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockKeeperLoanManager is ILoanManager {
    uint256 public currentLtv;
    bool public loanExistsFlag = true;
    bool public stale;

    function setCurrentLtv(uint256 ltv) external {
        currentLtv = ltv;
    }

    function setLoanExists(bool exists_) external {
        loanExistsFlag = exists_;
    }

    function setStale(bool stale_) external {
        stale = stale_;
    }

    function getCurrentLTV() external view returns (uint256) {
        return currentLtv;
    }

    function loanExists() external view returns (bool exists) {
        return loanExistsFlag;
    }

    function maxLtvBps() external pure returns (uint256) {
        return type(uint256).max;
    }

    function checkOracleFreshness() external view {
        if (stale) revert("stale");
    }

    function getCurrentCollateral() external pure returns (uint256 collateral) {
        collateral = 0;
    }

    function getCurrentDebt() external pure returns (uint256 debt) {
        debt = 0;
    }

    function collateralAsset() external pure returns (address asset_) {
        asset_ = address(0);
    }

    function debtAsset() external pure returns (address asset_) {
        asset_ = address(0);
    }

    function getHealth() external pure returns (int256 health) {
        health = 0;
    }

    function getCollateralValue(uint256) external pure returns (uint256 value) {
        value = 0;
    }

    function getDebtValue(uint256) external pure returns (uint256 value) {
        value = 0;
    }

    function calculateBorrowAmount(uint256, uint256)
        external
        pure
        returns (uint256 borrowAmount)
    {
        borrowAmount = 0;
    }

    function healthCalculator(int256, int256) external pure returns (int256 health) {
        health = 0;
    }

    function minCollateral(uint256, uint256) external pure returns (uint256 minCollat) {
        minCollat = 0;
    }

    function getPositionValues() external pure returns (uint256 collateralValue, uint256 debtValue) {
        collateralValue = 0;
        debtValue = 0;
    }

    function getNetCollateralValue() external pure returns (uint256 value) {
        value = 0;
    }

    function transferCollateral(address, uint256) external pure { }

    function transferDebt(address, uint256) external pure { }

    function getCollateralBalance() external pure returns (uint256 balance) {
        balance = 0;
    }

    function getDebtBalance() external pure returns (uint256 balance) {
        balance = 0;
    }

    function createLoan(uint256, uint256) external pure { }

    function addCollateral(uint256) external pure { }

    function borrowMore(uint256, uint256) external pure { }

    function repayDebt(uint256) external pure { }

    function removeCollateral(uint256) external pure { }

    function unwindPosition(uint256) external pure { }

    function initializeVault(address) external pure { }

    function setMaxLtvBps(uint256) external pure { }

    function setMinHealthFactor(uint256) external pure { }

    function setLiquidationThresholdBps(uint256) external pure { }

    function setMaxSlippage(uint256) external pure { }

    function setSwapper(address) external pure { }

    function setKeeper(address, bool) external pure { }

    function pause() external pure { }

    function unpause() external pure { }
}

contract MockKeeperVault {
    ILoanManager public loanManager;
    uint256 public targetLtv;
    uint256 public constant DEADBAND_SPREAD = 3e16;
    bool public idle;
    bool public emergencyMode;
    bool public ratioNeeded;
    bool public rebalanceCalled;

    constructor(address loanManager_) {
        loanManager = ILoanManager(loanManager_);
        targetLtv = 65e16;
    }

    function setIdle(bool v) external {
        idle = v;
    }

    function setEmergencyMode(bool v) external {
        emergencyMode = v;
    }

    function setRatioNeeded(bool v) external {
        ratioNeeded = v;
    }

    function setTargetLtv(uint256 v) external {
        targetLtv = v;
    }

    function strategyDebtRebalanceNeeded() external view returns (bool) {
        return ratioNeeded;
    }

    function rebalance() external {
        rebalanceCalled = true;
    }
}

contract ZenjiRebalanceKeeperTest is Test {
    ZenjiRebalanceKeeper internal keeper;
    MockKeeperToken internal token;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant MOCK_VAULT = address(0xBEEF);

    MockKeeperLoanManager internal mockLoanManager;
    MockKeeperVault internal mockVault;
    ZenjiRebalanceKeeper internal keeperWithMockVault;

    function setUp() external {
        keeper = new ZenjiRebalanceKeeper(MOCK_VAULT, OWNER);
        mockLoanManager = new MockKeeperLoanManager();
        mockVault = new MockKeeperVault(address(mockLoanManager));
        keeperWithMockVault = new ZenjiRebalanceKeeper(address(mockVault), OWNER);
        token = new MockKeeperToken();

        token.mint(address(keeper), 1_000e18);
    }

    function test_checkUpkeep_trueWhenLtvOutOfBand() external {
        mockLoanManager.setCurrentLtv(70e16); // above upper band 68%
        (bool needed,) = keeperWithMockVault.checkUpkeep("");
        assertTrue(needed, "LTV out-of-band should require upkeep");
    }

    function test_checkUpkeep_trueWhenRatioOutOfBandEvenIfOracleStale() external {
        mockLoanManager.setStale(true);
        mockVault.setRatioNeeded(true);

        (bool needed,) = keeperWithMockVault.checkUpkeep("");
        assertTrue(needed, "Ratio drift should require upkeep even when oracle stale");
    }

    function test_performUpkeep_callsRebalanceWhenRatioOutOfBand() external {
        mockLoanManager.setStale(true);
        mockVault.setRatioNeeded(true);

        keeperWithMockVault.performUpkeep("");
        assertTrue(mockVault.rebalanceCalled(), "performUpkeep should call vault.rebalance");
    }

    function test_ownerCanDrainErc20() external {
        uint256 amount = 250e18;

        vm.prank(OWNER);
        keeper.drainERC20(address(token), RECEIVER, amount);

        assertEq(token.balanceOf(RECEIVER), amount);
        assertEq(token.balanceOf(address(keeper)), 750e18);
    }

    function test_nonOwnerCannotDrainErc20() external {
        vm.prank(OTHER);
        vm.expectRevert(ZenjiRebalanceKeeper.Unauthorized.selector);
        keeper.drainERC20(address(token), RECEIVER, 1e18);
    }

    function test_transferOwnership_newOwnerCanDrain() external {
        vm.prank(OWNER);
        keeper.transferOwnership(OTHER);

        vm.prank(OWNER);
        vm.expectRevert(ZenjiRebalanceKeeper.Unauthorized.selector);
        keeper.drainERC20(address(token), RECEIVER, 1e18);

        vm.prank(OTHER);
        keeper.drainERC20(address(token), RECEIVER, 1e18);

        assertEq(token.balanceOf(RECEIVER), 1e18);
    }
}
