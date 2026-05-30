// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { ZenjiStrategyTestBase } from "./ZenjiStrategyTestBase.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";

/// @title AaveBackedStrategyTestBase
/// @notice Mid-level base shared by all Aave-collateralised strategy fork tests
///         (IPOR vault, PmUsd LP, and any future Aave-backed yield strategy). Encapsulates:
///           - USDT debt-token / oracle constants
///           - The MIN_ROUTABLE_DEBT dust-unwind contract (oversell + reverse-swap)
///           - AaveLoanManager access-control surface tests
///           - Debt-token decimal-scaling invariant
///           - Donation resilience for Aave-side accounting
///         Strategy-specific concerns (IPOR plasma vault vs Stake DAO LP, etc.) live in the
///         next layer down (IporVaultStrategyTestBase, PmUsdAaveStrategyTestBase).
abstract contract AaveBackedStrategyTestBase is ZenjiStrategyTestBase {
    using SafeTransferLib for IERC20;

    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    /// @notice Debt asset for all Aave-backed Zenji vaults is USDT.
    function _debtOracle() internal pure override returns (address) {
        return USDT_USD_ORACLE;
    }

    /// @notice Aave-backed vaults denominate yield + TVL in USDT (6 dec).
    function _tvlTarget() internal pure virtual override returns (uint256) {
        return 5_000_000e6;
    }

    /// @notice The strategy's internal withdrawal path swaps crvUSD → USDT via Curve.
    /// When the USDT oracle is dropped 5% in test_withdrawWithUnrealizedStrategyLoss,
    /// the crvUSD oracle must drop too or the Curve minAmountOut floor blocks the swap.
    function _strategyOraclesToDrop() internal override returns (address[] memory) {
        address[] memory oracles = new address[](1);
        oracles[0] = CRVUSD_USD_ORACLE;
        return oracles;
    }

    // ============ Dust unwind: contract-level invariants ============

    /// @notice Aave dust unwind path: a sub-dollar shortfall (e.g. flashloan premium on a tiny
    /// residual debt) bumps the swap to MIN_ROUTABLE_DEBT, then unwindPosition reverse-swaps
    /// the surplus back to collateral. This test asserts the manager is left with zero idle
    /// balance — leftover USDT or collateral would indicate a regression in the reverse-swap
    /// or transfer logic.
    function test_dustUnwind_noStrandedBalances() public {
        _deployVault();

        // MIN_DEPOSIT-sized deposit guarantees a dust shortfall on full close.
        uint256 dep = _effectiveMinDeposit();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);
        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "User must receive collateral on full redeem");

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        assertEq(
            dt.balanceOf(address(loanManager)),
            0,
            "Loan manager stranded debt token after dust unwind"
        );
        assertEq(
            collateralToken.balanceOf(address(loanManager)),
            0,
            "Loan manager stranded collateral after dust unwind"
        );
    }

    /// @notice Withdrawer pays slippage only on the MIN_ROUTABLE_DEBT over-amount,
    /// not on the full position. Loss is bounded by 2x swap fees on ~$1, regardless of
    /// position size. At MIN_DEPOSIT, that's ~1% (small base amplifies the fixed cost);
    /// for larger positions the cost amortizes to near-zero.
    function test_dustUnwind_userLossBounded() public {
        _deployVault();

        uint256 dep = _effectiveMinDeposit();
        deal(_collateral(), user1, dep);
        _depositAs(user1, dep);
        _refreshOracles();

        uint256 received = _redeemAllAs(user1);
        assertGe(received * 100, dep * 95, "Dust unwind cost exceeded 5% of deposit");
    }

    /// @notice Repeated dust unwinds must not leave residual state. Three users
    /// deposit at MIN_DEPOSIT and redeem in sequence; after each redeem, the loan
    /// manager must hold zero idle USDT and zero idle collateral.
    function test_dustUnwind_repeated_keepsStateClean() public {
        _deployVault();

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        address[3] memory users = [makeAddr("dust1"), makeAddr("dust2"), makeAddr("dust3")];
        uint256 dep = _effectiveMinDeposit();

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            deal(_collateral(), u, dep);
            _depositAs(u, dep);
            _refreshOracles();
            uint256 received = _redeemAllAs(u);
            assertGt(received, 0, "User must receive collateral");

            assertEq(
                dt.balanceOf(address(loanManager)),
                0,
                "Loan manager accumulated debt-token dust across iterations"
            );
            assertEq(
                collateralToken.balanceOf(address(loanManager)),
                0,
                "Loan manager accumulated collateral dust across iterations"
            );
        }
    }

    /// @notice Donating debt token directly to the manager between deposit and
    /// redeem must not break the unwind. The manager's pre-existing USDT balance
    /// effectively pre-pays part of the flashloan, so the swap needed at unwind
    /// shrinks (potentially to zero).
    function test_donation_debtTokenToManager_doesNotBrickUnwind() public {
        _deployVault();
        _depositAs(user1, _unit() * 2);

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        uint256 donation = loanManager.DUST_THRESHOLD() * 5;
        deal(address(dt), address(this), donation);
        dt.safeTransfer(address(loanManager), donation);

        _refreshOracles();
        uint256 received = _redeemAllAs(user1);
        assertGt(received, 0, "Redeem failed after debt-token donation");

        assertLe(
            dt.balanceOf(address(loanManager)),
            loanManager.DUST_THRESHOLD(),
            "Donation left as stranded debt token in manager"
        );
    }

    /// @notice Partial close hitting the dust shortfall path.
    function test_partialClose_dustShortfall_keepsStateClean() public {
        _deployVault();

        IERC20 dt = IERC20(address(loanManager.debtToken()));
        uint256 dep = _effectiveMinDeposit() * 4;
        deal(_collateral(), user1, dep);
        uint256 shares = _depositAs(user1, dep);
        _refreshOracles();

        vm.prank(user1);
        uint256 received = vault.redeem(shares / 2, user1, user1);
        assertGt(received, 0, "Partial redeem returned zero");

        assertEq(
            dt.balanceOf(address(loanManager)),
            0,
            "Manager left holding debt token after partial-close dust unwind"
        );
        assertEq(
            collateralToken.balanceOf(address(loanManager)),
            0,
            "Manager left holding collateral after partial-close dust unwind"
        );

        _refreshOracles();
        uint256 remaining = _redeemAllAs(user1);
        assertGt(remaining, 0, "Remaining shares undeemable after partial dust unwind");
    }

    /// @notice DUST_THRESHOLD and MIN_ROUTABLE_DEBT must scale with the debt
    /// token's decimals — hardcoding USDT (1e6) would break for 18-decimal stables.
    function test_loanManager_dustConstants_scaleWithDebtDecimals() public {
        _deployVault();
        uint256 expected = 10 ** uint256(loanManager.debtToken().decimals());
        assertEq(
            loanManager.DUST_THRESHOLD(),
            expected,
            "DUST_THRESHOLD does not scale with debt token decimals"
        );
        assertEq(
            loanManager.MIN_ROUTABLE_DEBT(),
            expected,
            "MIN_ROUTABLE_DEBT does not scale with debt token decimals"
        );
    }
}
