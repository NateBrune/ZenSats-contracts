// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { SafeTransferLib } from "../src/libraries/SafeTransferLib.sol";
import { OracleLib } from "../src/libraries/OracleLib.sol";
import { CurveUsdtSwapLib } from "../src/libraries/CurveUsdtSwapLib.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { BaseSwapper } from "../src/swappers/base/BaseSwapper.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";

// ============ Harness Contracts ============

contract TimelockHarness {
    using TimelockLib for TimelockLib.TimelockData;
    using TimelockLib for TimelockLib.AddressTimelockData;

    TimelockLib.TimelockData public data;
    TimelockLib.AddressTimelockData public addrData;

    function propose(uint256 newValue, uint256 delay) external {
        data.propose(newValue, delay);
    }

    function execute() external returns (uint256) {
        return data.execute();
    }

    function cancel() external returns (uint256) {
        return data.cancel();
    }

    function proposeAddress(address newValue, uint256 delay) external {
        addrData.proposeAddress(newValue, delay);
    }

    function executeAddress() external returns (address) {
        return addrData.executeAddress();
    }

    function cancelAddress() external returns (address) {
        return addrData.cancelAddress();
    }
}

contract SafeTransferHarness {
    using SafeTransferLib for IERC20;

    function safeTransfer(address token, address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) external {
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function ensureApproval(address token, address spender, uint256 amount) external {
        IERC20(token).ensureApproval(spender, amount);
    }

    function safeApprove(address token, address spender, uint256 amount) external {
        IERC20(token).safeApprove(spender, amount);
    }
}

// ============ Mock Tokens ============

/// @notice Token that returns false from transfer/transferFrom
contract MockFailToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Token that reverts on approve (simulates USDT reset failure)
contract MockRevertApproveToken {
    mapping(address => mapping(address => uint256)) private _allowances;

    bool public shouldRevertOnApprove;

    function setRevertOnApprove(bool val) external {
        shouldRevertOnApprove = val;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (shouldRevertOnApprove && amount == 0) {
            revert("approve reverted");
        }
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Normal mock token for SafeTransferLib tests
contract MockGoodToken {
    mapping(address => mapping(address => uint256)) private _allowances;

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

// ============ Mock Oracle ============

contract MockOracleFull {
    uint8 public decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setPrice(int256 price_) external {
        price = price_;
        updatedAt = block.timestamp;
    }

    function setStale(uint256 staleness) external {
        updatedAt = block.timestamp - staleness;
    }

    function setAnsweredBehind() external {
        answeredInRound = roundId - 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, block.timestamp, updatedAt, answeredInRound);
    }
}

/// @notice Mock ERC20 for oracle tests
contract MockTokenDecimals {
    uint8 public decimals;

    constructor(uint8 dec_) {
        decimals = dec_;
    }
}

// ============ Concrete swapper for BaseSwapper tests ============

contract ConcreteSwapper is BaseSwapper, ISwapper {
    constructor(address _gov) BaseSwapper(_gov) { }

    function quoteCollateralForDebt(uint256) external pure returns (uint256) {
        return 0;
    }

    function swapCollateralForDebt(uint256) external pure returns (uint256) {
        return 0;
    }

    function swapDebtForCollateral(uint256) external pure returns (uint256) {
        return 0;
    }
}

// ============ Tests ============

contract TimelockLibTest is Test {
    TimelockHarness harness;

    function setUp() public {
        harness = new TimelockHarness();
    }

    function test_execute_no_pending_reverts() public {
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        harness.execute();
    }

    function test_execute_not_ready_reverts() public {
        harness.propose(42, 2 days);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        harness.execute();
    }

    function test_execute_expired_reverts() public {
        harness.propose(42, 2 days);
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        vm.expectRevert(TimelockLib.TimelockExpired.selector);
        harness.execute();
    }

    function test_cancel_no_pending_reverts() public {
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        harness.cancel();
    }

    function test_execute_success() public {
        harness.propose(99, 2 days);
        vm.warp(block.timestamp + 2 days + 1);
        uint256 val = harness.execute();
        assertEq(val, 99);
    }

    // Address timelock tests
    function test_executeAddress_no_pending_reverts() public {
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        harness.executeAddress();
    }

    function test_executeAddress_not_ready_reverts() public {
        harness.proposeAddress(address(1), 2 days);
        vm.expectRevert(TimelockLib.TimelockNotReady.selector);
        harness.executeAddress();
    }

    function test_executeAddress_expired_reverts() public {
        harness.proposeAddress(address(1), 2 days);
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        vm.expectRevert(TimelockLib.TimelockExpired.selector);
        harness.executeAddress();
    }

    function test_cancelAddress_no_pending_reverts() public {
        vm.expectRevert(TimelockLib.NoTimelockPending.selector);
        harness.cancelAddress();
    }
}

contract SafeTransferLibTest is Test {
    SafeTransferHarness harness;

    function setUp() public {
        harness = new SafeTransferHarness();
    }

    function test_safeTransfer_fail_token_reverts() public {
        MockFailToken token = new MockFailToken();
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        harness.safeTransfer(address(token), address(1), 100);
    }

    function test_safeTransferFrom_fail_token_reverts() public {
        MockFailToken token = new MockFailToken();
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        harness.safeTransferFrom(address(token), address(this), address(1), 100);
    }

    function test_ensureApproval_skip_when_sufficient() public {
        MockGoodToken token = new MockGoodToken();
        // First call sets max approval
        harness.ensureApproval(address(token), address(1), 100);
        // Second call should skip because allowance is max
        harness.ensureApproval(address(token), address(1), 100);
    }

    function test_safeApprove_reset_to_zero_path() public {
        MockGoodToken token = new MockGoodToken();
        // Set non-zero allowance first
        harness.safeApprove(address(token), address(1), 50);
        // Now approve with existing allowance > 0 triggers USDT reset-to-zero path
        harness.safeApprove(address(token), address(1), 100);
    }

    function test_safeApprove_reset_failure_reverts() public {
        MockRevertApproveToken token = new MockRevertApproveToken();
        // Set non-zero allowance
        harness.safeApprove(address(token), address(1), 50);
        // Make reset-to-zero revert
        token.setRevertOnApprove(true);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        harness.safeApprove(address(token), address(1), 100);
    }
}

contract OracleLibTest is Test {
    MockOracleFull collateralOracle;
    MockOracleFull debtOracle;
    MockTokenDecimals collateralToken;
    MockTokenDecimals debtToken;

    function setUp() public {
        collateralOracle = new MockOracleFull(8, 50000e8); // BTC $50k
        debtOracle = new MockOracleFull(8, 1e8); // USDT $1
        collateralToken = new MockTokenDecimals(8); // WBTC
        debtToken = new MockTokenDecimals(6); // USDT
    }

    function test_staleOracle_answeredBehind() public {
        vm.warp(200000);
        collateralOracle = new MockOracleFull(8, 50000e8);
        collateralOracle.setAnsweredBehind();
        vm.expectRevert(OracleLib.StaleOracle.selector);
        OracleLib.getCollateralUsdValue(
            1e8,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IERC20(address(collateralToken))
        );
    }

    function test_invalidPrice_zero() public {
        collateralOracle.setPrice(0);
        vm.expectRevert(OracleLib.InvalidPrice.selector);
        OracleLib.getCollateralUsdValue(
            1e8,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IERC20(address(collateralToken))
        );
    }

    function test_invalidPrice_negative() public {
        collateralOracle.setPrice(-1);
        vm.expectRevert(OracleLib.InvalidPrice.selector);
        OracleLib.getCollateralUsdValue(
            1e8,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IERC20(address(collateralToken))
        );
    }

    function test_getCollateralUsdValue_zero_amount() public view {
        uint256 val = OracleLib.getCollateralUsdValue(
            0, IChainlinkOracle(address(collateralOracle)), 90000, IERC20(address(collateralToken))
        );
        assertEq(val, 0);
    }

    function test_getDebtUsdValue_zero_amount() public view {
        uint256 val = OracleLib.getDebtUsdValue(
            0, IChainlinkOracle(address(debtOracle)), 90000, IERC20(address(debtToken))
        );
        assertEq(val, 0);
    }

    function test_getCollateralValue_zero_amount_aave() public view {
        uint256 val = OracleLib.getCollateralValue(
            0,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000,
            IERC20(address(collateralToken)),
            IERC20(address(debtToken))
        );
        assertEq(val, 0);
    }

    function test_getDebtValue_zero_amount_aave() public view {
        uint256 val = OracleLib.getDebtValue(
            0,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000,
            IERC20(address(collateralToken)),
            IERC20(address(debtToken))
        );
        assertEq(val, 0);
    }

    function test_getCollateralValue_zero_amount_llama() public view {
        uint256 val = OracleLib.getCollateralValue(
            0,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000,
            IERC20(address(collateralToken))
        );
        assertEq(val, 0);
    }

    function test_getDebtValue_zero_amount_llama() public view {
        uint256 val = OracleLib.getDebtValue(
            0,
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000,
            IERC20(address(collateralToken))
        );
        assertEq(val, 0);
    }

    function test_checkOracleFreshness_stale_collateral() public {
        vm.warp(200000);
        collateralOracle = new MockOracleFull(8, 50000e8);
        collateralOracle.setStale(100000);
        debtOracle = new MockOracleFull(8, 1e8);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        OracleLib.checkOracleFreshness(
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000
        );
    }

    function test_checkOracleFreshness_stale_debt() public {
        vm.warp(200000);
        collateralOracle = new MockOracleFull(8, 50000e8);
        debtOracle = new MockOracleFull(8, 1e8);
        debtOracle.setStale(100000);
        vm.expectRevert(OracleLib.StaleOracle.selector);
        OracleLib.checkOracleFreshness(
            IChainlinkOracle(address(collateralOracle)),
            90000,
            IChainlinkOracle(address(debtOracle)),
            90000
        );
    }
}

contract BaseSwapperTest is Test {
    address gov = makeAddr("gov");

    function test_constructor_zero_address_reverts() public {
        vm.expectRevert(ISwapper.InvalidAddress.selector);
        new ConcreteSwapper(address(0));
    }

    function test_transferGovernance_zero_address_reverts() public {
        ConcreteSwapper swapper = new ConcreteSwapper(gov);
        vm.prank(gov);
        vm.expectRevert(ISwapper.InvalidAddress.selector);
        swapper.transferGovernance(address(0));
    }

    function test_acceptGovernance_wrong_caller_reverts() public {
        ConcreteSwapper swapper = new ConcreteSwapper(gov);
        address newGov = makeAddr("newGov");
        vm.prank(gov);
        swapper.transferGovernance(newGov);

        vm.prank(makeAddr("random"));
        vm.expectRevert(BaseSwapper.Unauthorized.selector);
        swapper.acceptGovernance();
    }

    function test_setSlippage_exactly_precision_reverts() public {
        ConcreteSwapper swapper = new ConcreteSwapper(gov);
        vm.prank(gov);
        vm.expectRevert(BaseSwapper.InvalidSlippage.selector);
        swapper.setSlippage(1e18); // exactly PRECISION
    }
}

/// @notice Wrapper to expose CurveUsdtSwapLib internal functions for testing with vm.expectRevert
contract CurveUsdtSwapLibWrapper {
    function convertCrvUsdToUsdt(
        uint256 crvUsdValue,
        IChainlinkOracle crvUsdOracle,
        IChainlinkOracle usdtOracle,
        uint256 maxStaleness
    ) external view returns (uint256) {
        return CurveUsdtSwapLib.convertCrvUsdToUsdt(
            crvUsdValue, crvUsdOracle, usdtOracle, maxStaleness
        );
    }
}

contract CurveUsdtSwapLibTest is Test {
    MockOracleFull crvUsdOracle;
    MockOracleFull usdtOracle;
    CurveUsdtSwapLibWrapper wrapper;

    function setUp() public {
        crvUsdOracle = new MockOracleFull(8, 1e8);
        usdtOracle = new MockOracleFull(8, 1e8);
        wrapper = new CurveUsdtSwapLibWrapper();
    }

    function test_convertCrvUsdToUsdt_stale_crvUsd_reverts() public {
        vm.warp(200000);
        crvUsdOracle = new MockOracleFull(8, 1e8);
        crvUsdOracle.setStale(100000);
        usdtOracle = new MockOracleFull(8, 1e8);
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_stale_usdt_reverts() public {
        vm.warp(200000);
        crvUsdOracle = new MockOracleFull(8, 1e8);
        usdtOracle = new MockOracleFull(8, 1e8);
        usdtOracle.setStale(100000);
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_negative_crvUsd_price_reverts() public {
        crvUsdOracle.setPrice(-1);
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_negative_usdt_price_reverts() public {
        usdtOracle.setPrice(-1);
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_answeredBehind_crvUsd_reverts() public {
        vm.warp(200000);
        crvUsdOracle = new MockOracleFull(8, 1e8);
        crvUsdOracle.setAnsweredBehind();
        usdtOracle = new MockOracleFull(8, 1e8);
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_answeredBehind_usdt_reverts() public {
        vm.warp(200000);
        crvUsdOracle = new MockOracleFull(8, 1e8);
        usdtOracle = new MockOracleFull(8, 1e8);
        usdtOracle.setAnsweredBehind();
        vm.expectRevert(CurveUsdtSwapLib.StaleOrInvalidOracle.selector);
        wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
    }

    function test_convertCrvUsdToUsdt_zero_returns_zero() public view {
        uint256 result = wrapper.convertCrvUsdToUsdt(
            0, IChainlinkOracle(address(crvUsdOracle)), IChainlinkOracle(address(usdtOracle)), 90000
        );
        assertEq(result, 0);
    }

    function test_convertCrvUsdToUsdt_normal() public view {
        uint256 result = wrapper.convertCrvUsdToUsdt(
            1e18,
            IChainlinkOracle(address(crvUsdOracle)),
            IChainlinkOracle(address(usdtOracle)),
            90000
        );
        // Both at $1, so 1e18 crvUSD = 1e6 USDT
        assertEq(result, 1e6);
    }
}
