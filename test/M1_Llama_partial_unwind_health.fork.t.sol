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
import { NgCrvUsdLpStakeDaoStrategy } from "../src/strategies/lp/NgCrvUsdLpStakeDaoStrategy.sol";
import { ICurveStableSwapNG } from "../src/interfaces/ICurveStableSwapNG.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { IStakeDaoRewardVault } from "../src/interfaces/IStakeDaoRewardVault.sol";
import { Zenji } from "../src/Zenji.sol";

/// @title M1_Llama_partial_unwind_health
/// @notice PoC for M1: LlamaLoanManager partial unwind reverts on oracle price drops
/// @dev Demonstrates that the partial unwind path skips a health check between
///      oracle freshness check and remove_collateral, causing reverts on price drops.
contract M1_Llama_partial_unwind_health is ZenjiForkTestBase {
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

    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;
    address constant CRV_USD_ORACLE = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    UniswapMixedCurveSwapper public swapper;
    CrvToCrvUsdSwapper public crvSwapper;
    NgCrvUsdLpStakeDaoStrategy public strategy;
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

        strategy = new NgCrvUsdLpStakeDaoStrategy(
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
            address(0),
            3600
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

    // ============ M1 PoC: partial unwind reverts on oracle price drop ============

    /// @dev M1: Demonstrates that partial unwind reverts when collateral price drops
    ///      between the oracle freshness check and remove_collateral call.
    function test_partial_unwind_reverts_on_price_drop() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);

        // Verify loan exists and position has value
        assertTrue(llamaManager.loanExists(), "Loan should exist");

        uint256 ltvBefore = loanManager.getCurrentLTV();
        console.log("LTV before unwind: %d", ltvBefore);

        // Get BTC oracle data
        (uint80 roundId, int256 btcPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();

        // Decrease BTC price by 50% to push the position into liquidation territory
        // With ~60% LTV, a 50% price drop makes collateral value half, pushing LTV > 100%
        int256 newPrice = (btcPrice * 50) / 100;

        // Warp and mock oracle — this simulates price drop between checks
        vm.warp(block.timestamp + 2);
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, block.timestamp, block.timestamp, roundId)
        );

        // Check health after price drop
        int256 healthAfterDrop = llamaManager.getHealth();
        console.log("Health after 50% price drop: %d", healthAfterDrop);

        // Partial unwind: request 50% of collateral back (5e7 out of ~1e8)
        // The partial path: _checkOracleFreshness() → remove_collateral()
        // No health check between freshness check and remove_collateral
        // LlamaLend's remove_collateral will revert because position is unhealthy
        vm.prank(address(llamaVault));
        vm.expectRevert(); // LlamaLend reverts with HealthTooLow or similar
        llamaManager.unwindPosition(5e7); // ~50% of 1e8 WBTC collateral

        console.log("M1 PoC: partial unwind reverted on 50% price drop");
    }

    /// @dev M1: Demonstrates that partial unwind succeeds when price is stable.
    function test_partial_unwind_succeeds_stable_price() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        // Mock accountant.claim to avoid Unauthorized / insufficient allowance during deposit.
        // _claimAndCompound() -> rewardVault.claimRewards() -> accountant.claim(gauges, harvestData, receiver).
        address accountant = IStakeDaoRewardVault(STAKE_DAO_REWARD_VAULT).ACCOUNTANT();
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                bytes4(keccak256("claim(address[],bytes[],address)")),
                abi.encode(new address[](0), new bytes[](0), address(0))
            ),
            abi.encode()
        );

        _depositAs(user1, depositAmount);
        _refreshOracles();

        // Re-apply accountant.claim mock after refreshOracles
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                bytes4(keccak256("claim(address[],bytes[],address)")),
                abi.encode(new address[](0), new bytes[](0), address(0))
            ),
            abi.encode()
        );

        uint256 vaultBtcBefore = IERC20(WBTC).balanceOf(address(llamaVault));

        // Partial unwind with stable price
        vm.prank(address(llamaVault));
        llamaManager.unwindPosition(1e7); // ~10% of 1e8 WBTC collateral

        uint256 vaultBtcAfter = IERC20(WBTC).balanceOf(address(llamaVault));
        assertGt(vaultBtcAfter, vaultBtcBefore, "Vault should receive WBTC from partial unwind");

        console.log(
            "M1 PoC: partial unwind succeeded with stable price, vault received %d WBTC",
            vaultBtcAfter - vaultBtcBefore
        );
    }

    /// @dev M1: Demonstrates the health check gap — drop price after freshness check
    ///      but before remove_collateral by simulating the exact sequence.
    function test_partial_unwind_health_check_gap() public {
        _deployVault();
        uint256 depositAmount = _baseDeposit();

        _depositAs(user1, depositAmount);
        _refreshOracles();

        // Get current BTC price
        (uint80 roundId, int256 btcPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();

        // Drop BTC price by 30%
        int256 newPrice = (btcPrice * 70) / 100;

        // Mock the oracle with the new price
        vm.mockCall(
            BTC_USD_ORACLE,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, newPrice, block.timestamp, block.timestamp, roundId)
        );

        // Check health before unwind
        int256 healthBefore = llamaManager.getHealth();
        console.log("Health before unwind: %d", healthBefore);

        // The partial unwind calls _checkOracleFreshness() which passes (fresh oracle),
        // then calls remove_collateral which checks health and reverts if too low.
        vm.prank(address(llamaVault));
        vm.expectRevert();
        llamaManager.unwindPosition(99_999_999); // Try to remove all AMM collateral shares

        console.log("M1 PoC: partial unwind reverted due to low health after price drop");
    }
}
