// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { AaveLoanManager } from "../src/lenders/AaveLoanManager.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";
import { CbBtcWbtcUsdtSwapper } from "../src/swappers/base/CbBtcWbtcUsdtSwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IYieldVault } from "../src/interfaces/IYieldVault.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title H-6 Verification: IPOR PlasmaVault withdrawal cooldown DoS
/// @notice Tests whether a deposit to Zenji triggers an IPOR cooldown that blocks
///         subsequent withdrawal attempts.
///
/// Hypothesis: IF any user deposits to Zenji (triggering iporVault.deposit()),
/// THEN withdrawal attempts will revert due to IPOR's internal withdrawal cooldown.
///
/// Key distinction: Zenji has its own 1-block cooldown (lastInBlock). The IPOR
/// hypothesis claims an ADDITIONAL cooldown on the IPOR side that persists BEYOND
/// the Zenji 1-block cooldown.
contract VerifyH6ForkTest is Test {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_CBBTC = 0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    address constant CBBTC_USD_ORACLE = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant CURVE_USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    int128 constant USDT_INDEX = 0;
    int128 constant CRVUSD_INDEX = 1;

    address constant CBBTC_WBTC_POOL = 0x839d6bDeDFF886404A6d7a788ef241e4e28F4802;
    uint256 constant CBBTC_INDEX = 0;
    uint256 constant WBTC_INDEX = 1;

    address constant TRICRYPTO_POOL = 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4;
    uint256 constant TRICRYPTO_USDT_INDEX = 0;
    uint256 constant TRICRYPTO_WBTC_INDEX = 1;

    address constant CBBTC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    Zenji vault;
    ZenjiViewHelper viewHelper;
    AaveLoanManager loanManager;
    UsdtIporYieldStrategy strategy;
    CbBtcWbtcUsdtSwapper swapper;

    IERC20 cbbtc;
    IYieldVault iporVault;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        }
        require(bytes(rpcUrl).length > 0, "RPC URL required");
        vm.createSelectFork(rpcUrl);

        (,, uint256 cbBtcUpdate,,) = IChainlinkOracle(CBBTC_USD_ORACLE).latestRoundData();
        if (cbBtcUpdate + 1 > block.timestamp) {
            vm.warp(cbBtcUpdate + 1);
        }
        _refreshOracles();

        cbbtc = IERC20(CBBTC);
        iporVault = IYieldVault(IPOR_PLASMA_VAULT);

        viewHelper = new ZenjiViewHelper();
        swapper = new CbBtcWbtcUsdtSwapper(
            owner, CBBTC, USDT, WBTC,
            CBBTC_WBTC_POOL, CBBTC_INDEX, WBTC_INDEX,
            TRICRYPTO_POOL, TRICRYPTO_WBTC_INDEX, TRICRYPTO_USDT_INDEX,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE, 3_600
        );
        loanManager = new AaveLoanManager(
            CBBTC, USDT, AAVE_A_CBBTC, AAVE_VAR_DEBT_USDT, AAVE_POOL,
            CBBTC_USD_ORACLE, USDT_USD_ORACLE, address(swapper), 7500, 8000, address(0), 0, 3600
        );
        strategy = new UsdtIporYieldStrategy(
            USDT, CRVUSD, address(0), CURVE_USDT_CRVUSD_POOL, IPOR_PLASMA_VAULT,
            USDT_INDEX, CRVUSD_INDEX, CRVUSD_USD_ORACLE, USDT_USD_ORACLE
        );
        vault = new Zenji(
            CBBTC, USDT, address(loanManager), address(strategy),
            address(swapper), owner, address(viewHelper)
        );
        loanManager.initializeVault(address(vault));
        strategy.initializeVault(address(vault));

        vm.prank(address(vault));
        strategy.setSlippage(5e16);
        vm.store(address(swapper), bytes32(uint256(0)), bytes32(uint256(5e16)));

        vm.prank(CBBTC_WHALE);
        cbbtc.transfer(user, 2e8);
        vm.prank(CBBTC_WHALE);
        cbbtc.transfer(attacker, 1e6);

        vm.prank(user);
        cbbtc.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        cbbtc.approve(address(vault), type(uint256).max);
    }

    /// @notice CORE TEST: After deposit triggers IPOR deposit, +1 block is insufficient
    ///         to clear the effective cooldown for redemption.
    ///
    /// Current observed behavior: redeem reverts after only +1 block.
    function test_H6_IPORCooldownBlocksNextBlockRedeem() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) {
            console.log("SKIP: IPOR vault at deposit cap");
            return;
        }

        // === Record initial state ===
        uint256 iporSharesBefore = iporVault.balanceOf(address(strategy));

        // === STEP 1: Deposit - triggers iporVault.deposit() internally ===
        uint256 depositAmount = 1e7; // 0.1 cbBTC
        vm.prank(user);
        vault.deposit(depositAmount, user);

        uint256 userShares = vault.balanceOf(user);
        uint256 iporSharesAfter = iporVault.balanceOf(address(strategy));

        console.log("IPOR shares before deposit:", iporSharesBefore);
        console.log("IPOR shares after deposit:", iporSharesAfter);
        assertGt(iporSharesAfter, iporSharesBefore, "IPOR deposit must occur for test to be valid");
        assertGt(userShares, 0, "User must have Zenji shares");

        // === STEP 2: Advance +1 block, NO time advance ===
        // This clears Zenji's own 1-block cooldown (lastInBlock).
        // We do NOT warp time to isolate any IPOR time-based cooldown.
        vm.roll(block.number + 1);
        _refreshOracles();

        // === STEP 3: Attempt redeem - the critical assertion ===
        // If IPOR has a block-based cooldown > 1 block: revert -> CONFIRMED
        // If IPOR has a time-based cooldown and we advanced no time: revert -> CONFIRMED
        // If no additional cooldown: succeed -> FALSE_POSITIVE
        bool reverted = false;
        bytes4 revertSelector;
        uint256 received = 0;

        vm.prank(user);
        try vault.redeem(userShares / 2, user, user) returns (uint256 r) {
            received = r;
        } catch (bytes memory data) {
            reverted = true;
            if (data.length >= 4) {
                assembly { revertSelector := mload(add(data, 32)) }
            }
        }

        console.log("Reverted:", reverted);
        console.log("Received:", received);
        if (reverted) {
            console.logBytes4(revertSelector);
        }

        assertTrue(
            reverted,
            "Expected redeem to remain blocked after only 1 block"
        );
        console.log("CONFIRMED: redeem remains blocked after only 1 block");
    }

    /// @notice ATTACKER SCENARIO: Attacker deposits minimum amount after user has a position,
    ///         refreshing the IPOR cooldown. Does this block the user from withdrawing?
    function test_H6_AttackerGriefingScenario() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) {
            console.log("SKIP: IPOR vault at deposit cap");
            return;
        }

        // === User establishes a position ===
        vm.prank(user);
        vault.deposit(1e7, user);
        uint256 userShares = vault.balanceOf(user);

        // Advance time to clear all initial cooldowns (Zenji + any IPOR)
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        _refreshOracles();

        // Verify user can withdraw at baseline
        uint256 snapshotId = vm.snapshot();
        vm.prank(user);
        bool baselineWorked = false;
        try vault.redeem(userShares / 4, user, user) returns (uint256) {
            baselineWorked = true;
        } catch { }
        vm.revertTo(snapshotId);

        console.log("Baseline withdrawal works:", baselineWorked);
        if (!baselineWorked) {
            console.log("SKIP: Baseline withdrawal already fails - cannot isolate attack");
            return;
        }

        // === ATTACKER deposits minimum (1e4 = MIN_DEPOSIT) to trigger IPOR deposit ===
        vm.prank(attacker);
        vault.deposit(1e4, attacker);
        console.log("Attacker deposited 1e4 cbBTC units (minimum deposit)");

        // === Advance ONLY Zenji's 1-block cooldown (no time) ===
        vm.roll(block.number + 1);
        _refreshOracles();

        // === User attempts withdrawal - is it now blocked? ===
        bool blockedByAttack = false;
        uint256 received = 0;
        vm.prank(user);
        try vault.redeem(userShares / 4, user, user) returns (uint256 r) {
            received = r;
        } catch {
            blockedByAttack = true;
        }

        console.log("After attacker deposit + 1 block:");
        console.log("User blocked:", blockedByAttack);
        console.log("User received:", received);

        // If blockedByAttack == true: griefing attack CONFIRMED
        // If blockedByAttack == false: no griefing possible (FALSE_POSITIVE)
        if (blockedByAttack) {
            console.log("H6 CONFIRMED: Attacker can block user withdrawals via minimal deposit");

            // Measure: does time advance fix it?
            vm.warp(block.timestamp + 2);
            vm.roll(block.number + 1);
            _refreshOracles();

            vm.prank(user);
            try vault.redeem(userShares / 4, user, user) returns (uint256 r2) {
                console.log("After +2s +1 block: unblocked, received:", r2);
            } catch {
                console.log("After +2s +1 block: still blocked");
            }
        } else {
            console.log("FALSE_POSITIVE: Attack does not block user withdrawals");
        }
    }

    /// @notice DEFENDER TEST: The existing test suite pattern (vm.warp +2s + 1 block)
    ///         always works. This confirms the cooldown is trivially short even if it exists.
    function test_H6_ExistingTestPatternAlwaysWorks() public {
        if (iporVault.maxDeposit(address(vault)) < 1e18) {
            console.log("SKIP: IPOR vault at deposit cap");
            return;
        }

        // Deposit
        vm.prank(user);
        vault.deposit(1e7, user);
        uint256 userShares = vault.balanceOf(user);

        // Standard test pattern: 2 seconds + 1 block
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        _refreshOracles();

        // This MUST succeed - it mirrors what existing tests already do
        vm.prank(user);
        uint256 received = vault.redeem(userShares / 2, user, user);

        assertGt(received, 0, "Withdrawal with standard time advance must succeed");
        console.log("DEFENDER: Standard pattern (2s+1block) succeeds, received:", received);
        console.log("Cooldown duration is AT MOST 2 seconds (trivially short)");
    }

    function _mockOracle(address oracle) internal {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkOracle(oracle).latestRoundData();
        uint256 timestamp = block.timestamp > updatedAt ? block.timestamp : updatedAt;
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(roundId, answer, timestamp, timestamp, answeredInRound)
        );
    }

    function _refreshOracles() internal {
        _mockOracle(CBBTC_USD_ORACLE);
        _mockOracle(USDT_USD_ORACLE);
        _mockOracle(CRVUSD_USD_ORACLE);
    }
}
