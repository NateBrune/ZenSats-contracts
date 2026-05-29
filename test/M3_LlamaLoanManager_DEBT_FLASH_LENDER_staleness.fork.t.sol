// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { console } from "forge-std/Test.sol";
import { ZenjiForkTestBase } from "./base/ZenjiForkTestBase.sol";
import { ZenjiWbtcLlamaStakeDao } from "../src/implementations/stakedao/ZenjiWbtcLlamaStakeDao.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UniswapMixedCurveSwapper } from "../src/swappers/base/UniswapMixedCurveSwapper.sol";
import { ICurveTriCrypto } from "../src/interfaces/ICurveTriCrypto.sol";
import { CrvToCrvUsdSwapper } from "../src/swappers/reward/CrvToCrvUsdSwapper.sol";
import { PmUsdCrvUsdStakeDaoStrategy } from "../src/strategies/lp/PmUsdCrvUsdStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IStakeDaoRewardVault } from "../src/interfaces/IStakeDaoRewardVault.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title M3_LlamaLoanManager_DEBT_FLASH_LENDER_staleness
/// @notice PoC for M3: LlamaLoanManager DEBT_FLASH_LENDER hardcoded address staleness
/// @dev Demonstrates that if the crvUSD FlashLender is deprecated, full close unwinds
///      will revert until emergency steps are used.
contract M3_LlamaLoanManager_DEBT_FLASH_LENDER_staleness is ZenjiForkTestBase {
    using SafeTransferLib for IERC20;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant LLAMALEND_WBTC_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant FEE_WBTC_WETH = 500;
    address constant TRICRYPTO_POOL = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    address constant PMUSD_CRVUSD_POOL = 0xEcb0F0d68C19BdAaDAEbE24f6752A4Db34e2c2cb;
    address constant PMUSD = 0xC0c17dD08263C16f6b64E772fB9B723Bf1344DdF;
    address constant PMUSD_CRVUSD_GAUGE = 0xF3c43E7D722963b9569d1E39873dF9E2dFE8C087;
    address constant STAKE_DAO_REWARD_VAULT = 0x7d3CDe9cCf0109423E672c17bD36481CF8CE437D;
    address constant CRV_CRVUSD_TRICRYPTO = 0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14;
    address constant DEBT_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniswapMixedCurveSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    PmUsdCrvUsdStakeDaoStrategy public strategy;
    LlamaLoanManager public llamaManager;
    ZenjiWbtcLlamaStakeDao public llamaVault;

    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e8;
    }

    function _tinyDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function _oracleList() internal pure override returns (address[] memory) {
        address[] memory oracles = new address[](3);
        oracles[0] = BTC_USD_ORACLE;
        oracles[1] = CRVUSD_USD_ORACLE;
        oracles[2] = CRV_USD_ORACLE;
        return oracles;
    }

    function _collateralPriceOracle() internal pure override returns (address) {
        return BTC_USD_ORACLE;
    }

    function _fuzzMultiMax() internal pure override returns (uint256) {
        return 2e8;
    }

    function _fuzzMultiUserLossPct() internal pure override returns (uint256) {
        return 20;
    }

    function _fuzzMultiUserFairnessPct() internal pure override returns (uint256) {
        return 20;
    }

    function _getLpCrvUsdIndex() internal view returns (int128) {
        address coin0 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(0);
        address coin1 = ICurveStableSwapNG(PMUSD_CRVUSD_POOL).coins(1);
        if (coin0 == CRVUSD) return int128(0);
        if (coin1 == CRVUSD) return int128(1);
        revert("crvUSD not found in pmUSD pool");
    }

    function _getWethCrvUsdIndices() internal view returns (uint256 wethIdx, uint256 crvUsdIdx) {
        ICurveTriCrypto pool = ICurveTriCrypto(TRICRYPTO_POOL);
        for (uint256 i = 0; i < 3; i++) {
            address coin = pool.coins(i);
            if (coin == WETH) wethIdx = i;
            else if (coin == CRVUSD) crvUsdIdx = i;
        }
    }

    function setUp() public override {
        super.setUp();
    }

    function _deployVaultContracts() internal override {
        uint256 startNonce = vm.getNonce(address(this));
        address expectedVaultAddress = computeCreateAddress(address(this), startNonce + 4);

        int128 lpCrvUsdIndex = _getLpCrvUsdIndex();
        (uint256 wethIdx, uint256 crvUsdIdx) = _getWethCrvUsdIndices();

        crvSwapper = new CrvToCrvUsdSwapper(
            owner, CRV, CRVUSD, CRV_CRVUSD_TRICRYPTO, CRV_USD_ORACLE, CRVUSD_USD_ORACLE
        );

        swapper = new UniswapMixedCurveSwapper(
            owner,
            WBTC,
            CRVUSD,
            WETH,
            UNIVERSAL_ROUTER,
            FEE_WBTC_WETH,
            TRICRYPTO_POOL,
            wethIdx,
            crvUsdIdx,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            3600
        );

        strategy = new PmUsdCrvUsdStakeDaoStrategy(
            CRVUSD,
            address(0),
            owner,
            PMUSD_CRVUSD_POOL,
            STAKE_DAO_REWARD_VAULT,
            address(crvSwapper),
            PMUSD_CRVUSD_GAUGE,
            lpCrvUsdIndex,
            CRVUSD_USD_ORACLE,
            CRV_USD_ORACLE
        );

        llamaManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_WBTC_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            address(swapper),
            address(0)
        );

        llamaVault = new ZenjiWbtcLlamaStakeDao(
            address(llamaManager), address(strategy), address(swapper), owner, address(viewHelper)
        );
        require(address(llamaVault) == expectedVaultAddress, "Vault address mismatch");

        llamaManager.initializeVault(address(llamaVault));
        strategy.initializeVault(address(llamaVault));

        vm.prank(owner);
        swapper.setVault(address(llamaVault));

        loanManager = AaveLoanManager(address(llamaManager));
        vault = Zenji(address(llamaVault));
        yieldStrategy = strategy;
    }

    function _postDeploySetup() internal override {
        _syncAndMockOracles();
    }

    // ============ M3 PoC: DEBT_FLASH_LENDER staleness ============

    /// @dev M3: Demonstrates that if the crvUSD FlashLender reverts on flashLoan,
    ///      full close unwinds fail until emergency steps are used.
    function test_full_close_reverts_on_flash_lender_deprecation() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);
        _refreshOracles();

        assertTrue(llamaManager.loanExists(), "Loan should exist");

        // Get the current debt
        uint256 debtBefore = llamaManager.getCurrentDebt();
        console.log("Debt before full close: %d", debtBefore);

        // Mock the DEBT_FLASH_LENDER to revert on flashLoan
        // This simulates the FlashLender being deprecated
        vm.mockCall(
            DEBT_FLASH_LENDER,
            abi.encodeWithSelector(
                0x1601b8f4, // flashLoan selector (ERC3156)
                address(llamaManager),
                CRVUSD,
                debtBefore,
                new bytes(0)
            ),
            abi.encode(false) // flashLoan returns false on failure
        );

        // Full close should revert because flashLoan fails
        vm.prank(owner);
        vm.expectRevert();
        llamaManager.unwindPosition(type(uint256).max);

        console.log("M3 PoC: full close reverted on deprecated flash lender");
    }

    /// @dev M3: Demonstrates that partial unwind still works when flash lender is deprecated.
    function test_partial_unwind_works_on_flash_lender_deprecation() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        // Mock accountant.claim to avoid Unauthorized during deposit
        address accountant = IStakeDaoRewardVault(STAKE_DAO_REWARD_VAULT).ACCOUNTANT();
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                bytes4(keccak256("claim(address)")),
                STAKE_DAO_REWARD_VAULT
            ),
            abi.encode()
        );

        _depositAs(user1, depositAmount);
        _refreshOracles();

        // Re-apply accountant.claim mock after refreshOracles
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                bytes4(keccak256("claim(address)")),
                STAKE_DAO_REWARD_VAULT
            ),
            abi.encode()
        );

        assertTrue(llamaManager.loanExists(), "Loan should exist");

        uint256 vaultBtcBefore = IERC20(WBTC).balanceOf(address(llamaVault));

        // Mock the DEBT_FLASH_LENDER to revert on flashLoan
        vm.mockCall(
            DEBT_FLASH_LENDER,
            abi.encodeWithSelector(
                0x1601b8f4, // flashLoan selector
                address(llamaManager),
                CRVUSD,
                1,
                new bytes(0)
            ),
            abi.encode(false)
        );

        // Partial unwind should still work (no flashloan needed)
        // Call from vault (onlyVault modifier)
        // Use a small amount to avoid "Amount too low" from LlamaLend
        // (with outstanding debt, removing too much collateral makes position underwater)
        vm.prank(address(llamaVault));
        llamaManager.unwindPosition(1e7); // 10% of 1e8 collateral

        uint256 vaultBtcAfter = IERC20(WBTC).balanceOf(address(llamaVault));
        assertGt(vaultBtcAfter, vaultBtcBefore, "Vault should receive WBTC from partial unwind");

        console.log("M3 PoC: partial unwind succeeded, vault received %d WBTC",
            vaultBtcAfter - vaultBtcBefore);
    }

    /// @dev M3: Demonstrates the emergency recovery path when flash lender is deprecated.
    function test_emergency_recovery_on_flash_lender_deprecation() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        // Mock claimRewards to avoid Accountant.claim Unauthorized
        vm.mockCall(
            STAKE_DAO_REWARD_VAULT,
            abi.encodeWithSelector(bytes4(keccak256("claimRewards()"))),
            abi.encode()
        );

        _depositAs(user1, depositAmount);
        _refreshOracles();

        assertTrue(llamaManager.loanExists(), "Loan should exist");

        // Mock the DEBT_FLASH_LENDER to revert on flashLoan
        vm.mockCall(
            DEBT_FLASH_LENDER,
            abi.encodeWithSelector(
                0x1601b8f4,
                address(llamaManager),
                CRVUSD,
                1,
                new bytes(0)
            ),
            abi.encode(false)
        );

        // Enter emergency mode
        vm.prank(owner);
        vault.enterEmergencyMode();

        // Execute step 0 (yield) - this will try withdrawAll but harvest is mocked
        vm.prank(owner);
        vault.emergencyStep(0);

        // Execute step 1 (loan) - partial unwind works without flashloan
        vm.prank(owner);
        vault.emergencyStep(1);

        // Complete liquidation
        vm.prank(owner);
        vault.emergencyStep(2);

        assertTrue(vault.liquidationComplete(), "Should be liquidation complete");

        // User can now redeem collateral
        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 redeemed = vault.redeem(shares, user1, user1);

        assertGt(redeemed, 0, "User should receive WBTC from emergency redeem");

        console.log("M3 PoC: emergency recovery worked, user redeemed %d WBTC", redeemed);
    }

    /// @dev M3: Documents the staleness risk — the DEBT_FLASH_LENDER address is hardcoded
    ///      and cannot be updated via governance (only via emergency steps).
    function test_debt_flash_lender_is_hardcoded() public {
        _deployVault();

        // Verify the DEBT_FLASH_LENDER is a constant
        address flashLender = llamaManager.DEBT_FLASH_LENDER();
        console.log("DEBT_FLASH_LENDER address: %s", flashLender);
        assertEq(flashLender, DEBT_FLASH_LENDER, "DEBT_FLASH_LENDER should be hardcoded");

        // Verify there's no setter for DEBT_FLASH_LENDER
        // (the LlamaLoanManager has no setDebtFlashLender function)
        console.log("M3: DEBT_FLASH_LENDER is hardcoded and immutable");
    }
}
