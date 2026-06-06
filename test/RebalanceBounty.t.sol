// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { ZenjiCoreLib } from "../src/libraries/ZenjiCoreLib.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mintable ERC20 standing in for the debt asset (crvUSD).
contract MockDebtToken is ERC20 {
    constructor() ERC20("Mock crvUSD", "mUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Simple 1:1 ERC4626 yield vault.
contract MockYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock Yield Vault", "mYV") { }
}

/// @notice Mock yield strategy mirroring the production withdraw semantics:
///         caps the redeemed shares at the held balance and forwards received
///         assets to the vault. Only `deposit`/`withdraw`/`balanceOf` matter here.
contract MockYieldStrategy is IYieldStrategy {
    ERC4626 public immutable yieldVault;
    IERC20 public immutable debt;
    address public override vault;
    uint256 private _costBasis;

    constructor(address _debt, address _vault, address _yieldVault) {
        debt = IERC20(_debt);
        vault = _vault;
        yieldVault = ERC4626(_yieldVault);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function deposit(uint256 amount) external onlyVault returns (uint256) {
        debt.transferFrom(msg.sender, address(this), amount);
        debt.approve(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));
        _costBasis += amount;
        return amount;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 shares = yieldVault.convertToShares(amount);
        uint256 totalShares = yieldVault.balanceOf(address(this));
        if (shares > totalShares) shares = totalShares;

        uint256 basisReduction = totalShares > 0 ? (_costBasis * shares) / totalShares : 0;
        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;

        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        debt.transfer(vault, received);
        return received;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares == 0) return 0;
        _costBasis = 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        debt.transfer(vault, received);
        return received;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
        return this.withdrawAll();
    }

    function asset() external view returns (address) {
        return address(debt);
    }

    function underlyingAsset() external view returns (address) {
        return address(debt);
    }

    function balanceOf() external view returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        return shares > 0 ? yieldVault.convertToAssets(shares) : 0;
    }

    function costBasis() external view returns (uint256) {
        return _costBasis;
    }

    function unrealizedProfit() external view returns (uint256) {
        uint256 current = this.balanceOf();
        return current > _costBasis ? current - _costBasis : 0;
    }

    function pendingRewards() external pure returns (uint256) {
        return 0;
    }

    function transferOwnerFromVault(address) external pure { }
    function setSlippage(uint256) external pure { }
    function updateCachedVirtualPrice() external { }

    function name() external pure returns (string memory) {
        return "Mock Yield Strategy";
    }
}

