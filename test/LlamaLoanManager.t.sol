// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";
import { LoanManagerTestBase, MockERC20 } from "./base/LoanManagerTestBase.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ILlamaLendController } from "../src/interfaces/ILlamaLendController.sol";
import { ICurveTwoCrypto } from "../src/interfaces/ICurveTwoCrypto.sol";
import { IChainlinkOracle } from "../src/interfaces/IChainlinkOracle.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

// ============ Llama-Specific Mocks ============

contract MockOracle is IChainlinkOracle {
    uint8 public immutable decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals, int256 _price) {
        decimals = _decimals;
        price = _price;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setPrice(int256 _price) external {
        price = _price;
        roundId++;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setAnsweredInRound(uint80 _answered) external {
        answeredInRound = _answered;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }

    function description() external pure returns (string memory) {
        return "Mock Oracle";
    }

    function latestAnswer() external view returns (int256) {
        return price;
    }
}

contract MockTwoCrypto is ICurveTwoCrypto {
    MockERC20 public wbtc;
    MockERC20 public crvUSD;
    uint256 public rateCrvUsdPerWbtc;

    constructor(address _wbtc, address _crvUSD, uint256 _rate) {
        wbtc = MockERC20(_wbtc);
        crvUSD = MockERC20(_crvUSD);
        rateCrvUsdPerWbtc = _rate;
    }

    function setRate(uint256 _rate) external {
        rateCrvUsdPerWbtc = _rate;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return (dx * rateCrvUsdPerWbtc) / 1e8;
        if (i == 0 && j == 1) return (dx * 1e8) / rateCrvUsdPerWbtc;
        return 0;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256) external returns (uint256) {
        return exchange(i, j, dx, 0, msg.sender);
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256, address receiver)
        public
        returns (uint256)
    {
        if (i == 1 && j == 0) {
            wbtc.transferFrom(msg.sender, address(this), dx);
            uint256 out = (dx * rateCrvUsdPerWbtc) / 1e8;
            crvUSD.mint(receiver, out);
            return out;
        }
        if (i == 0 && j == 1) {
            crvUSD.transferFrom(msg.sender, address(this), dx);
            uint256 out = (dx * 1e8) / rateCrvUsdPerWbtc;
            wbtc.mint(receiver, out);
            return out;
        }
        return 0;
    }

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(crvUSD) : address(wbtc);
    }

    function balances(uint256 i) external view returns (uint256) {
        return i == 0 ? crvUSD.balanceOf(address(this)) : wbtc.balanceOf(address(this));
    }
}

contract MockLlamaLendController is ILlamaLendController {
    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address => Position) public positions;

    function create_loan(uint256 coll, uint256 debtAmount, uint256) external payable {
        positions[msg.sender].collateral += coll;
        positions[msg.sender].debt += debtAmount;
    }

    function add_collateral(uint256 coll) external payable {
        positions[msg.sender].collateral += coll;
    }

    function add_collateral(uint256 coll, address _for) external payable {
        positions[_for].collateral += coll;
    }

    function remove_collateral(uint256 coll) external {
        Position storage pos = positions[msg.sender];
        require(pos.collateral >= coll, "Insufficient collateral");
        pos.collateral -= coll;
    }

    function borrow_more(uint256 coll, uint256 debtAmount) external payable {
        positions[msg.sender].collateral += coll;
        positions[msg.sender].debt += debtAmount;
    }

    function repay(uint256 _d_debt) external {
        Position storage pos = positions[msg.sender];
        pos.debt = _d_debt >= pos.debt ? 0 : pos.debt - _d_debt;
    }

    function repay(uint256 _d_debt, address _for) external {
        Position storage pos = positions[_for];
        pos.debt = _d_debt >= pos.debt ? 0 : pos.debt - _d_debt;
    }

    function debt(address user) external view returns (uint256) {
        return positions[user].debt;
    }

    function loan_exists(address user) external view returns (bool) {
        Position memory pos = positions[user];
        return pos.debt > 0 || pos.collateral > 0;
    }

    function total_debt() external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function max_borrowable(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function min_collateral(uint256 debt_, uint256 bands) external pure returns (uint256) {
        return bands == 0 ? 0 : debt_ / bands;
    }

    function health(address) external pure returns (int256) {
        return 2e18;
    }

    function health(address, bool) external pure returns (int256) {
        return 2e18;
    }

    function health_calculator(address, int256, int256, bool) external pure returns (int256) {
        return 2e18;
    }

    function user_state(address user) external view returns (uint256[4] memory) {
        Position memory pos = positions[user];
        return [pos.collateral, 0, pos.debt, 0];
    }

    function amm_price() external pure returns (uint256) {
        return 0;
    }

    function user_prices(address) external pure returns (uint256[2] memory) {
        return [uint256(0), uint256(0)];
    }

    function collateral_token() external pure returns (address) {
        return address(0);
    }

    function amm() external pure returns (address) {
        return address(0);
    }

    function liquidation_discounts(address) external pure returns (uint256) {
        return 0;
    }

    function liquidation_discount() external pure returns (uint256) {
        return 0;
    }

    function loan_discount() external pure returns (uint256) {
        return 0;
    }
}