/// @notice Isolated unit tests for ZenjiCoreLib.processRebalanceBounty.
/// @dev `processRebalanceBounty` is the first, unconditional step of `rebalance()`. Its
///      property — clamp the keeper bounty at the strategy's withdrawable balance — is a
///      function of that step alone. These tests exercise it directly (the external library
///      is reached via DELEGATECALL, so `address(this)` is this test contract, which acts as
///      the strategy's vault). No fork, no loan manager, no LTV adjustment, and therefore no
///      borrow-coverage guard — the prior integration test (`test_rebalance_bountyPartialPayment`)
///      could never observe a partial bounty because the drained-strategy state it required also
///      tripped the 97% borrow-coverage guard, reverting the whole atomic rebalance.
contract RebalanceBountyTest is Test {
    uint256 constant PRECISION = 1e18;

    MockDebtToken debt;
    MockYieldVault yieldVault;
    MockYieldStrategy strategy;
    address keeper = makeAddr("keeper");

    function setUp() public {
        debt = new MockDebtToken();
        yieldVault = new MockYieldVault(address(debt));
        // This test contract is the strategy's vault (the DELEGATECALL caller context).
        strategy = new MockYieldStrategy(address(debt), address(this), address(yieldVault));
    }

    /// @dev Fund the strategy with `amount` of debt asset (this contract acts as the vault).
    function _fundStrategy(uint256 amount) internal {
        debt.mint(address(this), amount);
        debt.approve(address(strategy), amount);
        strategy.deposit(amount);
    }

    /// @notice When the owed bounty exceeds the strategy balance, payout is clamped to the
    ///         strategy balance — the keeper gets a partial bounty and nothing reverts.
    function test_processRebalanceBounty_clampsToStrategyBalance() public {
        uint256 strategyBalance = 1e18;
        _fundStrategy(strategyBalance);

        // Owed bounty = 100e18 * 10% = 10e18, far above the 1e18 strategy balance.
        uint256 accumulatedFees = 100e18;
        uint256 feesAtLastRebalance = 0;
        uint256 bountyRate = 1e17; // 10%
        uint256 owedBounty = (accumulatedFees * bountyRate) / PRECISION;
        assertGt(owedBounty, strategyBalance, "owed bounty must exceed strategy balance");

        uint256 keeperBefore = debt.balanceOf(keeper);

        (uint256 newFeesAtLast,, uint256 bountyPaid) = ZenjiCoreLib.processRebalanceBounty(
            IYieldStrategy(address(strategy)),
            IERC20(address(debt)),
            accumulatedFees,
            feesAtLastRebalance,
            bountyRate,
            PRECISION,
            keeper
        );

        // Clamped to what the strategy could supply, NOT the full owed amount.
        assertEq(bountyPaid, strategyBalance, "bounty should clamp to strategy balance");
        assertLt(bountyPaid, owedBounty, "clamp must pay less than the full owed bounty");
        assertEq(debt.balanceOf(keeper) - keeperBefore, strategyBalance, "keeper received partial bounty");
        assertApproxEqAbs(strategy.balanceOf(), 0, 1, "strategy drained by the payout");
        assertEq(newFeesAtLast, accumulatedFees, "fees watermark advances to accumulatedFees");
    }

    /// @notice When the strategy can cover the owed bounty, the keeper is paid in full and the
    ///         remainder stays deployed.
    function test_processRebalanceBounty_paysFullWhenCovered() public {
        uint256 strategyBalance = 100e18;
        _fundStrategy(strategyBalance);

        uint256 accumulatedFees = 100e18;
        uint256 bountyRate = 1e17; // 10%
        uint256 owedBounty = (accumulatedFees * bountyRate) / PRECISION; // 10e18

        uint256 keeperBefore = debt.balanceOf(keeper);

        (,, uint256 bountyPaid) = ZenjiCoreLib.processRebalanceBounty(
            IYieldStrategy(address(strategy)),
            IERC20(address(debt)),
            accumulatedFees,
            0,
            bountyRate,
            PRECISION,
            keeper
        );

        assertEq(bountyPaid, owedBounty, "full bounty paid when strategy covers it");
        assertEq(debt.balanceOf(keeper) - keeperBefore, owedBounty, "keeper received full bounty");
        assertApproxEqAbs(strategy.balanceOf(), strategyBalance - owedBounty, 1, "remainder stays deployed");
    }

    /// @notice A zero bounty rate pays nothing and leaves the fees watermark untouched.
    function test_processRebalanceBounty_zeroRatePaysNothing() public {
        _fundStrategy(100e18);

        uint256 feesAtLastRebalance = 5e18;
        uint256 keeperBefore = debt.balanceOf(keeper);

        (uint256 newFeesAtLast,, uint256 bountyPaid) = ZenjiCoreLib.processRebalanceBounty(
            IYieldStrategy(address(strategy)),
            IERC20(address(debt)),
            100e18,
            feesAtLastRebalance,
            0, // zero bounty rate
            PRECISION,
            keeper
        );

        assertEq(bountyPaid, 0, "no bounty paid at zero rate");
        assertEq(debt.balanceOf(keeper), keeperBefore, "keeper balance unchanged");
        assertEq(newFeesAtLast, feesAtLastRebalance, "fees watermark untouched at zero rate");
    }
}