contract MockSwapper is ISwapper {
    MockERC20 public collateralToken;
    MockERC20 public debtToken;
    MockTwoCrypto public pool;

    constructor(address _collateral, address _debt, address _pool) {
        collateralToken = MockERC20(_collateral);
        debtToken = MockERC20(_debt);
        pool = MockTwoCrypto(_pool);
    }

    function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
        if (debtAmount == 0) return 0;
        return pool.get_dy(0, 1, debtAmount);
    }

    function swapCollateralForDebt(uint256 collateralAmount) external returns (uint256) {
        if (collateralAmount == 0) return 0;
        collateralToken.approve(address(pool), collateralAmount);
        uint256 received = pool.exchange(1, 0, collateralAmount, 0);
        debtToken.transfer(msg.sender, received);
        return received;
    }

    function swapDebtForCollateral(uint256 debtAmount) external returns (uint256) {
        if (debtAmount == 0) return 0;
        debtToken.approve(address(pool), debtAmount);
        uint256 received = pool.exchange(0, 1, debtAmount, 0);
        collateralToken.transfer(msg.sender, received);
        return received;
    }
}

// ============ Test Contract ============

contract LlamaLoanManagerTest is LoanManagerTestBase {
    MockERC20 wbtc;
    MockERC20 crvUSD;
    MockOracle oracle;
    MockOracle crvUsdOracle;
    MockTwoCrypto pool;
    MockLlamaLendController llamaLend;
    MockSwapper swapper;
    LlamaLoanManager llamaManager;

    function _deployManager() internal override {
        vm.warp(block.timestamp + 1 days);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        oracle = new MockOracle(8, 20_000e8);
        crvUsdOracle = new MockOracle(8, 1e8);
        pool = new MockTwoCrypto(address(wbtc), address(crvUSD), 20_000e18);
        llamaLend = new MockLlamaLendController();
        swapper = new MockSwapper(address(wbtc), address(crvUSD), address(pool));

        llamaManager = new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(llamaLend),
            address(pool),
            address(oracle),
            address(crvUsdOracle),
            address(swapper),
            vault
        );
        manager = ILoanManager(address(llamaManager));
        collateral = wbtc;
        debt = crvUSD;
    }

    function _deployDeferredManager() internal override returns (ILoanManager) {
        LlamaLoanManager deferred = new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(llamaLend),
            address(pool),
            address(oracle),
            address(crvUsdOracle),
            address(swapper),
            address(0)
        );
        return ILoanManager(address(deferred));
    }

    function _makeOracleStale() internal override {
        oracle.setUpdatedAt(block.timestamp - 2 hours);
    }

    function _makeOracleInvalidPrice() internal override {
        oracle.setPrice(0);
    }

    function _makeOracleStaleAnsweredInRound() internal override {
        oracle.setAnsweredInRound(0);
    }

    function _defaultCollateral() internal pure override returns (uint256) {
        return 1e8;
    }

    function _defaultDebt() internal pure override returns (uint256) {
        return 10_000e18;
    }

    function _defaultBands() internal pure override returns (uint256) {
        return 4;
    }

    function _newMockSwapper() internal override returns (address) {
        return address(new MockSwapper(address(wbtc), address(crvUSD), address(pool)));
    }

    // ============ Llama-Specific Tests ============

    function test_createLoan_borrow_repay_and_removeCollateral() public {
        manager.createLoan(1e8, 10_000e18, 4);
        assertEq(manager.getCurrentCollateral(), 1e8);
        assertEq(manager.getCurrentDebt(), 10_000e18);

        manager.addCollateral(5e7);
        assertEq(manager.getCurrentCollateral(), 1.5e8);

        manager.borrowMore(0, 1000e18);
        assertEq(manager.getCurrentDebt(), 11_000e18);

        crvUSD.mint(address(manager), 2000e18);
        manager.repayDebt(2000e18);
        assertEq(manager.getCurrentDebt(), 9000e18);

        manager.removeCollateral(5e7);
        assertEq(manager.getCurrentCollateral(), 1e8);
    }

    function test_minCollateral_and_positionValues() public view {
        uint256 minCol = manager.minCollateral(1000, 4);
        assertEq(minCol, 250);

        (uint256 c, uint256 d) = manager.getPositionValues();
        assertEq(c, 0);
        assertEq(d, 0);
    }

    function test_unwindPosition_fullClose() public {
        manager.createLoan(2e8, 10_000e18, 4);
        crvUSD.mint(address(manager), 10_000e18);

        manager.unwindPosition(type(uint256).max);
        assertEq(manager.getCurrentCollateral(), 0);
    }

    function test_createLoan_revertsOnStaleOracle() public {
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.createLoan(1e8, 10_000e18, 4);
    }

    function test_addCollateral_revertsOnStaleOracle() public {
        manager.createLoan(1e8, 10_000e18, 4);
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.addCollateral(1e7);
    }

    function test_borrowMore_revertsOnStaleOracle() public {
        manager.createLoan(1e8, 10_000e18, 4);
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.borrowMore(0, 100e18);
    }

    function test_repayDebt_revertsOnStaleOracle() public {
        manager.createLoan(1e8, 10_000e18, 4);
        crvUSD.mint(address(manager), 100e18);
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.repayDebt(100e18);
    }

    function test_transfer_revertsOnNonVault() public {
        wbtc.mint(address(manager), 1e8);
        vm.prank(nonVault);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        manager.transferCollateral(nonVault, 1e8);
    }

    function test_unwindPosition_partial_noFlashloan() public {
        manager.createLoan(1e8, 10_000e18, 4);

        uint256 d = llamaLend.debt(address(manager));
        crvUSD.mint(address(manager), d - 500);
        manager.repayDebt(d - 500);

        manager.unwindPosition(0.5e8);
    }

    function test_onFlashLoan_repayPartial() public {
        manager.createLoan(1e8, 10_000e18, 4);
        crvUSD.mint(address(manager), 1010e18);

        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        bytes memory data = abi.encode(0.5e8, false);
        llamaManager.onFlashLoan(address(llamaManager), address(crvUSD), 1000e18, 5e18, data);
        vm.stopPrank();
    }

    function test_onFlashLoan_unauthorizedInitiator() public {
        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        llamaManager.onFlashLoan(address(0xbad), address(crvUSD), 1000e18, 5e18, "");
    }

    function test_onFlashLoan_invalidToken() public {
        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        llamaManager.onFlashLoan(address(llamaManager), address(0xbad), 1000e18, 5e18, "");
    }

    function test_onFlashLoan_unauthorizedCaller() public {
        vm.prank(address(0xbad));
        vm.expectRevert(ILoanManager.Unauthorized.selector);
        llamaManager.onFlashLoan(address(llamaManager), address(crvUSD), 1000e18, 0, "");
    }

    function test_unwindPosition_noLoan_transfersWbtc() public {
        wbtc.mint(address(manager), 1e8);
        uint256 vaultBefore = wbtc.balanceOf(vault);
        manager.unwindPosition(5e7);
        assertEq(wbtc.balanceOf(vault) - vaultBefore, 1e8, "Should transfer all WBTC");
    }

    function test_unwindPosition_noLoan_noWbtc() public {
        manager.unwindPosition(5e7);
    }

    function test_unwindPosition_noLoan_fullClose() public {
        wbtc.mint(address(manager), 2e8);
        uint256 vaultBefore = wbtc.balanceOf(vault);
        manager.unwindPosition(type(uint256).max);
        assertEq(wbtc.balanceOf(vault) - vaultBefore, 2e8);
    }

    function test_unwindPosition_dustDebt_noFlashloan() public {
        manager.createLoan(2e8, 1e18, 4);
        crvUSD.mint(address(manager), 5e17);
        manager.unwindPosition(1e8);
        assertGt(wbtc.balanceOf(vault), 0);
    }

    function test_unwindPosition_dustDebt_fullRepayWithDust() public {
        manager.createLoan(2e8, 5e17, 4);
        crvUSD.mint(address(manager), 1e18);
        manager.unwindPosition(1e8);
    }

    function test_isDustDebt_exactThreshold() public {
        manager.createLoan(2e8, 1e18, 4);
        manager.unwindPosition(1e8);
    }

    function test_isDustDebt_aboveThreshold() public {
        manager.createLoan(2e8, 2e18, 4);
        assertTrue(llamaLend.loan_exists(address(manager)));
    }

    // ============ crvUSD Oracle Staleness ============

    function test_crvUsdOracle_stale_reverts() public {
        crvUsdOracle.setUpdatedAt(block.timestamp - 25201);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.checkOracleFreshness();
    }

    function test_crvUsdOracle_justFresh_succeeds() public view {
        manager.checkOracleFreshness();
    }

    function test_crvUsdOracle_invalidPrice_reverts() public {
        crvUsdOracle.setPrice(0);
        vm.expectRevert(ILoanManager.InvalidPrice.selector);
        manager.checkOracleFreshness();
    }

    function test_crvUsdOracle_negativePrice_reverts() public {
        crvUsdOracle.setPrice(-1);
        vm.expectRevert(ILoanManager.InvalidPrice.selector);
        manager.checkOracleFreshness();
    }

    function test_crvUsdOracle_answeredInRound_stale() public {
        crvUsdOracle.setAnsweredInRound(0);
        vm.expectRevert(ILoanManager.StaleOracle.selector);
        manager.checkOracleFreshness();
    }

    // ============ onFlashLoan Edge Cases ============

    function test_onFlashLoan_residualDebt() public {
        manager.createLoan(2e8, 10_000e18, 4);
        crvUSD.mint(address(manager), 11_000e18);

        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        bytes memory data = abi.encode(1e8, false);
        llamaManager.onFlashLoan(address(llamaManager), address(crvUSD), 1000e18, 5e18, data);
        vm.stopPrank();
    }

    function test_onFlashLoan_fullyClose() public {
        manager.createLoan(2e8, 10_000e18, 4);
        crvUSD.mint(address(manager), 11_000e18);

        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        bytes memory data = abi.encode(type(uint256).max, true);
        llamaManager.onFlashLoan(address(llamaManager), address(crvUSD), 1000e18, 5e18, data);
        vm.stopPrank();
    }

    function test_onFlashLoan_swapShortfall() public {
        manager.createLoan(2e8, 5000e18, 4);
        crvUSD.mint(address(manager), 5000e18);
        wbtc.mint(address(manager), 1e8);

        vm.startPrank(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
        bytes memory data = abi.encode(1e8, false);
        llamaManager.onFlashLoan(address(llamaManager), address(crvUSD), 6000e18, 30e18, data);
        vm.stopPrank();
    }

    // ============ healthCalculator ============

    function test_healthCalculator_withDeltas() public {
        manager.createLoan(1e8, 10_000e18, 4);

        int256 healthBase = manager.healthCalculator(0, 0);
        int256 healthMoreColl = manager.healthCalculator(int256(uint256(1e8)), 0);
        int256 healthLessDebt = manager.healthCalculator(0, -int256(5000e18));

        assertGt(healthBase, 0);
        assertGt(healthMoreColl, 0);
        assertGt(healthLessDebt, 0);
    }

    function test_borrowMore_collateralOnly() public {
        manager.createLoan(1e8, 10_000e18, 4);
        manager.borrowMore(5e7, 0);
        assertEq(manager.getCurrentCollateral(), 1.5e8);
        assertEq(manager.getCurrentDebt(), 10_000e18);
    }

    function test_getCurrentCollateral_noLoan() public view {
        assertEq(manager.getCurrentCollateral(), 0);
    }

    function test_getCurrentDebt_noLoan() public view {
        assertEq(manager.getCurrentDebt(), 0);
    }

    // ============ Constructor Zero-Address Checks ============

    function test_constructor_zeroCollateral_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new LlamaLoanManager(
            address(0),
            address(crvUSD),
            address(llamaLend),
            address(pool),
            address(oracle),
            address(crvUsdOracle),
            address(swapper),
            vault
        );
    }

    function test_constructor_zeroDebt_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new LlamaLoanManager(
            address(wbtc),
            address(0),
            address(llamaLend),
            address(pool),
            address(oracle),
            address(crvUsdOracle),
            address(swapper),
            vault
        );
    }

    function test_constructor_zeroLlamaLend_reverts() public {
        vm.expectRevert(ILoanManager.InvalidAddress.selector);
        new LlamaLoanManager(
            address(wbtc),
            address(crvUSD),
            address(0),
            address(pool),
            address(oracle),
            address(crvUsdOracle),
            address(swapper),
            vault
        );
    }
}
